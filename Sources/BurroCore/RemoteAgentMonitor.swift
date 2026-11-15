// Run a bounded, read-only metadata probe through the user's existing SSH authentication.
// Every SSH call Burro makes (probes, transcripts, replies, machine checks) shares one connection per
// host: Burro's own master socket lives in an owner-only folder and closes 2 minutes after the last use.
import Foundation
import Darwin

public struct RemoteAgentMonitor: Sendable {
    public init() {}
    public static var probeURL: URL { Bundle.module.url(forResource: "remote_probe", withExtension: "py")! }
    public static func arguments(for host: RemoteHost) -> [String] {
        var args = ["-T", "-o", "BatchMode=yes", "-o", "StrictHostKeyChecking=yes", "-o", "ConnectTimeout=5",
                    "-o", "ConnectionAttempts=1", "-o", "ServerAliveInterval=5", "-o", "ServerAliveCountMax=1",
                    "-o", "ClearAllForwardings=yes", "-o", "ForwardAgent=no", "-o", "ForwardX11=no",
                    "-o", "PermitLocalCommand=no", "-o", "LogLevel=ERROR"]
        args += SSHControlSocket.options(directory: SSHControlSocket.directory)
        if let port = host.port { args += ["-p", String(port)] }
        return args + ["--", host.destination, "python3 -"]
    }
    public func sample(_ host: RemoteHost) async -> RemoteHostSnapshot {
        let now = Date()
        guard host.enabled else { return RemoteHostSnapshot(host: host, state: .disabled) }
        if let error = host.validationError { return RemoteHostSnapshot.mergeFailure(host: host, error: error, previous: nil, now: now) }
        guard let input = try? Data(contentsOf: Self.probeURL) else {
            return .mergeFailure(host: host, error: "The remote session reader is missing from this app bundle.", previous: nil, now: now)
        }
        let result = await CommandRunner().run("/usr/bin/ssh", Self.arguments(for: host), timeout: 15, input: input)
        guard result.succeeded else {
            let detail = result.timedOut ? "Connection timed out." : String(result.error.trimmingCharacters(in: .whitespacesAndNewlines).prefix(400))
            return .mergeFailure(host: host, error: detail.isEmpty ? "SSH did not complete. Confirm this host connects in Terminal and has Python 3." : detail, previous: nil, now: Date())
        }
        do { return try Self.decode(Data(result.output.utf8), host: host, receivedAt: Date()) }
        catch { return .mergeFailure(host: host, error: "The remote session response was not supported. Python 3 and readable provider metadata are required.", previous: nil, now: Date()) }
    }
    public static func decode(_ data: Data, host: RemoteHost, receivedAt: Date) throws -> RemoteHostSnapshot {
        struct Response: Decodable { var version: Int; var sessions: [AgentSession]; var warnings: [String] }
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .secondsSince1970
        let response = try decoder.decode(Response.self, from: data)
        guard response.version == 1, response.sessions.count <= 2000 else { throw CocoaError(.coderReadCorrupt) }
        var seen = Set<String>()
        let sessions = response.sessions.filter { seen.insert($0.id).inserted }.map { source in
            var value = source
            value.id = "remote:\(host.id.uuidString):\(source.id)"
            value.parentSessionID = source.parentSessionID.map { "remote:\(host.id.uuidString):\($0)" }
            value.remote = RemoteOrigin(hostID: host.id, hostName: host.name, sampledAt: receivedAt, stale: false)
            return value
        }
        return RemoteHostSnapshot(host: host, sessions: sessions, warnings: response.warnings, sampledAt: receivedAt,
                                  attemptedAt: receivedAt, state: .online)
    }
}

/// OpenSSH connection sharing confined to a folder only this user can reach. Only Burro creates masters
/// there, so every shared connection was opened with Burro's strict options. Each SSH call keeps its own
/// hard timeout, and the master's keepalives (5 s, one miss) end it when the network drops.
public enum SSHControlSocket {
    /// Unix socket paths are limited to 104 bytes (with the terminator). OpenSSH binds the master at
    /// "<path>.<16 random characters>" before renaming it, and `%C` is 40 hex characters.
    public static let maxDirectoryLength = 104 - 1 - (1 + 40 + 1 + 16)
    public static let persistSeconds = 120

    /// Prepared once per run; nil disables sharing (calls then connect individually, as before).
    public static let directory: String? = prepare(candidates: [
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Caches/burro-ssh").path,
        "/tmp/burro-ssh-\(getuid())"])

    public static func options(directory: String?) -> [String] {
        guard let directory else { return [] }
        return ["-o", "ControlMaster=auto", "-o", "ControlPersist=\(persistSeconds)", "-o", "ControlPath=\(directory)/%C"]
    }

    /// The first candidate short enough for a socket path that is (or becomes) a real directory owned by
    /// this user with mode 0700. Anything else, such as a symlink or another user's folder, is skipped.
    public static func prepare(candidates: [String]) -> String? {
        for path in candidates where path.utf8.count <= maxDirectoryLength && !path.contains("%") {
            if mkdir(path, 0o700) != 0 && errno != EEXIST { continue }
            var info = stat()
            guard lstat(path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR, info.st_uid == getuid() else { continue }
            if info.st_mode & 0o077 != 0 && chmod(path, 0o700) != 0 { continue }
            return path
        }
        return nil
    }
}

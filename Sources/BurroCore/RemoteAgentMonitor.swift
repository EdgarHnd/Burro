// Run a bounded, read-only metadata probe through the user's existing SSH authentication.
import Foundation

public struct RemoteAgentMonitor: Sendable {
    public init() {}
    public static var probeURL: URL { Bundle.module.url(forResource: "remote_probe", withExtension: "py")! }
    public static func arguments(for host: RemoteHost) -> [String] {
        var args = ["-T", "-o", "BatchMode=yes", "-o", "StrictHostKeyChecking=yes", "-o", "ConnectTimeout=5",
                    "-o", "ConnectionAttempts=1", "-o", "ServerAliveInterval=5", "-o", "ServerAliveCountMax=1",
                    "-o", "ClearAllForwardings=yes", "-o", "ForwardAgent=no", "-o", "ForwardX11=no",
                    "-o", "PermitLocalCommand=no", "-o", "LogLevel=ERROR"]
        if let port = host.port { args += ["-p", String(port)] }
        return args + ["--", host.destination, "python3 -"]
    }
    public func sample(_ host: RemoteHost) -> RemoteHostSnapshot {
        let now = Date()
        guard host.enabled else { return RemoteHostSnapshot(host: host, state: .disabled) }
        if let error = host.validationError { return RemoteHostSnapshot.mergeFailure(host: host, error: error, previous: nil, now: now) }
        guard let input = try? Data(contentsOf: Self.probeURL) else {
            return .mergeFailure(host: host, error: "The remote session reader is missing from this app bundle.", previous: nil, now: now)
        }
        let result = CommandRunner().run("/usr/bin/ssh", Self.arguments(for: host), timeout: 15, input: input)
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

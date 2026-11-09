// Machines and the agent tools ("harnesses") installed on them. Tailscale lists the devices on
// your tailnet; a fixed, read-only probe reports the OS and each tool's version (locally through
// your login shell, remotely over the same hardened SSH options as remote monitoring); npm's
// public registry gives the latest versions. Updating runs the tool's own updater, only when asked.
import Foundation

public enum Harness: String, CaseIterable, Identifiable, Sendable {
    case claude, codex, opencode, grok, cursor, gemini
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .claude: "Claude Code"; case .codex: "Codex"; case .opencode: "opencode"
        case .grok: "Grok CLI"; case .cursor: "Cursor CLI"; case .gemini: "Gemini CLI"
        }
    }
    public var command: String { self == .cursor ? "cursor-agent" : rawValue }
    /// Public npm package used to learn the latest release, when the tool ships there.
    public var npmPackage: String? {
        switch self {
        case .claude: "@anthropic-ai/claude-code"; case .codex: "@openai/codex"; case .opencode: "opencode-ai"
        case .gemini: "@google/gemini-cli"; case .grok, .cursor: nil
        }
    }
    /// The tool's own self-update command; tools without one show their version only.
    public var updateArguments: [String]? {
        switch self {
        case .claude, .codex, .cursor: ["update"]; case .opencode: ["upgrade"]; case .grok, .gemini: nil
        }
    }
    /// The first dotted version in a `--version` line ("2.1.317 (Claude Code)", "codex-cli 0.166.0").
    public static func parseVersion(_ text: String) -> String? {
        guard let range = text.range(of: #"\d+\.\d+(\.\d+)?([-+.][0-9A-Za-z.]+)?"#, options: .regularExpression) else { return nil }
        let version = String(text[range])
        return version.count <= 40 ? version : nil
    }
    /// Numeric comparison of the leading dotted parts; pre-release suffixes sort before the release.
    public static func isOlder(_ installed: String, than latest: String) -> Bool {
        func parts(_ v: String) -> [Int] {
            v.split(whereSeparator: { !$0.isNumber && $0 != "." }).first.map { $0.split(separator: ".").compactMap { Int($0) } } ?? []
        }
        let a = parts(installed), b = parts(latest)
        for i in 0..<max(a.count, b.count) {
            let x = i < a.count ? a[i] : 0, y = i < b.count ? b[i] : 0
            if x != y { return x < y }
        }
        return installed.contains("-") && !latest.contains("-")
    }
}

public struct MachineFacts: Sendable, Equatable {
    public var os: String?
    public var versions: [Harness: String]
    public var checkedAt: Date
    public init(os: String?, versions: [Harness: String], checkedAt: Date = Date()) {
        self.os = os; self.versions = versions; self.checkedAt = checkedAt
    }
}

public enum MachineProbe {
    /// POSIX sh: no user input is interpolated. Adds the usual per-user tool folders to PATH,
    /// because non-interactive SSH shells often miss them.
    static let pathPrelude = #"""
    for d in "$HOME/.local/bin" "$HOME/.npm-global/bin" "$HOME/.bun/bin" "$HOME/.cargo/bin" /opt/homebrew/bin /usr/local/bin; do
      [ -d "$d" ] && PATH="$PATH:$d"
    done
    for d in "$HOME"/.nvm/versions/node/*/bin; do [ -d "$d" ] && PATH="$PATH:$d"; done
    export PATH

    """#
    static let script = pathPrelude + #"""
    if [ "$(uname -s)" = Darwin ]; then printf 'os=macOS %s\n' "$(sw_vers -productVersion 2>/dev/null)"
    elif [ -r /etc/os-release ]; then printf 'os=%s\n' "$(. /etc/os-release; printf '%s' "${PRETTY_NAME:-$NAME}")"
    else printf 'os=%s %s\n' "$(uname -s)" "$(uname -r)"; fi
    for t in claude codex opencode grok cursor-agent gemini; do
      if command -v "$t" >/dev/null 2>&1; then printf '%s=%s\n' "$t" "$("$t" --version 2>/dev/null </dev/null | head -n 1)"; fi
    done
    """#

    public static func parse(_ output: String, checkedAt: Date = Date()) -> MachineFacts {
        var os: String?, versions: [Harness: String] = [:]
        for line in output.split(whereSeparator: \.isNewline).prefix(64) {
            guard let equals = line.firstIndex(of: "=") else { continue }
            let key = String(line[..<equals]), value = String(line[line.index(after: equals)...]).trimmingCharacters(in: .whitespaces)
            if key == "os" { os = value.isEmpty ? nil : String(value.prefix(60)); continue }
            guard let harness = Harness.allCases.first(where: { $0.command == key }), let version = Harness.parseVersion(value) else { continue }
            versions[harness] = version
        }
        return MachineFacts(os: os, versions: versions, checkedAt: checkedAt)
    }

    /// This Mac, through your login shell (so tools on your usual PATH are found).
    public static func local() -> MachineFacts? {
        let result = CommandRunner().run("/bin/zsh", ["-lc", script], timeout: 30)
        return result.timedOut ? nil : parse(result.output)
    }

    public static func remote(_ host: RemoteHost) -> MachineFacts? {
        guard host.enabled, host.validationError == nil else { return nil }
        let result = CommandRunner().run("/usr/bin/ssh", sshArguments(for: host, command: "sh -s"), timeout: 30, input: Data(script.utf8))
        return result.succeeded ? parse(result.output) : nil
    }

    /// Remote monitoring's hardened options with a different fixed remote command.
    static func sshArguments(for host: RemoteHost, command: String) -> [String] {
        var args = RemoteAgentMonitor.arguments(for: host)
        args.removeLast() // "python3 -"
        return args + [command]
    }
}

public enum HarnessUpdate {
    /// Runs the tool's own updater (e.g. `claude update`) on this Mac or over SSH. Explicit action only.
    public static func run(_ harness: Harness, on host: RemoteHost?) throws -> String {
        guard let arguments = harness.updateArguments else { throw LaunchError.failed("\(harness.title) has no built-in updater.") }
        let output: String, ok: Bool
        if let host {
            // Command and arguments are fixed per tool; nothing user-supplied reaches the remote shell.
            let script = MachineProbe.pathPrelude + "exec \(harness.command) \(arguments.joined(separator: " "))\n"
            let result = CommandRunner().run("/usr/bin/ssh", MachineProbe.sshArguments(for: host, command: "sh -s"), timeout: 300, input: Data(script.utf8))
            output = result.output + result.error; ok = result.succeeded
        } else {
            let result = try LaunchShell.run(harness.command, arguments, timeout: 300)
            output = result.text; ok = result.code == 0
        }
        let last = output.split(whereSeparator: \.isNewline).last.map(String.init)?.trimmingCharacters(in: .whitespaces) ?? ""
        guard ok else { throw LaunchError.failed("\(harness.title) update failed\(last.isEmpty ? "." : ": \(last.prefix(200))")") }
        return last
    }
}

// MARK: Latest versions

public enum HarnessReleases {
    /// Latest published versions from the public npm registry (no credentials, no cookies).
    public static func latest(session: URLSession = .shared) async -> [Harness: String] {
        await withTaskGroup(of: (Harness, String?).self) { group in
            for harness in Harness.allCases {
                guard let package = harness.npmPackage else { continue }
                group.addTask {
                    let name = package.replacingOccurrences(of: "/", with: "%2F")
                    guard let url = URL(string: "https://registry.npmjs.org/\(name)/latest") else { return (harness, nil) }
                    var request = URLRequest(url: url, timeoutInterval: 10)
                    request.setValue("application/json", forHTTPHeaderField: "Accept")
                    request.httpShouldHandleCookies = false
                    guard let (data, response) = try? await session.data(for: request), (response as? HTTPURLResponse)?.statusCode == 200,
                          data.count < 1_000_000,
                          let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                          let version = (object["version"] as? String).flatMap(Harness.parseVersion) else { return (harness, nil) }
                    return (harness, version)
                }
            }
            var result: [Harness: String] = [:]
            for await (harness, version) in group { if let version { result[harness] = version } }
            return result
        }
    }
}

// MARK: Tailscale

public struct TailscalePeer: Identifiable, Sendable, Equatable {
    public var id: String
    public var hostName: String
    public var dnsName: String?
    public var os: String
    public var online: Bool
    public var lastSeen: Date?
    public var isSelf: Bool
}

public enum Tailscale {
    public static func executable(exists: (String) -> Bool = FileManager.default.isExecutableFile(atPath:)) -> String? {
        ["/Applications/Tailscale.app/Contents/MacOS/Tailscale", "/opt/homebrew/bin/tailscale", "/usr/local/bin/tailscale"].first(where: exists)
    }
    /// `tailscale status --json`, keeping names, OS and presence only (no addresses or keys).
    public static func peers(executable: String? = executable()) -> [TailscalePeer]? {
        guard let executable else { return nil }
        let result = CommandRunner().run(executable, ["status", "--json"], timeout: 6)
        guard result.succeeded else { return nil }
        return parse(Data(result.output.utf8))
    }
    static func parse(_ data: Data) -> [TailscalePeer]? {
        guard data.count < 8 * 1024 * 1024, let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        func peer(_ row: [String: Any], isSelf: Bool) -> TailscalePeer? {
            guard let id = row["ID"] as? String ?? row["PublicKey"] as? String, let name = row["HostName"] as? String else { return nil }
            let dns = (row["DNSName"] as? String).map { $0.hasSuffix(".") ? String($0.dropLast()) : $0 }.flatMap { $0.isEmpty ? nil : $0 }
            let seen = (row["LastSeen"] as? String).flatMap { iso.date(from: $0) ?? ISO8601DateFormatter().date(from: $0) }
            return TailscalePeer(id: String(id.prefix(80)), hostName: String(name.prefix(80)), dnsName: dns.map { String($0.prefix(200)) },
                                 os: String((row["OS"] as? String ?? "").prefix(40)), online: isSelf || row["Online"] as? Bool == true,
                                 lastSeen: seen.flatMap { $0.timeIntervalSince1970 > 0 ? $0 : nil }, isSelf: isSelf)
        }
        var peers: [TailscalePeer] = []
        if let me = object["Self"] as? [String: Any], let value = peer(me, isSelf: true) { peers.append(value) }
        for row in (object["Peer"] as? [String: [String: Any]] ?? [:]).values.prefix(500) {
            if let value = peer(row, isSelf: false) { peers.append(value) }
        }
        return peers.sorted { ($0.isSelf ? 0 : 1, $0.online ? 0 : 1, $0.hostName.lowercased()) < ($1.isSelf ? 0 : 1, $1.online ? 0 : 1, $1.hostName.lowercased()) }
    }
}

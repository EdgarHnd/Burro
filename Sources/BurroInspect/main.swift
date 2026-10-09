// Inspect the same live snapshot as the app without launching a window.
import Foundation
import BurroCore

@main struct BurroInspect {
    static func main() async throws {
        let paths = Array(CommandLine.arguments.dropFirst())
        if paths.first == "--profile" || paths.first == "--profile-agents" {
            try PerformanceProfile.run(includeUsage: paths.first == "--profile")
            return
        }
        if paths == ["--agents"] {
            let activity = AgentMonitor().sample()
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]; encoder.dateEncodingStrategy = .iso8601
            struct Output: Encodable { var sessions: [AgentSession]; var warnings: [String] }
            FileHandle.standardOutput.write(try encoder.encode(Output(sessions: activity.visibleSessions(includeIdle: true), warnings: activity.warnings)))
            return
        }
        let snapshot = await Scanner().scan(ScanConfiguration(repositories: paths, discover: paths.isEmpty))
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]; encoder.dateEncodingStrategy = .iso8601
        FileHandle.standardOutput.write(try encoder.encode(snapshot))
        FileHandle.standardOutput.write(Data("\n".utf8))
    }
}

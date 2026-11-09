// burro-mcp: Burro's tool server for the orchestrator chat. Claude Code starts it over stdio
// (newline-delimited JSON-RPC); it answers from the snapshot Burro writes at $BURRO_STATE.
import Foundation
import BurroCore

let stateURL = ProcessInfo.processInfo.environment["BURRO_STATE"].map { URL(fileURLWithPath: $0) } ?? Orchestrator.stateURL
let tools = OrchestratorTools(stateURL: stateURL)
while let line = readLine(strippingNewline: true) {
    guard !line.isEmpty, let message = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else { continue }
    guard let reply = tools.handle(message),
          let data = try? JSONSerialization.data(withJSONObject: reply, options: [.withoutEscapingSlashes]) else { continue }
    FileHandle.standardOutput.write(data + Data([0x0A]))
}

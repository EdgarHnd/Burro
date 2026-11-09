// Validate the packaged resources through Foundation, independent of SwiftPM bundle layout.
import Foundation

let app = URL(fileURLWithPath: CommandLine.arguments[1])
guard let bundle = Bundle(url: app),
      let executable = bundle.executableURL,
      FileManager.default.isExecutableFile(atPath: executable.path),
      FileManager.default.isExecutableFile(atPath: executable.deletingLastPathComponent().appendingPathComponent("burro-log-worker").path),
      FileManager.default.isExecutableFile(atPath: executable.deletingLastPathComponent().appendingPathComponent("burro-mcp").path),
      let name = bundle.object(forInfoDictionaryKey: "CFBundleIconFile") as? String,
      bundle.url(forResource: name, withExtension: "icns") != nil,
      let resources = bundle.resourceURL,
      let brand = Bundle(url: resources.appendingPathComponent("Burro_Burro.bundle")),
      brand.url(forResource: "butter", withExtension: "pdf", subdirectory: "Brand") != nil,
      brand.url(forResource: "butter-body", withExtension: "pdf", subdirectory: "Brand") != nil,
      brand.url(forResource: "butter-plate", withExtension: "pdf", subdirectory: "Brand") != nil,
      brand.url(forResource: "butter-eyes", withExtension: "json", subdirectory: "Brand") != nil,
      brand.url(forResource: "abstract", withExtension: "pdf", subdirectory: "Brand") != nil,
      let core = Bundle(url: resources.appendingPathComponent("Burro_BurroCore.bundle")),
      let probe = core.url(forResource: "remote_probe", withExtension: "py"),
      FileManager.default.isReadableFile(atPath: probe.path),
      let transcript = core.url(forResource: "remote_transcript", withExtension: "py"),
      FileManager.default.isReadableFile(atPath: transcript.path),
      core.url(forResource: "remote_media", withExtension: "py") != nil,
      core.url(forResource: "remote_reply", withExtension: "py") != nil else {
    fputs("App bundle is missing its executable, Rust log worker, orchestrator tools, icon, brand assets, or remote scripts.\n", stderr)
    exit(1)
}
print("Bundle resources verified")

// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Burro",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "Burro", targets: ["Burro"]),
               .executable(name: "burro-inspect", targets: ["BurroInspect"]),
               .executable(name: "burro-mcp", targets: ["BurroMCP"])],
    targets: [
        .target(name: "CSystem", linkerSettings: [.linkedLibrary("proc"), .linkedLibrary("sqlite3")]),
        .target(name: "BurroCore", dependencies: ["CSystem"], resources: [.copy("Resources/remote_probe.py"), .copy("Resources/remote_transcript.py"),
                                                                   .copy("Resources/remote_media.py"), .copy("Resources/remote_reply.py")]),
        .executableTarget(name: "Burro", dependencies: ["BurroCore"], resources: [.copy("Resources/Brand")],
                          linkerSettings: [.linkedFramework("AVKit")]),
        .executableTarget(name: "BurroInspect", dependencies: ["BurroCore"]),
        .executableTarget(name: "BurroMCP", dependencies: ["BurroCore"]),
        .testTarget(name: "BurroCoreTests", dependencies: ["BurroCore", "Burro"])
    ]
)

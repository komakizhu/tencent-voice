// swift-tools-version: 5.10
import PackageDescription

// Offline harness: compiles unchanged production writer sources plus replay tests.
// This does not build the application or its unrelated MCP/network dependencies.
let package = Package(
    name: "AXTransactionReplay",
    platforms: [.macOS(.v13)],
    targets: [
        .target(name: "TencentVoiceMVP"),
        .testTarget(name: "AXTransactionReplayTests", dependencies: ["TencentVoiceMVP"])
    ]
)

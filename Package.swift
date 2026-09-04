// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "TencentVoiceMVP",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "TencentVoiceMVP", targets: ["TencentVoiceMVP"]),
        .library(name: "RimeSyncCore", targets: ["RimeSyncCore"]),
        .executable(name: "RimeSync", targets: ["RimeSync"]),
        .executable(name: "RimeAuditMCP", targets: ["RimeAuditMCP"])
    ],
    dependencies: [
        .package(url: "https://github.com/modelcontextprotocol/swift-sdk.git", from: "0.11.0")
    ],
    targets: [
        .executableTarget(
            name: "TencentVoiceMVP",
            dependencies: ["RimeSyncCore"],
            path: "Sources/TencentVoiceMVP"
        ),
        .target(
            name: "RimeSyncCore",
            path: "Sources/RimeSyncCore"
        ),
        .executableTarget(
            name: "RimeSync",
            dependencies: ["RimeSyncCore"],
            path: "Sources/RimeSync"
        ),
        .executableTarget(
            name: "RimeAuditMCP",
            dependencies: [
                "RimeSyncCore",
                .product(name: "MCP", package: "swift-sdk")
            ],
            path: "Sources/RimeAuditMCP"
        ),
        .testTarget(
            name: "TencentVoiceMVPTests",
            dependencies: ["TencentVoiceMVP"],
            path: "Tests/TencentVoiceMVP"
        ),
        .testTarget(
            name: "RimeSyncCoreTests",
            dependencies: ["RimeSyncCore"],
            path: "Tests/RimeSyncCore"
        )
    ]
)

// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "TencentVoiceMVP",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "TencentVoiceMVP", targets: ["TencentVoiceMVP"]),
        .library(name: "RimeSyncCore", targets: ["RimeSyncCore"]),
        .executable(name: "RimeSync", targets: ["RimeSync"])
    ],
    targets: [
        .executableTarget(
            name: "TencentVoiceMVP",
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

// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "TencentVoiceMVP",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "TencentVoiceMVP", targets: ["TencentVoiceMVP"])
    ],
    targets: [
        .executableTarget(
            name: "TencentVoiceMVP",
            path: "Sources/TencentVoiceMVP"
        ),
        .testTarget(
            name: "TencentVoiceMVPTests",
            dependencies: ["TencentVoiceMVP"],
            path: "Tests/TencentVoiceMVP"
        )
    ]
)

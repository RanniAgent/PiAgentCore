// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "PiAgentCore",
    platforms: [.iOS(.v17), .macOS(.v14)],   // 待拍板项 1，先按草案
    products: [
        .library(name: "PiAgentCore", targets: ["PiAgentCore"]),
        .library(name: "PiAgentHarness", targets: ["PiAgentHarness"]),
        .library(name: "PiAgentTestSupport", targets: ["PiAgentTestSupport"]),
    ],
    targets: [
        .target(name: "PiAgentCore"),
        .target(name: "PiAgentHarness", dependencies: ["PiAgentCore"]),
        .target(name: "PiAgentTestSupport", dependencies: ["PiAgentCore"]),
        .testTarget(
            name: "PiAgentCoreTests",
            dependencies: ["PiAgentCore", "PiAgentTestSupport"],
            resources: [.copy("Fixtures")]
        ),
        .testTarget(name: "PiAgentHarnessTests", dependencies: ["PiAgentHarness"]),
    ]
)

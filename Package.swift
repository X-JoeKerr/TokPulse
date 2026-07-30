// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "TokPulse",
    platforms: [
        .macOS(.v13),
    ],
    products: [
        .executable(name: "TokPulse", targets: ["TokPulseApp"]),
        .executable(name: "tokpulse-cli", targets: ["TokPulseCLI"]),
        .library(name: "TokPulseProtocol", targets: ["TokPulseProtocol"]),
        .library(name: "TokPulseCore", targets: ["TokPulseCore"]),
    ],
    targets: [
        .target(name: "TokPulseProtocol"),
        .target(
            name: "TokPulseCore",
            dependencies: ["TokPulseProtocol"]
        ),
        .executableTarget(
            name: "TokPulseApp",
            dependencies: ["TokPulseProtocol"]
        ),
        .executableTarget(
            name: "TokPulseCLI",
            dependencies: ["TokPulseCore", "TokPulseProtocol"]
        ),
        .testTarget(
            name: "TokPulseCoreTests",
            dependencies: ["TokPulseCore", "TokPulseProtocol"]
        ),
    ]
)

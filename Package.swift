// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "TokPulse",
    platforms: [
        .macOS(.v13),
    ],
    products: [
        .executable(name: "TokPulse", targets: ["TokPulseApp"]),
        .library(name: "TokPulseCore", targets: ["TokPulseCore"]),
    ],
    targets: [
        .target(name: "TokPulseCore"),
        .executableTarget(
            name: "TokPulseApp",
            dependencies: ["TokPulseCore"]
        ),
        .testTarget(
            name: "TokPulseCoreTests",
            dependencies: ["TokPulseCore"]
        ),
    ]
)


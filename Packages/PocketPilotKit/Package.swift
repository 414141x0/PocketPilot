// swift-tools-version: 6.4
import PackageDescription

let settings: [SwiftSetting] = [
    .enableUpcomingFeature("NonisolatedNonsendingByDefault"),
    .enableUpcomingFeature("InferIsolatedConformances"),
    .enableUpcomingFeature("ExistentialAny"),
    .enableUpcomingFeature("MemberImportVisibility"),
]

let package = Package(
    name: "PocketPilotKit",
    platforms: [.iOS(.v27), .macOS(.v27)],
    products: [
        .library(name: "AgentCore", targets: ["AgentCore"]),
        .library(name: "DeviceLink", targets: ["DeviceLink"]),
        .library(name: "MLXPilot", targets: ["MLXPilot"]),
        .library(name: "OpenAIPilot", targets: ["OpenAIPilot"]),
        .library(name: "GeminiPilot", targets: ["GeminiPilot"]),
        .library(name: "PilotSchema", targets: ["PilotSchema"]),
        .library(name: "SystemPilot", targets: ["SystemPilot"]),
        .library(name: "RunActivity", targets: ["RunActivity"]),
    ],
    dependencies: [
        .package(url: "https://github.com/MacPaw/OpenAI.git", from: "0.5.1"),
        .package(
            url: "https://github.com/ml-explore/mlx-swift-lm.git",
            revision: "ee673d6a71d76e67b532dc7eaf91d92edc3bb8bb"
        ),
        .package(url: "https://github.com/huggingface/swift-huggingface.git", exact: "0.9.0"),
        .package(url: "https://github.com/huggingface/swift-transformers.git", exact: "1.3.0"),
    ],
    targets: [
        .target(
            name: "AgentCore",
            resources: [.process("EvalSuite.json")],
            swiftSettings: settings
        ),
        .target(name: "DeviceLink", dependencies: ["AgentCore", "PilotBridge"], swiftSettings: settings),
        // Built by Scripts/build-xcframework.sh.
        .binaryTarget(name: "PilotBridge", path: "Frameworks/PilotBridge.xcframework"),
        .target(
            name: "MLXPilot",
            dependencies: [
                "AgentCore",
                "PilotSchema",
                .product(name: "HuggingFace", package: "swift-huggingface"),
                .product(name: "Tokenizers", package: "swift-transformers"),
                .product(name: "MLXFoundationModels", package: "mlx-swift-lm"),
                .product(name: "MLXLMCommon", package: "mlx-swift-lm"),
                .product(name: "MLXVLM", package: "mlx-swift-lm"),
            ],
            swiftSettings: settings
        ),
        .target(
            name: "OpenAIPilot",
            dependencies: [
                "AgentCore",
                .product(name: "OpenAI", package: "OpenAI"),
            ],
            swiftSettings: settings
        ),
        .target(
            name: "GeminiPilot",
            dependencies: ["AgentCore"],
            swiftSettings: settings
        ),
        .target(
            name: "PilotSchema",
            dependencies: ["AgentCore"],
            swiftSettings: settings
        ),
        .target(
            name: "SystemPilot",
            dependencies: ["AgentCore", "PilotSchema"],
            swiftSettings: settings
        ),
        .target(name: "RunActivity", swiftSettings: settings),
        .testTarget(name: "AgentCoreTests", dependencies: ["AgentCore"], swiftSettings: settings),
        .testTarget(name: "DeviceLinkTests", dependencies: ["DeviceLink"], swiftSettings: settings),
        .testTarget(
            name: "MLXPilotTests",
            dependencies: ["MLXPilot", "PilotSchema", "SystemPilot"],
            swiftSettings: settings
        ),
        .testTarget(name: "OpenAIPilotTests", dependencies: ["OpenAIPilot"], swiftSettings: settings),
        .testTarget(name: "GeminiPilotTests", dependencies: ["GeminiPilot"], swiftSettings: settings),
        .testTarget(name: "PilotSchemaTests", dependencies: ["PilotSchema"], swiftSettings: settings),
        .testTarget(
            name: "SystemPilotTests",
            dependencies: ["PilotSchema", "SystemPilot"],
            swiftSettings: settings
        ),
        .testTarget(name: "RunActivityTests", dependencies: ["RunActivity"], swiftSettings: settings),
    ]
)

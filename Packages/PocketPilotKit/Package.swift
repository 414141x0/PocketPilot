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
        .library(name: "OpenAIPilot", targets: ["OpenAIPilot"]),
        .library(name: "GeminiPilot", targets: ["GeminiPilot"]),
        .library(name: "PilotSchema", targets: ["PilotSchema"]),
        .library(name: "SystemPilot", targets: ["SystemPilot"]),
        .library(name: "RunActivity", targets: ["RunActivity"]),
    ],
    dependencies: [
        .package(url: "https://github.com/MacPaw/OpenAI.git", from: "0.5.1"),
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

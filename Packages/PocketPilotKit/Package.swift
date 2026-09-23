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
    ],
    targets: [
        .target(name: "AgentCore", swiftSettings: settings),
        .testTarget(name: "AgentCoreTests", dependencies: ["AgentCore"], swiftSettings: settings),
    ]
)

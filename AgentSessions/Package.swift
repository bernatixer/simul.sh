// swift-tools-version: 6.0
import PackageDescription

/// Logic-only package used for tests of the parts that can regress
/// (models, persistence, tmux command generation).
///
/// The full app target is built by scripts/build-app.sh (no xcodeproj).
/// Tests are a plain executable (not a test bundle) so they run on
/// CLT-only machines where XCTest/swift-testing runners are unavailable:
/// `swift run AgentSessionsTests`
let package = Package(
    name: "AgentSessions",
    targets: [
        .target(
            name: "AgentSessionsCore",
            path: ".",
            exclude: [
                "App",
                "State",
                "Terminal",
                "UI",
                "Vendor",
                "Build",
                "scripts",
                "Support/Info.plist",
                "Tests",
                "README.md",
                "Package.swift",
            ],
            sources: [
                "Models",
                "Persistence",
                "Sessions",
                "Support",
            ]
        ),
        .executableTarget(
            name: "AgentSessionsTests",
            dependencies: ["AgentSessionsCore"],
            path: "Tests"
        ),
    ]
)

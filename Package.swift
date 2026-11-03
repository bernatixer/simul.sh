// swift-tools-version: 6.0
import PackageDescription

/// Logic-only package used for tests of the parts that can regress
/// (models, persistence, tmux command generation).
///
/// The full app target is built by scripts/build-app.sh (no xcodeproj).
/// Tests are a plain executable (not a test bundle) so they run on
/// CLT-only machines where XCTest/swift-testing runners are unavailable:
/// `swift run SimulTests`
let package = Package(
    name: "Simul",
    targets: [
        .target(
            name: "SimulCore",
            dependencies: ["CTreeSitter"],
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
                "Support/TreeSitter",
                "Tests",
                "Resources",
                "site",
                "README.md",
                "LICENSE",
                "Package.swift",
            ],
            sources: [
                "Models",
                "Persistence",
                "Sessions",
                "Support",
            ]
        ),
        // tree-sitter core + grammars, vendored by scripts/fetch-tree-sitter.sh.
        // Each grammar's parser.c finds its own tree_sitter/parser.h next to it.
        .target(
            name: "CTreeSitter",
            path: ".",
            exclude: ["Build", "Vendor/Ghostty", "Vendor/zig"],
            sources: [
                "Vendor/tree-sitter/core/lib/src/lib.c",
                "Vendor/tree-sitter/python/src/parser.c",
                "Vendor/tree-sitter/python/src/scanner.c",
                "Vendor/tree-sitter/javascript/src/parser.c",
                "Vendor/tree-sitter/javascript/src/scanner.c",
                "Vendor/tree-sitter/typescript/typescript/src/parser.c",
                "Vendor/tree-sitter/typescript/typescript/src/scanner.c",
                "Vendor/tree-sitter/typescript/tsx/src/parser.c",
                "Vendor/tree-sitter/typescript/tsx/src/scanner.c",
            ],
            publicHeadersPath: "Support/TreeSitter",
            cSettings: [
                .headerSearchPath("Vendor/tree-sitter/core/lib/src"),
                .headerSearchPath("Vendor/tree-sitter/core/lib/include"),
                .define("_POSIX_C_SOURCE", to: "200112L"),
                .define("_DEFAULT_SOURCE"),
                .define("_DARWIN_C_SOURCE"),
                .unsafeFlags(["-w"]),
            ]
        ),
        .executableTarget(
            name: "SimulTests",
            dependencies: ["SimulCore", "CTreeSitter"],
            path: "Tests"
        ),
    ]
)

// swift-tools-version:5.10
// esclop — free-software image, video, PDF and clipboard optimiser for macOS.
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import PackageDescription

// SwiftUI needs Xcode's macro plugins; the Command Line Tools alone cannot compile the app.
// Everything else (CLI, MCP, engines, pipelines) builds without Xcode, so the app target only
// joins the package when the active developer directory is an Xcode (DEVELOPER_DIR, else the
// one `xcode-select` chose) or ESCLOP_WITH_APP is set. Having Xcode installed is not enough:
// with the Command Line Tools selected, the SwiftUI macro plugins are still missing.
let environment = ProcessInfo.processInfo.environment
let developerDir = environment["DEVELOPER_DIR"]
    ?? (try? FileManager.default.destinationOfSymbolicLink(atPath: "/var/db/xcode_select_link"))
    ?? ""
let buildApp = developerDir.contains(".app/") || environment["ESCLOP_WITH_APP"] != nil

let appProducts: [Product] = buildApp ? [.executable(name: "EsclopApp", targets: ["EsclopApp"])] : []
let appDependencies: [Package.Dependency] = buildApp
    ? [
        .package(url: "https://github.com/sindresorhus/KeyboardShortcuts", from: "2.2.0"),
        // Updates: an appcast and EdDSA-signed DMGs (docs/release.md › Updates).
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.10.1"),
    ] : []
let appSwiftSettings: [SwiftSetting] = [.enableExperimentalFeature("StrictConcurrency")]
let appTargets: [Target] = buildApp ? [
    // Menu bar app: clipboard watcher, floating results, drop zone, hotkeys, IPC server side.
    // Everything but the entry point lives in EsclopAppKit so tests and renders can reach it.
    .target(
        name: "EsclopAppKit",
        dependencies: [
            "EsclopCore", "EsclopIPC", "EsclopPipelines", "EsclopOptimisers", "EsclopMCP",
            .product(name: "KeyboardShortcuts", package: "KeyboardShortcuts"),
            .product(name: "Sparkle", package: "Sparkle"),
        ],
        // MenuBarIcon.pdf: the menu bar glyph, generated from assets/menubar.svg (make icons).
        resources: [.process("Resources")],
        swiftSettings: appSwiftSettings
    ),
    .executableTarget(
        name: "EsclopApp", dependencies: ["EsclopAppKit"], swiftSettings: appSwiftSettings,
        // Sparkle.framework sits in Contents/Frameworks of the bundle (Scripts/bundle-app.sh).
        linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])]
    ),
    .testTarget(name: "EsclopAppTests", dependencies: ["EsclopAppKit"], swiftSettings: appSwiftSettings),
] : []

let package = Package(
    name: "esclop",
    defaultLocalization: "en",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "esclop", targets: ["esclop"]),
        .library(name: "EsclopCore", targets: ["EsclopCore"]),
        .library(name: "EsclopOptimisers", targets: ["EsclopOptimisers"]),
        .library(name: "EsclopPipelines", targets: ["EsclopPipelines"]),
        .library(name: "EsclopIPC", targets: ["EsclopIPC"]),
        .library(name: "EsclopMCP", targets: ["EsclopMCP"]),
    ] + appProducts,
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.5.0"),
        .package(url: "https://github.com/modelcontextprotocol/swift-sdk.git", exact: "0.12.1"),
    ] + appDependencies,
    targets: [
        // Shared models, errors, settings registry, process runner, binary locator, logging.
        .target(name: "EsclopCore"),

        // Image / video / PDF / audio / GIF engines built on the bundled tools and Apple frameworks.
        .target(name: "EsclopOptimisers", dependencies: ["EsclopCore"]),

        // Pipeline model, text DSL parser and executor.
        .target(name: "EsclopPipelines", dependencies: ["EsclopCore", "EsclopOptimisers"]),

        // App <-> CLI protocol (message ports), request/response payloads.
        .target(name: "EsclopIPC", dependencies: ["EsclopCore"]),

        // MCP server: tools, resources, prompts, agent installers.
        .target(
            name: "EsclopMCP",
            dependencies: [
                "EsclopCore", "EsclopIPC", "EsclopPipelines", "EsclopOptimisers",
                .product(name: "MCP", package: "swift-sdk"),
            ]
        ),

        // Command line: `esclop optimise|convert|crop|pipeline|settings|mcp serve ...`
        .executableTarget(
            name: "esclop",
            dependencies: [
                "EsclopCore", "EsclopIPC", "EsclopPipelines", "EsclopOptimisers", "EsclopMCP",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ]
        ),

        .testTarget(name: "EsclopCoreTests", dependencies: ["EsclopCore"]),
        .testTarget(name: "EsclopOptimisersTests", dependencies: ["EsclopCore", "EsclopOptimisers"]),
        .testTarget(name: "EsclopPipelinesTests", dependencies: ["EsclopPipelines"]),
        .testTarget(name: "EsclopIPCTests", dependencies: ["EsclopIPC"]),
        .testTarget(
            name: "EsclopMCPTests",
            dependencies: ["EsclopMCP", "EsclopIPC", "EsclopPipelines", .product(name: "MCP", package: "swift-sdk")]
        ),
        // CLI parsing and the end-to-end MCP conformance test against the built `esclop` binary.
        .testTarget(name: "esclopTests", dependencies: ["esclop", "EsclopIPC", "EsclopMCP"]),
    ] + appTargets
)

// swift-tools-version: 6.2
import Foundation
import PackageDescription

// Linux-only package that compiles and tests Broom's scanner and models outside Xcode.
// The app's sources are symlinked into Sources/Broom and Tests/BroomTests; see README.md.
//
// Settings mirror the Xcode project: Swift 5 mode, MainActor default isolation, approachable
// concurrency, member import visibility. BROOM_STRICT=1 switches to the Swift 6 language mode.
let strict = ProcessInfo.processInfo.environment["BROOM_STRICT"] == "1"
let mode: SwiftLanguageMode = strict ? .v6 : .v5

var approachable: [SwiftSetting] = [
    .enableUpcomingFeature("NonisolatedNonsendingByDefault"),
    .enableUpcomingFeature("InferIsolatedConformances"),
    .enableUpcomingFeature("MemberImportVisibility"),
    .swiftLanguageMode(mode),
]
if !strict {
    // Part of approachable concurrency, and already on by default in Swift 6.
    approachable += [
        .enableUpcomingFeature("InferSendableFromCaptures"),
        .enableUpcomingFeature("GlobalActorIsolatedTypesUsability"),
        .enableUpcomingFeature("DisableOutwardActorInference"),
    ]
}

let package = Package(
    name: "BroomHarness",
    targets: [
        .target(name: "CFTS", path: "Shims/CFTS"),
        .target(name: "DarwinShim", dependencies: ["CFTS"], path: "Shims/DarwinShim"),
        .target(name: "CoreGraphics", path: "Shims/CoreGraphics"),
        .target(
            name: "Broom",
            dependencies: ["DarwinShim", "CoreGraphics"],
            path: "Sources/Broom",
            // `import Darwin` in the app's sources resolves to the shim.
            swiftSettings: [.defaultIsolation(MainActor.self)] + approachable
                + [.unsafeFlags(["-module-alias", "Darwin=DarwinShim"])]
        ),
        // Benchmark/main.swift built with the scanner sources, as Benchmark/run.sh does on macOS.
        .executableTarget(
            name: "Bench",
            dependencies: ["DarwinShim"],
            path: "Bench",
            swiftSettings: [.defaultIsolation(MainActor.self)] + approachable
                + [.unsafeFlags(["-module-alias", "Darwin=DarwinShim"])]
        ),
        .executableTarget(
            name: "Stress",
            dependencies: ["Broom", "DarwinShim"],
            path: "Stress",
            swiftSettings: approachable
        ),
        .testTarget(
            name: "BroomTests",
            dependencies: ["Broom", "CoreGraphics"],
            path: "Tests/BroomTests",
            // Our fake CoreGraphics module would otherwise pull in Swift Testing's CG overlay.
            swiftSettings: approachable + [.unsafeFlags(["-Xfrontend", "-disable-cross-import-overlays"])]
        ),
    ]
)

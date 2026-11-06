// swift-tools-version: 6.0
import PackageDescription

// Hostless native composition checks: the application entry point is excluded.
let package = Package(
    name: "StashMacChecks",
    platforms: [.macOS(.v14)],
    dependencies: [.package(path: "StashCore")],
    targets: [
        .target(name: "StashMac", dependencies: [.product(name: "StashCore", package: "StashCore")],
                path: "StashMac", exclude: ["StashApp.swift", "Assets.xcassets"]),
        .testTarget(name: "StashMacTests", dependencies: ["StashMac"], path: "Tests/StashMacTests")
    ]
)

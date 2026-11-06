// swift-tools-version: 6.0
import PackageDescription
let package = Package(name: "StashCore", platforms: [.macOS(.v14), .iOS(.v17)], products: [.library(name: "StashCore", targets: ["StashCore"])], targets: [.systemLibrary(name: "CSQLite"), .target(name: "StashCore", dependencies: ["CSQLite"]), .testTarget(name: "StashCoreTests", dependencies: ["StashCore"])])

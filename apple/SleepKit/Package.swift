// swift-tools-version:5.9
import PackageDescription
import Foundation

// MARK: - Optional Rust FFI target
//
// The `SleepCoreFFI` binary target is added only when the xcframework produced
// by `scripts/build_rust_xcframework.sh` is present on disk, and when the
// swift-bridge generated Swift file has been copied into `Sources/SleepKit/Generated/`
// by `scripts/gen_bindings.sh`.
//
// This keeps `swift build` working out-of-the-box (pure Swift scaffold) and
// flips on the Rust bridge automatically once both artefacts exist.

let fm = FileManager.default
let packageRoot = (#filePath as NSString).deletingLastPathComponent
let xcframeworkPath = "\(packageRoot)/../../rust/target-xcframework/SleepCore.xcframework"
let generatedSwift  = "\(packageRoot)/Sources/SleepKit/Generated/SleepCore.swift"

let rustAvailable =
    fm.fileExists(atPath: xcframeworkPath) &&
    fm.fileExists(atPath: generatedSwift)

var sleepKitDeps: [Target.Dependency] = []
var sleepKitSettings: [SwiftSetting] = []
var extraTargets: [Target] = []

if rustAvailable {
    sleepKitDeps.append(.target(name: "SleepCoreFFI"))
    sleepKitSettings.append(.define("SLEEPKIT_USE_RUST"))
    extraTargets.append(
        .binaryTarget(
            name: "SleepCoreFFI",
            path: "../../rust/target-xcframework/SleepCore.xcframework"
        )
    )
}

let package = Package(
    name: "SleepKit",
    platforms: [
        .iOS(.v17),
        .watchOS(.v10),
        .macOS(.v14)
    ],
    products: [
        .library(name: "SleepKit", targets: ["SleepKit"]),
    ],
    targets: [
        .target(
            name: "SleepKit",
            dependencies: sleepKitDeps,
            path: "Sources/SleepKit",
            swiftSettings: sleepKitSettings
        ),
        .testTarget(
            name: "SleepKitTests",
            dependencies: ["SleepKit"],
            path: "Tests/SleepKitTests"
        ),
    ] + extraTargets
)

// swift-tools-version: 6.0
import PackageDescription

// One umbrella product so later phases can add targets without touching the
// Xcode project — the app depends on `HaloCore`, and new targets join here.
let package = Package(
    name: "HaloCore",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "HaloCore", targets: ["HaloCapture"])
    ],
    targets: [
        .target(name: "HaloCapture"),
        .testTarget(name: "HaloCaptureTests", dependencies: ["HaloCapture"]),
    ]
)

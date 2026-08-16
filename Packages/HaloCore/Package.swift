// swift-tools-version: 6.0
import PackageDescription

// One umbrella product so later phases can add targets without touching the
// Xcode project — the app depends on `HaloCore`, and new targets join here.
let package = Package(
    name: "HaloCore",
    platforms: [.macOS(.v15)],
    products: [
        .library(
            name: "HaloCore",
            targets: ["HaloCapture", "HaloComposite", "HaloExport", "HaloShapes"])
    ],
    targets: [
        .target(name: "HaloExport"),
        .target(name: "HaloShapes"),
        // SwiftPM does not compile .metal sources, so the shader ships as a
        // resource and is compiled at start-up. See Compositor.makeLibrary.
        .target(
            name: "HaloComposite",
            dependencies: ["HaloShapes"],
            resources: [.copy("Shaders.metal")]),
        .target(name: "HaloCapture", dependencies: ["HaloComposite", "HaloExport"]),
        .testTarget(name: "HaloCaptureTests", dependencies: ["HaloCapture"]),
        .testTarget(name: "HaloCompositeTests", dependencies: ["HaloComposite"]),
        .testTarget(name: "HaloExportTests", dependencies: ["HaloExport"]),
        .testTarget(name: "HaloShapesTests", dependencies: ["HaloShapes"]),
    ]
)

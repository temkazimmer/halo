import CoreGraphics
import Testing

@testable import HaloCapture

@Test("Retina displays report native pixel dimensions")
func pixelSizeAppliesScale() {
    let display = DisplaySource(
        id: 1, name: "Built-in", pointSize: CGSize(width: 1728, height: 1117),
        scale: 2, isMain: true)
    #expect(display.pixelSize == CGSize(width: 3456, height: 2234))
}

@Test("A 1x display reports its point size unchanged")
func pixelSizeAtUnitScale() {
    let display = DisplaySource(
        id: 2, name: "External", pointSize: CGSize(width: 2560, height: 1440),
        scale: 1, isMain: false)
    #expect(display.pixelSize == CGSize(width: 2560, height: 1440))
}

@Test("An ordinary application window is offered as a source")
func ordinaryWindowIsUserFacing() {
    #expect(WindowSource.isUserFacing(
        title: "Documents — Local",
        bundleIdentifier: "com.apple.finder",
        layer: 0,
        frame: CGRect(x: 0, y: 0, width: 900, height: 600)))
}

@Test(
    "Stage Manager chrome is rejected despite looking like a real window",
    arguments: ["Gesture Blocking Overlay", "App Icon Window"]
)
func stageManagerChromeIsRejected(title: String) {
    // These pass every structural test — layer 0, titled, full size — so only
    // the owner check excludes them.
    #expect(!WindowSource.isUserFacing(
        title: title,
        bundleIdentifier: "com.apple.WindowManager",
        layer: 0,
        frame: CGRect(x: 0, y: 0, width: 3456, height: 2234)))
}

@Test("Windows above the normal layer, untitled, or tiny are rejected")
func structuralRejections() {
    let frame = CGRect(x: 0, y: 0, width: 900, height: 600)
    // Menu bar items and overlays sit above layer 0.
    #expect(!WindowSource.isUserFacing(
        title: "Menu", bundleIdentifier: "com.example.app", layer: 25, frame: frame))
    #expect(!WindowSource.isUserFacing(
        title: "", bundleIdentifier: "com.example.app", layer: 0, frame: frame))
    #expect(!WindowSource.isUserFacing(
        title: "Tooltip", bundleIdentifier: "com.example.app", layer: 0,
        frame: CGRect(x: 0, y: 0, width: 20, height: 12)))
}

@Test("Sources are empty only when both lists are")
func emptiness() {
    #expect(ShareableSources().isEmpty)

    let withDisplay = ShareableSources(displays: [
        DisplaySource(id: 1, name: "Built-in", pointSize: .zero, scale: 2, isMain: true)
    ])
    #expect(!withDisplay.isEmpty)
}

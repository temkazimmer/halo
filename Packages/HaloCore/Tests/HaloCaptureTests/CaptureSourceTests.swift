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

@Test("Sources are empty only when both lists are")
func emptiness() {
    #expect(ShareableSources().isEmpty)

    let withDisplay = ShareableSources(displays: [
        DisplaySource(id: 1, name: "Built-in", pointSize: .zero, scale: 2, isMain: true)
    ])
    #expect(!withDisplay.isEmpty)
}

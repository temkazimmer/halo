import CoreGraphics
import Foundation
import Testing

@testable import HaloShapes

@Suite("Shape model")
struct ShapeModelTests {

    @Test("Out-of-range parameters are clamped to values the SDFs behave over")
    func clampingKeepsShapesValid() {
        // A two-sided polygon or a star whose inner radius exceeds its outer do
        // not error, they just render as nonsense.
        #expect(
            BubbleShape.polygon(sides: 1, rounding: 5).clamped()
                == .polygon(sides: 3, rounding: 0.5))
        #expect(
            BubbleShape.star(points: 40, innerRatio: 2, rounding: -1).clamped()
                == .star(points: 12, innerRatio: 0.9, rounding: 0))
        #expect(
            BubbleShape.squircle(exponent: 0.5).clamped() == .squircle(exponent: 2))
    }

    @Test("Every shape kind has a distinct index for the shader to switch on")
    func kindIndicesAreUnique() {
        let indices = BubbleShape.allKinds.map(\.kindIndex)
        #expect(Set(indices).count == indices.count)
        #expect(indices.allSatisfy { $0 >= 0 && $0 < 6 })
    }

    @Test("Shader parameters carry each shape's own values")
    func shaderParametersMapCorrectly() {
        let star = BubbleShape.star(points: 7, innerRatio: 0.3, rounding: 0.05)
        let parameters = star.shaderParameters
        #expect(parameters.a == 7)
        #expect(abs(parameters.b - 0.3) < 0.0001)
        #expect(abs(parameters.c - 0.05) < 0.0001)
    }

    @Test("Style clamping keeps size, zoom and aspect usable")
    func styleClamping() {
        var style = BubbleStyle()
        style.size = 5_000
        style.zoom = 99
        style.aspect = 0.01
        style.feather = -3

        let clamped = style.clamped()
        #expect(clamped.size == 520)
        #expect(clamped.zoom == 3)
        #expect(clamped.aspect == 0.5)
        #expect(clamped.feather == 0)
    }

    @Test("Mirroring defaults differ for preview and output, deliberately")
    func mirroringDefaults() {
        let style = BubbleStyle()
        // People expect to see themselves mirrored; viewers expect text behind
        // you to read correctly. Getting this pair backwards is the classic
        // webcam-app complaint.
        #expect(style.mirrorPreview)
        #expect(!style.mirrorOutput)
    }
}

@Suite("Preset library")
struct PresetLibraryTests {

    @Test("Presets survive a round trip through their encoded form")
    func roundTripsThroughCoding() throws {
        var library = ShapePresetLibrary.builtIn()
        library.add(
            ShapePreset(
                name: "Mine",
                style: BubbleStyle(
                    shape: .star(points: 6, innerRatio: 0.5, rounding: 0.1),
                    border: BorderStyle(width: 5, color: .black))))

        let restored = try #require(ShapePresetLibrary.decoded(from: library.encoded()))
        #expect(restored == library)
        #expect(restored.presets.last?.name == "Mine")
    }

    @Test("Reordering by drag keeps the new order")
    func reordering() {
        var library = ShapePresetLibrary.builtIn()
        let firstName = library.presets[0].name
        library.move(fromOffsets: IndexSet(integer: 0), toOffset: 3)
        #expect(library.presets[2].name == firstName)
    }

    @Test("Keyboard shortcuts cover the first nine presets only")
    func shortcutIndices() {
        var library = ShapePresetLibrary()
        for index in 0..<12 {
            library.add(ShapePreset(name: "P\(index)", style: BubbleStyle()))
        }
        #expect(library.preset(forShortcutIndex: 0)?.name == "P0")
        #expect(library.preset(forShortcutIndex: 8)?.name == "P8")
        #expect(library.preset(forShortcutIndex: 9) == nil)
    }

    @Test("Removing a preset leaves the rest in order")
    func removal() {
        var library = ShapePresetLibrary.builtIn()
        let removed = library.presets[1]
        library.remove(id: removed.id)
        #expect(!library.presets.contains(removed))
        #expect(library.presets.count == 4)
    }
}

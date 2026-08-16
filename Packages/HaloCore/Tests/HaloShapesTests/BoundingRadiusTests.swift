import Foundation
import Testing

@testable import HaloShapes

/// The floating panel is sized from `boundingRadius`. Get it too small and the
/// window edge clips the outline — a straight cut that reads as a rectangle
/// drawn around the bubble, which is exactly how the blob case first showed up.
@Suite("Bounding radius")
struct BoundingRadiusTests {

    @Test("A circle needs no headroom")
    func circleIsExactlyOne() {
        #expect(BubbleShape.circle.boundingRadius == 1)
    }

    @Test("A blob's lobes push its extent past the nominal radius")
    func blobAccountsForAmplitude() {
        let blob = BubbleShape.blob(lobes: 12, amplitude: 0.34, phase: 4.13, seed: 7)
        // The reported case: amplitude 0.34 reaches 1.34, and a panel sized to
        // 1.0 clipped the difference.
        #expect(abs(blob.boundingRadius - 1.34) < 0.0001)
    }

    @Test("A squircle grows towards its corners as the exponent rises")
    func squircleReachesTowardsTheDiagonal() {
        // Exponent 2 is a circle exactly.
        #expect(abs(BubbleShape.squircle(exponent: 2).boundingRadius - 1) < 0.0001)

        let apple = BubbleShape.squircle(exponent: 4).boundingRadius
        let boxy = BubbleShape.squircle(exponent: 12).boundingRadius
        #expect(apple > 1)
        #expect(boxy > apple)
        // Never past a full square's diagonal.
        #expect(boxy < 2.0.squareRoot())
    }

    @Test("A rounded rect runs from a square's diagonal down to a circle")
    func roundedRectInterpolates() {
        #expect(
            abs(BubbleShape.roundedRect(cornerRadius: 0).boundingRadius
                - 2.0.squareRoot()) < 0.0001)
        #expect(abs(BubbleShape.roundedRect(cornerRadius: 1).boundingRadius - 1) < 0.0001)
    }

    @Test("Polygons and stars are built with a circumradius of one")
    func polygonsAndStarsStayAtOne() {
        #expect(BubbleShape.polygon(sides: 3, rounding: 0.4).boundingRadius == 1)
        #expect(BubbleShape.star(points: 5, innerRatio: 0.3, rounding: 0.2).boundingRadius == 1)
    }

    @Test("Panel size covers the shape's extent and its decorations")
    func panelSizeLeavesRoomForEverything() {
        var style = BubbleStyle(
            shape: .blob(lobes: 12, amplitude: 0.34, phase: 0, seed: 1), size: 400)
        #expect(abs(style.panelSize - 536) < 0.001)  // 400 * 1.34

        style.border = BorderStyle(width: 6)
        style.shadow = ShadowStyle(radius: 20, opacity: 0.4, offset: CGPoint(x: 0, y: 8))
        // 536 + 2 * (6 + 20 + 8)
        #expect(abs(style.panelSize - 604) < 0.001)
    }

    @Test("Every shape's panel is at least as wide as the shape itself")
    func panelNeverClips() {
        for shape in BubbleShape.allKinds {
            let style = BubbleStyle(shape: shape, size: 300)
            #expect(
                style.panelSize >= 300 * shape.boundingRadius,
                "\(shape.name) would be clipped by its panel")
        }
    }
}

import CoreGraphics
import Testing

@testable import HaloShapes

@Suite("SnapAnchor")
struct BubblePositionTests {
    /// A display whose visible frame does not start at the origin, so a bug that
    /// ignores the frame's offset cannot pass by accident.
    private static let screen = CGRect(x: 100, y: 50, width: 1600, height: 1000)
    private static let size: CGFloat = 200
    private static let inset: CGFloat = 20

    @Test("Bottom anchors sit at the bottom, in AppKit's upward-y coordinates")
    func bottomIsActuallyBottom() {
        let origin = SnapAnchor.bottomLeading.origin(
            in: Self.screen, size: Self.size, inset: Self.inset)
        #expect(origin.x == 120)  // minX + inset
        #expect(origin.y == 70)   // minY + inset — not maxY
    }

    @Test("Top anchors leave the bubble fully on screen")
    func topFitsOnScreen() {
        let origin = SnapAnchor.topTrailing.origin(
            in: Self.screen, size: Self.size, inset: Self.inset)
        #expect(origin.x == 1480)  // maxX - size - inset
        #expect(origin.y == 830)   // maxY - size - inset
        #expect(origin.x + Self.size <= Self.screen.maxX)
        #expect(origin.y + Self.size <= Self.screen.maxY)
    }

    @Test("Centre is centred")
    func centreIsCentred() {
        let origin = SnapAnchor.center.origin(
            in: Self.screen, size: Self.size, inset: Self.inset)
        #expect(origin.x + Self.size / 2 == Self.screen.midX)
        #expect(origin.y + Self.size / 2 == Self.screen.midY)
    }

    @Test("Every anchor keeps the bubble inside the visible frame")
    func allAnchorsStayOnScreen() {
        for anchor in SnapAnchor.allCases {
            let origin = anchor.origin(in: Self.screen, size: Self.size, inset: Self.inset)
            #expect(origin.x >= Self.screen.minX)
            #expect(origin.y >= Self.screen.minY)
            #expect(origin.x + Self.size <= Self.screen.maxX)
            #expect(origin.y + Self.size <= Self.screen.maxY)
        }
    }

    @Test("A drop near the bottom-right picks the bottom-trailing anchor")
    func nearestPicksTheObviousCorner() {
        let nearBottomRight = CGPoint(x: Self.screen.maxX - 90, y: Self.screen.minY + 90)
        let result = SnapAnchor.nearest(
            to: nearBottomRight, in: Self.screen, size: Self.size, inset: Self.inset)
        #expect(result.anchor == .bottomTrailing)
        #expect(result.distance < 60)
    }

    @Test("A drop in open space is far from every anchor, so it can stay free")
    func nearestReportsDistanceForFreePlacement() {
        // Deliberately between the centre and a corner, close to nothing.
        let awkward = CGPoint(x: Self.screen.midX - 340, y: Self.screen.midY - 230)
        let result = SnapAnchor.nearest(
            to: awkward, in: Self.screen, size: Self.size, inset: Self.inset)
        #expect(result.distance > 110)
    }
}

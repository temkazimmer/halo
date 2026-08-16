import CoreGraphics

/// One of the nine places a dragged bubble can settle.
///
/// Coordinates are AppKit screen coordinates, so **y increases upward** — the
/// opposite of most UI geometry, and the easy thing to get backwards.
public enum SnapAnchor: String, CaseIterable, Codable, Sendable {
    case topLeading, top, topTrailing
    case leading, center, trailing
    case bottomLeading, bottom, bottomTrailing

    /// Origin for a bubble of `size` within `visibleFrame`.
    ///
    /// Takes a rect rather than an `NSScreen` so the geometry can be tested
    /// without a display attached.
    public func origin(in visibleFrame: CGRect, size: CGFloat, inset: CGFloat) -> CGPoint {
        let x: CGFloat = switch self {
        case .topLeading, .leading, .bottomLeading: visibleFrame.minX + inset
        case .top, .center, .bottom: visibleFrame.midX - size / 2
        case .topTrailing, .trailing, .bottomTrailing: visibleFrame.maxX - size - inset
        }
        let y: CGFloat = switch self {
        case .bottomLeading, .bottom, .bottomTrailing: visibleFrame.minY + inset
        case .leading, .center, .trailing: visibleFrame.midY - size / 2
        case .topLeading, .top, .topTrailing: visibleFrame.maxY - size - inset
        }
        return CGPoint(x: x, y: y)
    }

    /// The anchor whose resting place is nearest `centre`, and how far away it is.
    public static func nearest(
        to centre: CGPoint,
        in visibleFrame: CGRect,
        size: CGFloat,
        inset: CGFloat
    ) -> (anchor: SnapAnchor, origin: CGPoint, distance: CGFloat) {
        var best: (SnapAnchor, CGPoint, CGFloat)?
        for candidate in allCases {
            let origin = candidate.origin(in: visibleFrame, size: size, inset: inset)
            let candidateCentre = CGPoint(x: origin.x + size / 2, y: origin.y + size / 2)
            let distance = hypot(candidateCentre.x - centre.x, candidateCentre.y - centre.y)
            if best == nil || distance < best!.2 {
                best = (candidate, origin, distance)
            }
        }
        // `allCases` is never empty, so this is unreachable in practice.
        guard let best else {
            return (.bottomTrailing, .zero, .infinity)
        }
        return best
    }
}

/// Where the bubble sits: locked to an anchor, or wherever it was dropped.
public enum BubblePosition: Equatable, Codable, Sendable {
    case snapped(SnapAnchor, inset: CGFloat)
    case free(CGPoint)
}

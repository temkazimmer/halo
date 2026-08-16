import CoreGraphics
import Foundation

/// A display that can be recorded.
public struct DisplaySource: Identifiable, Hashable, Sendable {
    public let id: CGDirectDisplayID
    /// Human-readable name, e.g. "Studio Display". `SCDisplay` has no name of its
    /// own, so this comes from the matching `NSScreen`.
    public let name: String
    /// Logical size in points, as reported by `SCDisplay`.
    public let pointSize: CGSize
    /// Backing scale factor of the matching `NSScreen` — 2 on Retina.
    public let scale: Int
    public let isMain: Bool

    /// Native pixel dimensions: what `SCStreamConfiguration` should capture at.
    public var pixelSize: CGSize {
        CGSize(width: pointSize.width * CGFloat(scale),
               height: pointSize.height * CGFloat(scale))
    }

    public init(
        id: CGDirectDisplayID,
        name: String,
        pointSize: CGSize,
        scale: Int,
        isMain: Bool
    ) {
        self.id = id
        self.name = name
        self.pointSize = pointSize
        self.scale = scale
        self.isMain = isMain
    }
}

/// A window that can be recorded.
public struct WindowSource: Identifiable, Hashable, Sendable {
    public let id: CGWindowID
    public let title: String
    public let applicationName: String
    public let bundleIdentifier: String?
    public let frame: CGRect

    public init(
        id: CGWindowID,
        title: String,
        applicationName: String,
        bundleIdentifier: String?,
        frame: CGRect
    ) {
        self.id = id
        self.title = title
        self.applicationName = applicationName
        self.bundleIdentifier = bundleIdentifier
        self.frame = frame
    }
}

/// Everything currently available to record.
public struct ShareableSources: Hashable, Sendable {
    public var displays: [DisplaySource]
    public var windows: [WindowSource]

    public init(displays: [DisplaySource] = [], windows: [WindowSource] = []) {
        self.displays = displays
        self.windows = windows
    }

    public var isEmpty: Bool { displays.isEmpty && windows.isEmpty }
}

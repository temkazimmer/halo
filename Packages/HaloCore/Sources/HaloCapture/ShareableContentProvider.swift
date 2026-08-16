import AppKit
import ScreenCaptureKit

/// Why a shareable-content fetch failed, in terms the UI can act on.
public enum ShareableContentError: Error, Sendable, Equatable {
    /// Screen Recording permission is missing. The user must grant it in System
    /// Settings and relaunch — TCC does not take effect in a running process.
    case permissionDenied
    case failed(String)
}

/// Reads the current set of recordable displays and windows.
///
/// `SCShareableContent` snapshots go stale immediately (see HALO_PLAN §8.10), so
/// this deliberately offers no caching — call it again whenever you need current
/// state, and rebuild any `SCContentFilter` from the fresh result.
@MainActor
public struct ShareableContentProvider {
    public init() {}

    public func fetch(onScreenWindowsOnly: Bool = true) async throws -> ShareableSources {
        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(
                false, onScreenWindowsOnly: onScreenWindowsOnly)
        } catch let error as SCStreamError where error.code == .userDeclined {
            throw ShareableContentError.permissionDenied
        } catch {
            throw ShareableContentError.failed(error.localizedDescription)
        }

        let metrics = ScreenMetrics.current()
        let displays = content.displays
            .map { metrics.describe($0) }
            .sorted { ($0.isMain ? 0 : 1, $0.name) < ($1.isMain ? 0 : 1, $1.name) }

        return ShareableSources(
            displays: displays,
            windows: content.windows.compactMap(WindowSource.init(_:)))
    }
}

// MARK: - NSScreen bridging

/// `SCDisplay` exposes neither a name nor a scale factor, so both are looked up
/// on the matching `NSScreen` via its `NSScreenNumber` device description.
@MainActor
struct ScreenMetrics {
    private let byDisplayID: [CGDirectDisplayID: NSScreen]

    static func current() -> ScreenMetrics {
        var map: [CGDirectDisplayID: NSScreen] = [:]
        for screen in NSScreen.screens {
            let key = NSDeviceDescriptionKey("NSScreenNumber")
            guard let number = screen.deviceDescription[key] as? NSNumber else { continue }
            map[CGDirectDisplayID(number.uint32Value)] = screen
        }
        return ScreenMetrics(byDisplayID: map)
    }

    func describe(_ display: SCDisplay) -> DisplaySource {
        let screen = byDisplayID[display.displayID]
        return DisplaySource(
            id: display.displayID,
            name: screen?.localizedName ?? "Display \(display.displayID)",
            pointSize: CGSize(width: display.width, height: display.height),
            // Round rather than truncate: a 1.0 scale must not become 0.
            scale: Int((screen?.backingScaleFactor ?? 1).rounded()),
            isMain: display.displayID == CGMainDisplayID())
    }
}

// MARK: - Window filtering

extension WindowSource {
    /// Returns `nil` for anything the user would not recognise as a window:
    /// menu-bar items, shadows, and other chrome that `SCShareableContent`
    /// happily reports alongside real windows.
    init?(_ window: SCWindow) {
        guard window.isOnScreen,
              window.windowLayer == 0,
              let app = window.owningApplication,
              let title = window.title, !title.isEmpty,
              window.frame.width >= 40, window.frame.height >= 40
        else { return nil }

        self.init(
            id: window.windowID,
            title: title,
            applicationName: app.applicationName,
            bundleIdentifier: app.bundleIdentifier.isEmpty ? nil : app.bundleIdentifier,
            frame: window.frame)
    }
}

import AppKit
import UniformTypeIdentifiers

/// Remembers where recordings go.
///
/// Under the sandbox a chosen folder is only reachable through a
/// **security-scoped bookmark**: the open panel runs out of process and extends
/// the sandbox to what the user picked, but that grant does not survive a
/// relaunch on its own. A hand-built path fails outright.
@MainActor
final class DestinationStore {
    private static let bookmarkKey = "halo.destinationBookmark"

    private(set) var folderURL: URL?
    /// Balanced against `stopAccessingSecurityScopedResource` when the folder
    /// changes or the app exits.
    private var accessingURL: URL?

    var folderName: String? { folderURL?.lastPathComponent }

    init() {
        restore()
    }

    deinit {
        // The URL is a value type and the call is thread-safe, so this needs no
        // main-actor hop.
        accessingURL?.stopAccessingSecurityScopedResource()
    }

    // MARK: - Choosing

    /// Asks for a folder to keep recordings in.
    func chooseFolder() -> Bool {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.title = "Choose where Halo saves recordings"
        panel.prompt = "Choose"

        guard panel.runModal() == .OK, let url = panel.url else { return false }
        adopt(url)
        return true
    }

    /// A one-off destination, for "Save As…".
    func chooseFile(defaultName: String) -> URL? {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.mpeg4Movie]
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = defaultName
        panel.title = "Save Recording"
        return panel.runModal() == .OK ? panel.url : nil
    }

    /// The next automatic destination, or `nil` if no folder has been chosen.
    func nextURL(defaultName: String) -> URL? {
        guard let folderURL else { return nil }
        return uniqueURL(for: folderURL.appending(path: defaultName))
    }

    /// Never silently overwrite: two recordings started in the same second would
    /// otherwise collide.
    private func uniqueURL(for url: URL) -> URL {
        var candidate = url
        var counter = 2
        let base = url.deletingPathExtension().lastPathComponent
        let ext = url.pathExtension

        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = url.deletingLastPathComponent()
                .appending(path: "\(base) \(counter).\(ext)")
            counter += 1
        }
        return candidate
    }

    // MARK: - Bookmarks

    private func adopt(_ url: URL) {
        releaseAccess()

        guard let bookmark = try? url.bookmarkData(
            options: .withSecurityScope,
            includingResourceValuesForKeys: nil,
            relativeTo: nil)
        else { return }

        UserDefaults.standard.set(bookmark, forKey: Self.bookmarkKey)
        folderURL = url
        if url.startAccessingSecurityScopedResource() { accessingURL = url }
    }

    private func restore() {
        guard let bookmark = UserDefaults.standard.data(forKey: Self.bookmarkKey) else { return }

        var isStale = false
        guard let url = try? URL(
            resolvingBookmarkData: bookmark,
            options: .withSecurityScope,
            relativeTo: nil,
            bookmarkDataIsStale: &isStale)
        else {
            UserDefaults.standard.removeObject(forKey: Self.bookmarkKey)
            return
        }

        folderURL = url
        if url.startAccessingSecurityScopedResource() { accessingURL = url }

        // A stale bookmark still resolves, but only once — rewrite it now rather
        // than lose the folder on the next launch.
        if isStale, let refreshed = try? url.bookmarkData(
            options: .withSecurityScope,
            includingResourceValuesForKeys: nil,
            relativeTo: nil) {
            UserDefaults.standard.set(refreshed, forKey: Self.bookmarkKey)
        }
    }

    private func releaseAccess() {
        accessingURL?.stopAccessingSecurityScopedResource()
        accessingURL = nil
    }
}

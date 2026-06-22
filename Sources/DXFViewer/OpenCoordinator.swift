import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Shared funnel for "user wants to view this DXF" intents: Finder
/// double-click, drag onto Dock icon, File → Open, File → Open Recent.
/// ContentView observes `pendingOpen` and feeds it into the parser.
@MainActor
final class OpenCoordinator: ObservableObject {
    static let shared = OpenCoordinator()

    @Published var pendingOpen: URL?
    @Published var recents: [URL] = []

    private let recentsKey = "RecentDocumentBookmarks_v1"
    private let recentsLimit = 10

    private init() { loadRecents() }

    func open(_ url: URL) {
        pendingOpen = url
        addRecent(url)
        NSDocumentController.shared.noteNewRecentDocumentURL(url)
    }

    func openPicker() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType("com.autodesk.dxf") ?? .data]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        if panel.runModal() == .OK, let url = panel.url { open(url) }
    }

    func clearRecents() {
        recents = []
        UserDefaults.standard.removeObject(forKey: recentsKey)
        NSDocumentController.shared.clearRecentDocuments(nil)
    }

    private func addRecent(_ url: URL) {
        var next = recents.filter { $0.path != url.path }
        next.insert(url, at: 0)
        recents = Array(next.prefix(recentsLimit))
        persistRecents()
    }

    private func loadRecents() {
        guard let arr = UserDefaults.standard.array(forKey: recentsKey) as? [Data] else { return }
        recents = arr.compactMap { data in
            var stale = false
            return try? URL(resolvingBookmarkData: data,
                            options: [.withSecurityScope],
                            relativeTo: nil,
                            bookmarkDataIsStale: &stale)
        }
    }

    private func persistRecents() {
        let blobs = recents.compactMap {
            try? $0.bookmarkData(options: [.withSecurityScope],
                                 includingResourceValuesForKeys: nil,
                                 relativeTo: nil)
        }
        UserDefaults.standard.set(blobs, forKey: recentsKey)
    }
}

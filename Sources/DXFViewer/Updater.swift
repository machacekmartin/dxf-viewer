import Foundation
import SwiftUI
#if canImport(Sparkle)
import Sparkle
#endif

/// Thin facade over Sparkle so the rest of the app stays decoupled.
/// When the Sparkle package is wired up, the menu item drives a real update
/// check; until then it pops an "updates not yet wired" alert.
@MainActor
final class UpdaterController: ObservableObject {
    static let shared = UpdaterController()

    #if canImport(Sparkle)
    let controller: SPUStandardUpdaterController
    @Published private(set) var canCheck = true
    private init() {
        controller = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
    }
    func checkForUpdates() { controller.checkForUpdates(nil) }
    #else
    @Published private(set) var canCheck = false
    private init() {}
    func checkForUpdates() {
        let alert = NSAlert()
        alert.messageText = "Update checking unavailable"
        alert.informativeText = "Sparkle is not bundled in this build. Add the Sparkle SwiftPM dependency and re-build to enable auto-updates."
        alert.runModal()
    }
    #endif
}

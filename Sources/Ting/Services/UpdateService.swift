// Automatic updates with Sparkle from the public GitHub release feed (`SUFeedURL` in Info.plist).
// Updates are verified with the EdDSA public key in `SUPublicEDKey` and by Apple's code signature checks.
import AppKit
import Observation
import Sparkle

@MainActor
@Observable
final class UpdateService {
    static let shared = UpdateService()

    /// False for development builds without a feed URL; the update UI is hidden then.
    let isAvailable: Bool
    @ObservationIgnored private let controller: SPUStandardUpdaterController?

    private init() {
        let info = Bundle.main.infoDictionary ?? [:]
        let hasFeed = (info["SUFeedURL"] as? String)?.isEmpty == false
        let hasKey = (info["SUPublicEDKey"] as? String)?.isEmpty == false
        isAvailable = hasFeed && hasKey
        controller = isAvailable
            ? SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
            : nil
        automaticallyChecks = controller?.updater.automaticallyChecksForUpdates ?? false
    }

    /// Mirrors Sparkle's own preference, which Sparkle stores in the app's user defaults.
    var automaticallyChecks: Bool {
        didSet {
            guard let updater = controller?.updater, updater.automaticallyChecksForUpdates != automaticallyChecks else { return }
            updater.automaticallyChecksForUpdates = automaticallyChecks
        }
    }

    var canCheck: Bool { controller?.updater.canCheckForUpdates ?? false }

    func checkForUpdates() {
        NSApp.activate()
        controller?.checkForUpdates(nil)
    }
}

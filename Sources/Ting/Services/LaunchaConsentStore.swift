// The user's choice to let launcha search Desktop, Documents and Downloads.
// Kept apart from the config file, so a shared or synced config never grants it.
import Foundation

@MainActor
final class LaunchaConsentStore {
    private struct Stored: Codable {
        var protectedFolders: Bool
    }

    let url: URL
    private(set) var policy: ProtectedFolderPolicy
    /// Why the choice could not be read or saved.
    private(set) var error: String?

    init(url: URL = LaunchaConsentStore.defaultURL()) {
        self.url = url
        policy = .needsConsent
        load()
    }

    /// With `$TING_CONFIG` the choice sits next to that file, so manual checks never read or
    /// change the real one. Otherwise `~/Library/Application Support/Ting/launcha-consent.json`.
    nonisolated static func defaultURL(environment: [String: String] = ProcessInfo.processInfo.environment,
                                       home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        if let config = environment["TING_CONFIG"], !config.isEmpty {
            return URL(fileURLWithPath: (config as NSString).expandingTildeInPath).appendingPathExtension("launcha-consent.json")
        }
        return home.appendingPathComponent("Library/Application Support/Ting/launcha-consent.json")
    }

    private func load() {
        do {
            let stored = try JSONDecoder().decode(Stored.self, from: Data(contentsOf: url))
            policy = stored.protectedFolders ? .allowed : .needsConsent
        } catch {
            // No file is the normal first state. Anything else fails closed.
            let ns = error as NSError
            if !(ns.domain == NSCocoaErrorDomain && ns.code == NSFileReadNoSuchFileError) {
                self.error = "Cannot read the launcha folder choice: \(error.localizedDescription)"
            }
            policy = .needsConsent
        }
    }

    /// Saves the choice. The policy changes only when the file was written.
    @discardableResult
    func set(_ policy: ProtectedFolderPolicy) -> Bool {
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            try encoder.encode(Stored(protectedFolders: policy == .allowed)).write(to: url, options: .atomic)
            self.policy = policy
            error = nil
            return true
        } catch {
            self.error = "Cannot save the launcha folder choice: \(error.localizedDescription)"
            return false
        }
    }
}

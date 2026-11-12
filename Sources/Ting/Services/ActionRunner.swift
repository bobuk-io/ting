// Runs a binding: opens an app (or brings it to the front) or a URL.
import AppKit
import TingCore

@MainActor
final class ActionRunner {
    /// Reports a short, user-facing error. Never throws or crashes.
    var onError: ((String) -> Void)?

    func run(_ item: Item) {
        switch item.action {
        case .group:
            break
        case .app(let bundleID):
            openApp(bundleID, label: item.label)
        case .url(let text):
            openURL(text, label: item.label)
        }
    }

    private func openApp(_ bundleID: String, label: String) {
        let name = label.isEmpty ? bundleID : label
        guard !bundleID.isEmpty, let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
            onError?("\(name): app not found (\(bundleID.isEmpty ? "no bundle ID" : bundleID))")
            return
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        Task {
            do {
                _ = try await NSWorkspace.shared.openApplication(at: url, configuration: configuration)
            } catch {
                onError?("\(name): \(error.localizedDescription)")
            }
        }
    }

    private func openURL(_ text: String, label: String) {
        let name = label.isEmpty ? text : label
        guard let url = URL(string: text.trimmingCharacters(in: .whitespacesAndNewlines)), url.scheme?.isEmpty == false else {
            onError?("\(name): invalid URL")
            return
        }
        if !NSWorkspace.shared.open(url) {
            onError?("\(name): cannot open \(text)")
        }
    }
}

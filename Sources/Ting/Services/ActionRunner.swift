// Runs a binding or a launcha result: opens an app (or brings it to the front), a URL or a file.
// Every open reports a `LaunchOutcome`, so the caller can count successful launches once.
import AppKit
import TingCore

/// What launcha needs to open its results. `ActionRunner` is the real one; tests use a fake.
@MainActor
protocol LaunchaOpening: AnyObject {
    /// Opens the app at `url` (the retained bundle URL from the index), or activates it.
    func openApp(at url: URL, name: String) async -> LaunchOutcome
    /// Opens a file or folder with its usual app.
    func openFile(_ url: URL, name: String) async -> LaunchOutcome
    /// Shows the item in Finder. Never counts as a launch.
    func reveal(_ url: URL) -> LaunchOutcome
}

@MainActor
final class ActionRunner: LaunchaOpening {
    /// Reports a short, user-facing error. Never throws or crashes.
    var onError: ((String) -> Void)?

    /// Runs a selecta binding.
    func run(_ item: Item) async -> LaunchOutcome {
        switch item.action {
        case .group:
            return .failed
        case .app(let bundleID):
            let name = item.label.isEmpty ? bundleID : item.label
            guard !bundleID.isEmpty, let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
                onError?("\(name): app not found (\(bundleID.isEmpty ? "no bundle ID" : bundleID))")
                return .failed
            }
            return await openApp(at: url, name: name)
        case .url(let text):
            return openURL(text, label: item.label)
        }
    }

    func openApp(at url: URL, name: String) async -> LaunchOutcome {
        let wasRunning = Self.isRunning(url)
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        do {
            _ = try await NSWorkspace.shared.openApplication(at: url, configuration: configuration)
            return wasRunning ? .activated : .opened
        } catch {
            onError?("\(name): \(error.localizedDescription)")
            return .failed
        }
    }

    func openFile(_ url: URL, name: String) async -> LaunchOutcome {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        do {
            _ = try await NSWorkspace.shared.open(url, configuration: configuration)
            return .opened
        } catch {
            onError?("\(name): \(error.localizedDescription)")
            return .failed
        }
    }

    func reveal(_ url: URL) -> LaunchOutcome {
        NSWorkspace.shared.activateFileViewerSelecting([url])
        return .revealed
    }

    private func openURL(_ text: String, label: String) -> LaunchOutcome {
        let name = label.isEmpty ? text : label
        guard let url = URL(string: text.trimmingCharacters(in: .whitespacesAndNewlines)), url.scheme?.isEmpty == false else {
            onError?("\(name): invalid URL")
            return .failed
        }
        guard NSWorkspace.shared.open(url) else {
            onError?("\(name): cannot open \(text)")
            return .failed
        }
        return .opened
    }

    /// True when an app from this bundle is already running: opening it only activates it.
    private static func isRunning(_ url: URL) -> Bool {
        let path = url.standardizedFileURL.resolvingSymlinksInPath().path
        return NSWorkspace.shared.runningApplications.contains {
            $0.bundleURL?.standardizedFileURL.resolvingSymlinksInPath().path == path
        }
    }
}

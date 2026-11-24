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
    /// Sends a saved-site deep link explicitly to Lowkey, not to an arbitrary URL handler.
    func openLowkeySite(_ url: URL, name: String) async -> LaunchOutcome
    /// Shows the item in Finder. Never counts as a launch.
    func reveal(_ url: URL) -> LaunchOutcome
}

extension LaunchaOpening {
    func openLowkeySite(_ url: URL, name: String) async -> LaunchOutcome { .failed }
}

@MainActor
final class ActionRunner: LaunchaOpening {
    typealias SubmitApplication = (URL, @escaping @Sendable (Error?) -> Void) -> Void

    /// Reports a short, user-facing error. Never throws or crashes.
    var onError: ((String) -> Void)?
    var onPlaySound: (() -> Void)?
    private var appURLs: [String: URL] = [:]
    private let submitApplication: SubmitApplication
    private let locateLowkey: () -> URL?
    private let launchLowkey: (URL, URL) async throws -> Void

    init(locateLowkey: (() -> URL?)? = nil, launchLowkey: ((URL, URL) async throws -> Void)? = nil,
         submitApplication: SubmitApplication? = nil) {
        self.submitApplication = submitApplication ?? { url, completion in
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = true
            NSWorkspace.shared.openApplication(at: url, configuration: configuration) { _, error in
                completion(error)
            }
        }
        self.locateLowkey = locateLowkey ?? { LowkeyIntegration.applicationURL() }
        self.launchLowkey = launchLowkey ?? { url, app in
            let configuration = NSWorkspace.OpenConfiguration()
            _ = try await NSWorkspace.shared.open([url], withApplicationAt: app, configuration: configuration)
        }
    }

    private func runControl(at helper: URL, arguments: [String]) async throws -> Bool {
        let process = Process()
        process.executableURL = helper
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        return try await withCheckedThrowingContinuation { done in
            process.terminationHandler = { child in
                done.resume(returning: child.terminationReason == .exit && child.terminationStatus == 0)
            }
            do { try process.run() } catch { done.resume(throwing: error) }
        }
    }

    func prepare(_ items: [Item]) {
        appURLs.removeAll()
        func visit(_ items: [Item]) {
            for item in items {
                switch item.action {
                case .group(let children): visit(children)
                case .app(let id):
                    appURLs[id] = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id)
                default: break
                }
            }
        }
        visit(items)
    }

    // 1Password can keep running with its main window closed. Activation alone
    // does not reopen it; let Launch Services deliver a normal open request instead.
    func tryActivation(bundleID: String?, activate: () -> Bool) -> Bool {
        guard bundleID != "com.1password.1password", activate() else { return false }
        onPlaySound?()
        return true
    }

    /// Starts activation synchronously, before the leader panel returns focus to another app.
    func activateRunning(_ item: Item) -> LaunchOutcome? {
        guard case .app(let id) = item.action,
              let app = NSRunningApplication.runningApplications(withBundleIdentifier: id).first,
              tryActivation(bundleID: id, activate: { app.activate(options: []) }) else { return nil }
        return .activated
    }

    /// Runs a selecta binding.
    func run(_ item: Item) async -> LaunchOutcome {
        switch item.action {
        case .group, .micro, .open, .window:
            // Micro-app, panel and window bindings run in `AppModel`, not here.
            return .failed
        case .app(let bundleID):
            let name = item.label.isEmpty ? bundleID : item.label
            if let outcome = activateRunning(item) { return outcome }
            guard !bundleID.isEmpty, let url = appURLs[bundleID] ?? NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
                onError?("\(name): app not found (\(bundleID.isEmpty ? "no bundle ID" : bundleID))")
                return .failed
            }
            appURLs[bundleID] = url
            return await openApp(at: url, name: name)
        case .url(let text):
            if let url = URL(string: text), url.scheme?.lowercased() == "lowkey" {
                return await openLowkeySite(url, name: item.label)
            }
            return openURL(text, label: item.label)
        }
    }

    func openApp(at url: URL, name: String) async -> LaunchOutcome {
        let running = NSWorkspace.shared.runningApplications.first { $0.bundleURL == url }
        if let running, tryActivation(bundleID: running.bundleIdentifier, activate: { running.activate(options: []) }) {
            return .activated
        }
        let error: Error? = await withCheckedContinuation { done in
            submitApplication(url) { error in done.resume(returning: error) }
            // Launch Services has the request. Sound can start while the app is opening.
            onPlaySound?()
        }
        if let error {
            onError?("\(name): \(error.localizedDescription)")
            return .failed
        }
        return running == nil ? .opened : .activated
    }

    func openFile(_ url: URL, name: String) async -> LaunchOutcome {
        onPlaySound?()
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

    func openLowkeySite(_ url: URL, name: String) async -> LaunchOutcome {
        onPlaySound?()
        guard url.scheme?.lowercased() == "lowkey", let app = locateLowkey() else {
            onError?("lowkey is not installed. Install it to open this site.")
            return .failed
        }
        do {
            if let arguments = LowkeySite.controlArguments(for: url) {
                let helper = app.appendingPathComponent("Contents/Helpers/lowkeyctl")
                guard FileManager.default.isExecutableFile(atPath: helper.path) else {
                    onError?("Update lowkey: its lowkeyctl helper is missing.")
                    return .failed
                }
                // Never replay a failed toggle via URL: it may already have taken effect.
                guard try await runControl(at: helper, arguments: arguments) else {
                    onError?("lowkeyctl could not \(arguments[0]) \(arguments[1]).")
                    return .failed
                }
            } else {
                // The prompt, wildcard, reload, etc. are URL-only lowkey commands.
                try await launchLowkey(url, app)
            }
            return .opened
        } catch {
            onError?("lowkey: cannot open \(name.isEmpty ? "the site" : name).")
            return .failed
        }
    }

    func reveal(_ url: URL) -> LaunchOutcome {
        NSWorkspace.shared.activateFileViewerSelecting([url])
        return .revealed
    }

    private func openURL(_ text: String, label: String) -> LaunchOutcome {
        onPlaySound?()
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

}

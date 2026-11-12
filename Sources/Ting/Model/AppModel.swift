// App state shared by the status menu, Welcome and Settings. Views read it and call its methods;
// file IO, hotkeys and actions live in the services it owns.
import AppKit
import Observation
import SwiftUI
import TingCore

@MainActor
@Observable
final class AppModel {
    static let shared = AppModel()

    /// The last good config.
    private(set) var config = Config()
    /// Why the config file could not be read or written; the last good config stays in use.
    private(set) var configError: String?
    private(set) var issues: [ConfigIssue] = []
    private(set) var hotkeyStatus: HotkeyService.Status = .inactive
    private(set) var loginItemError: String?
    /// Session-only: the leader is off while paused.
    var isPaused = false {
        didSet { applyHotkey() }
    }
    /// The leader is off while a new one is being recorded, so pressing the old one records it.
    private(set) var isRecordingLeader = false

    @ObservationIgnored let store = ConfigStore()
    @ObservationIgnored private let hotkeys = HotkeyService()
    @ObservationIgnored private let leader = LeaderController()
    @ObservationIgnored private let runner = ActionRunner()
    @ObservationIgnored private let toast = ToastController()

    var leaderDisplay: String { config.leader?.display ?? "Not set" }
    var isLeaderActive: Bool { hotkeyStatus == .active && !isPaused }

    var hotkeyProblem: String? {
        switch hotkeyStatus {
        case .failed(let reason): reason
        case .inactive, .active: nil
        }
    }

    // MARK: Lifecycle

    func start() {
        hotkeys.onStatusChange = { [weak self] status in self?.hotkeyStatus = status }
        hotkeys.onLeader = { [weak self] in self?.leader.leaderPressed() }
        leader.onRun = { [weak self] item in self?.run(item) }
        runner.onError = { [weak self] message in self?.toast.show(message) }

        if !store.fileExists {
            do {
                try store.write(.sample)
            } catch {
                apply(.sample)
                configError = "Cannot create \(store.displayPath): \(error.localizedDescription)"
            }
        }
        reload()
        store.watch { [weak self] in self?.reload() }
    }

    func reload() {
        switch store.load() {
        case .success(let loaded):
            configError = nil
            apply(loaded)
        case .failure(let error):
            configError = error.message
        }
    }

    // MARK: Editing (every edit writes the file atomically)

    func update(_ change: (inout Config) -> Void) {
        var next = config
        change(&next)
        guard next != config else { return }
        do {
            try store.write(next)
            configError = nil
            apply(next)
        } catch {
            configError = "Cannot save \(store.displayPath): \(error.localizedDescription)"
        }
    }

    /// A binding that writes the config on every change.
    func binding<Value>(_ keyPath: WritableKeyPath<Config, Value>) -> Binding<Value> {
        Binding(get: { self.config[keyPath: keyPath] },
                set: { value in self.update { $0[keyPath: keyPath] = value } })
    }

    func setLeader(_ hotkey: Hotkey) {
        update { $0.leader = hotkey }
    }

    func setRecordingLeader(_ recording: Bool) {
        guard recording != isRecordingLeader else { return }
        isRecordingLeader = recording
        applyHotkey()
    }

    func replaceConfig(_ imported: Config) {
        update { $0 = imported }
    }

    // MARK: Bindings

    func insertBinding(_ item: Item, at sequence: [String]) throws {
        var items = config.items
        try BindingTree.insert(item, at: sequence, in: &items)
        update { $0.items = items }
    }

    func moveBinding(from: [String], to: [String]) throws {
        var items = config.items
        try BindingTree.move(from: from, to: to, in: &items)
        update { $0.items = items }
    }

    func convertToGroup(at prefix: [String]) {
        update { try? BindingTree.convertToGroup(at: prefix, in: &$0.items) }
    }

    func updateBinding(at sequence: [String], _ change: (inout Item) -> Void) {
        update { try? BindingTree.update(at: sequence, in: &$0.items, change) }
    }

    func removeBindings(_ sequences: [[String]]) {
        // Deepest first, so removing a child before its group still works.
        update { config in
            for sequence in sequences.sorted(by: { $0.count > $1.count }) {
                try? BindingTree.remove(at: sequence, in: &config.items)
            }
        }
    }

    // MARK: Config file

    func openConfigFile() {
        let url = store.url
        if NSWorkspace.shared.urlForApplication(toOpen: url) != nil, NSWorkspace.shared.open(url) { return }
        // No app claims .json: fall back to TextEdit.
        guard let textEdit = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.TextEdit") else { return }
        NSWorkspace.shared.open([url], withApplicationAt: textEdit, configuration: NSWorkspace.OpenConfiguration())
    }

    func revealConfigFile() {
        NSWorkspace.shared.activateFileViewerSelecting([store.url])
    }

    // MARK: Private

    private func apply(_ next: Config) {
        let previous = config
        config = next
        issues = ConfigValidator.validate(next)
        leader.configure(next)
        next.appearance.apply()
        applyHotkey()
        if next.launchAtLogin != previous.launchAtLogin {
            loginItemError = LoginItemService.set(next.launchAtLogin)
        }
    }

    private func applyHotkey() {
        if isPaused || isRecordingLeader {
            leader.close()
            hotkeys.activate(nil)
        } else {
            hotkeys.activate(config.leader)
        }
        hotkeyStatus = hotkeys.status
    }

    private func run(_ item: Item) {
        if config.playSound { NSSound(named: "Tink")?.play() }
        runner.run(item)
    }
}

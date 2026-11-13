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
    private(set) var launchaHotkeyStatus: HotkeyService.Status = .inactive
    private(set) var loginItemError: String?
    /// Session-only: the leader is off while paused.
    var isPaused = false {
        didSet { applyHotkey() }
    }
    /// Both hotkeys are off while a new one is being recorded, so pressing an existing one records it.
    private(set) var isRecordingHotkey = false
    /// launcha may search Desktop, Documents and Downloads. Stored apart from the config.
    var protectedFoldersAllowed: Bool { launchaModel.protectedFolders == .allowed }
    var launchaConsentError: String? { launchaModel.consentError }

    @ObservationIgnored let store = ConfigStore()
    @ObservationIgnored private let hotkeys = HotkeyService()
    @ObservationIgnored private let leader = LeaderController()
    @ObservationIgnored private let runner: ActionRunner
    @ObservationIgnored private let toast = ToastController()
    @ObservationIgnored private let launchaModel: LaunchaModel
    @ObservationIgnored private let launcha: LaunchaController
    /// Held-key guard for the launcha hotkey: a repeat while held never toggles twice.
    @ObservationIgnored private var launchaKey = LeaderDoubleTap(isEnabled: false)

    init() {
        let runner = ActionRunner()
        self.runner = runner
        launchaModel = LaunchaModel(opener: runner, historyStore: LaunchaHistoryStore(), consent: LaunchaConsentStore())
        launcha = LaunchaController(model: launchaModel)
    }

    var leaderDisplay: String { config.leader?.display ?? "Not set" }
    var isLeaderActive: Bool { hotkeyStatus == .active && !isPaused }

    var hotkeyProblem: String? {
        switch hotkeyStatus {
        case .failed(let reason): reason
        case .inactive, .active: nil
        }
    }

    var launchaHotkeyDisplay: String { config.launcha.hotkey?.display ?? "Not set" }

    /// Why the launcha hotkey does not work: invalid, the same as the leader, or taken.
    var launchaHotkeyProblem: String? {
        if let issue = issues.first(where: { $0.kind == .invalidLaunchaHotkey || $0.kind == .launchaHotkeyConflict }) {
            return issue.message
        }
        switch launchaHotkeyStatus {
        case .failed(let reason): return reason
        case .inactive, .active: return nil
        }
    }

    // MARK: Lifecycle

    func start() {
        hotkeys.onStatusChange = { [weak self] slot, status in
            switch slot {
            case .leader: self?.hotkeyStatus = status
            case .launcha: self?.launchaHotkeyStatus = status
            }
        }
        hotkeys.onPress = { [weak self] slot, time in self?.hotkeyPressed(slot, at: time) }
        hotkeys.onRelease = { [weak self] slot in
            switch slot {
            case .leader: self?.leader.leaderReleased()
            case .launcha: self?.launchaKey.release()
            }
        }
        leader.onRun = { [weak self] item in self?.run(item) }
        leader.onDoubleTap = { [weak self] in self?.launcha.open() }
        launchaModel.onWillOpen = { [weak self] in self?.playSound() }
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
        launchaModel.prewarm()
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

    /// nil removes the separate launcha hotkey.
    func setLaunchaHotkey(_ hotkey: Hotkey?) {
        update { $0.launcha.hotkey = hotkey }
    }

    func setRecordingHotkey(_ recording: Bool) {
        guard recording != isRecordingHotkey else { return }
        isRecordingHotkey = recording
        applyHotkey()
    }

    // MARK: launcha

    func openLauncha() {
        guard !isPaused, !isRecordingHotkey else { return }
        leader.close()
        launcha.open()
    }

    /// Call only after the user read what this allows and which macOS prompts may follow.
    func setProtectedFoldersAllowed(_ allowed: Bool) {
        if allowed { launchaModel.allowProtectedFolders() } else { launchaModel.revokeProtectedFolders() }
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
        launcha.configure(next)
        next.appearance.apply()
        applyHotkey()
        if next.launchAtLogin != previous.launchAtLogin {
            loginItemError = LoginItemService.set(next.launchAtLogin)
        }
    }

    private func applyHotkey() {
        if isPaused || isRecordingHotkey {
            leader.close()
            launcha.close()
            hotkeys.activate(nil, for: .launcha)
            hotkeys.activate(nil, for: .leader)
        } else {
            // The leader wins a conflict: free the launcha slot first.
            let separate = config.launcha.hotkey.flatMap { $0.isValid && $0 != config.leader ? $0 : nil }
            if hotkeys.hotkey(.launcha) != separate { hotkeys.activate(nil, for: .launcha) }
            hotkeys.activate(config.leader, for: .leader)
            hotkeys.activate(separate, for: .launcha)
        }
        hotkeyStatus = hotkeys.status(.leader)
        launchaHotkeyStatus = hotkeys.status(.launcha)
    }

    private func hotkeyPressed(_ slot: HotkeyService.Slot, at time: TimeInterval) {
        switch slot {
        case .leader:
            // The leader switches from launcha back to selecta.
            if launcha.isOpen { launcha.close() }
            leader.leaderPressed(at: time)
        case .launcha:
            guard launchaKey.press(at: time, menuOpen: false, menuOpenAtRoot: false) != .ignored else { return }
            if leader.isOpen { leader.close() }
            launcha.toggle()
        }
    }

    private func playSound() {
        if config.playSound { NSSound(named: "Tink")?.play() }
    }

    /// Opens a selecta binding and counts a successful launch once.
    private func run(_ item: Item) {
        playSound()
        let id: String? = switch item.action {
        case .app(let bundleID): LaunchaCandidate.app(bundleID: bundleID, name: "").id
        case .url(let url): LaunchaCandidate.url(url, name: "").id
        case .group: nil
        }
        Task {
            let outcome = await runner.run(item)
            if let id { await launchaModel.record(outcome, id: id) }
        }
    }
}

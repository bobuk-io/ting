import TingRuntime
// App state shared by the status menu, Welcome and Settings. Views read it and call its methods;
// file IO, hotkeys and actions live in the services it owns.
import AppKit
import Observation
import SwiftUI
import TingCore
import BobukSystem
import BobukUI

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
    private(set) var alternateLeaderStatus: HotkeyService.Status = .inactive
    @ObservationIgnored private var assignments = HotkeyAssignments(Config())
    private(set) var launchaHotkeyStatus: HotkeyService.Status = .inactive
    private(set) var clipbawdHotkeyStatus: HotkeyService.Status = .inactive
    private(set) var chattaHotkeyStatus: HotkeyService.Status = .inactive
    private(set) var windowHotkeyStatuses: [WindowCommand: HotkeyService.Status] = [:]
    private(set) var loginItemError: String?
    /// Every file of the micro-apps folder, good and broken, by file name.
    private(set) var microApps: [MicroAppEntry] = []
    /// Problems of the micro-app files, by file name, then by line.
    private(set) var microAppIssues: [MicroAppIssue] = []
    /// Micro-app hotkeys macOS refused, such as a key another app holds, by micro-app id.
    private(set) var microHotkeyProblems: [String: String] = [:]
    /// Session-only: the leader is off while paused.
    var isPaused = false {
        didSet { applyHotkey() }
    }
    /// All hotkeys are off while a new one is recorded, so an existing shortcut can be captured.
    private(set) var isRecordingHotkey = false
    /// launcha may search Desktop, Documents and Downloads. Stored apart from the config.
    var protectedFoldersAllowed: Bool { launchaModel.protectedFolders == .allowed }
    /// launcha may search iCloud Drive. Off by default, stored apart from the config.
    var iCloudDriveAllowed: Bool { launchaModel.searchesICloudDrive }
    var launchaConsentError: String? { launchaModel.consentError }

    @ObservationIgnored let theme: ThemeStore
    @ObservationIgnored private let presentsWindows: Bool
    @ObservationIgnored private var syncingTheme = false
    @ObservationIgnored nonisolated(unsafe) private var themeObserver: NSObjectProtocol?
    @ObservationIgnored let store: ConfigStore
    @ObservationIgnored private(set) lazy var microStore = MicroAppStore(configURL: store.url)
    @ObservationIgnored private let hotkeys: HotkeyService
    /// Makes the extended key reader when the option turns on (`HIDKeyMonitor`; nil in tests).
    @ObservationIgnored private let makeExtendedKeys: () -> ExtendedKeySource?
    @ObservationIgnored private var extendedKeySource: ExtendedKeySource?
    /// The recorder that takes extended keys no hotkey took; the last one to start wins.
    @ObservationIgnored private var extendedKeyListener: (owner: ObjectIdentifier, handler: (ExtendedKeyEvent) -> Void)?
    @ObservationIgnored private var activeAppShortcuts: [AppShortcut] = []
    @ObservationIgnored private var activeMicroShortcuts: [MicroShortcut] = []
    @ObservationIgnored private var activeWindowShortcuts: [WindowShortcut] = []
    @ObservationIgnored let leader: LeaderController
    @ObservationIgnored private let runner: ActionRunner
    @ObservationIgnored private let windowManager: WindowManaging
    @ObservationIgnored private let toast: ToastController
    @ObservationIgnored private let launchaModel: LaunchaModel
    @ObservationIgnored let launcha: LaunchaController
    @ObservationIgnored let lowkey: LowkeyIntegration
    /// The clipboard history of this session.
    @ObservationIgnored let clipbawd: ClipbawdHistory
    @ObservationIgnored let clipbawdPanel: ClipbawdController
    @ObservationIgnored let schedule: ScheduleController
    @ObservationIgnored private(set) lazy var chatta = ChattaController(
        theme: theme,
        configURL: store.url,
        microAppsFolderURL: { [weak self] in self?.microStore.folderURL ?? MicroAppStore.folderURL(configURL: ConfigStore.defaultURL()) },
        presentsWindow: presentsWindows,
        openSettings: { [weak self] in self?.openSettingsFromLauncher(page: .chatta) },
        onAllowToolsPermanently: { [weak self] in self?.update { $0.chatta.allowTools = true } },
        onTextScale: { [weak self] scale in self?.update { $0.chatta.textScale = scale } }
    )
    /// Shows the Settings window; tests replace it so they never activate the app.
    @ObservationIgnored var settingsOpener: () -> Void = { SettingsOpener.open() }
    @ObservationIgnored var settingsPageOpener: (SettingsPage) -> Void = { SettingsOpener.open(page: $0) }
    /// True while the gear menu tracks: the launchers stay open but take no keys or hotkeys.
    @ObservationIgnored private(set) var isMenuTracking = false
    /// The one open micro-app flow: approval, working state and result.
    @ObservationIgnored private let microFlow = MicroAppFlowController()
    /// The Accessibility window, and whether Ting may use Accessibility.
    @ObservationIgnored let accessibility: AccessibilityWindowController
    /// Held-key guard for the launcha hotkey: a repeat while held never toggles twice.
    @ObservationIgnored private var launchaKey = LeaderDoubleTap(isEnabled: false)
    @ObservationIgnored private var clipbawdKey = LeaderDoubleTap(isEnabled: false)
    @ObservationIgnored private var chattaKey = LeaderDoubleTap(isEnabled: false)
    @ObservationIgnored private lazy var recordingGate = HotkeyRecordingGate { [weak self] in self?.setRecordingHotkey($0) }
    /// Loaded "ting" sounds by name; nil marks a name that cannot be loaded.
    @ObservationIgnored private var sounds: [String: NSSound?] = [:]

    /// `presentsWindows` false: the launchers keep their state but show no window (tests).
    init(presentsWindows: Bool = true, store: ConfigStore? = nil, hotkeys: HotkeyService? = nil,
         clipbawd: ClipbawdHistory? = nil, theme: ThemeStore? = nil, windowManager: WindowManaging? = nil,
         scheduleService: (any ScheduleServing)? = nil, extendedKeys: (() -> ExtendedKeySource?)? = nil) {
        self.presentsWindows = presentsWindows
        // Tests (no windows) never read the keyboards or ask for Input Monitoring.
        makeExtendedKeys = extendedKeys ?? (presentsWindows ? { HIDKeyMonitor() } : { nil })
        self.windowManager = windowManager ?? WindowManager()
        self.accessibility = AccessibilityWindowController(presentsWindow: presentsWindows)
        if let theme {
            self.theme = theme
        } else if presentsWindows {
            self.theme = .ting
        } else {
            let suite = UserDefaults(suiteName: "io.bobuk.ting.tests.theme." + UUID().uuidString) ?? .standard
            self.theme = ThemeStore(defaults: suite, keys: ThemeStore.tingKeys,
                                    defaultAppearance: .dark, defaultPreset: .amber,
                                    appliesToApplication: false)
        }
        self.toast = ToastController(theme: self.theme, mark: AnyView(TingMark(size: 12)))
        self.store = store ?? ConfigStore()
        let environment = store.map { ["TING_CONFIG": $0.url.path] } ?? ProcessInfo.processInfo.environment
        // Tests (no windows) never watch the person's clipboard.
        self.clipbawd = clipbawd ?? ClipbawdHistory(pasteboard: presentsWindows ? .general
            : NSPasteboard(name: NSPasteboard.Name("io.bobuk.ting.tests." + UUID().uuidString)),
            directory: presentsWindows ? ClipHistoryDisk.defaultDirectory(environment: environment) : nil)
        clipbawdPanel = ClipbawdController(history: self.clipbawd, presentsWindow: presentsWindows)
        let resolvedScheduleService = scheduleService ?? (presentsWindows ? EventKitScheduleService() : ScheduleUnavailableService())
        schedule = ScheduleController(model: ScheduleModel(service: resolvedScheduleService), presentsWindow: presentsWindows)
        self.hotkeys = hotkeys ?? HotkeyService()
        leader = LeaderController(presentsWindow: presentsWindows)
        let runner = ActionRunner()
        self.runner = runner
        let lowkey = presentsWindows ? LowkeyIntegration() : LowkeyIntegration(locate: { nil })
        self.lowkey = lowkey
        launchaModel = LaunchaModel(opener: runner,
            historyStore: LaunchaHistoryStore(url: LaunchaHistoryStore.defaultURL(environment: environment)),
            consent: LaunchaConsentStore(url: LaunchaConsentStore.defaultURL(environment: environment)),
            usageStore: LaunchaHistoryStore(url: LaunchaHistoryStore.usageURL(environment: environment)),
            lowkeySites: { lowkey.refresh(); return lowkey.sites },
            // Tests (no windows) never read the person's running apps.
            runningAppIDs: presentsWindows ? { LaunchaModel.runningAppIDs() } : { [] })
        launcha = LaunchaController(model: launchaModel, presentsWindow: presentsWindows)
        launcha.onBeginShortcutRecording = { [weak self] owner in self?.beginHotkeyRecording(owner) }
        launcha.onEndShortcutRecording = { [weak self] owner in self?.endHotkeyRecording(owner) }
        launcha.onSaveShortcut = { [weak self] row, hotkey in
            guard let self else { throw CancellationError() }
            try self.setAppShortcut(for: row, hotkey: hotkey)
        }
        themeObserver = NotificationCenter.default.addObserver(
            forName: ThemeStore.didChangeNotification, object: self.theme, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.syncConfigFromTheme() }
        }
    }

    deinit {
        if let themeObserver { NotificationCenter.default.removeObserver(themeObserver) }
    }

    private func syncConfigFromTheme() {
        guard !syncingTheme else { return }
        let nextAppearance = Appearance(theme.appearance)
        let nextPalette = theme.palette
        guard config.appearance != nextAppearance || config.theme != nextPalette else { return }
        update {
            $0.appearance = nextAppearance
            $0.theme = nextPalette
        }
    }

    var leaderDisplay: String { config.leaders.isEmpty ? "Not set" : config.leaderDisplay }
    var isLeaderActive: Bool { (hotkeyStatus == .active || alternateLeaderStatus == .active) && !isPaused }

    var hotkeyProblem: String? {
        leaderProblem(alternate: false) ?? leaderProblem(alternate: true)
    }

    func leaderProblem(alternate: Bool) -> String? {
        let kind: ConfigIssue.Kind = alternate ? .invalidAlternateLeader : .invalidLeader
        if let issue = issues.first(where: { $0.kind == kind }) { return issue.message }
        if case .failed(let reason) = alternate ? alternateLeaderStatus : hotkeyStatus { return reason }
        return nil
    }

    /// The menu-bar item shows its problem mark.
    var needsAttention: Bool {
        configError != nil || hotkeyProblem != nil || launchaHotkeyProblem != nil || clipbawdHotkeyProblem != nil
            || chattaHotkeyProblem != nil || !microAppIssues.isEmpty
            || !launcha.chrome.appShortcutProblems.isEmpty || !microHotkeyProblems.isEmpty
            || windowHotkeyStatuses.values.contains { if case .failed = $0 { true } else { false } }
            || issues.contains { $0.kind == .appHotkey || $0.kind == .microHotkey || $0.kind == .windowHotkey }
    }

    /// Why a window command's hotkey does not work: invalid, reserved, duplicate or taken by another app.
    func windowHotkeyProblem(_ command: WindowCommand) -> String? {
        if let problem = assignments.windowProblems[command] { return problem }
        if case .failed(let reason) = windowHotkeyStatuses[command] { return reason }
        return nil
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

    /// Why the clipbawd hotkey does not work: invalid, the same as another Ting key, or taken.
    var clipbawdHotkeyProblem: String? {
        guard config.clipbawd.enabled else { return nil }
        if let issue = issues.first(where: { $0.kind == .invalidClipbawdHotkey || $0.kind == .clipbawdHotkeyConflict }) {
            return issue.message
        }
        switch clipbawdHotkeyStatus {
        case .failed(let reason): return reason
        case .inactive, .active: return nil
        }
    }

    /// Why the chatta hotkey does not work: invalid, the same as another Ting key, or taken.
    var chattaHotkeyProblem: String? {
        if let issue = issues.first(where: { $0.kind == .invalidChattaHotkey || $0.kind == .chattaHotkeyConflict }) {
            return issue.message
        }
        switch chattaHotkeyStatus {
        case .failed(let reason): return reason
        case .inactive, .active: return nil
        }
    }

    // MARK: Lifecycle

    func start() {
        hotkeys.onStatusChange = { [weak self] slot, status in
            switch slot {
            case .leader: self?.hotkeyStatus = status
            case .alternateLeader: self?.alternateLeaderStatus = status
            case .launcha: self?.launchaHotkeyStatus = status
            case .clipbawd: self?.clipbawdHotkeyStatus = status
            case .chatta: self?.chattaHotkeyStatus = status
            case .application: self?.refreshAppShortcutProblems()
            case .micro: self?.refreshMicroShortcutProblems()
            case .window: self?.refreshWindowShortcutProblems()
            }
        }
        hotkeys.onPress = { [weak self] slot, time in self?.hotkeyPressed(slot, at: time) }
        hotkeys.onRelease = { [weak self] slot in self?.hotkeyReleased(slot) }
        hotkeys.onUnclaimedExtendedKey = { [weak self] event in self?.extendedKeyUnclaimed(event) }
        leader.onRun = { [weak self] item in self?.run(item) }
        leader.onDoubleTap = { [weak self] in self?.launcha.open() }
        runner.onPlaySound = { [weak self] in
            DispatchQueue.main.async { [weak self] in self?.playSound() }
        }
        leader.onOpenSettings = { [weak self] in self?.openSettingsFromLauncher() }
        launcha.onOpenSettings = { [weak self] in self?.openSettingsFromLauncher() }
        clipbawdPanel.onOpenSettings = { [weak self] in self?.openSettingsFromLauncher() }
        schedule.onOpenSettings = { [weak self] in self?.openSettingsFromLauncher(page: .schedule) }
        launchaModel.onCopyValue = { [weak self] value in self?.copyValue(value) }
        launchaModel.onStartMicro = { [weak self] start in
            switch start {
            case .id(let id): self?.microFlow.start(id: id)
            case .file(let file): self?.microFlow.start(file: file)
            }
        }
        runner.onError = { [weak self] message in self?.toast.show(message) }
        clipbawdPanel.onToast = { [weak self] message in self?.toast.show(message) }
        clipbawdPanel.onPasteError = { [weak self] error in
            if error.needsAccessibility { self?.accessibility.show() }
            self?.toast.show("Copied, not pasted: \(error.localizedDescription)")
        }
        clipbawdPanel.onExclude = { [weak self] source in
            guard let id = source.bundleID else { return }
            self?.update { _ = $0.clipbawd.exclude(app: id) }
            self?.toast.show("clipbawd will never keep copies from \(source.name).")
        }
        launchaModel.onOpenClipbawd = { [weak self] in self?.openClipbawd() }
        launchaModel.onOpenSchedule = { [weak self] in self?.openSchedule() }
        launchaModel.onOpenChatta = { [weak self] in self?.openChatta() }
        microFlow.clipboardSnapshot = { [weak self] in self?.clipbawd.microAppSnapshot() }
        microFlow.onToast = { [weak self] message in self?.toast.show(message) }
        microFlow.onAccessibilityNeeded = { [weak self] in self?.accessibility.show() }
        accessibility.onGranted = { [weak self] in self?.toast.show("Accessibility is on. Try the action again.") }
        microFlow.folderDisplay = { [weak self] in self?.microStore.displayPath ?? "the micro-apps folder" }

        if !store.fileExists {
            do {
                try store.write(.sample)
            } catch {
                apply(.sample)
                configError = "Cannot create \(store.displayPath): \(error.localizedDescription)"
            }
        }
        // The user's PATH is read at start (the first load) and again on each load of the folder.
        microStore.onLoad = { UserPATH.refresh() }
        reload()
        store.watch { [weak self] in self?.reload() }
        microStore.watch { [weak self] previous, current in
            self?.applyMicroApps(current)
            if let message = current.toastMessage(since: previous) { self?.toast.show(message) }
        }
        launchaModel.prewarm()
    }

    /// Loads the config file and the micro-apps folder again.
    func reload() {
        switch store.load() {
        case .success(let loaded):
            configError = nil
            apply(loaded, reloadMicroApps: false)
        case .failure(let error):
            configError = error.message
        }
        applyMicroApps(microStore.load())
    }

    private func applyMicroApps(_ loaded: MicroAppCatalog) {
        var catalog = loaded
        catalog.iconOverrides = config.microIcons
        leader.setMicroApps(catalog)
        microFlow.setCatalog(catalog)
        launchaModel.setMicroApps(catalog.launchaCandidates(bindings: config.items), folder: microStore.folderURL)
        if microApps != catalog.entries { microApps = catalog.entries }
        if microAppIssues != catalog.issues { microAppIssues = catalog.issues }
    }

    /// The loaded micro-apps, for the bindings editor and the Settings list.
    var microCatalog: MicroAppCatalog {
        var catalog = MicroAppCatalog(entries: microApps)
        catalog.iconOverrides = config.microIcons
        return catalog
    }

    /// Opens the micro-apps folder in Finder and creates it first when it is missing. The folder
    /// watch sees the new folder and loads it. Returns an error message when the folder cannot
    /// be created or opened.
    @discardableResult
    func openMicroAppsFolder() -> String? {
        let url = microStore.folderURL
        do {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        } catch {
            return "Cannot create \(microStore.displayPath): \(error.localizedDescription)"
        }
        return NSWorkspace.shared.open(url) ? nil : "Cannot open \(microStore.displayPath) in Finder."
    }

    /// Puts the agent prompt on the clipboard and shows the toast.
    /// The value of a launcha calculation goes to the clipboard.
    func copyValue(_ value: String, pasteboard: NSPasteboard = .general) {
        pasteboard.clearContents()
        pasteboard.setString(value, forType: .string)
        toast.show("Copied \(value)")
    }

    func copyAgentPrompt(pasteboard: NSPasteboard = .general) {
        AgentPromptSource.copy(AgentPromptSource.text(), to: pasteboard)
        toast.show(AgentPrompt.toast)
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

    /// nil removes the clipbawd hotkey.
    func setClipbawdHotkey(_ hotkey: Hotkey?) {
        update { $0.clipbawd.hotkey = hotkey }
    }

    /// nil removes the chatta hotkey.
    func setChattaHotkey(_ hotkey: Hotkey?) {
        update { $0.chatta.hotkey = hotkey }
    }

    /// The one hotkey of a micro-app, set in Settings; nil removes it.
    func setMicroHotkey(_ hotkey: Hotkey?, for micro: String) {
        update { MicroShortcutRules.assign(hotkey, to: micro, in: &$0) }
    }

    /// The icon of a micro-app, set in Settings; nil or an empty text removes it, so the `icon` key of the file shows again.
    /// A text that is not an icon changes nothing.
    func setMicroIcon(_ icon: String?, for micro: String) {
        let text = icon?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard text.isEmpty || MicroIcon(text) != nil else { return }
        update { $0.microIcons[micro] = text.isEmpty ? nil : text }
    }

    /// The direct hotkey of a window command; nil removes it. A refused key keeps the old one.
    func setWindowHotkey(_ command: WindowCommand, hotkey: Hotkey?) throws {
        var next = config
        try WindowShortcutRules.assign(command: command, hotkey: hotkey, in: &next)
        // The recorder suspends Ting's registrations first. OS conflicts fail without a save.
        if let hotkey, isRecordingHotkey, let error = hotkeys.checkAvailable(hotkey) {
            throw NSError(domain: "io.bobuk.ting.window-shortcuts", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: error])
        }
        try store.write(next)
        configError = nil
        apply(next)
    }

    /// Saves exactly the retained app selected in launcha, never a different bundle-ID match.
    func setAppShortcut(for row: LaunchaRow, hotkey: Hotkey?) throws {
        guard case .app(let url) = row.kind else { throw AppShortcutRules.Problem.invalidTarget }
        let id = row.id
        var next = config
        if let hotkey {
            let shortcut = AppShortcut(id: id, name: row.name, path: url.path, hotkey: hotkey)
            try AppShortcutRules.assign(shortcut, in: &next)
            // The editor suspends Ting's registrations first. OS conflicts fail without a save.
            if isRecordingHotkey, let error = hotkeys.checkAvailable(hotkey) {
                throw NSError(domain: "io.bobuk.ting.shortcuts", code: 1,
                              userInfo: [NSLocalizedDescriptionKey: error])
            }
        } else { next.appHotkeys.removeAll { $0.id == id } }
        try store.write(next)
        configError = nil
        apply(next)
    }

    private func refreshAppShortcutProblems() {
        var problems: [String: String] = [:]
        for (index, shortcut) in activeAppShortcuts.enumerated() {
            if case .failed(let reason) = hotkeys.status(.application(index)) { problems[shortcut.id] = reason }
        }
        launcha.chrome.appShortcutProblems = problems
    }

    private func refreshWindowShortcutProblems() {
        var statuses: [WindowCommand: HotkeyService.Status] = [:]
        for (index, shortcut) in activeWindowShortcuts.enumerated() {
            statuses[shortcut.command] = hotkeys.status(.window(index))
        }
        if windowHotkeyStatuses != statuses { windowHotkeyStatuses = statuses }
    }

    private func refreshMicroShortcutProblems() {
        var problems: [String: String] = [:]
        for (index, shortcut) in activeMicroShortcuts.enumerated() where problems[shortcut.micro] == nil {
            if case .failed(let reason) = hotkeys.status(.micro(index)) { problems[shortcut.micro] = reason }
        }
        if microHotkeyProblems != problems { microHotkeyProblems = problems }
    }

    /// Turns all hotkeys off until `owner` ends recording. A new recording cancels the
    /// previous one; the hotkeys stay off between them.
    func beginHotkeyRecording(_ owner: HotkeyRecordingOwner) {
        recordingGate.begin(owner)
    }

    /// Turns the hotkeys back on only if `owner` is the current recording.
    func endHotkeyRecording(_ owner: HotkeyRecordingOwner) {
        recordingGate.end(owner)
    }

    /// `handler` gets the extended keys (Stop, Again…) that no hotkey takes until `stop…(owner)`.
    func listenForExtendedKeys(_ owner: AnyObject, _ handler: @escaping (ExtendedKeyEvent) -> Void) {
        extendedKeyListener = (ObjectIdentifier(owner), handler)
    }

    func stopListeningForExtendedKeys(_ owner: AnyObject) {
        guard extendedKeyListener?.owner == ObjectIdentifier(owner) else { return }
        extendedKeyListener = nil
    }

    /// The reader exists only while the option is on; turning it off stops reading the keyboards.
    private func applyExtendedKeys(_ enabled: Bool) {
        if enabled, extendedKeySource == nil {
            extendedKeySource = makeExtendedKeys()
            hotkeys.extendedKeys = extendedKeySource
        } else if !enabled, let source = extendedKeySource {
            hotkeys.extendedKeys = nil
            (source as? HIDKeyMonitor)?.stop()
            extendedKeySource = nil
        }
    }

    /// An extended key no hotkey took goes to a recorder, or else to the open leader menu.
    func extendedKeyUnclaimed(_ event: ExtendedKeyEvent) {
        if let listener = extendedKeyListener {
            listener.handler(event)
            return
        }
        guard !isPaused, !isRecordingHotkey, !isMenuTracking else { return }
        leader.handleExtendedKey(event)
    }

    private func setRecordingHotkey(_ recording: Bool) {
        guard recording != isRecordingHotkey else { return }
        isRecordingHotkey = recording
        applyHotkey()
    }

    // MARK: launcha

    func openLauncha() {
        guard !isPaused, !isRecordingHotkey else { return }
        leader.close()
        clipbawdPanel.close()
        schedule.close()
        launcha.open()
    }

    func openClipbawd() {
        guard !isPaused, !isRecordingHotkey else { return }
        guard config.clipbawd.enabled else {
            toast.show("Clipbawd is off. Turn it on in Settings › Clipbawd.")
            return
        }
        leader.close()
        launcha.close()
        schedule.close()
        clipbawdPanel.open()
    }

    func openSchedule() {
        guard !isPaused, !isRecordingHotkey else { return }
        leader.close()
        launcha.close()
        clipbawdPanel.close()
        schedule.open()
    }

    func openChatta(mode: ChattaMode? = nil) {
        guard !isPaused, !isRecordingHotkey else { return }
        leader.close()
        launcha.close()
        clipbawdPanel.close()
        schedule.close()
        chatta.open(mode: mode)
    }

    /// ⌘, or Settings gear in selecta, launcha, clipbawd or chatta: close the launchers, then show Settings.
    func openSettingsFromLauncher(page: SettingsPage? = nil) {
        leader.close()
        launcha.close()
        clipbawdPanel.close()
        schedule.close()
        if let page {
            settingsPageOpener(page)
        } else {
            settingsOpener()
        }
    }

    /// Call only after the user read what this allows and which macOS prompts may follow.
    func setProtectedFoldersAllowed(_ allowed: Bool) {
        if allowed { launchaModel.allowProtectedFolders() } else { launchaModel.revokeProtectedFolders() }
    }

    /// Call only after the user read that macOS may ask about iCloud Drive.
    func setICloudDriveAllowed(_ allowed: Bool) {
        launchaModel.setICloudDrive(allowed)
    }

    func setScheduleCalendar(_ id: String, included: Bool) {
        let available = schedule.model.calendars.map(\.id)
        update { config in
            var selected = Set(config.schedule.calendars ?? available)
            if included { selected.insert(id) } else { selected.remove(id) }
            config.schedule.calendars = selected.sorted()
        }
        schedule.refresh()
    }

    func selectAllScheduleCalendars() {
        update { $0.schedule.calendars = nil }
        schedule.refresh()
    }

    func selectNoScheduleCalendars() {
        update { $0.schedule.calendars = [] }
        schedule.refresh()
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

    private func apply(_ next: Config, reloadMicroApps: Bool = true) {
        let previous = config
        config = next
        assignments = HotkeyAssignments(next)
        issues = assignments.issues + ConfigValidator.bindingIssues(in: next)
        runner.prepare(next.items)
        leader.configure(next)
        launcha.configure(next)
        launchaModel.clipbawdEnabled = next.clipbawd.enabled
        launchaModel.scheduleEnabled = true
        launchaModel.chattaEnabled = true
        clipbawd.configure(next.clipbawd)
        schedule.configure(next)
        clipbawdPanel.configure(next)
        chatta.configure(next.chatta)
        microStore.maxTimeLimit = next.microApps.maxTimeout
        microFlow.configure(next)
        if reloadMicroApps && next.microApps.maxTimeout != previous.microApps.maxTimeout {
            applyMicroApps(microStore.load())
        } else {
            // Binding labels name the micro-apps in launcha; `microIcons` gives their icons there and in the leader menu.
            var catalog = microStore.catalog
            catalog.iconOverrides = next.microIcons
            leader.setMicroApps(catalog)
            launchaModel.setMicroApps(catalog.launchaCandidates(bindings: next.items), folder: microStore.folderURL)
        }
        syncingTheme = true
        theme.appearance = next.appearance.choice
        theme.palette = next.theme
        if presentsWindows { theme.apply() }
        syncingTheme = false
        applyExtendedKeys(next.extendedKeys)
        applyHotkey()
        if next.launchAtLogin != previous.launchAtLogin {
            loginItemError = LoginItem.setReportingError(next.launchAtLogin, openSettingsIfNeeded: false)
        }
    }

    private func applyHotkey() {
        let active = isPaused || isRecordingHotkey ? nil : assignments
        activeAppShortcuts = active?.applications ?? []
        activeMicroShortcuts = active?.micros ?? []
        activeWindowShortcuts = active?.windows ?? []
        hotkeys.apply(active)
        if active == nil {
            leader.close()
            clipbawdPanel.close()
            schedule.close()
            if isPaused || launcha.chrome.shortcutEditor == nil { launcha.close() }
        }
        refreshAppShortcutProblems()
        refreshMicroShortcutProblems()
        refreshWindowShortcutProblems()
        hotkeyStatus = hotkeys.status(.leader)
        alternateLeaderStatus = hotkeys.status(.alternateLeader)
        launchaHotkeyStatus = hotkeys.status(.launcha)
        clipbawdHotkeyStatus = hotkeys.status(.clipbawd)
        chattaHotkeyStatus = hotkeys.status(.chatta)
    }

    func hotkeyReleased(_ slot: HotkeyService.Slot) {
        switch slot {
        case .leader: leader.leaderReleased()
        case .alternateLeader: leader.leaderReleased(.alternateLeader)
        case .launcha: launchaKey.release()
        case .clipbawd: clipbawdKey.release()
        case .chatta: chattaKey.release()
        case .application, .micro, .window: break
        }
    }

    func hotkeyPressed(_ slot: HotkeyService.Slot, at time: TimeInterval) {
        guard !isMenuTracking else { return }
        switch slot {
        case .leader, .alternateLeader:
            // The leader switches from launcha back to selecta. A repeat of a held leader
            // is ignored and leaves launcha open.
            leader.leaderPressed(at: time, source: slot == .leader ? .leader : .alternateLeader) { [launcha, clipbawdPanel, schedule] in
                if launcha.isOpen { launcha.close() }
                clipbawdPanel.close()
                schedule.close()
            }
        case .application(let index):
            guard !isPaused, !isRecordingHotkey, activeAppShortcuts.indices.contains(index) else { return }
            let shortcut = activeAppShortcuts[index]
            leader.close()
            launcha.close()
            clipbawdPanel.close()
            schedule.close()
            Task { [runner, launchaModel] in
                let outcome = await runner.openApp(at: URL(fileURLWithPath: shortcut.path), name: shortcut.name)
                await launchaModel.record(outcome, id: shortcut.id)
            }
        case .micro(let index):
            guard !isPaused, !isRecordingHotkey, activeMicroShortcuts.indices.contains(index) else { return }
            leader.close()
            launcha.close()
            clipbawdPanel.close()
            schedule.close()
            // The app in front keeps the keyboard, so `context` and `output.to: [app]` work as from the leader.
            microFlow.start(id: activeMicroShortcuts[index].micro)
        case .window(let index):
            guard !isPaused, !isRecordingHotkey, activeWindowShortcuts.indices.contains(index) else { return }
            let command = activeWindowShortcuts[index].command
            leader.close()
            launcha.close()
            clipbawdPanel.close()
            schedule.close()
            DispatchQueue.main.async { [weak self] in self?.runWindowCommand(command) }
        case .launcha:
            guard launchaKey.press(at: time, menuOpen: false, menuOpenAtRoot: false) != .ignored else { return }
            if leader.isOpen { leader.close() }
            clipbawdPanel.close()
            schedule.close()
            launcha.toggle()
        case .clipbawd:
            guard !isPaused, !isRecordingHotkey, config.clipbawd.enabled,
                  clipbawdKey.press(at: time, menuOpen: false, menuOpenAtRoot: false) != .ignored else { return }
            if leader.isOpen { leader.close() }
            if launcha.isOpen { launcha.close() }
            schedule.close()
            clipbawdPanel.toggle()
        case .chatta:
            guard !isPaused, !isRecordingHotkey,
                  chattaKey.press(at: time, menuOpen: false, menuOpenAtRoot: false) != .ignored else { return }
            if leader.isOpen { leader.close() }
            if launcha.isOpen { launcha.close() }
            clipbawdPanel.close()
            schedule.close()
            chatta.toggle()
        }
    }

    func beginMenuTracking() {
        isMenuTracking = true
        leader.suspendKeys()
        launcha.suspendKeys()
        clipbawdPanel.suspendKeys()
        schedule.suspendKeys()
    }

    /// The menu ended. A launcher takes keys again unless a chosen item opened another window.
    func endMenuTracking() {
        isMenuTracking = false
        leader.resumeKeys()
        launcha.resumeKeys()
        clipbawdPanel.resumeKeys()
        schedule.resumeKeys()
    }

    /// The "ting" for an opened app, link or file: `config.sound` at `config.soundVolume`.
    private func playSound() {
        if config.playSound { previewSound() }
    }

    /// Plays the configured sound once, whatever `playSound` says (the Settings preview).
    /// A name that cannot be loaded plays the default "Tink".
    func previewSound() {
        guard let sound = loadSound(config.sound) ?? loadSound(SystemSounds.defaultName) else { return }
        sound.stop()
        sound.volume = Float(config.soundVolume)
        sound.play()
    }

    private func loadSound(_ name: String) -> NSSound? {
        if let cached = sounds[name] { return cached }
        let sound = NSSound(named: NSSound.Name(name))
        sounds[name] = sound
        return sound
    }

    /// Opens a selecta binding and counts a successful launch once. A micro-app binding starts
    /// its flow; a missing or broken micro-app only shows its error.
    private func run(_ item: Item) {
        if case .micro(let id) = item.action {
            microFlow.start(id: id)
            return
        }
        if case .open(let panel) = item.action {
            // The leader panel is closing: open once it has handed the keyboard back.
            DispatchQueue.main.async { [weak self] in
                switch panel {
                case .launcha: self?.openLauncha()
                case .clipbawd: self?.openClipbawd()
                case .schedule: self?.openSchedule()
                case .chatta: self?.openChatta()
                }
            }
            return
        }
        if case .window(let command) = item.action {
            runWindowCommand(command)
            return
        }
        let id: String? = switch item.action {
        case .app(let bundleID): LaunchaCandidate.app(bundleID: bundleID, name: "").id
        case .url(let url): LaunchaCandidate.url(url, name: "").id
        case .group, .micro, .open, .window: nil
        }
        let activated = runner.activateRunning(item)
        Task {
            let outcome: LaunchOutcome
            if let activated { outcome = activated } else { outcome = await runner.run(item) }
            if let id { await launchaModel.record(outcome, id: id) }
        }
    }

    /// Moves or resizes the focused window off the main thread. Without Accessibility, the guide
    /// window explains it; other failures show a toast. Tests await the returned task.
    @discardableResult
    func runWindowCommand(_ command: WindowCommand) -> Task<Void, Never> {
        let gap = config.windowManagement.gap
        return Task { [weak self, windowManager] in
            do {
                try await windowManager.run(command, gap: gap)
            } catch WindowManagementError.accessibility {
                self?.accessibility.show()
            } catch {
                self?.toast.show(error.localizedDescription)
            }
        }
    }
}

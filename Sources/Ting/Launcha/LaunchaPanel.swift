// The launcha window: a non-activating panel with a real text input. Unlike the selecta
// panel it never routes keys to the sequence handler, so typing, paste and input methods work.
import AppKit
import SwiftUI
import TingCore

extension Notification.Name {
    static let launchaEditAppShortcut = Notification.Name("io.bobuk.ting.launcha.editAppShortcut")
    static let launchaRemoveAppShortcut = Notification.Name("io.bobuk.ting.launcha.removeAppShortcut")
}

final class LaunchaPanel: NSPanel {
    /// ⌘↩: show the selected result in Finder.
    var onReveal: (() -> Void)?
    /// List navigation must keep working when Tab moves focus away from the search field.
    var onMove: ((Int) -> Void)?
    var onEditShortcut: (() -> Void)?
    /// ⌘,: open Settings.
    var onOpenSettings: (() -> Void)?
    /// Returns true only while the inline recorder owns the panel's key events.
    var onRecordShortcut: ((NSEvent) -> Bool)?

    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 520, height: 600),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        isFloatingPanel = true
        level = .popUpMenu
        // Every Space and above full-screen apps, like the selecta panel.
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = false
        isReleasedWhenClosed = false
        animationBehavior = .none
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    static func navigationDelta(keyCode: UInt16, flags: NSEvent.ModifierFlags, composing: Bool) -> Int? {
        guard !composing, flags.intersection([.command, .shift, .option, .control]).isEmpty else { return nil }
        switch keyCode {
        case 126: return -1
        case 125: return 1
        case 116: return -8
        case 121: return 8
        default: return nil
        }
    }

    override func sendEvent(_ event: NSEvent) {
        if (event.type == .keyDown || event.type == .flagsChanged), onRecordShortcut?(event) == true { return }
        if event.type == .keyDown, let onMove,
           let delta = Self.navigationDelta(keyCode: event.keyCode, flags: event.modifierFlags,
                                           composing: (firstResponder as? NSTextView)?.hasMarkedText() == true) {
            onMove(delta)
            return
        }
        super.sendEvent(event)
    }

    /// What the panel does with a ⌘ key equivalent.
    enum KeyEquivalentRoute: Equatable {
        /// Not a ⌘ shortcut, or text navigation and deletion: the text editor handles it.
        case editor
        /// ⌘↩: show the selected result in Finder.
        case reveal
        case editShortcut
        /// ⌘,: open Settings.
        case settings
        /// A text command sent to the field through the responder chain.
        case action(Selector)
        /// Any other ⌘ shortcut, for example ⌘Q: ignored, so it never reaches Ting's menu.
        case swallow
    }

    /// Arrow keys, ⌫ and ⌦: ⌘ moves or deletes to the line edge, also with ⇧ or ⌥.
    private static let editingKeyCodes: Set<UInt16> = [51, 117, 123, 124, 125, 126]

    /// Ting has no Edit menu while it is not the active app, so text shortcuts are sent
    /// to the field here. Keys are matched by the Latin layout, so ⌘V also works with
    /// Russian or Ukrainian input. ⌘ with arrows, ⌫ or ⌦ goes to the text editor.
    /// ⌘, opens Settings. Other ⌘ shortcuts are swallowed: ⌘Q must not quit Ting.
    static func route(keyCode: UInt16, latin: String?, flags: NSEvent.ModifierFlags) -> KeyEquivalentRoute {
        let flags = flags.intersection([.command, .shift, .option, .control])
        guard flags.contains(.command) else { return .editor }
        if latin == "k", flags == [.command, .shift] { return .editShortcut }
        if SettingsOpener.isShortcut(latin: latin, flags: flags) { return .settings }
        if editingKeyCodes.contains(keyCode) { return .editor }
        if keyCode == 36 || keyCode == 76 { return flags == .command ? .reveal : .swallow }
        let action: String? = switch (latin ?? "", flags) {
        case ("x", .command): "cut:"
        case ("c", .command): "copy:"
        case ("v", .command): "paste:"
        case ("a", .command): "selectAll:"
        case ("z", .command): "undo:"
        case ("z", [.command, .shift]): "redo:"
        default: nil
        }
        return action.map { .action(Selector($0)) } ?? .swallow
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard event.type == .keyDown else { return super.performKeyEquivalent(with: event) }
        if onRecordShortcut?(event) == true { return true }
        switch Self.route(keyCode: event.keyCode, latin: KeyTranslator.latin(event.keyCode), flags: event.modifierFlags) {
        case .editor:
            // Text navigation returns false at once: the event then reaches the field's
            // `keyDown`. Other keys keep the default window handling.
            if event.modifierFlags.contains(.command) { return false }
            return super.performKeyEquivalent(with: event)
        case .editShortcut:
            if (firstResponder as? NSTextView)?.hasMarkedText() != true { onEditShortcut?() }
            return true
        case .reveal:
            let composing = (firstResponder as? NSTextView)?.hasMarkedText() == true
            if !composing { onReveal?() }
            return true
        case .settings:
            if !event.isARepeat, (firstResponder as? NSTextView)?.hasMarkedText() != true { onOpenSettings?() }
            return true
        case .action(let selector):
            NSApp.sendAction(selector, to: nil, from: self)
            return true
        case .swallow:
            return true
        }
    }
}

/// Presentation settings of the launcha panel, from the config.
@MainActor
@Observable
final class LaunchaChrome {
    var showHeader = true
    /// Tooltip and spoken label of the double tuning fork: the real keys that open launcha.
    var tokenDescription = "Open launcha"
    var leader = ""
    var maxListHeight: CGFloat = 360
    /// Bumped on every open to move focus into the search field.
    var focusToken = 0
    var appHotkeys: [AppShortcut] = []
    var appShortcutProblems: [String: String] = [:]
    var shortcutEditor: LaunchaShortcutEditor?
    @ObservationIgnored let icons = LaunchaIconCache()
}

/// Shows and hides the launcha panel for `LaunchaModel`.
@MainActor
final class LaunchaController: NSObject, NSWindowDelegate {
    let model: LaunchaModel
    let chrome = LaunchaChrome()
    private var panel: LaunchaPanel?
    private var observers: [NSObjectProtocol] = []
    private var config = Config()
    var onBeginShortcutRecording: ((HotkeyRecordingOwner) -> Void)?
    var onEndShortcutRecording: ((HotkeyRecordingOwner) -> Void)?
    var onSaveShortcut: ((LaunchaRow, Hotkey?) throws -> Void)?
    /// ⌘, in the panel.
    var onOpenSettings: (() -> Void)?

    var isOpen: Bool { model.isOpen }

    /// Tests exercise the controller without showing a window or taking keyboard focus.
    private let presentsWindow: Bool

    init(model: LaunchaModel, presentsWindow: Bool = true) {
        self.model = model
        self.presentsWindow = presentsWindow
        super.init()
        model.onRequestClose = { [weak self] in self?.hidePanel() }
        // A Space change leaves the panel behind on the old Space: close it.
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.close() }
            })
        observers.append(NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.close() }
            })
    }

    func configure(_ config: Config) {
        self.config = config
        chrome.appHotkeys = config.appHotkeys
        chrome.showHeader = config.showPanelHeader
        chrome.leader = config.leader?.display ?? ""
        chrome.tokenDescription = Self.tokenDescription(config)
        model.calculator = config.launcha.calculator
        model.converter = config.launcha.converter
    }

    /// The real keys that open launcha, e.g. "Open launcha: ⌥Space pressed twice, or ⌘K".
    static func tokenDescription(_ config: Config) -> String {
        var ways: [String] = []
        if config.launcha.doubleTap, let leader = config.leader { ways.append("\(leader.display) pressed twice") }
        if let hotkey = config.launcha.hotkey, hotkey.isValid, hotkey != config.leader { ways.append(hotkey.display) }
        return ways.isEmpty ? "Open launcha" : "Open launcha: " + ways.joined(separator: ", or ")
    }

    func toggle() {
        if isOpen { close() } else { open() }
    }

    func open() {
        guard !isOpen else { return }
        guard presentsWindow else {
            model.open()
            return
        }
        let panel = self.panel ?? makePanel()
        let screen = NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) } ?? NSScreen.main
        if let visible = screen?.visibleFrame {
            // Card near the upper third, so it does not jump while the list grows.
            let top = visible.maxY - max(40, visible.height * 0.16)
            let height = max(240, min(640, top - visible.minY - 20))
            let width: CGFloat = 520
            panel.setFrame(NSRect(x: visible.midX - width / 2, y: top - height, width: width, height: height), display: false)
            // Header, input, footer and notices take about 200 points.
            chrome.maxListHeight = max(120, min(420, height - 220))
        }
        model.open()
        chrome.focusToken += 1
        panel.alphaValue = 1
        panel.makeKeyAndOrderFront(nil)
        panel.orderFrontRegardless()
    }

    func close() {
        chrome.shortcutEditor?.cancel()
        hidePanel()
        model.close()
    }

    private func hidePanel() {
        panel?.orderOut(nil)
    }

    func editShortcut(for row: LaunchaRow? = nil) {
        guard isOpen, let row = row ?? model.selectedRow, row.isApp else { return }
        chrome.shortcutEditor?.cancel()
        let original = config.appHotkeys.first { $0.id == row.id }?.hotkey
        let editor = LaunchaShortcutEditor(row: row, original: original)
        editor.validate = { [weak self] hotkey in
            guard let self else { return "The launcher closed." }
            return AppShortcutRules.problem(for: hotkey, in: self.config)?.description
        }
        editor.persist = { [weak self] hotkey in
            guard let self, let save = self.onSaveShortcut else {
                throw NSError(domain: "io.bobuk.ting.shortcuts", code: 1,
                              userInfo: [NSLocalizedDescriptionKey: "Cannot save this shortcut."])
            }
            try save(row, hotkey)
        }
        editor.replacing = { [weak self] hotkey in
            self?.config.appHotkeys.first { $0.id != row.id && $0.hotkey == hotkey }?.name
        }
        editor.onFinish = { [weak self, weak editor] in
            guard let self, let editor else { return }
            self.chrome.shortcutEditor = nil
            self.onEndShortcutRecording?(editor)
            self.chrome.focusToken += 1
        }
        chrome.shortcutEditor = editor
        onBeginShortcutRecording?(editor)
    }

    private func makePanel() -> LaunchaPanel {
        let panel = LaunchaPanel()
        panel.delegate = self
        panel.onReveal = { [weak self] in self?.activate(reveal: true) }
        panel.onMove = { [weak self] delta in self?.model.moveSelection(by: delta) }
        panel.onEditShortcut = { [weak self] in self?.editShortcut() }
        panel.onOpenSettings = { [weak self] in self?.onOpenSettings?() }
        observers.append(NotificationCenter.default.addObserver(
            forName: .launchaEditAppShortcut, object: nil, queue: .main) { [weak self] notification in
                MainActor.assumeIsolated {
                    guard let self, let id = notification.object as? String,
                          let row = self.model.rows.first(where: { $0.id == id }) else { return }
                    self.editShortcut(for: row)
                }
            })
        observers.append(NotificationCenter.default.addObserver(
            forName: .launchaRemoveAppShortcut, object: nil, queue: .main) { [weak self] notification in
                MainActor.assumeIsolated {
                    guard let self, let id = notification.object as? String,
                          let row = self.model.rows.first(where: { $0.id == id }) else { return }
                    do { try self.onSaveShortcut?(row, nil) }
                    catch { self.chrome.appShortcutProblems[id] = error.localizedDescription }
                }
            })
        panel.onRecordShortcut = { [weak self] event in
            guard let editor = self?.chrome.shortcutEditor else { return false }
            return editor.handlePanelEvent(event)
        }
        let view = LaunchaView(model: model, chrome: chrome,
                               onActivate: { [weak self] reveal in self?.activate(reveal: reveal) },
                               onDismiss: { [weak self] in self?.close() },
                               onEditShortcut: { [weak self] row in self?.editShortcut(for: row) })
        let hosting = NSHostingView(rootView: view)
        hosting.sizingOptions = []
        panel.contentView = hosting
        self.panel = panel
        return panel
    }

    private func activate(reveal: Bool) {
        guard isOpen, chrome.shortcutEditor == nil else { return }
        Task { await model.activateSelection(reveal: reveal) }
    }

    /// Set while a menu tracks over the panel: losing key status keeps it open.
    var keysSuspended = false

    /// The menu is gone: take keys again, or close if another window took focus meanwhile.
    func resumeKeys() {
        keysSuspended = false
        guard isOpen, let panel else { return }
        if let key = NSApp.keyWindow, key !== panel { close() } else { panel.makeKeyAndOrderFront(nil) }
    }

    func windowDidResignKey(_ notification: Notification) {
        guard isOpen, !keysSuspended else { return }
        close()
    }
}

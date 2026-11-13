// The launcha window: a non-activating panel with a real text input. Unlike the selecta
// panel it never routes keys to the sequence handler, so typing, paste and input methods work.
import AppKit
import SwiftUI
import TingCore

final class LaunchaPanel: NSPanel {
    /// ⌘↩: show the selected result in Finder.
    var onReveal: (() -> Void)?

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

    /// What the panel does with a ⌘ key equivalent.
    enum KeyEquivalentRoute: Equatable {
        /// Not a ⌘ shortcut, or text navigation and deletion: the text editor handles it.
        case editor
        /// ⌘↩: show the selected result in Finder.
        case reveal
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
    /// Other ⌘ shortcuts are swallowed: ⌘Q must not quit Ting.
    static func route(keyCode: UInt16, latin: String?, flags: NSEvent.ModifierFlags) -> KeyEquivalentRoute {
        let flags = flags.intersection([.command, .shift, .option, .control])
        guard flags.contains(.command) else { return .editor }
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
        switch Self.route(keyCode: event.keyCode, latin: KeyTranslator.latin(event.keyCode), flags: event.modifierFlags) {
        case .editor:
            // Text navigation returns false at once: the event then reaches the field's
            // `keyDown`. Other keys keep the default window handling.
            if event.modifierFlags.contains(.command) { return false }
            return super.performKeyEquivalent(with: event)
        case .reveal:
            let composing = (firstResponder as? NSTextView)?.hasMarkedText() == true
            if !composing { onReveal?() }
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
    @ObservationIgnored let icons = LaunchaIconCache()
}

/// Shows and hides the launcha panel for `LaunchaModel`.
@MainActor
final class LaunchaController: NSObject, NSWindowDelegate {
    let model: LaunchaModel
    let chrome = LaunchaChrome()
    private var panel: LaunchaPanel?
    private var observers: [NSObjectProtocol] = []

    var isOpen: Bool { model.isOpen }

    init(model: LaunchaModel) {
        self.model = model
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
        chrome.showHeader = config.showPanelHeader
        chrome.leader = config.leader?.display ?? ""
        chrome.tokenDescription = Self.tokenDescription(config)
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
        hidePanel()
        model.close()
    }

    private func hidePanel() {
        panel?.orderOut(nil)
    }

    private func makePanel() -> LaunchaPanel {
        let panel = LaunchaPanel()
        panel.delegate = self
        panel.onReveal = { [weak self] in self?.activate(reveal: true) }
        let view = LaunchaView(model: model, chrome: chrome,
                               onActivate: { [weak self] reveal in self?.activate(reveal: reveal) },
                               onDismiss: { [weak self] in self?.close() })
        let hosting = NSHostingView(rootView: view)
        hosting.sizingOptions = []
        panel.contentView = hosting
        self.panel = panel
        return panel
    }

    private func activate(reveal: Bool) {
        guard isOpen else { return }
        Task { await model.activateSelection(reveal: reveal) }
    }

    func windowDidResignKey(_ notification: Notification) {
        guard isOpen else { return }
        close()
    }
}

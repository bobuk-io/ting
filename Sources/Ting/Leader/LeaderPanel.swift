// The leader menu window: a non-activating panel that takes keyboard focus at once,
// so keys typed after the leader never reach the front app.
import AppKit
import SwiftUI
import TingCore

final class LeaderPanel: NSPanel {
    /// Every keyDown goes here instead of the responder chain.
    var onKeyDown: ((NSEvent) -> Void)?
    /// Key releases, a second source for the leader release next to Carbon.
    var onKeyUp: ((NSEvent) -> Void)?
    /// ⌘,: open Settings.
    var onOpenSettings: (() -> Void)?

    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 460, height: 640),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        isFloatingPanel = true
        level = .popUpMenu
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = false
        isReleasedWhenClosed = false
        animationBehavior = .none
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown {
            onKeyDown?(event)
            return
        }
        if event.type == .keyUp { onKeyUp?(event) }
        super.sendEvent(event)
    }

    /// Swallow ⌘ shortcuts so, for example, ⌘Q does not quit Ting while the menu is up.
    /// ⌘, is the exception: it opens Settings.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        // AppKit also offers arrows here before sendEvent. Claiming every event
        // discards navigation before the controller can see it.
        guard event.type == .keyDown, event.modifierFlags.contains(.command) else { return false }
        if !event.isARepeat,
           SettingsOpener.isShortcut(latin: KeyTranslator.latin(event.keyCode), flags: event.modifierFlags) {
            onOpenSettings?()
        }
        return true
    }
}

/// What the leader menu shows. Updated by `LeaderController`.
@MainActor
@Observable
final class LeaderSession {
    var leader = ""
    var showPanelHeader = true
    var path: [String] = []
    var items: [Item] = []
    var selection = 0
    var selectedItem: Item? { items.indices.contains(selection) ? items[selection] : nil }
    var shakeToken = 0
    /// The loaded micro-apps, for the names and the "not working" mark of micro-app bindings.
    var microApps = MicroAppCatalog()
}

/// Drives the leader panel with `LeaderMachine`.
@MainActor
final class LeaderController: NSObject, NSWindowDelegate {
    let session = LeaderSession()
    /// Called after the panel closed for an action.
    var onRun: ((Item) -> Void)?
    /// A root double tap of the leader: the menu is closed, open launcha.
    var onDoubleTap: (() -> Void)?
    /// ⌘, in the menu.
    var onOpenSettings: (() -> Void)?

    private var machine = LeaderMachine(items: [])
    private var doubleTap = LeaderDoubleTap()
    private var leaderKeyCode: UInt16?
    private var showDelay: TimeInterval = 0.25
    private var panel: LeaderPanel?
    private var reveal: DispatchWorkItem?
    private let presentsWindow: Bool

    /// Tests exercise the controller without showing a window or taking keyboard focus.
    init(presentsWindow: Bool = true) {
        self.presentsWindow = presentsWindow
        super.init()
    }

    var isOpen: Bool { machine.isOpen }

    func setMicroApps(_ catalog: MicroAppCatalog) {
        if session.microApps != catalog { session.microApps = catalog }
    }

    func configure(_ config: Config) {
        let selectedKey = session.selectedItem?.key
        machine.items = config.items
        AppIcons.prepare(config.items)
        if !machine.isOpen {
            session.path = []
            session.items = config.items
        }
        machine.unknownKey = config.unknownKey
        showDelay = config.showDelay
        session.leader = config.leader?.display ?? ""
        doubleTap.isEnabled = config.launcha.doubleTap && config.leader != nil
        doubleTap.window = config.launcha.doubleTapWindow
        if case .combo(let keyCode, _)? = config.leader { leaderKeyCode = keyCode } else { leaderKeyCode = nil }
        session.showPanelHeader = config.showPanelHeader
        if machine.isOpen {
            session.path = machine.path
            session.items = machine.currentItems
        }
        session.selection = session.items.firstIndex(where: { $0.key == selectedKey }) ?? 0
    }

    /// The leader hotkey went down. `time` is any monotonic clock in seconds.
    /// The first press acts at once; only the second press of a root double tap opens launcha.
    /// `accepted` runs before the press acts, and not at all for an ignored repeat.
    func leaderPressed(at time: TimeInterval = ProcessInfo.processInfo.systemUptime, accepted: () -> Void = {}) {
        let press = doubleTap.press(at: time, machine: machine)
        guard press != .ignored else { return }
        accepted()
        switch press {
        case .ignored:
            return
        case .double:
            machine.reset()
            hide()
            onDoubleTap?()
        case .single:
            apply(machine.handle(.leader))
        }
    }

    /// The leader hotkey went up (from Carbon, or the panel saw the key up).
    func leaderReleased() {
        doubleTap.release()
    }

    func close() {
        machine.reset()
        doubleTap.reset()
        hide()
    }

    // MARK: Events

    /// Set while a menu tracks over the panel: no keys, and losing key status keeps it open.
    var keysSuspended = false

    /// The menu is gone: take keys again, or close if another window took focus meanwhile.
    func resumeKeys() {
        keysSuspended = false
        guard machine.isOpen, presentsWindow, let panel else { return }
        if let key = NSApp.keyWindow, key !== panel { close() } else { panel.makeKeyAndOrderFront(nil) }
    }

    func handleKeyDown(_ event: NSEvent) {
        guard machine.isOpen, !keysSuspended else { return }
        let plain = event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty
        if plain, event.keyCode == 125 || event.keyCode == 126 {
            doubleTap.sequenceInput()
            let delta = event.keyCode == 125 ? 1 : -1
            session.selection = min(max(session.selection + delta, 0), max(0, session.items.count - 1))
            reveal?.perform()
            return
        }
        guard !event.isARepeat else { return }
        // Any key in between: the next leader press is not a double tap.
        doubleTap.sequenceInput()
        if plain {
            switch event.keyCode {
            case 123:
                apply(machine.handle(.back))
                return
            case 124:
                if let item = session.selectedItem, item.isGroup { select(item.key) }
                return
            case 36, 76:
                if !session.items.contains(where: { $0.key == "return" }) {
                    if let item = session.selectedItem { select(item.key) }
                    return
                }
            default: break
            }
        }
        // Modified arrows are not sequence keys and must not close or shake the menu.
        if (123...126).contains(event.keyCode) { return }
        switch event.keyCode {
        case 53:
            apply(machine.handle(.escape))
        case 51, 117:
            apply(machine.handle(.back))
        default:
            let flags = event.modifierFlags
            if flags.contains(.command) || flags.contains(.control) { return }
            guard let name = SequenceKey.name(keyCode: event.keyCode, latin: KeyTranslator.latin(event.keyCode)) else {
                // Not a bindable key: same reaction as an unknown binding.
                if machine.unknownKey == .close { close() } else { shake() }
                return
            }
            apply(machine.handle(.key(name)))
        }
    }

    func select(_ key: String) {
        guard machine.isOpen else { return }
        doubleTap.sequenceInput()
        apply(machine.handle(.key(key)))
    }

    private func apply(_ effect: LeaderEffect) {
        switch effect {
        case .none:
            break
        case .open:
            present()
        case .show(let path):
            let returningKey = session.path.count > path.count ? session.path.last : nil
            session.path = path
            session.items = machine.currentItems
            session.selection = session.items.firstIndex(where: { $0.key == returningKey }) ?? 0
            resizePanel()
        case .run(let item):
            onRun?(item)
            hide()
        case .reject(_, let closed):
            if closed { doubleTap.reset(); hide() } else { shake() }
        case .close:
            doubleTap.reset()
            hide()
        }
    }

    private func shake() {
        reveal?.perform()
        session.shakeToken += 1
    }

    // MARK: Panel

    private func present() {
        if session.path != machine.path { session.path = machine.path }
        if session.items != machine.currentItems { session.items = machine.currentItems }
        session.selection = 0
        guard presentsWindow else { return }
        let panel = self.panel ?? makePanel()
        resizePanel()
        // Key at once, visible only after the delay: fast typing never shows the menu.
        panel.alphaValue = showDelay <= 0 ? 1 : 0
        panel.makeKeyAndOrderFront(nil)
        panel.orderFrontRegardless()
        reveal?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.panel?.alphaValue = 1 }
        }
        reveal = work
        if showDelay > 0 { DispatchQueue.main.asyncAfter(deadline: .now() + showDelay, execute: work) }
    }

    private func resizePanel() {
        guard let panel else { return }
        panel.contentView?.layoutSubtreeIfNeeded()
        let screen = NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) } ?? NSScreen.main
        guard let visible = screen?.visibleFrame else { return }
        let fitting = panel.contentView?.fittingSize ?? NSSize(width: 340, height: 640)
        let size = NSSize(width: 340, height: min(max(100, fitting.height), visible.height))
        panel.setFrame(NSRect(x: visible.midX - size.width / 2, y: visible.midY - size.height / 2,
                              width: size.width, height: size.height), display: false)
        panel.invalidateShadow()
    }

    private func hide() {
        reveal?.cancel()
        reveal = nil
        panel?.orderOut(nil)
    }

    private func makePanel() -> LeaderPanel {
        let panel = LeaderPanel()
        panel.delegate = self
        panel.onKeyDown = { [weak self] event in self?.handleKeyDown(event) }
        panel.onOpenSettings = { [weak self] in self?.onOpenSettings?() }
        panel.onKeyUp = { [weak self] event in
            guard let self, event.keyCode == self.leaderKeyCode else { return }
            self.leaderReleased()
        }
        let view = LeaderMenuView(session: session,
                                  onSelect: { [weak self] key in self?.select(key) },
                                  onDismiss: { [weak self] in self?.close() })
        let hosting = NSHostingView(rootView: view)
        hosting.sizingOptions = [.intrinsicContentSize]
        panel.contentView = hosting
        self.panel = panel
        return panel
    }

    func windowDidResignKey(_ notification: Notification) {
        guard machine.isOpen, !keysSuspended else { return }
        close()
    }
}

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

    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 460, height: 640),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        isFloatingPanel = true
        level = .popUpMenu
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

    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown {
            onKeyDown?(event)
            return
        }
        if event.type == .keyUp { onKeyUp?(event) }
        super.sendEvent(event)
    }

    /// Swallow ⌘ shortcuts so, for example, ⌘Q does not quit Ting while the menu is up.
    override func performKeyEquivalent(with event: NSEvent) -> Bool { true }
}

/// What the leader menu shows. Updated by `LeaderController`.
@MainActor
@Observable
final class LeaderSession {
    var leader = ""
    var showPanelHeader = true
    var path: [String] = []
    var items: [Item] = []
    var shakeToken = 0
    /// Bumped on every open so layout hints are recomputed for the current keyboard layout.
    var generation = 0
}

/// Drives the leader panel with `LeaderMachine`.
@MainActor
final class LeaderController: NSObject, NSWindowDelegate {
    let session = LeaderSession()
    /// Called after the panel closed for an action.
    var onRun: ((Item) -> Void)?
    /// A root double tap of the leader: the menu is closed, open launcha.
    var onDoubleTap: (() -> Void)?

    private var machine = LeaderMachine(items: [])
    private var doubleTap = LeaderDoubleTap()
    private var leaderKeyCode: UInt16?
    private var showDelay: TimeInterval = 0.25
    private var panel: LeaderPanel?
    private var reveal: DispatchWorkItem?

    var isOpen: Bool { machine.isOpen }

    func configure(_ config: Config) {
        machine.items = config.items
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
    }

    /// The leader hotkey went down. `time` is any monotonic clock in seconds.
    /// The first press acts at once; only the second press of a root double tap opens launcha.
    func leaderPressed(at time: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        switch doubleTap.press(at: time, machine: machine) {
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

    private func handleKeyDown(_ event: NSEvent) {
        guard machine.isOpen, !event.isARepeat else { return }
        // Any key in between: the next leader press is not a double tap.
        doubleTap.sequenceInput()
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

    private func select(_ key: String) {
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
            session.path = path
            session.items = machine.currentItems
        case .run(let item):
            hide()
            onRun?(item)
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
        session.path = machine.path
        session.items = machine.currentItems
        session.generation += 1
        let panel = self.panel ?? makePanel()
        let screen = NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) } ?? NSScreen.main
        if let visible = screen?.visibleFrame {
            let size = NSSize(width: 460, height: min(760, visible.height))
            panel.setFrame(NSRect(x: visible.midX - size.width / 2, y: visible.midY - size.height / 2,
                                  width: size.width, height: size.height), display: false)
        }
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

    private func hide() {
        reveal?.cancel()
        reveal = nil
        panel?.orderOut(nil)
    }

    private func makePanel() -> LeaderPanel {
        let panel = LeaderPanel()
        panel.delegate = self
        panel.onKeyDown = { [weak self] event in self?.handleKeyDown(event) }
        panel.onKeyUp = { [weak self] event in
            guard let self, event.keyCode == self.leaderKeyCode else { return }
            self.leaderReleased()
        }
        let view = LeaderMenuView(session: session,
                                  onSelect: { [weak self] key in self?.select(key) },
                                  onDismiss: { [weak self] in self?.close() })
        let hosting = NSHostingView(rootView: view)
        hosting.sizingOptions = []
        panel.contentView = hosting
        self.panel = panel
        return panel
    }

    func windowDidResignKey(_ notification: Notification) {
        guard machine.isOpen else { return }
        close()
    }
}

// The clipbawd window: a non-activating panel like launcha, so the app in front keeps its
// place and ↩ pastes into it. Search on top, the history on the left, the preview on the right.
import AppKit
import SwiftUI
import TingCore

final class ClipbawdPanel: NSPanel {
    static let width: CGFloat = 800

    var onMove: ((Int) -> Void)?
    /// ⌘↩: copy without pasting.
    var onCopy: (() -> Void)?
    /// ⇧⌘⌫: remove the selected item.
    var onDelete: (() -> Void)?
    /// ⌘,: open Settings.
    var onOpenSettings: (() -> Void)?

    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: Self.width, height: 600),
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

    private var composing: Bool { (firstResponder as? NSTextView)?.hasMarkedText() == true }

    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown, let onMove,
           let delta = LaunchaPanel.navigationDelta(keyCode: event.keyCode, flags: event.modifierFlags, composing: composing) {
            onMove(delta)
            return
        }
        super.sendEvent(event)
    }

    enum KeyEquivalentRoute: Equatable {
        case editor
        case copy
        case delete
        /// ⌘,: open Settings.
        case settings
        case action(Selector)
        case swallow
    }

    /// launcha's routes, with ⌘↩ copying and ⇧⌘⌫ removing the selected item; ⌘⌫ still
    /// erases the search text, as in launcha. ⌘, opens Settings, as in launcha.
    static func route(keyCode: UInt16, latin: String?, flags: NSEvent.ModifierFlags) -> KeyEquivalentRoute {
        let flags = flags.intersection([.command, .shift, .option, .control])
        if flags == .command, keyCode == 36 || keyCode == 76 { return .copy }
        if flags == [.command, .shift], keyCode == 51 { return .delete }
        switch LaunchaPanel.route(keyCode: keyCode, latin: latin, flags: flags) {
        case .editor: return .editor
        case .settings: return .settings
        case .action(let selector): return .action(selector)
        case .reveal, .editShortcut, .swallow: return .swallow
        }
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard event.type == .keyDown else { return super.performKeyEquivalent(with: event) }
        switch Self.route(keyCode: event.keyCode, latin: KeyTranslator.latin(event.keyCode), flags: event.modifierFlags) {
        case .editor:
            if event.modifierFlags.contains(.command) { return false }
            return super.performKeyEquivalent(with: event)
        case .copy:
            if !composing { onCopy?() }
            return true
        case .delete:
            if !composing { onDelete?() }
            return true
        case .settings:
            if !event.isARepeat, !composing { onOpenSettings?() }
            return true
        case .action(let selector):
            NSApp.sendAction(selector, to: nil, from: self)
            return true
        case .swallow:
            return true
        }
    }
}

/// What the clipbawd window shows: the search, the selection and the presentation settings.
@MainActor
@Observable
final class ClipbawdState {
    let history: ClipbawdHistory
    var query = ""
    var selectedID: Int?
    var showHeader = true
    var isRecording = true
    /// The real keys that open clipbawd, for the footer.
    var shortcut = ""
    var listHeight: CGFloat = 380
    /// Bumped on every open to move focus into the search field.
    var focusToken = 0
    var isOpen = false
    @ObservationIgnored let images = ClipImageCache()

    init(history: ClipbawdHistory) { self.history = history }

    /// The matching items, newest first.
    var results: [ClipEntry] { history.history.search(query) }

    /// The selected item; the first result when the selection is gone.
    var selected: ClipEntry? {
        let results = results
        return results.first { $0.id == selectedID } ?? results.first
    }

    func select(_ id: Int) { selectedID = id }

    func move(by delta: Int) {
        let results = results
        guard !results.isEmpty else { return }
        let current = results.firstIndex { $0.id == selected?.id } ?? 0
        selectedID = results[min(max(current + delta, 0), results.count - 1)].id
    }

    /// Removes the selected item and selects the one after it.
    func removeSelected() {
        let results = results
        guard let selected, let index = results.firstIndex(where: { $0.id == selected.id }) else { return }
        let next = results.indices.contains(index + 1) ? results[index + 1] : index > 0 ? results[index - 1] : nil
        history.remove(id: selected.id)
        selectedID = next?.id
    }
}

/// Shows and hides the clipbawd panel, and pastes or copies the chosen item.
@MainActor
final class ClipbawdController: NSObject, NSWindowDelegate {
    let state: ClipbawdState
    private var panel: ClipbawdPanel?
    private var observers: [NSObjectProtocol] = []
    private let presentsWindow: Bool
    private let keyboard: MicroAppKeyboard
    /// The app that was in front at open: ↩ pastes into it.
    private(set) var target: MicroAppTarget?
    var keysSuspended = false

    var onWillOpen: (() -> Void)?
    /// A paste failed; the error says why (Accessibility, secure input, the app is gone).
    var onPasteError: ((Error) -> Void)?
    var onToast: ((String) -> Void)?
    /// "Never Keep from <app>" was chosen.
    var onExclude: ((ClipSource) -> Void)?
    /// ⌘, in the panel.
    var onOpenSettings: (() -> Void)?

    var isOpen: Bool { state.isOpen }

    init(history: ClipbawdHistory, presentsWindow: Bool = true, keyboard: MicroAppKeyboard? = nil) {
        state = ClipbawdState(history: history)
        self.presentsWindow = presentsWindow
        self.keyboard = keyboard ?? MicroAppKeyboard()
        super.init()
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
        state.showHeader = config.showPanelHeader
        state.isRecording = config.clipbawd.enabled
        state.shortcut = config.clipbawd.activeHotkey.flatMap { $0.isValid ? $0.display : nil } ?? ""
        if !config.clipbawd.enabled { close() }
    }

    func toggle() {
        if isOpen { close() } else { open() }
    }

    func open() {
        guard !isOpen else { return }
        target = MicroAppTarget.frontmost()
        state.query = ""
        state.selectedID = nil
        state.isOpen = true
        onWillOpen?()
        guard presentsWindow else { return }
        let panel = self.panel ?? makePanel()
        let screen = NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) } ?? NSScreen.main
        if let visible = screen?.visibleFrame {
            let top = visible.maxY - max(40, visible.height * 0.16)
            let height = max(320, min(640, top - visible.minY - 20))
            let width = min(ClipbawdPanel.width, visible.width - 40)
            panel.setFrame(NSRect(x: visible.midX - width / 2, y: top - height, width: width, height: height), display: false)
            // Header, input and footer take about 190 points.
            state.listHeight = max(200, min(420, height - 200))
        }
        state.focusToken += 1
        panel.makeKeyAndOrderFront(nil)
        panel.orderFrontRegardless()
    }

    func close() {
        guard isOpen else { return }
        state.isOpen = false
        panel?.orderOut(nil)
    }

    /// ↩ pastes into the app that was in front; ⌘↩ (`paste` false) only copies.
    func choose(id: Int? = nil, paste: Bool) {
        guard isOpen, let entry = id.flatMap(state.history.history.entry(id:)) ?? state.selected else { return }
        guard state.history.copy(id: entry.id) else { return }
        let target = self.target
        close()
        guard paste else {
            onToast?("Copied \(entry.title.count > 40 ? String(entry.title.prefix(40)) + "…" : entry.title)")
            return
        }
        Task { [keyboard, weak self] in
            do { try await keyboard.pressPaste(in: target) }
            catch { self?.onPasteError?(error) }
        }
    }

    func removeSelected() {
        guard isOpen else { return }
        state.removeSelected()
    }

    func exclude(_ source: ClipSource) {
        onExclude?(source)
        state.focusToken += 1
    }

    private func makePanel() -> ClipbawdPanel {
        let panel = ClipbawdPanel()
        panel.delegate = self
        panel.onMove = { [weak self] delta in self?.state.move(by: delta) }
        panel.onCopy = { [weak self] in self?.choose(paste: false) }
        panel.onDelete = { [weak self] in self?.removeSelected() }
        panel.onOpenSettings = { [weak self] in self?.onOpenSettings?() }
        let view = ClipbawdView(state: state,
                                  onChoose: { [weak self] id, paste in self?.choose(id: id, paste: paste) },
                                  onDismiss: { [weak self] in self?.close() },
                                  onExclude: { [weak self] source in self?.exclude(source) })
        let hosting = NSHostingView(rootView: view)
        hosting.sizingOptions = []
        panel.contentView = hosting
        self.panel = panel
        return panel
    }

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

/// Small pictures of copied images and favicons, made off the main thread from the image header
/// and a downsampled decode, never from the full image.
@MainActor
final class ClipImageCache {
    private let cache = NSCache<NSString, NSImage>()

    init() { cache.countLimit = 300 }

    func image(_ data: Data, key: String, maxPixels: Int) async -> NSImage? {
        let cacheKey = "\(key)@\(maxPixels)" as NSString
        if let image = cache.object(forKey: cacheKey) { return image }
        let cgImage = await Task.detached(priority: .userInitiated) { Self.thumbnail(data, maxPixels: maxPixels) }.value
        guard let cgImage else { return nil }
        let image = NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
        cache.setObject(image, forKey: cacheKey)
        return image
    }

    nonisolated static func thumbnail(_ data: Data, maxPixels: Int) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixels,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }
}

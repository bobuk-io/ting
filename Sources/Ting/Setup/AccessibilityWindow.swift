// The Accessibility window: shown when a micro-app needs Accessibility and Ting does not have it,
// or from Settings. It opens Privacy & Security › Accessibility and lets the person drag Ting
// into its list, then closes by itself once macOS gives Ting access.
import AppKit
import BobukSystem
import SwiftUI
import BobukUI

/// Whether Ting may use Accessibility. Read again while the window is open.
@MainActor
@Observable
final class AccessibilityAccess {
    private(set) var isTrusted: Bool
    @ObservationIgnored private let check: () -> Bool

    init(check: @escaping () -> Bool = { AccessibilityPermission.isTrusted }) {
        self.check = check
        isTrusted = check()
    }

    /// Reads the state again. `true` when access has just turned on.
    @discardableResult
    func refresh() -> Bool {
        let was = isTrusted
        isTrusted = check()
        return !was && isTrusted
    }
}

@MainActor
final class AccessibilityWindowController {
    /// Privacy & Security › Accessibility of System Settings.
    static let settingsURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
    /// How often the open window checks for access.
    static let pollInterval: TimeInterval = 1

    let access: AccessibilityAccess
    /// Called once each time access turns on while the window is open.
    var onGranted: (() -> Void)?

    private let appURL: URL
    private let openURL: (URL) -> Void
    /// `false` builds the window but never puts it on screen, for tests.
    private let presentsWindow: Bool
    /// The window stays built while Ting runs (the poll keeps its state); a fixed `ChromeWindow`
    /// sized to its content, closed by its strip button or ⌘W.
    private lazy var hosted: HostedWindowController = {
        let hosted = HostedWindowController(releasesContentOnClose: false, window: {
            let window = ChromeWindow(contentRect: NSRect(x: 0, y: 0, width: 460, height: 400),
                                      theme: .ting, resizable: false)
            window.title = "Allow Accessibility"
            window.isMovableByWindowBackground = true
            // Above System Settings, so the icon can be dragged into its list.
            window.level = .floating
            window.hidesOnDeactivate = false
            return window
        }, rootView: { [access = self.access, appURL = self.appURL, weak self] in
            AccessibilityGuideView(access: access, appURL: appURL,
                                   onOpenSettings: { self?.openSettings() })
        })
        hosted.sizesToFitContent = true
        hosted.onClose = { [weak self] in self?.didClose() }
        return hosted
    }()
    private var timer: Timer?

    init(access: AccessibilityAccess? = nil, appURL: URL = Bundle.main.bundleURL,
         openURL: @escaping (URL) -> Void = { NSWorkspace.shared.open($0) }, presentsWindow: Bool = true) {
        self.access = access ?? AccessibilityAccess()
        self.appURL = appURL
        self.openURL = openURL
        self.presentsWindow = presentsWindow
    }

    /// The window is on screen (or would be, in tests).
    private(set) var isOpen = false

    /// Shows the window, unless Ting has access already.
    func show() {
        access.refresh()
        guard !access.isTrusted else { return }
        // Built also without presenting it (tests), never shown then.
        let window = hosted.prepare()
        isOpen = true
        startPolling()
        guard presentsWindow else { return }
        AppActivation.activate()
        if !window.isVisible { window.center() }
        window.makeKeyAndOrderFront(nil)
    }

    func close() {
        hosted.close()
        if isOpen { didClose() }
    }

    /// Opens System Settings and moves the window to the left of the screen, so the list of apps
    /// stays free for the drop.
    func openSettings() {
        openURL(Self.settingsURL)
        guard presentsWindow, let window = hosted.window, let visible = (window.screen ?? NSScreen.main)?.visibleFrame else { return }
        window.setFrameOrigin(NSPoint(x: visible.minX + 24, y: visible.midY - window.frame.height / 2))
    }

    /// One check of the open window: on access it says so, then closes.
    func poll() {
        guard access.refresh() else { return }
        stopPolling()
        onGranted?()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in self?.close() }
    }

    private func didClose() {
        isOpen = false
        stopPolling()
    }

    private func startPolling() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: Self.pollInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
    }

    private func stopPolling() {
        timer?.invalidate()
        timer = nil
    }
}

struct AccessibilityGuideView: View {
    let access: AccessibilityAccess
    let appURL: URL
    let onOpenSettings: () -> Void

    var body: some View {
        let granted = access.isTrusted
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                TingMark(size: 14)
                MonoLabel("Ting", size: 11, tracking: 2)
                Spacer()
                MonoLabel("accessibility", size: 10, weight: .regular, tracking: 1).foregroundStyle(Color.tingMuted)
            }
            Text("Let Ting use Accessibility.").font(.system(size: 24, weight: .medium)).tracking(-0.6).padding(.top, 18)
            Text("Window commands move and resize the focused window. Micro-apps may also read context, press keys or paste. "
                + "macOS allows these actions only for apps in Privacy & Security › Accessibility.")
                .font(.system(size: 12)).foregroundStyle(Color.tingMuted).padding(.top, 7)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 14) {
                AppIconDragSource(url: appURL)
                    .frame(width: 64, height: 64)
                    .accessibilityLabel("Ting app icon. Drag it into the Accessibility list.")
                VStack(alignment: .leading, spacing: 3) {
                    Text("Ting").font(.system(size: 13, weight: .semibold))
                    Text("Drag this icon into the list of apps in Accessibility.")
                        .font(.system(size: 12)).foregroundStyle(Color.tingMuted)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                Image(systemName: "arrow.right").font(.system(size: 15, weight: .semibold)).foregroundStyle(Color.tingAmber)
                    .accessibilityHidden(true)
            }
            .padding(14)
            .background(Color.tingInk.opacity(0.05), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color.tingAmber.opacity(0.55), style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
            .padding(.top, 18)

            VStack(alignment: .leading, spacing: 9) {
                step("1", "Click Open Accessibility Settings.")
                step("2", "Drag the Ting icon into the list of apps, or click + and choose Ting.")
                step("3", "Turn on the switch next to Ting.")
            }
            .padding(.top, 16)

            Rectangle().fill(Color.tingInk.opacity(0.12)).frame(height: 1).padding(.top, 18)
            HStack(spacing: 8) {
                if granted {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(Color.tingAmber).accessibilityHidden(true)
                    MonoLabel("access on", size: 9, weight: .regular, tracking: 1).foregroundStyle(Color.tingAmber)
                } else {
                    MonoLabel("waiting for access", size: 9, weight: .regular, tracking: 1).foregroundStyle(Color.tingMuted)
                }
                Spacer()
                if !granted {
                    Button("Open Accessibility Settings", action: onOpenSettings)
                        .buttonStyle(.tingQuiet(prominent: true))
                        .keyboardShortcut(.defaultAction)
                }
            }
            .frame(minHeight: 30)
            .padding(.top, 14)
        }
        .foregroundStyle(Color.tingInk)
        .padding(24)
        .padding(.top, 8)
        .frame(width: 460)
        .background(Color.tingPanel)
    }

    private func step(_ number: String, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            KeyCap(key: number, style: .quiet)
            Text(text).font(.system(size: 12)).fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// The app icon as a drag source: dropping it into the Accessibility list of System Settings
/// adds Ting there, as dragging the app from Finder does.
struct AppIconDragSource: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> AppIconDragView { AppIconDragView(url: url) }

    func updateNSView(_ view: AppIconDragView, context: Context) { view.url = url }
}

final class AppIconDragView: NSView, NSDraggingSource {
    var url: URL {
        didSet { if url != oldValue { icon = Self.icon(for: url); needsDisplay = true } }
    }
    private var icon: NSImage

    init(url: URL) {
        self.url = url
        icon = Self.icon(for: url)
        super.init(frame: .zero)
        toolTip = "Drag Ting into the Accessibility list"
    }

    required init?(coder: NSCoder) { nil }

    private static func icon(for url: URL) -> NSImage {
        let image = NSWorkspace.shared.icon(forFile: url.path)
        image.size = NSSize(width: 128, height: 128)
        return image
    }

    /// The window moves by its background; a drag that starts on the icon drags the app instead.
    override var mouseDownCanMoveWindow: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        icon.draw(in: bounds)
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .openHand)
    }

    override func mouseDown(with event: NSEvent) {}

    override func mouseDragged(with event: NSEvent) {
        let item = NSDraggingItem(pasteboardWriter: url as NSURL)
        item.setDraggingFrame(bounds, contents: icon)
        beginDraggingSession(with: [item], event: event, source: self)
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        context == .outsideApplication ? .copy : []
    }
}

// First launch: there is no default leader; Ting asks for one and starts listening at once.
import AppKit
import SwiftUI
import TingCore

@MainActor
final class WelcomeWindowController: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private let model: AppModel

    init(model: AppModel) {
        self.model = model
    }

    /// Drop the SwiftUI content on close so the leader recorder stops (its onDisappear runs).
    func windowWillClose(_ notification: Notification) {
        window?.contentView = nil
        window = nil
    }

    func show() {
        let window = self.window ?? makeWindow()
        NSApp.activate()
        window.center()
        window.makeKeyAndOrderFront(nil)
    }

    func close() {
        window?.close()
    }

    private func makeWindow() -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 440, height: 300),
                              styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
        window.title = "Welcome to Ting"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.standardWindowButton(.miniaturizeButton)?.isHidden = true
        window.standardWindowButton(.zoomButton)?.isHidden = true
        let hosting = NSHostingView(rootView: WelcomeView { [weak self] in self?.close() }.environment(model))
        window.contentView = hosting
        window.setContentSize(hosting.fittingSize)
        self.window = window
        return window
    }
}

struct WelcomeView: View {
    @Environment(AppModel.self) private var model
    let onContinue: () -> Void

    var body: some View {
        let ready = model.config.leader != nil
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                TingMark(size: 14)
                MonoLabel("Ting", size: 11, tracking: 2)
                Spacer()
                MonoLabel("01 / setup", size: 10, weight: .regular, tracking: 1).foregroundStyle(Color.tingMuted)
            }
            Text("Pick your leader.").font(.system(size: 27, weight: .medium)).tracking(-0.7).padding(.top, 18)
            Text("One shortcut opens Ting from anywhere. Then a key or two launches an app or a link.")
                .font(.system(size: 12)).foregroundStyle(Color.tingMuted).padding(.top, 7)
                .fixedSize(horizontal: false, vertical: true)
            LeaderField(large: true, autoStart: true).padding(.top, 20)
            Rectangle().fill(Color.tingInk.opacity(0.12)).frame(height: 1).padding(.top, 20)
            HStack {
                MonoLabel(ready ? "ready" : "waiting for a key", size: 9, weight: .regular, tracking: 1)
                    .foregroundStyle(ready ? Color.tingAmber : Color.tingMuted)
                Spacer()
                Button("Continue", action: onContinue)
                    .buttonStyle(QuietButtonStyle(prominent: ready))
                    .disabled(!ready)
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.top, 14)
        }
        .foregroundStyle(Color.tingInk)
        .padding(24)
        .padding(.top, 8)
        .frame(width: 440)
        .background(Color.tingPanel)
    }
}

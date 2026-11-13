// Record any non-modifier key, alone or with modifiers.
import AppKit
import SwiftUI
import TingCore

@MainActor
@Observable
final class HotkeyRecording {
    enum Target { case leader, launcha }

    private(set) var isRecording = false
    private(set) var preview = ""
    private(set) var warning: String?
    @ObservationIgnored private let monitor = KeyMonitor()
    @ObservationIgnored private var model: AppModel?
    @ObservationIgnored private var resignObserver: NSObjectProtocol?
    @ObservationIgnored private var target = Target.leader

    func start(model: AppModel, target: Target = .leader) {
        self.model = model
        self.target = target
        isRecording = true
        preview = ""
        warning = nil
        model.setRecordingHotkey(true)
        monitor.start { [weak self] event in
            guard let self else { return event }
            return self.handle(event)
        }
        // Leaving Ting stops recording, so the old leader never stays switched off.
        resignObserver = NotificationCenter.default.addObserver(forName: NSApplication.didResignActiveNotification,
                                                                object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.cancel() }
        }
    }

    func cancel() {
        guard isRecording else { return }
        isRecording = false
        preview = ""
        monitor.stop()
        if let resignObserver { NotificationCenter.default.removeObserver(resignObserver) }
        resignObserver = nil
        model?.setRecordingHotkey(false)
    }

    private func handle(_ event: NSEvent) -> NSEvent? {
        let modifiers = ModifierSet(event.modifierFlags).subtracting(.function)
        switch event.type {
        case .flagsChanged:
            // Modifiers may be held as part of a combination, but are never leaders alone.
            preview = modifiers.symbols
            return nil
        case .keyDown:
            let hotkey = Hotkey.combo(keyCode: event.keyCode, modifiers: modifiers)
            let role = target == .leader ? "be a leader" : "open launcha"
            if KeyCodes.name(for: event.keyCode) == nil || !hotkey.isValid {
                warning = "A modifier alone cannot \(role). Press any other key."
            } else if target == .launcha, hotkey == model?.config.leader {
                warning = "\(hotkey.display) is the leader. Press another key for launcha."
            } else if target == .leader, hotkey == model?.config.launcha.hotkey {
                warning = "\(hotkey.display) already opens launcha. Press another key."
            } else {
                finish(hotkey)
            }
            return nil
        default:
            return event
        }
    }

    private func finish(_ hotkey: Hotkey) {
        warning = nil
        cancel()
        switch target {
        case .leader: model?.setLeader(hotkey)
        case .launcha: model?.setLaunchaHotkey(hotkey)
        }
    }
}

/// Large "press your leader" surface, used in Welcome and General settings.
struct LeaderField: View {
    @Environment(AppModel.self) private var model
    @State private var recording = HotkeyRecording()
    var large = false
    /// Welcome starts listening at once: the user just presses the leader.
    var autoStart = false

    var body: some View {
        let isRecording = recording.isRecording
        VStack(alignment: .leading, spacing: 8) {
            Button {
                if isRecording { recording.cancel() } else { recording.start(model: model) }
            } label: {
                HStack(spacing: 10) {
                    if isRecording {
                        Circle().fill(Color.tingAmber).frame(width: 7, height: 7)
                        let preview = recording.preview
                        Text(preview.isEmpty ? "Press your leader…" : preview)
                            .foregroundStyle(preview.isEmpty ? Color.tingMuted : Color.tingInk)
                    } else if let hotkey = model.config.leader {
                        Text(hotkey.display)
                    } else {
                        Text("Click to record").foregroundStyle(Color.tingMuted)
                    }
                    Spacer(minLength: 0)
                }
                .font(.system(size: large ? 20 : 13, weight: .semibold, design: .monospaced))
                .padding(.horizontal, large ? 16 : 10)
                .frame(minWidth: large ? 0 : 200, maxWidth: large ? .infinity : nil)
                .frame(height: large ? 56 : 28)
                .contentShape(Rectangle())
                .background(Color.tingInk.opacity(0.05), in: RoundedRectangle(cornerRadius: large ? 10 : 6, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: large ? 10 : 6, style: .continuous)
                    .strokeBorder(isRecording ? Color.tingAmber : Color.tingInk.opacity(0.12),
                                  style: StrokeStyle(lineWidth: isRecording ? 1.5 : 1, dash: isRecording ? [4, 3] : [])))
            }
            .buttonStyle(.plain)
            .onAppear { if autoStart && model.config.leader == nil { recording.start(model: model) } }
            .onDisappear { recording.cancel() }
            // The config file changed the leader while recording: show the new one.
            .onChange(of: model.config.leader) { recording.cancel() }
            .accessibilityLabel(model.config.leader.map { "Leader key \($0.display). Click to change." } ?? "Record leader key")

            if let warning = recording.warning {
                hint(warning, symbol: "exclamationmark.triangle", color: .tingAmber)
            } else if let problem = model.hotkeyProblem, !isRecording {
                hint(problem, symbol: "exclamationmark.triangle", color: .tingAmber)
            } else if large {
                Text("Press any key: Home, Space, A, F13, or a combination such as ⌥⇧⌘F. Modifiers alone cannot be leaders.")
                    .font(.caption).foregroundStyle(Color.tingMuted)
            }
        }
    }

    private func hint(_ text: String, symbol: String, color: Color) -> some View {
        Label(text, systemImage: symbol).font(.caption).foregroundStyle(color)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// Records the separate launcha hotkey. It starts unset; Clear removes it.
struct LaunchaHotkeyField: View {
    @Environment(AppModel.self) private var model
    @State private var recording = HotkeyRecording()

    var body: some View {
        let isRecording = recording.isRecording
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Button {
                    if isRecording { recording.cancel() } else { recording.start(model: model, target: .launcha) }
                } label: {
                    HStack(spacing: 10) {
                        if isRecording {
                            Circle().fill(Color.tingAmber).frame(width: 7, height: 7)
                            let preview = recording.preview
                            Text(preview.isEmpty ? "Press a key…" : preview)
                                .foregroundStyle(preview.isEmpty ? Color.tingMuted : Color.tingInk)
                        } else if let hotkey = model.config.launcha.hotkey {
                            Text(hotkey.display)
                        } else {
                            Text("Not set").foregroundStyle(Color.tingMuted)
                        }
                        Spacer(minLength: 0)
                    }
                    .font(.system(size: 13, weight: .semibold, design: .monospaced))
                    .padding(.horizontal, 10)
                    .frame(minWidth: 160)
                    .frame(height: 28)
                    .contentShape(Rectangle())
                    .background(Color.tingInk.opacity(0.05), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .strokeBorder(isRecording ? Color.tingAmber : Color.tingInk.opacity(0.12),
                                      style: StrokeStyle(lineWidth: isRecording ? 1.5 : 1, dash: isRecording ? [4, 3] : [])))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(model.config.launcha.hotkey.map { "launcha hotkey \($0.display). Click to change." }
                                    ?? "Record a launcha hotkey")
                if model.config.launcha.hotkey != nil, !isRecording {
                    Button("Clear") { model.setLaunchaHotkey(nil) }
                        .accessibilityLabel("Clear the launcha hotkey")
                }
            }
            .onDisappear { recording.cancel() }
            .onChange(of: model.config.launcha.hotkey) { recording.cancel() }

            if let warning = recording.warning {
                Label(warning, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(Color.tingAmber)
                    .fixedSize(horizontal: false, vertical: true)
            } else if let problem = model.launchaHotkeyProblem, !isRecording {
                Label(problem, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(Color.tingAmber)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

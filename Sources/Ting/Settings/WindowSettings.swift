import SwiftUI
import TingCore

struct WindowSettingsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Form {
            Section {
                LabeledContent("Gap") {
                    HStack {
                        Slider(value: model.binding(\.windowManagement.gap),
                               in: WindowManagementSettings.gapRange, step: 1)
                            .frame(width: 180)
                        Text("\(Int(model.config.windowManagement.gap)) pt")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .frame(width: 52, alignment: .leading)
                    }
                }
                Text("The same gap is used at display edges and between adjacent tiles.")
                    .font(.caption).foregroundStyle(.secondary)
            } header: { SettingsSectionTitle("Layout") }
            .id("window-layout")

            commandSection("Halves", commands: [.leftHalf, .rightHalf, .topHalf, .bottomHalf])
            commandSection("Quarters", commands: [.topLeftQuarter, .topRightQuarter,
                                                   .bottomLeftQuarter, .bottomRightQuarter])
            commandSection("Thirds", commands: [.firstThird, .centerThird, .lastThird])
            commandSection("Position and Displays", commands: [.maximize, .center, .restore,
                                                                 .previousDisplay, .nextDisplay])
        }
        .tingSettingsForm()
    }

    private func commandSection(_ title: String, commands: [WindowCommand]) -> some View {
        Section {
            ForEach(commands) { command in
                LabeledContent {
                    WindowCommandHotkeyField(command: command)
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(command.title)
                        Text(command.detail).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        } header: { SettingsSectionTitle(title) }
    }
}

private struct WindowCommandHotkeyField: View {
    let command: WindowCommand
    @Environment(AppModel.self) private var model
    @State private var recording = HotkeyRecording()
    @State private var clearError: String?

    private var hotkey: Hotkey? {
        model.config.windowManagement.shortcuts.first { $0.command == command }?.hotkey
    }

    var body: some View {
        let isRecording = recording.isRecording
        VStack(alignment: .trailing, spacing: 5) {
            HStack(spacing: 6) {
                Button {
                    if isRecording {
                        recording.cancel()
                    } else {
                        clearError = nil
                        recording.start(model: model, command: command)
                    }
                } label: {
                    HStack(spacing: 8) {
                        if isRecording {
                            Circle().fill(Color.tingAmber).frame(width: 7, height: 7)
                            let preview = recording.preview
                            Text(preview.isEmpty ? "Press a key…" : preview)
                                .foregroundStyle(preview.isEmpty ? Color.tingMuted : Color.tingInk)
                        } else if let hotkey {
                            Text(hotkey.display)
                        } else {
                            Text("Not set").foregroundStyle(Color.tingMuted)
                        }
                        Spacer(minLength: 0)
                    }
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                    .padding(.horizontal, 9)
                    .frame(width: 145, height: 26)
                    .contentShape(Rectangle())
                    .background(Color.tingInk.opacity(0.05), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .strokeBorder(isRecording ? Color.tingAmber : Color.tingInk.opacity(0.12),
                                      style: StrokeStyle(lineWidth: isRecording ? 1.5 : 1,
                                                         dash: isRecording ? [4, 3] : [])))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(hotkey.map { "\(command.title) hotkey \($0.display). Click to change." }
                                    ?? "Record a hotkey for \(command.title)")
                if hotkey != nil, !isRecording {
                    Button("Clear") {
                        do {
                            try model.setWindowHotkey(command, hotkey: nil)
                            clearError = nil
                        } catch {
                            clearError = error.localizedDescription
                        }
                    }
                    .controlSize(.small)
                    .accessibilityLabel("Clear the \(command.title) hotkey")
                }
            }
            if let warning = recording.warning ?? clearError ?? model.windowHotkeyProblem(command), !isRecording {
                Text(warning).font(.caption2).foregroundStyle(Color.tingAmber)
                    .fixedSize(horizontal: false, vertical: true)
            } else if let warning = recording.warning {
                Text(warning).font(.caption2).foregroundStyle(Color.tingAmber)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .onDisappear { recording.cancel() }
        .onChange(of: hotkey) { recording.cancel() }
    }
}

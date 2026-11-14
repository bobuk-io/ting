// Settings: native Form/Table (HIG) with Ting's mono labels, amber keycaps and Ting buttons.
// System toggles keep the system accent.
import AppKit
import SwiftUI
import TingCore
import UniformTypeIdentifiers

struct SettingsRoot: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 0) {
            if let error = model.configError {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(Color.tingAmber)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(Color.tingAmber.opacity(0.1))
            }
            TabView {
                GeneralSettings().tabItem { Label("General", systemImage: "gearshape") }
                BindingsSettings().tabItem { Label("Bindings", systemImage: "keyboard") }
                AdvancedSettings().tabItem { Label("Advanced", systemImage: "wrench.and.screwdriver") }
            }
        }
    }
}

// MARK: - General

private struct GeneralSettings: View {
    @Environment(AppModel.self) private var model
    @Bindable private var updates = UpdateService.shared

    private static var version: String {
        let info = Bundle.main.infoDictionary ?? [:]
        let short = info["CFBundleShortVersionString"] as? String ?? "dev"
        let build = info["CFBundleVersion"] as? String ?? "0"
        return "\(short) (\(build))"
    }

    var body: some View {
        Form {
            Picker("Appearance", selection: model.binding(\.appearance)) {
                Text(Appearance.light.title).tag(Appearance.light)
                Text(Appearance.dark.title).tag(Appearance.dark)
            }
            .pickerStyle(.segmented)
            Section {
                Toggle("Show panel title", isOn: model.binding(\.showPanelHeader))
                Text("Show the Ting · selecta / launcha title row. The leader symbol and input stay visible.")
                    .font(.caption).foregroundStyle(.secondary)
            } header: { MonoLabel("Panel", size: 9).foregroundStyle(Color.tingAmber) }
            Section {
                LabeledContent("Leader") { LeaderField() }
                LabeledContent("Show menu after") {
                    HStack {
                        Slider(value: model.binding(\.showDelay), in: 0...1, step: 0.05).frame(width: 160)
                        Text(model.config.showDelay == 0 ? "instantly" : String(format: "%.2f s", model.config.showDelay))
                            .font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
                            .frame(width: 64, alignment: .leading)
                    }
                }
                Text("Type the whole sequence faster than this and the menu never appears.")
                    .font(.caption).foregroundStyle(.secondary)
                Picker("Unknown key", selection: model.binding(\.unknownKey)) {
                    Text("Shake and stay open").tag(UnknownKeyBehavior.shake)
                    Text("Close the menu").tag(UnknownKeyBehavior.close)
                }
            } header: { MonoLabel("Activation", size: 9).foregroundStyle(Color.tingAmber) }
            LaunchaSettingsSection()
            Section {
                Toggle("Launch at login", isOn: model.binding(\.launchAtLogin))
                if let error = model.loginItemError {
                    Text(error).font(.caption).foregroundStyle(Color.tingAmber)
                }
                Toggle("Show icon in menu bar", isOn: model.binding(\.showMenuBarIcon))
                if !model.config.showMenuBarIcon {
                    Text("Open Ting again from Finder or Spotlight to get back to Settings.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Toggle("Play a “ting” when opening an app, link or file", isOn: model.binding(\.playSound))
            } header: { MonoLabel("System", size: 9).foregroundStyle(Color.tingAmber) }
            if updates.isAvailable {
                Section {
                    Toggle("Check for updates automatically", isOn: $updates.automaticallyChecks)
                    HStack {
                        Text("Version \(Self.version)").font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
                        Spacer()
                        Button("Check Now") { updates.checkForUpdates() }
                    }
                } header: { MonoLabel("Updates", size: 9).foregroundStyle(Color.tingAmber) }
            }
        }
        .formStyle(.grouped)
        .frame(width: 560, height: updates.isAvailable ? 720 : 620)
    }
}

// MARK: - launcha

private struct LaunchaSettingsSection: View {
    @Environment(AppModel.self) private var model
    @State private var confirmingFolders = false

    var body: some View {
        let launcha = model.config.launcha
        Section {
            LabeledContent("Hotkey") { LaunchaHotkeyField() }
            Toggle("Double-tap the leader", isOn: model.binding(\.launcha.doubleTap))
            LabeledContent("Double-tap interval") {
                HStack {
                    Slider(value: model.binding(\.launcha.doubleTapWindow),
                           in: LaunchaSettings.doubleTapWindowRange, step: 0.05)
                        .frame(width: 160)
                        .accessibilityValue(String(format: "%.2f seconds", launcha.doubleTapWindow))
                    Text(String(format: "%.2f s", launcha.doubleTapWindow))
                        .font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
                        .frame(width: 64, alignment: .leading)
                }
            }
            .disabled(!launcha.doubleTap)
            Text("Press the leader twice to open launcha. The first press opens selecta at once, so sequences are never delayed. A separate hotkey is optional.")
                .font(.caption).foregroundStyle(.secondary)
            Toggle("Search Desktop, Documents and Downloads", isOn: Binding(
                get: { model.protectedFoldersAllowed },
                set: { allowed in
                    if allowed { confirmingFolders = true } else { model.setProtectedFoldersAllowed(false) }
                }))
            Text("Off by default. Ting saves this choice outside the config file.")
                .font(.caption).foregroundStyle(.secondary)
            if let error = model.launchaConsentError {
                Text(error).font(.caption).foregroundStyle(Color.tingAmber)
            }
        } header: { MonoLabel("launcha", size: 9).foregroundStyle(Color.tingAmber) }
        .alert("Search Desktop, Documents and Downloads?", isPresented: $confirmingFolders) {
            Button("Allow Access") { model.setProtectedFoldersAllowed(true) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("launcha will also list apps on your Desktop and find files in these folders. macOS may ask you to allow Ting to access each folder.")
        }
    }
}

// MARK: - Advanced

private struct AdvancedSettings: View {
    @Environment(AppModel.self) private var model
    @State private var message: String?

    var body: some View {
        Form {
            Section {
                LabeledContent("Location") {
                    Text(model.store.displayPath).font(.system(size: 12, design: .monospaced)).textSelection(.enabled)
                }
                HStack {
                    Button("Reveal in Finder") { model.revealConfigFile() }
                    Button("Open in Editor") { model.openConfigFile() }
                    Spacer()
                    Button("Reload") { model.reload() }
                }
                Text("Ting reloads the file when it changes on disk. Set TING_CONFIG to use another file.")
                    .font(.caption).foregroundStyle(.secondary)
            } header: { MonoLabel("Configuration file", size: 9).foregroundStyle(Color.tingAmber) }
            Section {
                HStack {
                    Button("Export…", action: export)
                    Button("Import…", action: importConfig)
                }
                if let message {
                    Text(message).font(.caption).foregroundStyle(Color.tingAmber)
                }
            } header: { MonoLabel("Backup", size: 9).foregroundStyle(Color.tingAmber) }
        }
        .formStyle(.grouped)
        .frame(width: 560, height: 320)
    }

    private func export() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "ting-config.json"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try ConfigCodec.encode(model.config).write(to: url, options: .atomic)
            message = "Exported to \(url.lastPathComponent)."
        } catch {
            message = "Export failed: \(error.localizedDescription)"
        }
    }

    private func importConfig() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let imported = try ConfigCodec.decode(Data(contentsOf: url))
            model.replaceConfig(imported)
            message = "Imported \(url.lastPathComponent)."
        } catch let error as ConfigError {
            message = "Import failed: " + ConfigStore.LoadError.invalid(error).message
        } catch {
            message = "Import failed: \(error.localizedDescription)"
        }
    }
}

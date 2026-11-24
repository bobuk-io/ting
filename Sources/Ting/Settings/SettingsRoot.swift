// Native Mac preferences: stable sidebar, clear page hierarchy and readable grouped controls.
// Amber identifies Ting; ordinary controls retain the system accent. The window (`SettingsWindow`)
// owns the only close control: the strip's close button and ⌘W.
import AppKit
import BobukUI
import SwiftUI
import TingCore
import UniformTypeIdentifiers
import BobukUpdates

struct SettingsRoot: View {
    @Environment(AppModel.self) private var model
    @State private var page: SettingsPage? = .general
    @State private var query = ""
    @State private var target: String?
    private let navigation: SettingsNavigation?

    init(page: SettingsPage = .general, query: String = "", target: String? = nil, navigation: SettingsNavigation? = nil) {
        self.navigation = navigation
        _page = State(initialValue: navigation?.page ?? page)
        _query = State(initialValue: query)
        _target = State(initialValue: target)
    }

    var body: some View {
        HStack(spacing: 0) {
            SettingsSidebar(page: page ?? .general, query: $query) { selected in
                page = selected
                navigation?.page = selected
                query = ""
                target = nil
            }
            .frame(width: SettingsSidebar.width)
            Rectangle().fill(Color.tingStroke.opacity(0.35)).frame(width: 1)
            detail
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .background(Color.tingPanel)
        }
        .foregroundStyle(Color.tingInk)
        .tint(Color.tingAmber)
        .frame(minWidth: SettingsWindow.minimumContentSize.width, idealWidth: 1040,
               minHeight: SettingsWindow.minimumContentSize.height, idealHeight: 720)
        // The window draws the accent line, the strip with the close button and the separator.
        .background(Color.tingPanel)
        .onChange(of: navigation?.requestID) { _, _ in
            if let requested = navigation?.page {
                page = requested
                query = ""
                target = nil
            }
        }
    }

    private var detail: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(query.isEmpty ? (page ?? .general).title : "Search Settings")
                        .font(.system(size: 26, weight: .semibold))
                        .accessibilityAddTraits(.isHeader)
                    Text(query.isEmpty ? (page ?? .general).settingsDescription : "Find a setting by its name or what it does.")
                        .font(.system(size: 13)).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 24).padding(.top, 24).padding(.bottom, 16)
            if let error = model.configError {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(Color.tingAmber)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(Color.tingAmber.opacity(0.1))
            }
            if !model.microAppIssues.isEmpty {
                Button { page = .microApps; query = "" } label: {
                Label("Some micro-app files have errors. Open Micro-apps.", systemImage: "exclamationmark.triangle.fill")
                }
                .buttonStyle(.plain)
                    .font(.caption)
                    .foregroundStyle(Color.tingAmber)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(Color.tingAmber.opacity(0.1))
            }
            if !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                let results = SettingsCatalog.search(query)
                if results.isEmpty {
                    ContentUnavailableView.search(text: query)
                } else {
                    List(results) { result in
                        Button {
                            page = result.page
                            query = ""
                            target = result.id
                        } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(result.title).font(.headline)
                                Text(result.page.title).font(.caption).foregroundStyle(.secondary)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 4)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                    .scrollContentBackground(.hidden)
                    .accessibilityLabel("Matching settings")
                }
            } else {
                ScrollViewReader { proxy in
                    Group {
                        switch page ?? .general {
                        case .general: GeneralSettings(activation: false)
                        case .activation: GeneralSettings(activation: true)
                        case .bindings: BindingsSettings()
                        case .windows: WindowSettingsView()
                        case .clipbawd: ClipbawdSettingsView(searchTarget: target)
                        case .chatta: ChattaSettingsView()
                        case .microApps:
                            Form { MicroAppsSection().id("micro-apps") }.tingSettingsForm()
                        case .advanced: AdvancedSettings()
                        }
                    }
                    .frame(maxWidth: page == .bindings ? .infinity : 780, maxHeight: .infinity, alignment: .topLeading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .id(page)
                    .onAppear { if let target { proxy.scrollTo(target, anchor: .top) } }
                    .onChange(of: target) { if let target { proxy.scrollTo(target, anchor: .top) } }
                }
            }
        }
    }
}

/// A permanent column, not a split-view/sidebar controller that can collapse or add toolbar items.
struct SettingsSidebar: View {
    static let width: CGFloat = 216
    let page: SettingsPage
    @Binding var query: String
    let onChoose: (SettingsPage) -> Void
    @FocusState private var focusedPage: SettingsPage?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 8) {
                Image(nsImage: StatusIcon.image).renderingMode(.template)
                    .foregroundStyle(Color.tingAmber).accessibilityHidden(true)
                Text("Ting").font(.system(size: 18, weight: .semibold))
            }
            .padding(.horizontal, 16).padding(.top, 20)
            PickerSearchField(text: $query, placeholder: "Search settings",
                              accessibilityLabel: "Search all Ting settings", palette: TingPickerStyle.palette)
                .padding(.horizontal, 12)
            ScrollView {
                VStack(spacing: 4) {
                    ForEach(SettingsPage.allCases) { item in
                        Button { onChoose(item) } label: {
                            PickerRow(selected: page == item, palette: TingPickerStyle.palette) {
                                HStack(spacing: 10) {
                                    Image(systemName: item.symbol).frame(width: 18)
                                        .foregroundStyle(page == item ? Color.tingAmber : Color.tingMuted)
                                        .accessibilityHidden(true)
                                    Text(item.title).font(.system(size: 13, weight: page == item ? .semibold : .regular))
                                        .foregroundStyle(Color.tingInk).lineLimit(1)
                                    Spacer(minLength: 0)
                                }
                            }
                        }
                        .buttonStyle(.plain)
                        .focused($focusedPage, equals: item)
                        .accessibilityLabel(item.title)
                        .accessibilityAddTraits(page == item ? .isSelected : [])
                        .onKeyPress(.upArrow) { move(from: item, by: -1) }
                        .onKeyPress(.downArrow) { move(from: item, by: 1) }
                    }
                }
                .padding(.horizontal, 10)
            }
            .scrollIndicators(.hidden)
            Text("Settings save automatically")
                .font(.system(size: 11)).foregroundStyle(Color.tingMuted)
                .padding(.horizontal, 16).padding(.bottom, 16)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Settings sections")
        .accessibilityIdentifier("settings.sidebar")
    }

    private func move(from page: SettingsPage, by delta: Int) -> KeyPress.Result {
        let pages = SettingsPage.allCases
        guard let index = PickerSelection.move(pages.firstIndex(of: page), by: delta, count: pages.count) else { return .ignored }
        onChoose(pages[index])
        focusedPage = pages[index]
        return .handled
    }
}

private extension SettingsPage {
    var settingsDescription: String {
        switch self {
        case .general: "Appearance, sound and startup."
        case .activation: "Leader keys, menu timing and launcha."
        case .bindings: "Choose what each key sequence opens."
        case .windows: "Move and resize the focused window."
        case .clipbawd: "Choose what to keep and when to forget it."
        case .chatta: "Talk to a local ACP agent or let it configure Ting."
        case .microApps: "Your tools, diagnostics and permissions."
        case .advanced: "Configuration files and backups."
        }
    }
}

// MARK: - General

private struct GeneralSettings: View {
    let activation: Bool
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
            if !activation {
            Section {
                ThemeSettingsFormRows(theme: model.theme)
                SettingsToggle("Show panel title", detail: "Keep the title row above selecta, launcha and Clipbawd. The leader symbol and input always stay visible.",
                               isOn: model.binding(\.showPanelHeader))
            } header: { SettingsSectionTitle("Appearance") }
            .id("appearance")
            }
            if activation {
            Section {
                LabeledContent("Leader") { LeaderField() }
                LabeledContent("Second leader") {
                    HStack {
                        LeaderField(alternate: true)
                        if model.config.alternateLeader != nil {
                            Button("Clear") { model.update { $0.alternateLeader = nil } }
                                .accessibilityLabel("Clear second leader key")
                        }
                    }
                }
                LabeledContent("Show menu after") {
                    HStack {
                        Slider(value: model.binding(\.showDelay), in: 0...1, step: 0.05).frame(width: 160)
                        Text(model.config.showDelay == 0 ? "instantly" : String(format: "%.2f s", model.config.showDelay))
                            .font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
                            .frame(width: 64, alignment: .leading)
                    }
                }
                Text("Finish a sequence before this delay to launch without showing the menu.")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                Picker("Unknown key", selection: model.binding(\.unknownKey)) {
                    Text("Shake and stay open").tag(UnknownKeyBehavior.shake)
                    Text("Close the menu").tag(UnknownKeyBehavior.close)
                }
            } header: { SettingsSectionTitle("Leader and selecta") }
            .id("activation")
            LaunchaSettingsSection().id("launcha")
            }
            if !activation {
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
            } header: { SettingsSectionTitle("Startup") }
            .id("system")
            Section {
                SettingsToggle("Play a “ting” when opening an app, link or file", detail: "Preview the sound by choosing one or changing its volume.",
                               isOn: model.binding(\.playSound))
                SoundSettings()
            } header: { SettingsSectionTitle("Sound") }
            .id("sound")
            if updates.isAvailable {
                Section {
                    Toggle("Check for updates automatically", isOn: $updates.automaticallyChecks)
                    HStack {
                        Text("Version \(Self.version)").font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
                        Spacer()
                        Button("Check Now") { updates.checkForUpdates() }
                    }
                } header: { SettingsSectionTitle("Updates") }
                .id("updates")
            } else if let homebrew = updates.homebrew {
                Section {
                    Text("Homebrew installed this copy (\(homebrew.prefix.path)), so Homebrew updates it.")
                        .font(.caption).foregroundStyle(.secondary)
                    HStack {
                        Text("Version \(Self.version)").font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
                        Spacer()
                        Button("Update Ting via Homebrew…") { updates.checkForUpdates() }
                    }
                } header: { SettingsSectionTitle("Updates") }
                .id("updates")
            }
            }
        }
        .tingSettingsForm()
    }
}

// MARK: - Sound

/// The sound and its volume, under the "ting" toggle. Both are disabled while the toggle is off.
private struct SoundSettings: View {
    @Environment(AppModel.self) private var model
    /// Read once: the sounds in /System/Library/Sounds do not change while Ting runs.
    private static let systemNames = SystemSounds.names()

    var body: some View {
        let config = model.config
        let names = Self.systemNames.contains(config.sound) ? Self.systemNames : Self.systemNames + [config.sound]
        let sound = model.binding(\.sound)
        // Choosing a sound saves it and plays it once; a reload of the file plays nothing.
        let choice = Binding(get: { sound.wrappedValue },
                             set: { sound.wrappedValue = $0; model.previewSound() })
        Group {
            Picker("Sound", selection: choice) {
                ForEach(names, id: \.self) { Text($0).tag($0) }
            }
            LabeledContent("Volume") {
                HStack {
                    Slider(value: model.binding(\.soundVolume), in: 0...1) { editing in
                        if !editing { model.previewSound() }
                    }
                    .frame(width: 160)
                    Text("\(Int((config.soundVolume * 100).rounded())) %")
                        .font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
                        .frame(width: 64, alignment: .leading)
                }
            }
        }
        .disabled(!config.playSound)
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
            SettingsToggle("Double-tap the leader", detail: "Open launcha with two taps. The first tap still opens selecta immediately.",
                           isOn: model.binding(\.launcha.doubleTap))
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
            SettingsToggle("Calculate in launcha", detail: "Try 2*(3+4). Return copies the result.",
                           isOn: model.binding(\.launcha.calculator))
            SettingsToggle("Convert in launcha", detail: "Units, number bases and dates. Try 5 yd to m or now + 2 days.",
                           isOn: model.binding(\.launcha.converter))
            SettingsToggle("Rank by apps you use",
                           detail: "Also count the apps you switch to outside launcha, at most once per app every 30 minutes. "
                            + "Off by default; the record stays on this Mac, and turning this off deletes it.",
                           isOn: model.binding(\.launcha.appSwitching))
            Picker("Running apps", selection: model.binding(\.launcha.runningApps)) {
                Text("Higher").tag(RunningAppsOrder.higher)
                Text("Lower").tag(RunningAppsOrder.lower)
                Text("No preference").tag(RunningAppsOrder.any)
            }
            .disabled(!launcha.appSwitching)
            .help("Where launcha lists apps that are already open, among equally good matches.")
            SettingsToggle("Search Desktop, Documents and Downloads", detail: "Off by default. macOS may ask for folder access.", isOn: Binding(
                get: { model.protectedFoldersAllowed },
                set: { allowed in
                    if allowed { confirmingFolders = true } else { model.setProtectedFoldersAllowed(false) }
                }))
            .help("Ting saves this consent separately from config.json.")
            if let error = model.launchaConsentError {
                Text(error).font(.caption).foregroundStyle(Color.tingAmber)
            }
        } header: { SettingsSectionTitle("launcha") }
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
                Text("Ting reloads the file when it changes on disk. Micro-apps live in \(model.microStore.displayPath), next to it. Set TING_CONFIG to use another file.")
                    .font(.caption).foregroundStyle(.secondary)
            } header: { SettingsSectionTitle("Configuration file") }
            .id("config")
            Section {
                HStack {
                    Button("Export…", action: export)
                    Button("Import…", action: importConfig)
                }
                if let message {
                    Text(message).font(.caption).foregroundStyle(Color.tingAmber)
                }
            } header: { SettingsSectionTitle("Backup") }
            .id("backup")
        }
        .tingSettingsForm()
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

// MARK: - Micro-apps

private struct MicroAppsSection: View {
    @Environment(AppModel.self) private var model
    @State private var folderError: String?

    var body: some View {
        Section {
            LabeledContent("Folder") {
                Text(model.microStore.displayPath).font(.system(size: 12, design: .monospaced)).textSelection(.enabled)
            }
            let working = model.microApps.filter { !$0.isBroken }.count
            let broken = model.microApps.count - working
            Text(model.microApps.isEmpty ? "No micro-apps."
                 : "\(working) working, \(broken) broken.")
                .font(.caption).foregroundStyle(.secondary)
            if !model.microApps.isEmpty {
                MicroAppList(entries: model.microApps)
            }
            if model.microAppIssues.isEmpty {
                Label("No errors.", systemImage: "checkmark.circle").font(.caption).foregroundStyle(.secondary)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(Array(model.microAppIssues.enumerated()), id: \.offset) { _, issue in
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                Text("\(issue.file):\(issue.line)")
                                    .font(.system(size: 11, design: .monospaced))
                                    .foregroundStyle(Color.tingAmber)
                                Text(issue.message).font(.caption)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
                }
                .frame(maxHeight: 140)
            }
            HStack {
                Button("Open Folder in Finder") { folderError = model.openMicroAppsFolder() }
                Button("Configure with Chatta") { model.openChatta(mode: .configure) }
                    .help("Open Chatta in your Ting config folder to write or edit micro-apps and bindings.")
                Button("Copy Agent Prompt") { model.copyAgentPrompt() }
                    .help("Copy a text for a coding agent such as Claude Code, Codex or pi; add your task after it.")
                Spacer()
                Button("Reload") { model.reload() }
            }
            if let folderError {
                Text(folderError).font(.caption).foregroundStyle(Color.tingAmber)
            }
            let access = model.accessibility.access
            LabeledContent("Accessibility") {
                HStack(spacing: 8) {
                    if access.isTrusted {
                        Label("Allowed", systemImage: "checkmark.circle").foregroundStyle(.secondary)
                    } else {
                        Text("Not allowed").foregroundStyle(Color.tingAmber)
                        Button("Allow…") { model.accessibility.show() }
                    }
                }
            }
            .onAppear { access.refresh() }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in access.refresh() }
            Text("Only micro-apps that read the selected text or the front window, press keys or paste need it.")
                .font(.caption).foregroundStyle(.secondary)
            Text("One micro-app per .yaml file. Ting creates the folder when you open it, loads it again when it changes and writes the errors to \(model.microStore.logDisplayPath).")
                .font(.caption).foregroundStyle(.secondary)
        } header: { SettingsSectionTitle("Micro-apps") }
        Section {
            let settings = model.config.microApps
            LabeledContent("Result panel width") {
                Stepper(value: model.binding(\.microApps.resultWidth), in: MicroAppsSettings.resultWidthRange, step: 20) {
                    Text("\(settings.resultWidth) pt").monospacedDigit()
                }
            }
            LabeledContent("Result text size") {
                Stepper(value: model.binding(\.microApps.resultTextSize), in: MicroAppsSettings.resultTextSizeRange) {
                    Text("\(settings.resultTextSize) pt").monospacedDigit()
                }
            }
            LabeledContent("Maximum run timeout") {
                TextField("", value: Binding(get: { settings.maxTimeout }, set: { value in
                    let range = MicroAppsSettings.maxTimeoutRange
                    model.update { $0.microApps.maxTimeout = min(max(value, range.lowerBound), range.upperBound) }
                }), format: .number.grouping(.never))
                    .labelsHidden()
                    .frame(width: 80)
                    .accessibilityLabel("Maximum micro-app run timeout in seconds")
                Text("seconds")
            }
            Text("Individual micro-apps still default to 60 seconds and can set a smaller or larger `timeout` up to this maximum.")
                .font(.caption).foregroundStyle(.secondary)
        } header: { SettingsSectionTitle("Result panel and limits") }
    }
}

/// Read-only: every file of the micro-apps folder with its name, id and state.
private struct MicroAppList: View {
    let entries: [MicroAppEntry]

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 4) {
            GridRow {
                ForEach(["Name", "Id", "File", "State"], id: \.self) { title in
                    MonoLabel(title, size: 9, weight: .regular, tracking: 1).foregroundStyle(.secondary)
                }
            }
            ForEach(entries, id: \.file) { entry in
                GridRow {
                    Text(entry.app?.shownName ?? "—").lineLimit(1)
                    Text(entry.app?.id ?? entry.fileID).font(.system(size: 11, design: .monospaced)).lineLimit(1)
                    Text(entry.file).font(.system(size: 11, design: .monospaced)).lineLimit(1).truncationMode(.middle)
                    if entry.isBroken {
                        Label("broken", systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(Color.tingAmber)
                            .help(entry.issues.first.map { "line \($0.line): \($0.message)" } ?? "")
                    } else {
                        Label("good", systemImage: "checkmark.circle").foregroundStyle(.secondary)
                    }
                }
                .font(.caption)
                .accessibilityElement(children: .combine)
            }
        }
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

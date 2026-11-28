// Bindings: the "Sequences" table over `BindingTree` and `Config.items`.
import AppKit
import BobukCore
import SwiftUI
import TingCore
import UniformTypeIdentifiers
import BobukUI

/// One table row: a flattened binding plus the validator's first issue for it.
private struct BindingRow: Identifiable {
    let binding: FlatBinding
    let issue: String?

    var id: String { binding.sequence.joined(separator: " ") }
    var sequence: [String] { binding.sequence }
    var item: Item { binding.item }
}

struct BindingsSettings: View {
    @Environment(AppModel.self) private var model
    @State private var selection: Set<String> = []
    @State private var query = ""
    @State private var recordingFor: String?
    @State private var newBinding: Item?
    @State private var addError: String?

    private var allRows: [BindingRow] {
        let issues = model.issues
        let catalog = model.microCatalog
        let folder = model.microStore.displayPath
        return BindingTree.flatten(model.config.items).map { binding in
            var issue = issues.first { $0.sequence == binding.sequence }?.message
            // A binding to a missing or broken micro-app keeps the config valid; the row says why it does not work.
            if issue == nil, case .micro(let id) = binding.item.action, !id.isEmpty {
                issue = catalog.resolve(id).problem(id: id, folder: folder)
            }
            return BindingRow(binding: binding, issue: issue)
        }
    }

    private var rows: [BindingRow] {
        let all = allRows
        let query = query.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return all }
        // Names and targets match fuzzily, key sequences as typed ("g s"). The tree order stays.
        let fuzzy = FuzzyQuery(query)
        return all.filter { row in
            fuzzy.bestMatch(in: [row.item.label, target(of: row.item)]) != nil
                || row.sequence.joined(separator: " ").contains(query.lowercased())
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                MonoLabel(String(format: "%02d / bindings", allRows.filter { !$0.item.isGroup }.count), size: 10, tracking: 1)
                    .foregroundStyle(Color.tingAmber)
                TextField("Filter by name, URL, window command, micro-app or keys", text: $query).textFieldStyle(.roundedBorder)
                Menu {
                    Button("Application…", action: addApplication)
                    Button("URL", action: addURL)
                    Button("Clipbawd") { add(.open("", "Clipboard history", .clipbawd)) }
                    Button("My Schedule") { add(.open("", "My Schedule", .schedule)) }
                    Button("Chatta") { add(.open("", "Chatta", .chatta)) }
                    Button("launcha") { add(.open("", "Search", .launcha)) }
                    Menu("Window") {
                        ForEach(WindowCommand.allCases) { command in
                            Button(command.title) { add(.window("", command.title, command)) }
                        }
                    }
                    if model.lowkey.isInstalled {
                        Menu("lowkey") {
                            if let problem = model.lowkey.problem {
                                Text(problem)
                            } else if model.lowkey.sites.isEmpty {
                                Text("No saved sites in lowkey")
                            }
                            ForEach(model.lowkey.sites) { site in
                                Menu(site.name == site.alias ? site.name : "\(site.name) (\(site.alias))") {
                                    Button("Open") { add(.url("", site.name, site.url(.open).absoluteString)) }
                                    Button("Toggle") { add(.url("", "Toggle \(site.name)", site.url(.toggle).absoluteString)) }
                                }
                            }
                        }
                    }
                    Menu("Micro-app") {
                        let choices = model.microCatalog.bindingChoices()
                        if choices.isEmpty {
                            Text("No micro-apps in \(model.microStore.displayPath)")
                        }
                        ForEach(choices) { choice in
                            Button(choice.title) { add(.micro("", choice.name, choice.id)) }
                        }
                    }
                } label: { Image(systemName: "plus") }
                    .menuStyle(.borderlessButton).fixedSize()
                    .accessibilityLabel("Add binding")
                Button(action: deleteSelection) { Image(systemName: "minus") }
                    .buttonStyle(.borderless)
                    .disabled(selection.isEmpty)
                    .accessibilityLabel("Delete selected bindings")
            }
            .padding(10)

            Table(rows, selection: $selection) {
                TableColumn("Keys") { row in keysCell(row) }.width(min: 170, ideal: 200)
                TableColumn("Name") { row in
                    HStack {
                        ItemIcon(item: row.item, size: 16, microIcon: microIcon(row.item))
                        TextField("Name", text: labelBinding(row)).textFieldStyle(.plain)
                            .font(row.item.isGroup ? .system(size: 13, weight: .semibold) : .body)
                    }
                }
                .width(min: 140, ideal: 180)
                TableColumn("Action") { row in actionCell(row) }
            }
            HStack {
                if let addError {
                    Label(addError, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(Color.tingAmber)
                } else {
                    Text("Groups appear when a sequence needs them and disappear when they are empty.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(8)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .id("bindings")
        .task {
            // Also pick up changes made in Lowkey while Settings stays open.
            repeat {
                model.lowkey.refresh()
                do { try await Task.sleep(for: .seconds(5)) } catch { return }
            } while !Task.isCancelled
        }
        .sheet(isPresented: Binding(get: { newBinding != nil },
                                    set: { if !$0 { newBinding = nil } })) {
            if let item = newBinding {
                SequenceRecorder(recording: .new(item)) { newBinding = nil }
                    .environment(model)
            }
        }
    }

    // MARK: Cells

    private func keysCell(_ row: BindingRow) -> some View {
        HStack(spacing: 3) {
            ForEach(Array(row.sequence.enumerated()), id: \.offset) { KeyCap(key: $0.element) }
            if let issue = row.issue {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(Color.tingAmber)
                    .help(issue)
                    .accessibilityLabel(issue)
            }
            Spacer(minLength: 4)
            if !row.item.isGroup {
                Button { recordingFor = row.id } label: { Image(systemName: "record.circle") }
                    .buttonStyle(.borderless)
                    .foregroundStyle(Color.tingAmber)
                    .help("Record keys")
                    .accessibilityLabel("Record keys for \(row.item.label)")
                    .popover(isPresented: Binding(get: { recordingFor == row.id },
                                                  set: { if !$0, recordingFor == row.id { recordingFor = nil } }),
                             arrowEdge: .bottom) {
                        SequenceRecorder(recording: .existing(sequence: row.sequence, label: row.item.label)) { recordingFor = nil }
                            .environment(model)
                    }
            }
        }
    }

    @ViewBuilder private func actionCell(_ row: BindingRow) -> some View {
        switch row.item.action {
        case .group(let children):
            MonoLabel(String(format: "group · %02d", children.count), size: 9, weight: .regular, tracking: 1)
                .foregroundStyle(.secondary)
        case .app:
            HStack {
                TextField("Bundle ID", text: targetBinding(row)).textFieldStyle(.plain).font(.system(size: 12, design: .monospaced))
                Button("Choose…") { chooseApp(for: row) }.controlSize(.small)
            }
        case .url:
            TextField("URL", text: targetBinding(row)).textFieldStyle(.plain).font(.system(size: 12, design: .monospaced))
        case .micro(let id):
            microPicker(row, id: id)
        case .open(let panel):
            Picker("Ting window", selection: Binding(
                get: { panel },
                set: { next in model.updateBinding(at: row.sequence) { $0.action = .open(next) } })) {
                ForEach(TingPanel.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .labelsHidden()
            .controlSize(.small)
            .accessibilityLabel("Ting window for \(row.item.label)")
        case .window(let command):
            Picker("Window command", selection: Binding(
                get: { command },
                set: { next in model.updateBinding(at: row.sequence) { $0.action = .window(next) } })) {
                ForEach(WindowCommand.allCases) { Text($0.title).tag($0) }
            }
            .labelsHidden()
            .controlSize(.small)
            .accessibilityLabel("Window command for \(row.item.label)")
        }
    }

    private func microIcon(_ item: Item) -> MicroIcon? {
        if case .micro(let id) = item.action { return model.microCatalog.icon(id) }
        return nil
    }

    /// The found micro-apps; a missing or broken current id stays in the list, marked, until another one is picked.
    private func microPicker(_ row: BindingRow, id: String) -> some View {
        let catalog = model.microCatalog
        let choices = catalog.bindingChoices(current: id)
        return Picker("Micro-app", selection: Binding(
            get: { id },
            set: { newID in
                guard newID != id, !newID.isEmpty else { return }
                model.updateBinding(at: row.sequence) { item in
                    let oldName = catalog.bindingName(label: "", id: id)
                    item.action = .micro(newID)
                    // A label that only repeated the old micro-app's name follows the new one.
                    if item.label.isEmpty || item.label == oldName || item.label == id {
                        item.label = catalog.bindingName(label: "", id: newID)
                    }
                }
            })) {
            if id.isEmpty { Text("Choose a micro-app").tag("") }
            ForEach(choices) { choice in
                Text(choice.title).tag(choice.id)
            }
        }
        .labelsHidden()
        .controlSize(.small)
        .accessibilityLabel("Micro-app for \(row.item.label)")
    }

    private func target(of item: Item) -> String {
        switch item.action {
        case .group: ""
        case .app(let bundleID): bundleID
        case .url(let url): url
        case .micro(let id): id
        case .open(let panel): panel.rawValue
        case .window(let command): command.title
        }
    }

    private func labelBinding(_ row: BindingRow) -> Binding<String> {
        Binding(get: { row.item.label },
                set: { label in model.updateBinding(at: row.sequence) { $0.label = label } })
    }

    private func targetBinding(_ row: BindingRow) -> Binding<String> {
        Binding(get: { target(of: row.item) },
                set: { text in
                    model.updateBinding(at: row.sequence) { item in
                        switch item.action {
                        case .group, .open, .window: break
                        case .app: item.action = .app(text)
                        case .url: item.action = .url(text)
                        case .micro: item.action = .micro(text)
                        }
                    }
                })
    }

    // MARK: Add / delete

    /// Keep the item as a draft: cancel never leaves an automatically assigned binding behind.
    private func add(_ item: Item) {
        addError = nil
        newBinding = item
    }

    private func addApplication() {
        guard let (bundleID, name) = pickApplication() else { return }
        add(.app("", name, bundleID))
    }

    private func addURL() {
        add(.url("", "New link", "https://"))
    }

    private func chooseApp(for row: BindingRow) {
        guard let (bundleID, name) = pickApplication() else { return }
        model.updateBinding(at: row.sequence) { item in
            item.action = .app(bundleID)
            if item.label.isEmpty { item.label = name }
        }
    }

    private func pickApplication() -> (bundleID: String, name: String)? {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        guard let bundleID = Bundle(url: url)?.bundleIdentifier else {
            addError = "\(url.lastPathComponent) has no bundle identifier."
            return nil
        }
        let name = FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
        return (bundleID, name)
    }

    private func deleteSelection() {
        let selected = allRows.filter { selection.contains($0.id) }
        let groups = selected.filter { ($0.item.children?.isEmpty == false) }
        if !groups.isEmpty {
            let alert = NSAlert()
            alert.messageText = groups.count == 1 ? "Delete the group \(groups[0].item.label)?" : "Delete \(groups.count) groups?"
            alert.informativeText = "Everything inside will be deleted too."
            alert.addButton(withTitle: "Delete")
            alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }
        model.removeBindings(selected.map(\.sequence))
        selection = []
    }
}

// Bindings: the "Sequences" table over `BindingTree` and `Config.items`.
import AppKit
import SwiftUI
import TingCore
import UniformTypeIdentifiers

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
    @State private var addError: String?

    private var allRows: [BindingRow] {
        let issues = model.issues
        return BindingTree.flatten(model.config.items).map { binding in
            BindingRow(binding: binding, issue: issues.first { $0.sequence == binding.sequence }?.message)
        }
    }

    private var rows: [BindingRow] {
        let all = allRows
        let query = query.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return all }
        return all.filter { row in
            row.item.label.localizedCaseInsensitiveContains(query)
                || target(of: row.item).localizedCaseInsensitiveContains(query)
                || row.sequence.joined(separator: " ").contains(query.lowercased())
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                MonoLabel(String(format: "%02d / bindings", allRows.filter { !$0.item.isGroup }.count), size: 10, tracking: 1)
                    .foregroundStyle(Color.tingAmber)
                TextField("Filter by name, URL or keys", text: $query).textFieldStyle(.roundedBorder)
                Menu {
                    Button("Application…", action: addApplication)
                    Button("URL", action: addURL)
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
                        ItemIcon(item: row.item, size: 16)
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
        .frame(width: 820, height: 520)
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
                        SequenceRecorder(sequence: row.sequence, label: row.item.label) { recordingFor = nil }
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
        }
    }

    private func target(of item: Item) -> String {
        switch item.action {
        case .group: ""
        case .app(let bundleID): bundleID
        case .url(let url): url
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
                        case .group: break
                        case .app: item.action = .app(text)
                        case .url: item.action = .url(text)
                        }
                    }
                })
    }

    // MARK: Add / delete

    /// New items take a free top-level key, then the key recorder opens at once.
    private func add(_ item: Item) {
        let candidates = "abcdefghijklmnopqrstuvwxyz0123456789".map(String.init) + (1...20).map { "f\($0)" }
        guard let free = candidates.first(where: { key in !model.config.items.contains { $0.key == key } }) else {
            addError = "Every top-level key is taken. Free one first."
            return
        }
        do {
            try model.insertBinding(item, at: [free])
            addError = nil
            selection = [free]
            DispatchQueue.main.async { recordingFor = free }
        } catch {
            addError = "Cannot add the binding."
        }
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

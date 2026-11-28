// The launcha panel in the Ting style: graphite card, amber top rule, a search input and a
// list of apps (or files when no app matches) with their real icons.
import AppKit
import SwiftUI
import TingCore
import BobukUI

struct LaunchaView: View {
    let model: LaunchaModel
    let chrome: LaunchaChrome
    let onActivate: (_ reveal: Bool) -> Void
    let onDismiss: () -> Void
    var onEditShortcut: (LaunchaRow) -> Void = { _ in }
    var onOpenSettings: (() -> Void)? = nil

    var body: some View {
        ZStack(alignment: .top) {
            // A click beside the card closes launcha.
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture(perform: onDismiss)
            LaunchaCard(model: model, chrome: chrome, onActivate: onActivate, onDismiss: onDismiss,
                        onEditShortcut: onEditShortcut, onOpenSettings: onOpenSettings)
                .padding(.top, 8)
        }
    }
}

private struct LaunchaCard: View {
    @Bindable var model: LaunchaModel
    let chrome: LaunchaChrome
    let onActivate: (_ reveal: Bool) -> Void
    let onDismiss: () -> Void
    let onEditShortcut: (LaunchaRow) -> Void
    let onOpenSettings: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let editor = chrome.shortcutEditor {
                LaunchaShortcutEditorView(editor: editor)
            } else {
            if chrome.showHeader {
                HStack(spacing: 8) {
                    TingMark(size: 14)
                    MonoLabel("Ting  ·  launcha", size: 10, tracking: 2).foregroundStyle(Color.tingAmber)
                    Spacer()
                }
                .accessibilityElement(children: .combine)
                .accessibilityAddTraits(.isHeader)
                HStack(spacing: 10) {
                    LeaderToken(leader: chrome.leader, taps: 2, description: chrome.tokenDescription)
                    searchBox(trailingToken: false)
                }
                .padding(.top, 14)
            } else {
                searchBox(trailingToken: true)
            }
            results
            if let row = model.selectedRow, let problem = chrome.appShortcutProblems[row.id] {
                notice(problem, symbol: "exclamationmark.triangle", color: .tingAmber)
            }
            notices
            Rectangle().fill(Color.tingAmber.opacity(0.3)).frame(height: 1).padding(.top, 10)
            ShortcutFooter([.init("↩", "open"), .init("⌘↩", "reveal")]
                            + (model.canJumpToFiles ? [.init("⌘↓", "files")] : [])
                            + [.init("⌘⇧K", "shortcut"), .init("esc", "pull up")],
                           palette: TingPickerStyle.palette,
                           settingsHelp: "Settings · ⌘,",
                           onSettings: onOpenSettings)
                .padding(.top, 10)
            }
        }
        .foregroundStyle(Color.tingInk)
        .padding(.horizontal, 20)
        .padding(.top, chrome.showHeader ? 20 : 18)
        .padding(.bottom, 16)
        .frame(width: 460)
        .pickerPanel(palette: TingPickerStyle.palette)
        .background {
            RoundedRectangle(cornerRadius: PickerMetrics.panelRadius, style: .continuous)
                .fill(Color.tingPanel)
                .shadow(color: .black.opacity(0.35), radius: 24, y: 10)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("launcha")
    }

    private func searchBox(trailingToken: Bool) -> some View {
        HStack(spacing: 8) {
            LaunchaSearchField(text: $model.query, placeholder: "Search apps and files",
                               focusToken: chrome.focusToken,
                               onMove: { model.moveSelection(by: $0) },
                               onSubmit: { onActivate(false) },
                               onCancel: onDismiss)
            if trailingToken {
                LeaderToken(leader: chrome.leader, taps: 2, boxed: false, description: chrome.tokenDescription)
            }
        }
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity)
        .frame(height: 40)
        .background(Color.tingInk.opacity(0.05), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Color.tingStroke.opacity(0.7), lineWidth: 0.75))
    }

    @ViewBuilder private var results: some View {
        if model.rows.isEmpty {
            if let message = model.statusMessage {
                Label {
                    Text(message.text).fixedSize(horizontal: false, vertical: true)
                } icon: {
                    if case .problem = message { Image(systemName: "exclamationmark.triangle") }
                }
                .font(.system(size: 12))
                .foregroundStyle(messageColor(message))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 12)
                .accessibilityAddTraits(.updatesFrequently)
            }
        } else {
            ResultList(model: model, chrome: chrome, onActivate: onActivate)
                .padding(.top, 10)
        }
    }

    private func messageColor(_ message: LaunchaModel.Message) -> Color {
        if case .problem = message { return .tingAmber }
        return .tingMuted
    }

    @ViewBuilder private var notices: some View {
        if let incomplete = model.incompleteMessage {
            notice(incomplete, symbol: "exclamationmark.triangle", color: .tingAmber)
        }
        if let problem = model.consentError ?? model.historyIssue {
            notice(problem, symbol: "exclamationmark.triangle", color: .tingAmber)
        }
        if model.isExplainingConsent {
            ConsentExplanation(onAllow: {
                model.allowProtectedFolders()
                chrome.focusToken += 1
            }, onCancel: {
                model.isExplainingConsent = false
                chrome.focusToken += 1
            })
            .padding(.top, 10)
        } else if model.showsConsentNotice {
            HStack(spacing: 6) {
                Image(systemName: "lock").font(.system(size: 10))
                Text("Desktop, Documents and Downloads were not searched.")
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 6)
                Button("Search Them…") { model.isExplainingConsent = true }
                    .buttonStyle(.plain)
                    .foregroundStyle(Color.tingAmber)
                    .help("Explains what changes and which macOS prompts may appear")
            }
            .font(.system(size: 11))
            .foregroundStyle(Color.tingMuted)
            .padding(.top, 10)
        }
    }

    private func notice(_ text: String, symbol: String, color: Color) -> some View {
        Label(text, systemImage: symbol)
            .font(.system(size: 11))
            .foregroundStyle(color)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 10)
    }
}

private struct ConsentExplanation: View {
    let onAllow: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Search Desktop, Documents and Downloads?")
                .font(.system(size: 12, weight: .semibold))
            Text("launcha will also list apps on your Desktop and find files in these folders. macOS may ask you to allow Ting to access each folder; launcha closes while macOS asks. You can turn this off in Settings.")
                .font(.system(size: 11))
                .foregroundStyle(Color.tingMuted)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Not Now", action: onCancel).buttonStyle(.tingQuiet())
                Button("Allow Access", action: onAllow).buttonStyle(.tingQuiet(prominent: true))
            }
        }
        .padding(12)
        .background(Color.tingInk.opacity(0.05), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .accessibilityElement(children: .contain)
    }
}

private struct ResultList: View {
    let model: LaunchaModel
    let chrome: LaunchaChrome
    let onActivate: (_ reveal: Bool) -> Void

    static let rowHeight = PickerMetrics.rowHeight

    var body: some View {
        let rows = model.rows
        let selection = model.selection
        let preparedQuery = model.query.isEmpty ? nil : FuzzyQuery(model.query)
        let shortcuts = chrome.appHotkeysByID
        ScrollViewReader { proxy in
            ScrollView(.vertical) {
                LazyVStack(spacing: 0) {
                    ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                        ResultRow(row: row, preparedQuery: preparedQuery, selected: index == selection, icons: chrome.icons,
                                  shortcut: shortcuts[row.id]) {
                            model.select(row.id)
                            onActivate(false)
                        }
                        .id(row.id)
                    }
                }
            }
            .scrollIndicators(rows.count * Int(Self.rowHeight) > Int(chrome.maxListHeight) ? .automatic : .never)
            .frame(height: min(CGFloat(rows.count) * Self.rowHeight, chrome.maxListHeight))
            .padding(.horizontal, -8)
            .onChange(of: selection) {
                // No animation: also right for Reduce Motion.
                if rows.indices.contains(selection) { proxy.scrollTo(rows[selection].id) }
            }
            .onChange(of: model.rowsVersion) {
                // Refreshes preserve the selected result; keep it visible after reordering too.
                if rows.indices.contains(selection) {
                    proxy.scrollTo(rows[selection].id, anchor: selection == 0 ? .top : nil)
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(rows.contains { $0.isApp || $0.isMicro } || rows.allSatisfy(\.isCalculation) ? "Apps" : "Files")
    }
}

private struct ResultRow: View {
    let row: LaunchaRow
    /// Prepared once per list so rows do not re-parse the query or keyboard layout variants.
    let preparedQuery: FuzzyQuery?
    let selected: Bool
    let icons: LaunchaIconCache
    let shortcut: Hotkey?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            PickerRow(selected: selected, palette: TingPickerStyle.palette) {
            HStack(spacing: PickerMetrics.columnSpacing) {
                if case .clipbawd = row.kind {
                    Image(systemName: "list.clipboard").font(.system(size: 22)).frame(width: 32, height: 32)
                } else if case .schedule = row.kind {
                    Image(systemName: "calendar").font(.system(size: 20)).foregroundStyle(Color.tingAmber).frame(width: 32, height: 32)
                } else if case .chatta = row.kind {
                    Image(systemName: "sparkles").font(.system(size: 20)).foregroundStyle(Color.tingAmber).frame(width: 32, height: 32)
                } else if row.isLowkeySite {
                    Image(systemName: "globe").font(.system(size: 22)).frame(width: 32, height: 32)
                } else if row.isMicro {
                    MicroRowIcon(isWorking: row.isWorking, icon: row.microIcon)
                } else if row.isCalculation {
                    CalculationRowIcon()
                } else if let url = row.url {
                    RowIcon(url: url, icons: icons)
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text(row.isCalculation ? AttributedString(row.name)
                                           : preparedQuery.map { .highlighting(row.name, query: $0, color: .tingAmber) }
                                               ?? AttributedString(row.name))
                        .font(row.isCalculation ? .system(size: 15, weight: .semibold, design: .monospaced)
                                                : .system(size: 13, weight: .medium))
                        .lineLimit(1).truncationMode(.middle)
                        .textSelection(.disabled)
                    if !row.detail.isEmpty {
                        Text(row.detail).font(.system(size: 10.5))
                            .foregroundStyle(row.isWorking ? Color.tingMuted : Color.tingAmber)
                            .lineLimit(1).truncationMode(.middle)
                    }
                }
                Spacer(minLength: 8)
                if let shortcut {
                    Text(shortcut.display).font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(Color.tingMuted)
                        .accessibilityLabel("Global shortcut \(shortcut.display)")
                }
                if selected {
                    Image(systemName: row.isCalculation ? "doc.on.doc" : row.isApp || row.isMicro || row.isLowkeySite ? "arrow.right" : "arrow.up.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Color.tingAmber)
                        .accessibilityHidden(true)
                }
            }
            }

        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityHint(accessibilityHint)
        .contextMenu {
            if row.isApp {
                Button(shortcut == nil ? "Set Global Shortcut…" : "Change Global Shortcut…",
                       systemImage: "keyboard") {
                    NotificationCenter.default.post(name: .launchaEditAppShortcut, object: row.id)
                }
                if shortcut != nil {
                    Button("Remove Global Shortcut", systemImage: "keyboard.badge.ellipsis", role: .destructive) {
                        NotificationCenter.default.post(name: .launchaRemoveAppShortcut, object: row.id)
                    }
                }
            }
        }
    }

    private var help: String {
        if row.isMicro { return row.detail.isEmpty ? row.name : "\(row.name): \(row.detail)" }
        if row.isCalculation { return row.name }
        if row.isLowkeySite { return "\(row.name): \(row.detail)" }
        if case .clipbawd = row.kind { return "Open Clipbawd clipboard history" }
        if case .schedule = row.kind { return "Open My Schedule calendar" }
        if case .chatta = row.kind { return "Open Chatta agent chat" }
        return row.isApp ? row.name : row.url?.path ?? row.name
    }

    private var accessibilityLabel: String {
        switch row.kind {
        case .app: "\(row.name), app"
        case .file: "\(row.name), file in \(row.detail)"
        case .micro(_, _, let isWorking):
            isWorking ? "\(row.name), micro-app" : "\(row.name), micro-app, not working. \(row.detail)"
        case .calculation: "Result \(row.name)"
        case .clipbawd: "Clipbawd, clipboard history"
        case .schedule: "My Schedule, calendar events and availability"
        case .chatta: "Chatta, AI agent chat"
        case .lowkeySite: "\(row.name), lowkey site. \(row.detail)"
        }
    }

    private var accessibilityHint: String {
        switch row.kind {
        case .app: "Opens the app"
        case .file: "Opens the file with its usual app"
        case .micro(_, _, let isWorking): isWorking ? "Starts the micro-app" : "Shows the error of the file"
        case .calculation: "Copies the result"
        case .clipbawd: "Opens clipboard history"
        case .schedule: "Opens upcoming calendar events and availability"
        case .chatta: "Opens Chatta agent chat"
        case .lowkeySite: "Opens the site in its lowkey profile"
        }
    }
}

/// A calculation: an equals sign in the amber of Ting.
private struct CalculationRowIcon: View {
    var body: some View {
        Image(systemName: "equal")
            .font(.system(size: 13, weight: .bold))
            .foregroundStyle(Color.tingAmber)
            .frame(width: 24, height: 24)
            .background(RoundedRectangle(cornerRadius: 5).fill(Color.tingAmber.opacity(0.14)))
            .accessibilityHidden(true)
    }
}

/// A micro-app has no app icon: its own `icon`, else a terminal symbol, or a warning for a broken file.
private struct MicroRowIcon: View {
    let isWorking: Bool
    let icon: MicroIcon?

    var body: some View {
        Group {
            if isWorking, icon != nil {
                MicroIconView(icon: icon, size: 16)
            } else {
                Image(systemName: isWorking ? MicroIcon.defaultSymbol : "exclamationmark.triangle")
                    .font(.system(size: 13, weight: .medium))
            }
        }
            .foregroundStyle(isWorking ? Color.tingInk.opacity(0.75) : Color.tingAmber)
            .frame(width: 24, height: 24)
            .background(RoundedRectangle(cornerRadius: 5).fill(Color.tingInk.opacity(0.06)))
            .accessibilityHidden(true)
    }
}

private struct RowIcon: View {
    let url: URL
    let icons: LaunchaIconCache
    @State private var image: NSImage?

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image).resizable().scaledToFit()
            } else {
                RoundedRectangle(cornerRadius: 5).fill(Color.tingInk.opacity(0.06))
            }
        }
        .frame(width: 24, height: 24)
        .accessibilityHidden(true)
        .task(id: url) { image = await icons.icon(for: url) }
    }
}

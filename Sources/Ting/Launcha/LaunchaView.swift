// The launcha panel in the Ting style: graphite card, amber top rule, a search input and a
// list of apps (or files when no app matches) with their real icons.
import AppKit
import SwiftUI
import TingCore

struct LaunchaView: View {
    let model: LaunchaModel
    let chrome: LaunchaChrome
    let onActivate: (_ reveal: Bool) -> Void
    let onDismiss: () -> Void

    var body: some View {
        ZStack(alignment: .top) {
            // A click beside the card closes launcha.
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture(perform: onDismiss)
            LaunchaCard(model: model, chrome: chrome, onActivate: onActivate, onDismiss: onDismiss)
                .padding(.top, 8)
        }
    }
}

private struct LaunchaCard: View {
    @Bindable var model: LaunchaModel
    let chrome: LaunchaChrome
    let onActivate: (_ reveal: Bool) -> Void
    let onDismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
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
            notices
            Rectangle().fill(Color.tingAmber.opacity(0.3)).frame(height: 1).padding(.top, 10)
            HStack(spacing: 14) {
                MonoLabel("↩ open", size: 9, weight: .regular, tracking: 1)
                MonoLabel("⌘↩ reveal", size: 9, weight: .regular, tracking: 1)
                MonoLabel("esc pull up", size: 9, weight: .regular, tracking: 1)
                Spacer()
            }
            .foregroundStyle(Color.tingMuted)
            .padding(.top, 10)
            .accessibilityHidden(true)
        }
        .foregroundStyle(Color.tingInk)
        .padding(.horizontal, 20)
        .padding(.top, chrome.showHeader ? 20 : 18)
        .padding(.bottom, 16)
        .frame(width: 460)
        .background(Color.soundPanel, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(alignment: .top) {
            Rectangle().fill(Color.tingAmber).frame(height: 3)
                .clipShape(UnevenRoundedRectangle(topLeadingRadius: 14, topTrailingRadius: 14, style: .continuous))
        }
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.tingStroke.opacity(0.6), lineWidth: 0.75))
        .shadow(color: .black.opacity(0.35), radius: 24, y: 10)
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
                Button("Not Now", action: onCancel).buttonStyle(QuietButtonStyle())
                Button("Allow Access", action: onAllow).buttonStyle(QuietButtonStyle(prominent: true))
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

    static let rowHeight: CGFloat = 40

    var body: some View {
        let rows = model.rows
        let selection = model.selection
        ScrollViewReader { proxy in
            ScrollView(.vertical) {
                LazyVStack(spacing: 0) {
                    ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                        ResultRow(row: row, selected: index == selection, icons: chrome.icons) {
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
            .onChange(of: rows.first?.id) {
                if let first = rows.first?.id { proxy.scrollTo(first, anchor: .top) }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(rows.first?.isApp == false ? "Files" : "Apps")
    }
}

private struct ResultRow: View {
    let row: LaunchaRow
    let selected: Bool
    let icons: LaunchaIconCache
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                RowIcon(url: row.url, icons: icons)
                VStack(alignment: .leading, spacing: 1) {
                    Text(row.name).font(.system(size: 13, weight: .medium)).lineLimit(1)
                    if !row.detail.isEmpty {
                        Text(row.detail).font(.system(size: 10.5)).foregroundStyle(Color.tingMuted)
                            .lineLimit(1).truncationMode(.middle)
                    }
                }
                Spacer(minLength: 8)
                if selected {
                    Image(systemName: row.isApp ? "arrow.right" : "arrow.up.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Color.tingAmber)
                        .accessibilityHidden(true)
                }
            }
            .padding(.horizontal, 8)
            .frame(height: ResultList.rowHeight)
            .background(RoundedRectangle(cornerRadius: 6).fill(selected ? Color.tingAmber.opacity(0.18) : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(HoverRowStyle(cornerRadius: 6))
        .help(row.isApp ? row.name : row.url.path)
        .accessibilityLabel(row.isApp ? "\(row.name), app" : "\(row.name), file in \(row.detail)")
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityHint(row.isApp ? "Opens the app" : "Opens the file with its usual app")
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

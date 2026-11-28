// The Icon cell of Settings › Micro-apps: the icon as a button, and a popover to pick another one.
import AppKit
import SwiftUI
import TingCore

/// The symbols the popover offers. An emoji, a letter or any other SF Symbol name can be typed.
enum MicroIconChoices {
    /// Only the names this macOS has are shown.
    static let symbols = [
        "terminal", "globe", "magnifyingglass", "text.magnifyingglass", "doc.text", "doc.on.clipboard", "list.bullet", "textformat",
        "character.cursor.ibeam", "translate", "bubble.left", "sparkles", "wand.and.stars", "bolt", "gearshape", "wrench.and.screwdriver",
        "hammer", "folder", "archivebox", "link", "paperclip", "envelope", "calendar", "clock", "timer", "bell", "star", "heart",
        "bookmark", "tag", "flag", "pin", "lock", "key", "camera", "photo", "play", "music.note", "mic", "speaker.wave.2",
        "network", "cloud", "arrow.triangle.2.circlepath", "arrow.up.arrow.down", "square.and.arrow.up", "trash", "pencil", "scissors",
        "number", "function", "chart.bar", "curlybraces", "chevron.left.forwardslash.chevron.right", "cpu", "keyboard", "display",
        "lightbulb", "brain", "person", "house", "cart", "creditcard", "map", "location", "airplane", "sun.max", "moon", "ladybug",
    ].filter { NSImage(systemSymbolName: $0, accessibilityDescription: nil) != nil }
}

/// The icon of a micro-app as a button; a click opens the chooser. The choice goes to `microIcons`
/// of the config, never to the micro-app file, so the file stays approved.
struct MicroIconCell: View {
    let micro: String
    /// The `icon` key of the file.
    let fileIcon: MicroIcon?
    @Environment(AppModel.self) private var model
    @State private var isOpen = false

    var body: some View {
        let saved = model.config.microIcons[micro]
        Button { isOpen = true } label: {
            HStack(spacing: 3) {
                MicroIconView(icon: saved.flatMap(MicroIcon.init) ?? fileIcon, size: 16).foregroundStyle(Color.tingInk.opacity(0.8))
                Image(systemName: "chevron.down").font(.system(size: 7, weight: .bold)).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 5)
            .frame(height: 22)
            .contentShape(Rectangle())
            .background(Color.tingInk.opacity(0.05), in: RoundedRectangle(cornerRadius: 5, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous).strokeBorder(Color.tingInk.opacity(0.12), lineWidth: 1))
        }
        .buttonStyle(.plain)
        .help("Change the icon")
        .accessibilityLabel("Icon of \(micro). Click to change.")
        .popover(isPresented: $isOpen, arrowEdge: .bottom) {
            MicroIconChooser(selected: saved.flatMap(MicroIcon.init) ?? fileIcon, hasOverride: saved != nil, fileIcon: fileIcon) { choice in
                model.setMicroIcon(choice, for: micro)
                isOpen = false
            }
        }
    }
}

/// A grid of symbols, a field for any other icon, and the way back to the icon of the file.
/// `choose` gets the icon text, or nil to remove the choice.
struct MicroIconChooser: View {
    let selected: MicroIcon?
    let hasOverride: Bool
    let fileIcon: MicroIcon?
    let choose: (String?) -> Void
    @State private var custom = ""

    private let columns = Array(repeating: GridItem(.fixed(26), spacing: 4), count: 10)

    /// Why the typed text cannot be used; nil for an empty field or a good icon.
    private var customProblem: String? {
        let text = custom.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty { return nil }
        switch MicroIcon(text) {
        case nil: return "Type one emoji or letter, or an SF Symbol name such as globe."
        case .symbol(let name)? where NSImage(systemSymbolName: name, accessibilityDescription: nil) == nil:
            return "macOS has no symbol named \(name)."
        default: return nil
        }
    }

    private var canUseCustom: Bool { !custom.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && customProblem == nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            title("Symbols")
            grid(MicroIconChoices.symbols)
            Divider()
            title("Emoji, letter or another symbol")
            HStack(spacing: 6) {
                MicroIconView(icon: canUseCustom ? MicroIcon(custom) : nil, size: 16)
                    .foregroundStyle(Color.tingInk.opacity(0.8)).opacity(canUseCustom ? 1 : 0.25)
                TextField("Emoji, letter or SF Symbol name", text: $custom)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { if canUseCustom { choose(custom) } }
                    .accessibilityLabel("Another icon")
                Button("Use") { choose(custom) }.disabled(!canUseCustom)
            }
            if let customProblem {
                Text(customProblem).font(.caption).foregroundStyle(Color.tingAmber)
            }
            Divider()
            Button(fileIcon == nil ? "Use the default icon" : "Use the icon of the file") { choose(nil) }
                .disabled(!hasOverride)
                .help("Remove the icon chosen here")
        }
        .padding(12)
        .frame(width: 320)
    }

    private func title(_ text: String) -> some View {
        Text(text).font(.caption).foregroundStyle(.secondary)
    }

    private func grid(_ icons: [String]) -> some View {
        LazyVGrid(columns: columns, alignment: .leading, spacing: 4) {
            ForEach(icons, id: \.self) { text in
                let icon = MicroIcon(text)
                Button { choose(text) } label: {
                    MicroIconView(icon: icon, size: 16)
                        .foregroundStyle(Color.tingInk.opacity(0.8))
                        .frame(width: 26, height: 26)
                        .contentShape(Rectangle())
                        .background(RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .fill(icon == selected ? Color.tingAmber.opacity(0.3) : Color.tingInk.opacity(0.05)))
                }
                .buttonStyle(.plain)
                .help(text)
                .accessibilityLabel(text)
                .accessibilityAddTraits(icon == selected ? .isSelected : [])
            }
        }
    }
}

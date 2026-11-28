// Ting visual language powered by BobukKit's ThemeStore: curated presets + custom panel/accent
// colors, defaulting to graphite panels and amber "Soundsystem" keycaps.
import AppKit
import SwiftUI
import TingCore
import BobukUI
import BobukSystem

@MainActor extension ThemeStore {
    static let tingKeys = StorageKeys(appearance: "tingAppearance", palette: "tingThemePalette")

    /// Shared live theme store for Ting, mirrored from `config.json` (default: Dark + Amber).
    static let ting = ThemeStore(keys: tingKeys, defaultAppearance: .dark, defaultPreset: .amber)
}

/// App-owned colors; BobukKit owns shared picker geometry and rendering.
@MainActor enum TingPickerStyle {
    static var palette: PickerPalette { ThemeStore.ting.pickerPalette }
    static var toast: PickerPalette { ThemeStore.ting.pickerPalette }
}

/// Live themed surface and keycap colors backed by `ThemeStore.ting`.
@MainActor enum TingColors {
    static var soundPanel: NSColor { ThemeStore.ting.tokens.panelNSColor }
    static var soundKey: NSColor { ThemeStore.ting.tokens.accentNSColor }
    static var soundKeyInk: NSColor { ThemeStore.ting.tokens.keyInkNSColor }
}

extension Appearance {
    var choice: AppearanceChoice {
        switch self {
        case .system: .system
        case .light: .light
        case .dark: .dark
        }
    }

    init(_ choice: AppearanceChoice) {
        switch choice {
        case .system: self = .system
        case .light: self = .light
        case .dark: self = .dark
        }
    }

    var title: String { choice.title }

    /// Ting sets the whole app appearance, so Settings and the leader menu match.
    @MainActor func apply() { choice.apply() }
}

extension Color {
    @MainActor static var tingPanel: Color { ThemeStore.ting.tokens.panelColor }
    @MainActor static var tingInk: Color { ThemeStore.ting.tokens.inkColor }
    @MainActor static var tingMuted: Color { ThemeStore.ting.tokens.mutedColor }
    @MainActor static var tingAmber: Color { ThemeStore.ting.tokens.accentColor }
    @MainActor static var tingStroke: Color { ThemeStore.ting.tokens.lineColor }
    @MainActor static var tingElevated: Color { ThemeStore.ting.tokens.elevatedColor }
    @MainActor static var tingSelection: Color { ThemeStore.ting.tokens.selectionColor }
    @MainActor static var tingLink: Color { ThemeStore.ting.tokens.linkColor }
    @MainActor static var tingSuccess: Color { ThemeStore.ting.tokens.successColor }
    @MainActor static var tingDanger: Color { ThemeStore.ting.tokens.dangerColor }

    @MainActor static var soundPanel: Color { ThemeStore.ting.tokens.panelColor }
    @MainActor static var soundKey: Color { ThemeStore.ting.tokens.accentColor }
    @MainActor static var soundKeyInk: Color { ThemeStore.ting.tokens.keyInkColor }
}

extension ButtonStyle where Self == QuietButtonStyle {
    /// BobukKit's quiet button in Ting's active theme; `prominent` fills it with the accent.
    @MainActor static func tingQuiet(prominent: Bool = false) -> QuietButtonStyle {
        QuietButtonStyle(palette: TingPickerStyle.palette, prominent: prominent)
    }
}

/// Ting mark: a struck dot with two sound arcs.
struct TingMark: View {
    var color: Color? = nil
    var size: CGFloat = 16

    var body: some View {
        let tint = color ?? .tingAmber
        Canvas { context, canvas in
            let s = canvas.width / 16
            let dot = CGRect(x: 1 * s, y: 6 * s, width: 4 * s, height: 4 * s)
            context.fill(Path(ellipseIn: dot), with: .color(tint))
            for (index, radius) in [5.5, 9.5].enumerated() {
                var arc = Path()
                arc.addArc(center: CGPoint(x: 3 * s, y: 8 * s), radius: radius * s,
                           startAngle: .degrees(-50), endAngle: .degrees(50), clockwise: false)
                context.stroke(arc, with: .color(tint.opacity(index == 0 ? 1 : 0.55)),
                               style: StrokeStyle(lineWidth: 1.8 * s, lineCap: .round))
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

/// The leader is a tuning fork rather than the name of the configured key.
/// Two forks can represent a double-tap in the launcha panel.
struct LeaderToken: View {
    let leader: String
    var taps = 1
    /// The dashed key outline. Off inside the launcha search input.
    var boxed = true
    /// Replaces the default tooltip and spoken label, e.g. to name the launcha hotkey too.
    var description: String?

    var body: some View {
        HStack(spacing: taps > 1 ? 1 : 4) {
            ForEach(0..<taps, id: \.self) { _ in
                Image(nsImage: StatusIcon.image)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 18, height: 18)
            }
        }
        .foregroundStyle(Color.tingMuted)
        .padding(.horizontal, boxed ? 6 : 0)
        .frame(minWidth: boxed ? 30 : nil, minHeight: boxed ? 30 : nil)
        .overlay {
            if boxed {
                RoundedRectangle(cornerRadius: 7)
                    .strokeBorder(Color.tingMuted.opacity(0.5), style: StrokeStyle(lineWidth: 1, dash: [3, 2]))
            }
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Self.label(leader: leader, taps: taps, description: description))
        .help(Self.label(leader: leader, taps: taps, description: description))
    }

    /// Tooltip and spoken label: names the real key, and a double tap.
    static func label(leader: String, taps: Int, description: String?) -> String {
        if let description { return description }
        let key = leader.isEmpty ? "Leader key" : "Leader key \(leader)"
        return taps == 1 ? key : "\(key), pressed twice"
    }
}

enum KeyCapStyle { case quiet, sound }

/// A binding key. Shows the active non-Latin layout letter as a small hint.
struct KeyCap: View {
    let key: String
    var style: KeyCapStyle = .sound
    var large = false

    var body: some View {
        let hint = KeyTranslator.localHint(forLatin: key)
        HStack(alignment: .firstTextBaseline, spacing: 1) {
            Text(SequenceKey.display(key))
                .font(.system(size: large ? 15 : 11, weight: .semibold, design: .monospaced))
            if let hint {
                Text(hint.uppercased())
                    .font(.system(size: large ? 9 : 7.5, weight: .medium, design: .monospaced))
                    .opacity(0.55)
            }
        }
        .foregroundStyle(foreground)
        .padding(.horizontal, key.count > 1 && key.hasPrefix("f") ? 4 : 0)
        // One width with or without a layout hint, so the labels of a menu line up.
        .frame(minWidth: large ? 30 : 28, minHeight: large ? 30 : 22)
        .background(background, in: RoundedRectangle(cornerRadius: large ? 7 : 5, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: large ? 7 : 5, style: .continuous).strokeBorder(border))
        .accessibilityLabel("Key \(SequenceKey.spoken(key))")
    }

    private var foreground: Color {
        switch style {
        case .quiet: .tingInk
        case .sound: .soundKeyInk
        }
    }

    private var background: Color {
        switch style {
        case .quiet: Color.tingInk.opacity(0.07)
        case .sound: .soundKey
        }
    }

    private var border: Color {
        switch style {
        case .quiet: Color.tingInk.opacity(0.12)
        case .sound: .clear
        }
    }
}

/// Row highlight on hover, used by the leader menu rows.
struct HoverRowStyle: ButtonStyle {
    var cornerRadius: CGFloat = 6

    func makeBody(configuration: Configuration) -> some View {
        HoverRow(configuration: configuration, cornerRadius: cornerRadius)
    }

    private struct HoverRow: View {
        let configuration: Configuration
        let cornerRadius: CGFloat
        @State private var hovering = false

        var body: some View {
            configuration.label
                .background(RoundedRectangle(cornerRadius: cornerRadius)
                    .fill(Color.tingInk.opacity(configuration.isPressed ? 0.14 : hovering ? 0.06 : 0)))
                .onHover { hovering = $0 }
        }
    }
}

/// App icon for an `.app` item, a globe for a URL, a folder for a group.
/// The icon of a micro-app: its emoji or letter, its SF Symbol, or the terminal symbol when it
/// has none or macOS does not know the symbol name. The caller gives the colour of a symbol or a letter.
struct MicroIconView: View {
    let icon: MicroIcon?
    var size: CGFloat = 16

    var body: some View {
        Group {
            switch icon {
            case .glyph(let text)?:
                Text(text).font(.system(size: size * 0.85)).lineLimit(1).minimumScaleFactor(0.5)
            case .symbol(let name)? where NSImage(systemSymbolName: name, accessibilityDescription: nil) != nil:
                Image(systemName: name).resizable().scaledToFit()
            default:
                Image(systemName: MicroIcon.defaultSymbol).resizable().scaledToFit()
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

struct ItemIcon: View {
    let item: Item
    var size: CGFloat = 18
    /// The icon of a `micro` item, from `MicroAppCatalog.icon`.
    var microIcon: MicroIcon?

    var body: some View {
        Group {
            switch item.action {
            case .app(let bundleID):
                if let image = AppIcons.icon(bundleID) {
                    Image(nsImage: image).resizable()
                } else {
                    Image(systemName: "app.dashed").resizable().foregroundStyle(.secondary)
                }
            case .url:
                Image(systemName: "globe").resizable().foregroundStyle(.secondary)
            case .group:
                Image(systemName: "folder").resizable().foregroundStyle(.secondary)
            case .micro:
                MicroIconView(icon: microIcon, size: size).foregroundStyle(.secondary)
            case .open(let panel):
                Image(systemName: panel.symbol).resizable().foregroundStyle(.secondary)
            case .window:
                Image(systemName: "rectangle.inset.filled").resizable().foregroundStyle(.secondary)
            }
        }
        .scaledToFit()
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

@MainActor
enum AppIcons {
    private static var cache: [String: NSImage] = [:]
    private static var missing: Set<String> = []

    /// Resolve icons while loading bindings, never on the first menu opening.
    static func prepare(_ items: [Item]) {
        missing.removeAll()
        func visit(_ items: [Item]) {
            for item in items {
                switch item.action {
                case .group(let children): visit(children)
                case .app(let id): _ = icon(id)
                default: break
                }
            }
        }
        visit(items)
    }

    static func icon(_ bundleID: String) -> NSImage? {
        if let cached = cache[bundleID] { return cached }
        guard !missing.contains(bundleID) else { return nil }
        guard !bundleID.isEmpty, let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
            missing.insert(bundleID)
            return nil
        }
        let image = NSWorkspace.shared.icon(forFile: url.path)
        cache[bundleID] = image
        return image
    }
}

extension TingPanel {
    var symbol: String {
        switch self {
        case .launcha: "magnifyingglass"
        case .clipbawd: "list.clipboard"
        case .schedule: "calendar"
        case .chatta: "sparkles"
        }
    }
}

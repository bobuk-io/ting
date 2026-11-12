// Ting visual language: graphite panels, amber accents and solid amber "Soundsystem" keycaps.
import AppKit
import SwiftUI
import TingCore

extension Appearance {
    var title: String { self == .light ? "Light" : "Dark" }

    /// Ting sets the whole app appearance, so Settings and the leader menu match.
    @MainActor func apply() {
        NSApp.appearance = NSAppearance(named: self == .light ? .aqua : .darkAqua)
    }
}

extension NSColor {
    static func theme(light: UInt32, dark: UInt32) -> NSColor {
        NSColor(name: nil) { appearance in
            let hex = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
            return NSColor(srgbRed: Double((hex >> 16) & 255) / 255, green: Double((hex >> 8) & 255) / 255,
                           blue: Double(hex & 255) / 255, alpha: 1)
        }
    }
}

extension Color {
    static func theme(light: UInt32, dark: UInt32) -> Color { Color(nsColor: .theme(light: light, dark: dark)) }

    static var tingPanel: Color { .theme(light: 0xF7F8F5, dark: 0x222A2E) }
    static var tingInk: Color { .theme(light: 0x222A2E, dark: 0xEEF1EC) }
    static var tingMuted: Color { .theme(light: 0x59666C, dark: 0xA4AFB3) }
    static var tingAmber: Color { .theme(light: 0x885500, dark: 0xE7BB74) }
    static var tingStroke: Color { .theme(light: 0xB3BEC1, dark: 0x526064) }

    static var soundPanel: Color { .theme(light: 0xEEEDE6, dark: 0x181C1F) }
    static var soundKey: Color { .theme(light: 0xD99A2B, dark: 0xE7BB74) }
    static var soundKeyInk: Color { .theme(light: 0x2A1C05, dark: 0x1D1609) }
}

/// Mono, tracked, upper-case label: "TING", "W / WEB", "04".
struct MonoLabel: View {
    let text: String
    var size: CGFloat = 10
    var weight: Font.Weight = .semibold
    var tracking: CGFloat = 1.5

    init(_ text: String, size: CGFloat = 10, weight: Font.Weight = .semibold, tracking: CGFloat = 1.5) {
        self.text = text
        self.size = size
        self.weight = weight
        self.tracking = tracking
    }

    var body: some View {
        Text(text.uppercased()).font(.system(size: size, weight: weight, design: .monospaced)).tracking(tracking)
    }
}

/// Ting mark: a struck dot with two sound arcs.
struct TingMark: View {
    var color: Color = .tingAmber
    var size: CGFloat = 16

    var body: some View {
        Canvas { context, canvas in
            let s = canvas.width / 16
            let dot = CGRect(x: 1 * s, y: 6 * s, width: 4 * s, height: 4 * s)
            context.fill(Path(ellipseIn: dot), with: .color(color))
            for (index, radius) in [5.5, 9.5].enumerated() {
                var arc = Path()
                arc.addArc(center: CGPoint(x: 3 * s, y: 8 * s), radius: radius * s,
                           startAngle: .degrees(-50), endAngle: .degrees(50), clockwise: false)
                context.stroke(arc, with: .color(color.opacity(index == 0 ? 1 : 0.55)),
                               style: StrokeStyle(lineWidth: 1.8 * s, lineCap: .round))
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
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
        .frame(minWidth: large ? 30 : (hint == nil ? 22 : 28), minHeight: large ? 30 : 22)
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

/// Small bordered button used across Ting surfaces (Splash Finish "Snooze" style).
struct QuietButtonStyle: ButtonStyle {
    var prominent = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .medium))
            .padding(.horizontal, 13)
            .frame(height: 30)
            .foregroundStyle(prominent ? Color.soundKeyInk : Color.tingInk)
            .background(prominent ? Color.tingAmber.opacity(configuration.isPressed ? 0.8 : 1)
                                  : Color.tingInk.opacity(configuration.isPressed ? 0.14 : 0.05),
                        in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.tingInk.opacity(prominent ? 0 : 0.1)))
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
struct ItemIcon: View {
    let item: Item
    var size: CGFloat = 18

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

    static func icon(_ bundleID: String) -> NSImage? {
        if let cached = cache[bundleID] { return cached }
        guard !bundleID.isEmpty, let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return nil }
        let image = NSWorkspace.shared.icon(forFile: url.path)
        cache[bundleID] = image
        return image
    }
}

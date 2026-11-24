// The leader menu in the Soundsystem style: graphite panel, amber top bar,
// solid amber keycaps, the typed sequence shown as a track.
import AppKit
import SwiftUI
import TingCore
import BobukUI

struct LeaderMenuView: View {
    let session: LeaderSession
    let onSelect: (String) -> Void
    let onDismiss: () -> Void
    var onOpenSettings: (() -> Void)? = nil

    var body: some View {
        ZStack {
            // A click beside the menu closes it.
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture(perform: onDismiss)
            SoundList(session: session, onSelect: onSelect, onOpenSettings: onOpenSettings)
                .modifier(Shake(token: session.shakeToken))
        }
    }
}

private struct SoundList: View {
    let session: LeaderSession
    let onSelect: (String) -> Void
    let onOpenSettings: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if session.showPanelHeader {
                HStack(spacing: 8) {
                    TingMark(size: 14)
                    MonoLabel("Ting  ·  selecta", size: 10, tracking: 2).foregroundStyle(Color.tingAmber)
                    Spacer()
                }
            }
            // The typed sequence as a track: leader, keys so far, blinking slot.
            HStack(spacing: 6) {
                LeaderToken(leader: session.leader)
                ForEach(Array(session.path.enumerated()), id: \.offset) { KeyCap(key: $0.element, style: .sound, large: true) }
                BlinkingSlot(isActive: session.isVisible)
                Spacer()
            }
            .padding(.vertical, 14)
            VStack(spacing: 1) {
                if session.items.isEmpty {
                    Text("Nothing bound here yet. Add bindings in Settings.")
                        .font(.system(size: 12)).foregroundStyle(Color.tingMuted)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 8).padding(.vertical, 5)
                }
                ForEach(session.items, id: \.key) { item in
                    Row(item: item, microApps: session.microApps, selected: session.selectedItem?.key == item.key) { onSelect(item.key) }
                }
            }
            .padding(.horizontal, -8)
            Rectangle().fill(Color.tingAmber.opacity(0.3)).frame(height: 1).padding(.top, 10)
            ShortcutFooter([.init("↑↓", "select"), .init("↩", "open"),
                            .init("←", "back"), .init("esc", "close")],
                           palette: TingPickerStyle.palette,
                           settingsHelp: "Settings · ⌘,",
                           onSettings: onOpenSettings)
                .padding(.top, 10)
        }
        .foregroundStyle(Color.tingInk)
        .padding(.horizontal, 20)
        .padding(.top, session.showPanelHeader ? 20 : 4)
        .padding(.bottom, 20)
        .frame(width: 340)
        .pickerPanel(palette: TingPickerStyle.palette)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Ting menu")
    }
}

private struct Row: View {
    let item: Item
    let microApps: MicroAppCatalog
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            PickerRow(selected: selected, palette: TingPickerStyle.palette) {
            HStack(spacing: PickerMetrics.columnSpacing) {
                KeyCap(key: item.key, style: .sound)
                ItemIcon(item: item, size: 16)
                Text(title)
                    .font(.system(size: 13, weight: .medium)).lineLimit(1)
                    .foregroundStyle(isBrokenMicro ? Color.tingMuted : Color.tingInk)
                    .strikethrough(isBrokenMicro, color: Color.tingMuted)
                Spacer(minLength: 8)
                if isBrokenMicro {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 10)).foregroundStyle(Color.tingAmber)
                        .help("Not working: press the key to see why")
                }
                if let children = item.children {
                    Text(String(format: "%02d", children.count))
                        .font(.system(size: 10, design: .monospaced)).foregroundStyle(Color.tingAmber)
                }
                Image(systemName: arrow)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Color.tingAmber)
            }
            }

        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(SequenceKey.spoken(item.key)), \(title)\(item.isGroup ? ", group" : "")\(isBrokenMicro ? ", not working" : "")")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private var title: String {
        if case .micro(let id) = item.action { return microApps.bindingName(label: item.label, id: id) }
        if !item.label.isEmpty { return item.label }
        switch item.action {
        case .group: return "Group"
        case .app(let bundleID): return bundleID
        case .url(let url): return url
        case .micro(let id): return id
        case .open(let panel): return panel.rawValue
        case .window(let command): return command.title
        }
    }

    /// A micro-app binding whose micro-app is missing or broken.
    private var isBrokenMicro: Bool {
        if case .micro(let id) = item.action { return !microApps.resolve(id).isWorking }
        return false
    }

    private var arrow: String {
        switch item.action {
        case .group: "chevron.right"
        case .url: "arrow.up.right"
        case .app: "arrow.right"
        case .micro: "play"
        case .open: "arrow.right"
        case .window: "rectangle.inset.filled"
        }
    }
}

private struct BlinkingSlot: View {
    let isActive: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        // Unmounting the pulsing view when the panel hides guarantees zero display-link work
        // while ordered out, and animating layer opacity avoids per-frame stroke rasterization.
        Group {
            if isActive && !reduceMotion {
                PulsingSlot()
            } else {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .strokeBorder(Color.tingAmber, lineWidth: 1.5)
                    .opacity(0.9)
            }
        }
        .frame(width: 30, height: 30)
        .accessibilityHidden(true)
    }

    private struct PulsingSlot: View {
        @State private var dimmed = false

        var body: some View {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .strokeBorder(Color.tingAmber, lineWidth: 1.5)
                .opacity(dimmed ? 0.25 : 0.9)
                .onAppear {
                    withAnimation(.easeInOut(duration: 0.6).repeatForever(autoreverses: true)) {
                        dimmed = true
                    }
                }
        }
    }
}

/// Unknown key: a short shake, or a beep with Reduce Motion.
private struct Shake: ViewModifier {
    let token: Int
    @State private var offset: CGFloat = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .offset(x: offset)
            .onChange(of: token) {
                guard !reduceMotion else { NSSound.beep(); return }
                withAnimation(.spring(response: 0.08, dampingFraction: 0.2)) { offset = 8 }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.09) {
                    withAnimation(.spring(response: 0.2, dampingFraction: 0.4)) { offset = 0 }
                }
            }
    }
}

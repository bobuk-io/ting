// The leader menu in the Soundsystem style: graphite panel, amber top bar,
// solid amber keycaps, the typed sequence shown as a track.
import AppKit
import SwiftUI
import TingCore

struct LeaderMenuView: View {
    let session: LeaderSession
    let onSelect: (String) -> Void
    let onDismiss: () -> Void

    var body: some View {
        ZStack {
            // A click beside the menu closes it.
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture(perform: onDismiss)
            SoundList(session: session, onSelect: onSelect)
                .modifier(Shake(token: session.shakeToken))
        }
    }
}

private struct SoundList: View {
    let session: LeaderSession
    let onSelect: (String) -> Void

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
                BlinkingSlot()
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
                ForEach(Array(session.items.enumerated()), id: \.offset) { _, item in
                    Row(item: item) { onSelect(item.key) }
                }
            }
            .padding(.horizontal, -8)
            Rectangle().fill(Color.tingAmber.opacity(0.3)).frame(height: 1).padding(.top, 10)
            HStack(spacing: 14) {
                MonoLabel("esc pull up", size: 9, weight: .regular, tracking: 1)
                MonoLabel("⌫ rewind", size: 9, weight: .regular, tracking: 1)
                Spacer()
            }
            .foregroundStyle(Color.tingMuted)
            .padding(.top, 10)
        }
        .id(session.generation)
        .foregroundStyle(Color.tingInk)
        .padding(20)
        .frame(width: 340)
        .background(Color.soundPanel, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(alignment: .top) {
            Rectangle().fill(Color.tingAmber).frame(height: 3)
                .clipShape(UnevenRoundedRectangle(topLeadingRadius: 14, topTrailingRadius: 14, style: .continuous))
        }
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.tingStroke.opacity(0.6), lineWidth: 0.75))
        .shadow(color: .black.opacity(0.35), radius: 24, y: 10)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Ting menu")
    }
}

private struct Row: View {
    let item: Item
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                KeyCap(key: item.key, style: .sound)
                ItemIcon(item: item, size: 16)
                Text(item.label.isEmpty ? placeholder : item.label)
                    .font(.system(size: 13, weight: .medium)).lineLimit(1)
                Spacer(minLength: 8)
                if let children = item.children {
                    Text(String(format: "%02d", children.count))
                        .font(.system(size: 10, design: .monospaced)).foregroundStyle(Color.tingAmber)
                }
                Image(systemName: arrow)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Color.tingAmber)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .contentShape(Rectangle())
        }
        .buttonStyle(HoverRowStyle(cornerRadius: 6))
        .accessibilityLabel("\(SequenceKey.spoken(item.key)), \(item.label)\(item.isGroup ? ", group" : "")")
    }

    private var placeholder: String {
        switch item.action {
        case .group: "Group"
        case .app(let bundleID): bundleID
        case .url(let url): url
        }
    }

    private var arrow: String {
        switch item.action {
        case .group: "chevron.right"
        case .url: "arrow.up.right"
        case .app: "arrow.right"
        }
    }
}

private struct BlinkingSlot: View {
    @State private var on = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        RoundedRectangle(cornerRadius: 7, style: .continuous)
            .strokeBorder(Color.tingAmber.opacity(on ? 0.9 : 0.25), lineWidth: 1.5)
            .frame(width: 30, height: 30)
            .onAppear {
                guard !reduceMotion else { return }
                withAnimation(.easeInOut(duration: 0.6).repeatForever()) { on = false }
            }
            .accessibilityHidden(true)
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

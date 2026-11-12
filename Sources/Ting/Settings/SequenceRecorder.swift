// Record a key sequence: Return and Space are keys, so the "Done" button finishes.
import AppKit
import SwiftUI
import TingCore

struct SequenceRecorder: View {
    @Environment(AppModel.self) private var model
    /// Current sequence of the binding being recorded.
    let sequence: [String]
    let label: String
    let close: () -> Void
    @State private var keys: [String] = []
    @State private var monitor = KeyMonitor()
    @State private var rejected: String?
    @State private var saveError: String?

    var body: some View {
        let problem = BindingTree.problem(placing: keys, moving: sequence, in: model.config.items)
        VStack(alignment: .leading, spacing: 12) {
            MonoLabel("Keys for \(label.isEmpty ? "binding" : label)", size: 9, tracking: 1.5).foregroundStyle(Color.tingAmber)
            HStack(spacing: 6) {
                Text(model.leaderDisplay).font(.system(size: 12, weight: .semibold, design: .monospaced)).foregroundStyle(Color.tingMuted)
                ForEach(Array(keys.enumerated()), id: \.offset) { KeyCap(key: $0.element, large: true) }
                RoundedRectangle(cornerRadius: 7).strokeBorder(Color.tingAmber, style: StrokeStyle(lineWidth: 1.5, dash: [3, 2]))
                    .frame(width: 30, height: 30)
                Spacer(minLength: 0)
            }
            Group {
                if let rejected {
                    Label(rejected, systemImage: "nosign").foregroundStyle(Color.tingAmber)
                } else if let saveError {
                    Label(saveError, systemImage: "exclamationmark.triangle.fill").foregroundStyle(Color.tingAmber)
                } else if let problem, problem != .empty {
                    problemView(problem)
                } else if keys.isEmpty {
                    Text("Type the keys. ⌫ removes the last one, Esc cancels.").foregroundStyle(Color.tingMuted)
                } else {
                    Text(needsNewGroups ? "Missing groups will be created." : "Free.").foregroundStyle(Color.tingMuted)
                }
            }
            .font(.caption)
            .fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("Clear") { keys = [] }.buttonStyle(QuietButtonStyle()).disabled(keys.isEmpty)
                Spacer()
                Button("Cancel", action: finish).buttonStyle(QuietButtonStyle())
                Button("Done") {
                    do {
                        try model.moveBinding(from: sequence, to: keys)
                        finish()
                    } catch {
                        saveError = "Cannot save these keys."
                    }
                }
                .buttonStyle(QuietButtonStyle(prominent: problem == nil))
                .disabled(problem != nil)
            }
        }
        .foregroundStyle(Color.tingInk)
        .padding(16)
        .frame(width: 380)
        .background(Color.tingPanel)
        .onAppear {
            keys = sequence
            monitor.start(handle)
        }
        .onDisappear { monitor.stop() }
    }

    private var needsNewGroups: Bool {
        keys.count > 1 && BindingTree.item(at: Array(keys.dropLast()), in: model.config.items) == nil
    }

    private func finish() {
        monitor.stop()
        close()
    }

    @ViewBuilder private func problemView(_ problem: SequenceProblem) -> some View {
        switch problem {
        case .empty, .notFound:
            EmptyView()
        case .invalidKey(let key):
            warning("\(key) cannot be bound.")
        case .taken(let label):
            warning("Already used by \(label.isEmpty ? "another binding" : label).")
        case .insideItself:
            warning("A binding cannot move inside itself.")
        case .prefixIsAction(let prefix, let label):
            let shown = prefix.map(SequenceKey.display).joined(separator: " ")
            VStack(alignment: .leading, spacing: 6) {
                warning("\(shown) already opens \(label), so it cannot start a longer sequence.")
                Button("Make \(shown) a group (\(label) moves to \(shown) \(SequenceKey.display(prefix.last ?? "")))") {
                    model.convertToGroup(at: prefix)
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color.tingAmber)
                .underline()
            }
        }
    }

    private func warning(_ text: String) -> some View {
        Label(text, systemImage: "exclamationmark.triangle.fill").foregroundStyle(Color.tingAmber)
    }

    private func handle(_ event: NSEvent) -> NSEvent? {
        guard event.type == .keyDown else { return event }
        if event.modifierFlags.contains(.command) { return event }
        rejected = nil
        saveError = nil
        switch event.keyCode {
        case 53:
            finish()
        case 51, 117:
            if !keys.isEmpty { keys.removeLast() }
        default:
            if let key = SequenceKey.name(keyCode: event.keyCode, latin: KeyTranslator.latin(event.keyCode)) {
                keys.append(key)
            } else {
                rejected = "Only letters, digits, Space, Return and F-keys."
            }
        }
        return nil
    }
}

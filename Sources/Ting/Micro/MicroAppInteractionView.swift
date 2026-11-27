import BobukCore
import SwiftUI
import TingCore

@MainActor
@Observable
final class MicroAppInteractionModel {
    let request: MicroAppInteraction
    var text: String
    var query = "" {
        didSet {
            filteredChoices = query.isEmpty ? choices : MicroAppInteraction.filterChoices(choices, matching: query)
            selectedID = filteredChoices.first?.id
        }
    }
    var selectedID: Int?
    var error: String?
    /// The choices matching `query`, filtered once per change of the query: the view reads
    /// them several times per keystroke, and fuzzy matching a long list on each read lags typing.
    private(set) var filteredChoices: [MicroAppInteraction.Choice] = []

    init(_ request: MicroAppInteraction) {
        self.request = request
        if case .ask(_, let initial, _, _, _) = request { text = initial } else { text = "" }
        filteredChoices = choices
        selectedID = choices.first?.id
    }

    var choices: [MicroAppInteraction.Choice] {
        if case .choose(_, let choices, _) = request { return choices }
        return []
    }

    var isChoice: Bool { if case .choose = request { return true }; return false }
    var isPreview: Bool { if case .preview = request { return true }; return false }
    /// The choose step asked for `details`: the selected value is shown beside the list.
    var showsDetails: Bool { if case .choose(_, _, let details) = request { return details }; return false }
    var selectedChoice: MicroAppInteraction.Choice? { filteredChoices.first { $0.id == selectedID } }
    var multiline: Bool { if case .ask(_, _, _, let value, _) = request { return value }; return false }

    func move(_ delta: Int) {
        let list = filteredChoices
        guard !list.isEmpty else { selectedID = nil; return }
        let index = list.firstIndex { $0.id == selectedID } ?? 0
        selectedID = list[max(0, min(list.count - 1, index + delta))].id
    }

    func answer() -> String? {
        let value: String
        if isChoice {
            guard let choice = selectedChoice else { return nil }
            value = choice.value
        } else { value = text }
        do { return try request.validate(value) }
        catch { self.error = String(describing: error); return nil }
    }
}

struct MicroAppInteractionBody: View {
    @Bindable var model: MicroAppInteractionModel
    var textSize: CGFloat = CGFloat(MicroAppsSettings.defaultResultTextSize)
    var cardWidth: CGFloat = CGFloat(MicroAppPanelLayout.defaultCardWidth)
    let onSubmit: () -> Void
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(model.request.prompt).font(.headline).fixedSize(horizontal: false, vertical: true)
            if case .preview(let text, let style) = model.request {
                SelectableText(text: MicroAppOutputRenderer.render(text, style: style, bodySize: textSize),
                               plainText: text, takesFocus: false,
                               textWidth: CGFloat(MicroAppPanelLayout.textWidth(cardWidth: Double(cardWidth))))
                    .frame(height: 300).accessibilityLabel("Preview")
                Text("Esc cancels the run.").font(.caption)
            } else if model.isChoice {
                TextField("Filter options", text: $model.query)
                    .textFieldStyle(.roundedBorder)
                    .focused($focused)
                    .accessibilityLabel("Filter options")
                if model.showsDetails {
                    HStack(alignment: .top, spacing: 14) {
                        choiceList.frame(width: CGFloat(MicroAppPanelLayout.choiceDetailsListWidth))
                        Rectangle().fill(Color.tingStroke.opacity(0.5)).frame(width: 0.75)
                        ChoiceDetails(text: model.selectedChoice?.value, size: textSize)
                            .frame(maxWidth: .infinity, alignment: .topLeading)
                            .id(model.selectedID)
                    }
                    .frame(height: 300)
                } else {
                    choiceList
                }
            } else if case .ask(_, _, let placeholder, let multiline, _) = model.request {
                if multiline {
                    ZStack(alignment: .topLeading) {
                        TextEditor(text: $model.text)
                            .font(.body)
                            .focused($focused)
                            .accessibilityLabel(model.request.prompt)
                        if model.text.isEmpty {
                            Text(placeholder).foregroundStyle(.secondary).padding(.horizontal, 6).padding(.top, 8)
                                .allowsHitTesting(false).accessibilityHidden(true)
                        }
                    }
                    .frame(height: 180)
                } else {
                    TextField(placeholder, text: $model.text)
                        .textFieldStyle(.roundedBorder)
                        .focused($focused)
                        .accessibilityLabel(model.request.prompt)
                }
            }
            if let error = model.error {
                Text(error).font(.caption).foregroundStyle(.red)
            }
            HStack {
                Spacer()
                Button("Continue", action: onSubmit)
                    .disabled(model.isChoice && model.selectedID == nil)
            }
        }
        .onAppear { focused = true }
    }

    private var choiceList: some View {
        ScrollViewReader { reader in
            ScrollView {
                LazyVStack(spacing: 4) {
                    ForEach(model.filteredChoices) { choice in
                        Button {
                            model.selectedID = choice.id
                            onSubmit()
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(choice.title).lineLimit(2)
                                    if let subtitle = choice.subtitle {
                                        Text(subtitle).font(.caption).foregroundStyle(Color.tingMuted).lineLimit(2)
                                    }
                                }
                                Spacer()
                                if model.selectedID == choice.id {
                                    Image(systemName: "checkmark").foregroundStyle(Color.tingAmber)
                                }
                            }
                            .padding(8)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                            .background(model.selectedID == choice.id ? Color.tingAmber.opacity(0.15) : .clear,
                                        in: RoundedRectangle(cornerRadius: 6))
                        }
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(model.selectedID == choice.id ? .isSelected : [])
                        .id(choice.id)
                    }
                    if model.filteredChoices.isEmpty {
                        Text("No matching options").foregroundStyle(Color.tingMuted).padding(8)
                    }
                }
            }
            .frame(height: min(300, max(70, CGFloat(model.filteredChoices.count) * 54)))
            .onChange(of: model.selectedID) { _, id in
                if let id { reader.scrollTo(id) }
            }
        }
    }
}

/// The selected option's value beside the list, like Clipbawd's preview.
private struct ChoiceDetails: View {
    let text: String?
    let size: CGFloat

    var body: some View {
        if let text, !text.isEmpty {
            ScrollView(.vertical) {
                Text(text)
                    .font(.system(size: CGFloat(MicroAppPanelLayout.monoSize(forBodySize: Double(size))), design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 8)
            }
            .accessibilityLabel("Preview")
        } else {
            Text("No preview").font(.caption).foregroundStyle(Color.tingMuted).padding(.top, 8)
        }
    }
}

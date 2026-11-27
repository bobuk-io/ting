// The micro-app panels in the launcha style: graphite card, amber top rule, mono footer.
// The result text is drawn by `MicroAppOutputRenderer` in the style of `output.as`.
import AppKit
import SwiftUI
import TingCore
import BobukUI

struct MicroAppFlowView: View {
    let session: MicroAppFlowSession
    let onApprove: () -> Void
    var onSubmitAnswer: () -> Void = {}
    let onCopyAll: () -> Void
    let onDismiss: () -> Void
    /// A click on a link of the output; the controller decides whether the link warning shows first.
    var onLink: (URL) -> Void = { _ in }
    var onConfirmLink: () -> Void = {}
    var onCancelLink: () -> Void = {}

    var body: some View {
        ZStack(alignment: .top) {
            // A click beside the card works like Esc.
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture(perform: onDismiss)
            switch session.state {
            case .closed:
                EmptyView()
            case .approval(let app, let file):
                Card(title: app.shownName, showHeader: session.showHeader, footer: ["⌘↩ approve and run", "esc cancel"]) {
                    ApprovalBody(app: app, file: file, onApprove: onApprove)
                }
                .padding(.top, 8)
            case .form:
                if let model = session.form {
                Card(title: model.app.shownName, showHeader: session.showHeader, footer: formFooter(model.form)) {
                    MicroAppFormBody(model: model, maxHeight: session.formMaxHeight)
                }
                .padding(.top, 8)
                }
            case .interaction(let app):
                if let model = session.interaction {
                    let cardWidth = model.isPreview || model.showsDetails
                        ? session.effectiveCardWidth : CGFloat(MicroAppPanelLayout.defaultCardWidth)
                    Card(title: app.shownName, showHeader: session.showHeader, width: cardWidth,
                         footer: model.isChoice ? ["↑↓ choose", "↩ continue", "esc cancel"] :
                            [model.multiline ? "⌘↩ continue" : "↩ continue", "esc cancel"]) {
                        MicroAppInteractionBody(model: model, textSize: session.resultTextSize, cardWidth: cardWidth,
                                                onSubmit: onSubmitAnswer)
                    }
                    .padding(.top, 8)
                }
            case .working(let app):
                Card(title: app.shownName, showHeader: session.showHeader, width: session.effectiveCardWidth,
                     footer: session.pendingLink == nil ? ["esc stop"] : linkWarningFooter) {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 10) {
                            ProgressView().controlSize(.small)
                            Text("Running \(app.shownName)…").font(.system(size: 13))
                            Spacer()
                            if let progress = session.progress, progress.count > 1 {
                                MonoLabel(progress.label, size: 9, tracking: 1).foregroundStyle(Color.tingAmber)
                            }
                        }
                        .padding(.vertical, 4)
                        .accessibilityElement(children: .combine)
                        if let url = session.pendingLink {
                            LinkWarning(url: url, onOpen: onConfirmLink, onCancel: onCancelLink)
                        }
                        if let live = session.progress?.liveOutput, !live.isEmpty {
                            LiveOutput(text: live, style: app.output.style, cardWidth: session.effectiveCardWidth,
                                       textSize: session.resultTextSize, onLink: onLink)
                        }
                    }
                    .padding(.vertical, 8)
                }
                .padding(.top, 8)
            case .result(let content):
                Card(title: content.title, showHeader: session.showHeader, width: session.effectiveCardWidth,
                     footer: session.pendingLink == nil ? ["↩ copy all and close", "⌘C copy", "esc close"] : linkWarningFooter) {
                    VStack(alignment: .leading, spacing: 8) {
                        if let url = session.pendingLink {
                            LinkWarning(url: url, onOpen: onConfirmLink, onCancel: onCancelLink)
                        }
                        ResultBody(content: content, cardWidth: session.effectiveCardWidth,
                                   textSize: session.resultTextSize, onLink: onLink)
                    }
                }
                .padding(.top, 8)
            }
        }
    }
}

private let linkWarningFooter = ["↩ open link", "esc cancel"]

/// Shown on the first click on a link of the output, above the text, until the user opens or cancels.
private struct LinkWarning: View {
    let url: URL
    let onOpen: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Color.tingAmber)
                    .accessibilityHidden(true)
                Text("Open this link?").font(.system(size: 13, weight: .semibold))
            }
            Text(url.isFileURL
                 ? "Links come from the micro-app's output, which can carry text from the web or an AI. Ting shows this file in Finder and never opens it."
                 : "Links come from the micro-app's output, which can carry text from the web or an AI, and may lead to a harmful site. Check where it goes before you open it.")
                .font(.system(size: 12)).foregroundStyle(Color.tingMuted)
                .fixedSize(horizontal: false, vertical: true)
            Text(url.isFileURL ? url.path : url.absoluteString)
                .font(.system(size: 12, design: .monospaced))
                .lineLimit(3).truncationMode(.middle)
                .textSelection(.enabled)
            HStack {
                Text("Ting asks only once.").font(.system(size: 11)).foregroundStyle(Color.tingMuted)
                Spacer()
                Button("Cancel", action: onCancel).controlSize(.small)
                Button("Open Link", action: onOpen).controlSize(.small)
            }
        }
        .padding(10)
        .background(Color.tingAmber.opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.tingAmber.opacity(0.5), lineWidth: 0.75))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("link warning")
    }
}

private func formFooter(_ form: MicroAppForm) -> [String] {
    if form.isSingleChoiceList { return ["↑↓ choose", "↩ run", "esc cancel"] }
    var footer = ["↩ run"]
    if form.visibleIndexes.count > 1 || form.hasOptionalToggle { footer.append("tab next") }
    if form.hasOptionalToggle { footer.append("⌘O options") }
    footer.append("esc cancel")
    return footer
}

private struct Card<Content: View>: View {
    let title: String
    let showHeader: Bool
    var width: CGFloat = CGFloat(MicroAppPanelLayout.defaultCardWidth)
    let footer: [String]
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                if showHeader { TingMark(size: 14) }
                MonoLabel(showHeader ? "Ting  ·  \(title)" : title, size: 10, tracking: 2).foregroundStyle(Color.tingAmber)
                    .lineLimit(1)
                Spacer()
            }
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isHeader)
            content.padding(.top, 12)
            Rectangle().fill(Color.tingAmber.opacity(0.3)).frame(height: 1).padding(.top, 10)
            HStack(spacing: 14) {
                ForEach(footer, id: \.self) { MonoLabel($0, size: 9, weight: .regular, tracking: 1) }
                Spacer()
            }
            .foregroundStyle(Color.tingMuted)
            .padding(.top, 10)
            .accessibilityHidden(true)
        }
        .foregroundStyle(Color.tingInk)
        .padding(.horizontal, 20)
        .padding(.top, 18)
        .padding(.bottom, 16)
        .frame(width: width)
        .background(Color.soundPanel, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(alignment: .top) {
            Rectangle().fill(Color.tingAmber).frame(height: 3)
        }
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.tingStroke.opacity(0.6), lineWidth: 0.75))
        .background {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.soundPanel)
                .shadow(color: .black.opacity(0.35), radius: 24, y: 10)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("micro-app \(title)")
    }
}

private struct ApprovalBody: View {
    let app: MicroApp
    let file: String
    let onApprove: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Run this micro-app?").font(.system(size: 15, weight: .semibold))
            Text("This file is new or changed. Ting runs its command with your full rights. Approve it only if you trust every line.")
                .font(.system(size: 12)).foregroundStyle(Color.tingMuted)
                .fixedSize(horizontal: false, vertical: true)
            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 4) {
                GridRow {
                    MonoLabel("name", size: 9, weight: .regular).foregroundStyle(Color.tingMuted)
                    Text(app.shownName).font(.system(size: 12, weight: .medium))
                }
                GridRow {
                    MonoLabel("file", size: 9, weight: .regular).foregroundStyle(Color.tingMuted)
                    Text(file).font(.system(size: 12, design: .monospaced)).textSelection(.enabled)
                }
                if !app.tools.isEmpty {
                    GridRow {
                        MonoLabel("tools", size: 9, weight: .regular).foregroundStyle(Color.tingMuted)
                        Text(app.tools.joined(separator: ", ")).font(.system(size: 12, design: .monospaced))
                    }
                }
                if !app.requiredContext.isEmpty {
                    GridRow {
                        MonoLabel("reads", size: 9, weight: .regular).foregroundStyle(Color.tingMuted)
                        Text(app.requiredContext.map(\.summary).joined(separator: ", ")).font(.system(size: 12))
                    }
                }
                if app.readsClipboardHistory {
                    GridRow {
                        MonoLabel("reads", size: 9, weight: .regular).foregroundStyle(Color.tingMuted)
                        Text("Clipbawd clipboard history; steps may send it to other services").font(.system(size: 12))
                    }
                }
                if app.sendsInput {
                    GridRow {
                        MonoLabel("sends", size: 9, weight: .regular).foregroundStyle(Color.tingMuted)
                        Text("key presses and text to the app in front").font(.system(size: 12))
                    }
                }
            }
            MonoLabel(app.command == nil ? "file" : "command", size: 9, weight: .regular).foregroundStyle(Color.tingMuted).padding(.top, 4)
            SelectableText(text: app.approvalText, monospaced: true, takesFocus: false)
                .frame(height: commandHeight)
                .background(Color.tingInk.opacity(0.05), in: RoundedRectangle(cornerRadius: 6))
            HStack {
                Spacer()
                Button("Approve and Run", action: onApprove)
                    .keyboardShortcut(.return, modifiers: .command)
                    .controlSize(.small)
            }
        }
    }

    /// Grows with the command, then scrolls.
    private var commandHeight: CGFloat {
        let lines = app.approvalText.split(separator: "\n", omittingEmptySubsequences: false).count
        return min(300, max(44, CGFloat(lines) * 16 + 16))
    }
}

private struct ResultBody: View {
    let content: MicroAppPanelContent
    let cardWidth: CGFloat
    let textSize: CGFloat
    let onLink: (URL) -> Void

    private var textWidth: CGFloat {
        CGFloat(MicroAppPanelLayout.textWidth(cardWidth: Double(cardWidth)))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if content.isError || !content.notes.isEmpty {
                HStack(spacing: 8) {
                    if content.isError {
                        Image(systemName: "xmark.octagon.fill").foregroundStyle(Color.red)
                            .accessibilityLabel("Error")
                    }
                    ForEach(content.notes, id: \.self) { note in
                        MonoLabel(note, size: 9, tracking: 1).foregroundStyle(Color.tingAmber)
                    }
                    Spacer()
                }
            }
            if !content.text.isEmpty {
                let rendered = MicroAppOutputRenderer.render(content, bodySize: textSize)
                SelectableText(text: rendered, plainText: content.plainText, takesFocus: true,
                               textWidth: textWidth, onLink: onLink)
                    .frame(height: height(rendered))
                    .background(Color.tingInk.opacity(0.05), in: RoundedRectangle(cornerRadius: 6))
            }
        }
    }

    /// Grows with the text, then scrolls.
    private func height(_ rendered: NSAttributedString) -> CGFloat {
        let measured: CGFloat
        if rendered.length <= 20_000 {
            measured = ceil(rendered.boundingRect(with: NSSize(width: textWidth, height: .greatestFiniteMagnitude),
                                                  options: [.usesLineFragmentOrigin, .usesFontLeading]).height)
        } else {
            measured = CGFloat(content.text.split(separator: "\n", omittingEmptySubsequences: false).count) * ceil(textSize * 1.35)
        }
        return min(440, max(44, measured + 20))
    }
}

/// The output of the last step while it comes, kept scrolled to its end.
private struct LiveOutput: View {
    let text: String
    let style: MicroApp.OutputStyle
    let cardWidth: CGFloat
    let textSize: CGFloat
    let onLink: (URL) -> Void

    private var textWidth: CGFloat {
        CGFloat(MicroAppPanelLayout.textWidth(cardWidth: Double(cardWidth)))
    }

    var body: some View {
        let rendered = MicroAppOutputRenderer.render(text, style: style, bodySize: textSize)
        SelectableText(text: rendered, plainText: text, takesFocus: false, followsEnd: true,
                       textWidth: textWidth, onLink: onLink)
            .frame(height: height(rendered))
            .background(Color.tingInk.opacity(0.05), in: RoundedRectangle(cornerRadius: 6))
            .accessibilityLabel("output so far")
    }

    /// Grows with the text up to the height of the result panel, then scrolls.
    private func height(_ rendered: NSAttributedString) -> CGFloat {
        let measured: CGFloat
        if rendered.length <= 20_000 {
            measured = ceil(rendered.boundingRect(with: NSSize(width: textWidth, height: .greatestFiniteMagnitude),
                                                  options: [.usesLineFragmentOrigin, .usesFontLeading]).height)
        } else {
            measured = 440
        }
        return min(440, max(44, measured + 20))
    }
}

/// Read-only, selectable, scrolling text: ⌘C copies the selection as plain text (the whole plain
/// text when nothing is selected), ⌘A selects all.
struct SelectableText: NSViewRepresentable {
    let text: NSAttributedString
    let plainText: String
    /// The text view becomes the first responder, so ⌘C and the arrow keys reach it at once.
    let takesFocus: Bool
    /// A new text scrolls to the end, not to the beginning: for output that grows.
    var followsEnd = false
    /// Width used before the scroll view lays out.
    var textWidth: CGFloat = SelectableText.defaultTextWidth
    /// A click on a link; `nil` leaves links dead.
    var onLink: ((URL) -> Void)?

    /// The width the text gets inside the default card: the card minus its padding, the inset and the line padding.
    static let defaultTextWidth: CGFloat = CGFloat(MicroAppPanelLayout.textWidth(cardWidth: MicroAppPanelLayout.defaultCardWidth))

    init(text: NSAttributedString, plainText: String, takesFocus: Bool, followsEnd: Bool = false,
         textWidth: CGFloat = SelectableText.defaultTextWidth, onLink: ((URL) -> Void)? = nil) {
        self.text = text
        self.plainText = plainText
        self.takesFocus = takesFocus
        self.followsEnd = followsEnd
        self.textWidth = textWidth
        self.onLink = onLink
    }

    init(text: String, monospaced: Bool, takesFocus: Bool) {
        self.init(text: MicroAppOutputRenderer.render(text, style: monospaced ? .code : .text), plainText: text,
                  takesFocus: takesFocus)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        let view = PlainCopyTextView(frame: NSRect(x: 0, y: 0, width: textWidth, height: 0))
        view.minSize = .zero
        view.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        view.isVerticallyResizable = true
        view.isHorizontallyResizable = false
        view.autoresizingMask = [.width]
        view.textContainer?.widthTracksTextView = true
        view.isEditable = false
        view.isSelectable = true
        view.isRichText = true
        view.drawsBackground = false
        view.textContainerInset = NSSize(width: 6, height: 8)
        view.isAutomaticLinkDetectionEnabled = false
        // Links keep the colours and underlines the renderer gave them (no blue on every file of a list).
        view.linkTextAttributes = [.cursor: NSCursor.pointingHand]
        scroll.documentView = view
        update(scroll)
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        update(scroll)
    }

    private func update(_ scroll: NSScrollView) {
        guard let view = scroll.documentView as? PlainCopyTextView else { return }
        view.plainText = plainText
        view.onLink = onLink
        if let storage = view.textStorage, !storage.isEqual(to: text) {
            storage.setAttributedString(text)
            if followsEnd { view.scrollToEndOfDocument(nil) } else { view.scrollToBeginningOfDocument(nil) }
        }
        if takesFocus {
            DispatchQueue.main.async {
                if let window = view.window, window.firstResponder !== view { window.makeFirstResponder(view) }
            }
        }
    }
}

/// Copies plain text only, never the styling: the selection as shown, or `plainText` without a selection.
private final class PlainCopyTextView: NSTextView {
    var plainText = ""
    var onLink: ((URL) -> Void)?

    override func copy(_ sender: Any?) {
        let range = selectedRange()
        let text = range.length == 0 ? plainText : (string as NSString).substring(with: range)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    /// A markdown link goes to the flow controller, which shows the link warning or follows it.
    override func clicked(onLink link: Any, at charIndex: Int) {
        guard let url = link as? URL else { return }
        onLink?(url)
    }
}

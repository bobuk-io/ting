import TingRuntime
// One micro-app start: approval panel → context → parameter panel → working state → result (panel,
// clipboard, the app or a mix).
// Only one flow is open at a time; a new start closes the open one and stops its command.
import AppKit
import BobukUI
import SwiftUI
import TingCore

/// The flow window: a `BobukPanel` that takes keyboard focus, like launcha.
/// ↩, ⌘↩, ⌘O and Esc go to the flow; other keys go to the panel's views (the fields, the result text).
/// BobukPanel sends ⌘C/⌘V/⌘X/⌘A/⌘Z to the text by the Latin layout and swallows other ⌘ shortcuts,
/// so ⌘Q never quits Ting.
final class MicroAppFlowPanel: BobukPanel {
    enum Key { case enter, commandEnter, escape, toggleOptional, up, down }
    var onKey: ((Key) -> Void)?
    var multilineInput = false
    var choosing = false

    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 640, height: 600), kind: .launcher)
        // The card draws its own SwiftUI shadow.
        hasShadow = false
        onCommandKey = { [unowned self] event, command in
            guard let key = Self.key(for: command, latin: KeyEquivalent.latin(of: event), flags: event.modifierFlags) else {
                return false
            }
            self.onKey?(key)
            return true
        }
    }

    /// The flow's ⌘ shortcuts: ⌘↩ (also ⌘Enter) confirms, ⌘O shows the optional parameters, matched
    /// by the Latin layout. AppKit sends ⌘ shortcuts here before `sendEvent`, so ⌘↩ is handled here.
    /// nil leaves the key to BobukPanel.
    static func key(for command: EditCommand, latin: String?, flags: NSEvent.ModifierFlags) -> Key? {
        if command == .commandReturn { return .commandEnter }
        if command == .other, latin == "o", flags.intersection([.command, .shift, .option, .control]) == .command {
            return .toggleOptional
        }
        return nil
    }

    override func sendEvent(_ event: NSEvent) {
        // While an input method composes in a field, ↩ and Esc belong to it.
        if event.type == .keyDown, !KeyEquivalent.isComposing(in: self) {
            let flags = event.modifierFlags.intersection([.command, .shift, .option, .control])
            switch event.keyCode {
            case VirtualKey.escape:
                onKey?(.escape)
                return
            case VirtualKey.down, VirtualKey.up:
                if choosing && flags.isEmpty {
                    onKey?(event.keyCode == VirtualKey.down ? .down : .up)
                    return
                }
            case VirtualKey.returnKey, VirtualKey.keypadEnter:
                if flags.isEmpty && multilineInput { super.sendEvent(event); return }
                if flags.isEmpty { onKey?(.enter); return }
                if flags == .command { onKey?(.commandEnter); return }
                return
            default:
                break
            }
        }
        super.sendEvent(event)
    }
}

/// What the flow panel shows now.
@MainActor
@Observable
final class MicroAppFlowSession {
    enum State: Equatable {
        case closed
        case approval(MicroApp, file: String)
        case form(MicroApp)
        case working(MicroApp)
        case interaction(MicroApp)
        case result(MicroAppPanelContent)
    }

    var state: State = .closed {
        didSet {
            if case .form = state {} else { form = nil }
            if case .working = state {} else { progress = nil }
            pendingLink = nil
        }
    }
    /// A clicked link waiting for the user to read the link warning; cleared by every state change.
    var pendingLink: URL?
    /// The running step and the live output of the last step; set only while `state` is `.working`.
    var progress: MicroAppRunProgress?
    /// The open parameter panel; set only while `state` is `.form`.
    var form: MicroAppFormModel?
    var interaction: MicroAppInteractionModel?
    var showHeader = true
    /// Configured card width for the result panel (and live output / preview), in points.
    var resultCardWidth = CGFloat(MicroAppsSettings.defaultResultWidth)
    /// Card width clamped to the current screen, in points.
    var effectiveCardWidth = CGFloat(MicroAppsSettings.defaultResultWidth)
    /// Configured body text size for the result panel (and live output / preview), in points.
    var resultTextSize = CGFloat(MicroAppsSettings.defaultResultTextSize)
    /// The highest parameter form height in the current panel; beyond it the form scrolls.
    var formMaxHeight = CGFloat(MicroAppFormLayout.maxFormHeight(panelHeight: MicroAppFormLayout.panelCap))
}

@MainActor
final class MicroAppFlowController: NSObject {
    let session = MicroAppFlowSession()
    /// Shows a short message (the 'Copied' toast, errors that fit two lines).
    var onToast: ((String) -> Void)?
    /// A micro-app needs Accessibility and Ting does not have it: show the Accessibility window.
    var onAccessibilityNeeded: (() -> Void)?
    /// The micro-apps folder as the user sees it, for the 'not found' error.
    var folderDisplay: () -> String = { "the micro-apps folder" }

    private(set) var catalog = MicroAppCatalog()
    private let approvals: MicroAppApprovalStore
    private let values: MicroAppValueStore
    /// Whether the warning of the first link click was read.
    private let linkNotice: MicroAppLinkNoticeStore
    /// Follows a link of a result: opens it, or shows it in Finder.
    private let linkOpener: @MainActor (URL) -> Void
    /// Read only after approval, once per run, never into persisted parameter values.
    var clipboardSnapshot: (() -> [String?]?)?
    private var runner: MicroAppRunner
    /// The clipboard: stdin of `input: clipboard` and the `clipboard` target.
    private let pasteboard: NSPasteboard
    /// Reads the `context` of a micro-app.
    private let contextReader: MicroAppContextReading
    /// Sends `keys`, `paste` and the `app` output to the app where the micro-app started.
    private let keyboard: MicroAppKeyboardSending
    /// The app in front, read at each start.
    private let frontmost: @MainActor () -> MicroAppTarget?
    /// The app that was in front when the open flow started.
    private var target: MicroAppTarget?
    /// The context of the open flow, read before its parameter panel.
    private var context = MicroAppContext()
    /// The generation of the run that asked for Accessibility: its failure shows no panel.
    private var accessibilityAsked: Int?
    /// `false` builds the panel with its real views and key handling but never puts it on screen
    /// or gives it keyboard focus. For tests, so the user's screen and typing are not touched.
    private let presentsWindow: Bool
    private var panel: MicroAppFlowPanel?
    private var task: Task<Void, Never>?
    private var answerContinuation: CheckedContinuation<String, Error>?
    private var questionID: UUID?
    /// Bumped by every start and close, so a late result of a stopped flow is dropped.
    private var generation = 0
    /// The hash waiting for ⌘↩ in the approval panel.
    private var pendingHash = ""

    init(approvals: MicroAppApprovalStore? = nil, values: MicroAppValueStore? = nil, runner: MicroAppRunner = MicroAppRunner(),
         pasteboard: NSPasteboard = .general, presentsWindow: Bool = true, contextReader: MicroAppContextReading? = nil,
         keyboard: MicroAppKeyboardSending? = nil, frontmost: (@MainActor () -> MicroAppTarget?)? = nil,
         linkNotice: MicroAppLinkNoticeStore? = nil, linkOpener: (@MainActor (URL) -> Void)? = nil) {
        self.approvals = approvals ?? MicroAppApprovalStore()
        self.values = values ?? MicroAppValueStore()
        self.linkNotice = linkNotice ?? MicroAppLinkNoticeStore()
        self.linkOpener = linkOpener ?? MicroAppFlowController.follow
        self.runner = runner
        self.pasteboard = pasteboard
        self.presentsWindow = presentsWindow
        let real = MicroAppKeyboard(pasteboard: pasteboard)
        self.keyboard = keyboard ?? real
        self.contextReader = contextReader ?? MicroAppContextReader(copySelection: { await real.copySelection(from: $0) })
        self.frontmost = frontmost ?? { MicroAppTarget.frontmost() }
    }

    var isOpen: Bool { session.state != .closed }
    /// The flow panel, once a step has shown it.
    var flowPanel: MicroAppFlowPanel? { panel }

    func setCatalog(_ catalog: MicroAppCatalog) {
        self.catalog = catalog
    }

    func configure(_ config: Config) {
        runner.chattaDefaults = config.chatta
        session.showHeader = config.showPanelHeader
        session.resultCardWidth = CGFloat(config.microApps.resultWidth)
        session.resultTextSize = CGFloat(config.microApps.resultTextSize)
        if let panel, isOpen {
            applyPanelWidth(for: session.state, panel: panel)
        } else {
            session.effectiveCardWidth = session.resultCardWidth
        }
    }

    /// Starts the micro-app bound as `id`. A missing or broken micro-app shows its error and starts nothing.
    func start(id: String) {
        close()
        target = frontmost()
        approvals.load()
        begin(MicroAppStartStep.first(id: id, catalog: catalog, approvals: approvals.approvals, folder: folderDisplay()),
              title: id)
    }

    /// Starts the file `file` of the folder, as launcha starts a broken file: shows that file's
    /// own errors, or goes through the normal start when the file works by now.
    func start(file: String) {
        close()
        target = frontmost()
        approvals.load()
        begin(MicroAppStartStep.first(file: file, catalog: catalog, approvals: approvals.approvals, folder: folderDisplay()),
              title: file)
    }

    private func begin(_ step: MicroAppStartStep, title: String) {
        switch step {
        case .error(let message):
            present(MicroAppResultPlan.error(title: title, message: message))
        case .approve(let app, let hash):
            pendingHash = hash
            let file = catalog.resolve(app.id).entryFile ?? "\(app.id).yaml"
            show(.approval(app, file: (folderDisplay() as NSString).appendingPathComponent(file)))
        case .run(let app):
            prepare(app)
        }
    }

    /// Closes any panel and stops a running command, silently. The clipboard stays as it was.
    func close() {
        generation += 1
        task?.cancel()
        answerContinuation?.resume(throwing: CancellationError())
        answerContinuation = nil
        questionID = nil
        session.interaction = nil
        task = nil
        pendingHash = ""
        session.state = .closed
        panel?.orderOut(nil)
    }

    // MARK: Steps

    private func approve() {
        guard case .approval(let app, _) = session.state else { return }
        do {
            try approvals.approve(id: app.id, hash: pendingHash)
        } catch {
            onToast?("Cannot save the approval: \(error.localizedDescription)")
        }
        prepare(app)
    }

    /// Reads the context the micro-app lists, then asks its parameters. The context is of the
    /// app in front: an open approval panel is hidden first.
    private func prepare(_ app: MicroApp) {
        pendingHash = ""
        context = MicroAppContext()
        let sources = app.requiredContext
        guard !sources.isEmpty else { return askParameters(app) }
        if panel?.isVisible == true {
            // The state first: hiding the panel resigns its key status.
            session.state = .closed
            panel?.orderOut(nil)
        }
        generation += 1
        let current = generation
        let reader = contextReader
        let target = self.target
        task = Task { [weak self] in
            let result: Result<MicroAppContext, Error>
            do { result = .success(try await reader.read(sources, target: target)) } catch { result = .failure(error) }
            guard let self, self.generation == current, !Task.isCancelled else { return }
            self.task = nil
            switch result {
            case .success(let context):
                self.context = context
                self.askParameters(app)
            case .failure(let error) where error.needsAccessibility:
                self.close()
                self.onAccessibilityNeeded?()
            case .failure(let error):
                self.present(MicroAppResultPlan.error(title: app.shownName, message: error.localizedDescription))
            }
        }
    }

    /// The parameter panel, the same for every start way. A micro-app without parameters runs at once.
    private func askParameters(_ app: MicroApp) {
        pendingHash = ""
        values.load()
        let form = MicroAppForm.start(app, remembered: values.remembered)
        guard !form.isEmpty else { return run(app, values: [:]) }
        session.form = MicroAppFormModel(app: app, form: form)
        show(.form(app))
    }

    /// ↩ in the parameter panel: runs with the shown values and remembers them, or marks the empty
    /// required field and runs nothing.
    private func submitForm() {
        guard let model = session.form, case .form = session.state, let shown = model.submit() else { return }
        do {
            try values.remember(shown, for: model.app)
        } catch {
            onToast?("Cannot save the values: \(error.localizedDescription)")
        }
        run(model.app, values: shown)
    }

    private func run(_ app: MicroApp, values: [String: String]) {
        generation += 1
        let current = generation
        pendingHash = ""
        show(.working(app))
        let stdin = app.input == .clipboard ? (pasteboard.string(forType: .string) ?? "") : nil
        var runner = self.runner
        if app.readsClipboardHistory {
            runner.clipboardHistory = clipboardSnapshot?()
        }
        let target = self.target
        let context = self.context
        runner.interact = { [weak self] request in
            guard let self else { throw CancellationError() }
            return try await self.requestAnswer(request, app: app, generation: current)
        }
        runner.keyboard = { [weak self] action in
            guard let self else { throw CancellationError() }
            try await self.deliver(action, to: target, generation: current)
        }
        let progress: @Sendable (MicroAppRunProgress) -> Void = { [weak self] progress in
            // The main queue keeps the order of the updates.
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, self.generation == current, case .working = self.session.state else { return }
                    self.session.progress = progress
                }
            }
        }
        task = Task { [weak self] in
            let result = await runner.run(app, values: values, stdin: stdin, context: context, progress: progress)
            guard let self, self.generation == current, !Task.isCancelled else { return }
            self.task = nil
            // A `keys` or `paste` step without Accessibility: the Accessibility window says what to do.
            if self.accessibilityAsked == current, case .stepFailed = result {
                self.close()
                return
            }
            self.present(MicroAppResultPlan.make(app: app, result: result, outputLimit: runner.outputLimit,
                                                 timeLimit: runner.timeLimit(for: app)), title: app.shownName)
        }
    }

    private func requestAnswer(_ request: MicroAppInteraction, app: MicroApp, generation current: Int) async throws -> String {
        let id = UUID()
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            guard generation == current else { throw CancellationError() }
            return try await withCheckedThrowingContinuation { continuation in
                answerContinuation = continuation
                questionID = id
                session.interaction = MicroAppInteractionModel(request)
                show(.interaction(app))
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                guard let self, self.questionID == id else { return }
                self.answerContinuation?.resume(throwing: CancellationError())
                self.answerContinuation = nil
                self.questionID = nil
                self.session.interaction = nil
            }
        }
    }

    func submitAnswer() {
        guard case .interaction(let app) = session.state,
              let answer = session.interaction?.answer(), let continuation = answerContinuation else { return }
        answerContinuation = nil
        questionID = nil
        session.interaction = nil
        show(.working(app))
        continuation.resume(returning: answer)
    }

    /// A `keys` or `paste` step: the panel goes away until the result, so the keys reach the app.
    private func deliver(_ action: MicroAppKeyboardAction, to target: MicroAppTarget?, generation current: Int) async throws {
        guard generation == current else { throw CancellationError() }
        panel?.orderOut(nil)
        do {
            try await keyboard.send(action, to: target)
        } catch where error.needsAccessibility {
            if generation == current {
                accessibilityAsked = current
                onAccessibilityNeeded?()
            }
            throw error
        }
    }

    private func present(_ plan: MicroAppResultPlan, title: String = "Ting") {
        if let text = plan.clipboard {
            pasteboard.clearContents()
            pasteboard.setString(text, forType: .string)
        }
        if let text = plan.app {
            return paste(text, keepOnClipboard: plan.clipboard != nil, plan: plan, title: title)
        }
        switch plan.show {
        case .nothing:
            close()
        case .toast(let message):
            close()
            onToast?(message)
        case .panel(let content):
            show(.result(content))
        }
    }

    /// The `app` output: the panel closes and the result goes into the app. When that fails, the
    /// result stays on the clipboard and the error says so.
    private func paste(_ text: String, keepOnClipboard: Bool, plan: MicroAppResultPlan, title: String) {
        let target = self.target
        close()
        let keyboard = self.keyboard
        let current = generation
        Task { [weak self] in
            do {
                try await keyboard.send(.paste(text, keepOnClipboard: keepOnClipboard), to: target)
                guard let self, self.generation == current, case .toast(let message) = plan.show else { return }
                self.onToast?(message)
            } catch {
                guard let self, self.generation == current else { return }
                if !keepOnClipboard {
                    self.pasteboard.clearContents()
                    self.pasteboard.setString(text, forType: .string)
                }
                if error.needsAccessibility {
                    self.onAccessibilityNeeded?()
                    self.onToast?("Not pasted. The result is on the clipboard.")
                    return
                }
                self.present(MicroAppResultPlan.error(title: title, message: "\(error.localizedDescription) The result is on the clipboard."))
            }
        }
    }

    /// A key of the panel: ⌘↩, ↩, ⌘O or Esc.
    func handle(_ key: MicroAppFlowPanel.Key) {
        switch (session.state, key) {
        case (.approval, .commandEnter):
            approve()
        case (.form, .enter):
            submitForm()
        case (.interaction, .enter), (.interaction, .commandEnter):
            submitAnswer()
        case (.interaction, .up):
            session.interaction?.move(-1)
        case (.interaction, .down):
            session.interaction?.move(1)
        case (.form, .toggleOptional):
            session.form?.toggleOptional()
        case (_, .enter) where session.pendingLink != nil:
            confirmLink()
        case (_, .escape) where session.pendingLink != nil:
            cancelLink()
        case (.result(let content), .enter):
            copyAll(content)
            close()
        case (_, .escape):
            close()
        default:
            // ↩ in the approval panel does nothing: only ⌘↩ approves.
            break
        }
    }

    // MARK: Links

    /// A click on a link of the output. The first click ever shows the link warning instead.
    func clickLink(_ url: URL) {
        switch session.state {
        case .working, .result: break
        default: return
        }
        if linkNotice.seen {
            linkOpener(url)
        } else {
            session.pendingLink = url
        }
    }

    /// Open Link in the warning: remembered, so the warning never shows again, and the link is followed.
    func confirmLink() {
        guard let url = session.pendingLink else { return }
        session.pendingLink = nil
        if !linkNotice.markSeen(), let error = linkNotice.error { onToast?(error) }
        linkOpener(url)
    }

    /// Cancel in the warning: the link is not followed, and the warning shows on the next click.
    func cancelLink() {
        session.pendingLink = nil
    }

    /// Web and mail links open; a folder opens in Finder; any other file is shown selected in Finder.
    private static func follow(_ url: URL) {
        let workspace = NSWorkspace.shared
        let action = MarkdownLinkAction.of(url) { url in
            var isDirectory: ObjCBool = false
            return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue
                && !workspace.isFilePackage(atPath: url.path)
        }
        switch action {
        case .open(let url):
            workspace.open(url)
        case .showFolder(let url):
            workspace.selectFile(nil, inFileViewerRootedAtPath: url.path)
        case .revealFile(let url):
            guard FileManager.default.fileExists(atPath: url.path) else { NSSound.beep(); return }
            workspace.activateFileViewerSelecting([url])
        }
    }

    private func copyAll(_ content: MicroAppPanelContent) {
        pasteboard.clearContents()
        // The plain result: console text (and every error) without its escape codes.
        pasteboard.setString(content.plainText, forType: .string)
    }

    // MARK: Panel

    private func usesResultWidth(for state: MicroAppFlowSession.State) -> Bool {
        switch state {
        case .result, .working: true
        case .interaction: session.interaction?.isPreview ?? false
        case .closed, .approval, .form: false
        }
    }

    private func desiredCardWidth(for state: MicroAppFlowSession.State) -> Double {
        if case .interaction = state, session.interaction?.showsDetails == true {
            return max(MicroAppPanelLayout.choiceDetailsCardWidth, Double(session.resultCardWidth))
        }
        return usesResultWidth(for: state) ? Double(session.resultCardWidth) : MicroAppPanelLayout.defaultCardWidth
    }

    private func applyPanelWidth(for state: MicroAppFlowSession.State, panel: MicroAppFlowPanel) {
        let requested = desiredCardWidth(for: state)
        let visible = presentsWindow ? (panel.screen?.visibleFrame ?? Screens.underPointer?.visibleFrame) : nil
        let width = CGFloat(MicroAppPanelLayout.panelWidth(cardWidth: requested, visibleWidth: visible.map { Double($0.width) }))
        session.effectiveCardWidth = CGFloat(MicroAppPanelLayout.effectiveCardWidth(cardWidth: requested, visibleWidth: visible.map { Double($0.width) }))
        var frame = panel.frame
        guard abs(frame.width - width) > 0.5 else { return }
        let centerX = visible?.midX ?? frame.midX
        frame.origin.x = centerX - width / 2
        frame.size.width = width
        panel.setFrame(frame, display: panel.isVisible)
    }

    private func show(_ state: MicroAppFlowSession.State) {
        let panel = self.panel ?? makePanel()
        panel.multilineInput = false
        panel.choosing = false
        if case .interaction = state {
            panel.multilineInput = session.interaction?.multiline ?? false
            panel.choosing = session.interaction?.isChoice ?? false
        }
        guard presentsWindow else {
            applyPanelWidth(for: state, panel: panel)
            session.state = state
            return
        }
        let requested = desiredCardWidth(for: state)
        if !panel.isVisible {
            if let visible = Screens.underPointer?.visibleFrame {
                // Near the upper third, like launcha.
                let top = PanelPlacement.top(in: visible, anchor: .upper())
                let height = max(240, min(CGFloat(MicroAppFormLayout.panelCap), top - visible.minY - 20))
                let width = CGFloat(MicroAppPanelLayout.panelWidth(cardWidth: requested, visibleWidth: Double(visible.width)))
                session.effectiveCardWidth = CGFloat(MicroAppPanelLayout.effectiveCardWidth(cardWidth: requested, visibleWidth: Double(visible.width)))
                panel.setFrame(NSRect(x: visible.midX - width / 2, y: top - height, width: width, height: height), display: false)
            } else {
                applyPanelWidth(for: state, panel: panel)
            }
        } else {
            applyPanelWidth(for: state, panel: panel)
        }
        session.formMaxHeight = CGFloat(MicroAppFormLayout.maxFormHeight(panelHeight: Double(panel.frame.height)))
        session.state = state
        panel.makeKeyAndOrderFront(nil)
        panel.orderFrontRegardless()
    }

    private func makePanel() -> MicroAppFlowPanel {
        let panel = MicroAppFlowPanel()
        panel.bindTheme(.ting)
        panel.onDismiss = { [weak self] reason in self?.dismiss(reason) }
        panel.onKey = { [weak self] key in self?.handle(key) }
        let view = MicroAppFlowView(session: session,
                                    onApprove: { [weak self] in self?.approve() },
                                    onSubmitAnswer: { [weak self] in self?.submitAnswer() },
                                    onCopyAll: { [weak self] in
                                        guard let self, case .result(let content) = self.session.state else { return }
                                        self.copyAll(content)
                                        self.close()
                                    },
                                    onDismiss: { [weak self] in self?.close() },
                                    onLink: { [weak self] url in self?.clickLink(url) },
                                    onConfirmLink: { [weak self] in self?.confirmLink() },
                                    onCancelLink: { [weak self] in self?.cancelLink() })
        let hosting = NSHostingView(rootView: view)
        hosting.sizingOptions = []
        panel.contentView = hosting
        self.panel = panel
        return panel
    }

    /// A click elsewhere closes the approval (refused) and the result panel. A running command
    /// keeps running; its result comes back to the front. Esc and ⌘W act as Esc in the flow.
    func dismiss(_ reason: BobukPanel.DismissReason) {
        guard reason == .resignedKey else { return handle(.escape) }
        switch session.state {
        case .approval, .form, .interaction, .result: close()
        case .working, .closed: break
        }
    }
}

private extension MicroAppResolution {
    var entryFile: String? {
        switch self {
        case .working(_, let entry), .broken(let entry): entry.file
        case .missing: nil
        }
    }
}

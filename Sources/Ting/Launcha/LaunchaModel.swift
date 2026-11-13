// State and logic of the launcha panel: name search over the app index, a Spotlight file
// search only when no app matches, protected-folder consent and launch history.
// No AppKit windows here, so it can be tested without a panel.
import Foundation
import Observation
import TingCore

/// One line in the launcha list.
struct LaunchaRow: Identifiable, Equatable {
    enum Kind: Equatable {
        /// An indexed app. `candidateID` is the launch-history identity.
        case app(candidateID: String)
        case file
    }

    var id: String
    var kind: Kind
    var name: String
    /// The retained app bundle URL, or the file URL.
    var url: URL
    /// Secondary text: the folder of a file, with `~` for the home folder.
    var detail: String

    var isApp: Bool {
        if case .app = kind { return true }
        return false
    }
}

@MainActor
@Observable
final class LaunchaModel {
    struct Services {
        var index: LaunchaAppIndex
        var spotlight: LaunchaSpotlight
    }
    typealias ServiceFactory = @MainActor (ProtectedFolderPolicy) -> Services

    enum Message: Equatable {
        case info(String)
        case problem(String)

        var text: String {
            switch self {
            case .info(let text), .problem(let text): text
            }
        }
    }

    /// The text in the search field.
    var query = "" {
        didSet { if query != oldValue { queryChanged() } }
    }
    private(set) var rows: [LaunchaRow] = []
    private(set) var selection = 0
    private(set) var spotlight = LaunchaSpotlight.State()
    private(set) var indexIssues: [LaunchaServiceIssue] = []
    private(set) var isIndexing = false
    private(set) var hasIndex = false
    private(set) var isOpen = false
    private(set) var protectedFolders: ProtectedFolderPolicy
    /// The explanation of protected-folder access is shown.
    var isExplainingConsent = false
    private(set) var consentError: String?
    private(set) var historyIssue: String?
    /// Bumped on every open.
    private(set) var generation = 0

    /// Asks the owner to hide the panel. The owner then calls `close()`.
    @ObservationIgnored var onRequestClose: (() -> Void)?
    /// Called just before an app or file opens (not for a reveal in Finder).
    @ObservationIgnored var onWillOpen: (() -> Void)?

    @ObservationIgnored private let makeServices: ServiceFactory
    @ObservationIgnored private var services: Services
    @ObservationIgnored private let opener: LaunchaOpening
    @ObservationIgnored let historyStore: LaunchaHistoryStore
    @ObservationIgnored private let consent: LaunchaConsentStore
    @ObservationIgnored private let home: URL
    @ObservationIgnored private let refreshInterval: Duration
    @ObservationIgnored private var apps: [IndexedLaunchaApp] = []
    @ObservationIgnored private var history = LaunchHistory()
    @ObservationIgnored private var spotlightQuery: String?
    @ObservationIgnored private var scanSerial = 0
    @ObservationIgnored private var appliedScan = 0
    @ObservationIgnored private var historySerial = 0
    @ObservationIgnored private var appliedHistory = 0
    @ObservationIgnored private var refreshLoop: Task<Void, Never>?

    init(opener: LaunchaOpening, historyStore: LaunchaHistoryStore, consent: LaunchaConsentStore,
         home: URL = FileManager.default.homeDirectoryForCurrentUser,
         refreshInterval: Duration = .seconds(15),
         makeServices: ServiceFactory? = nil) {
        self.opener = opener
        self.historyStore = historyStore
        self.consent = consent
        self.home = home
        self.refreshInterval = refreshInterval
        let factory = makeServices ?? { policy in
            Services(index: LaunchaAppIndex(home: home, protectedFolders: policy),
                     spotlight: LaunchaSpotlight(home: home, protectedFolders: policy))
        }
        self.makeServices = factory
        protectedFolders = consent.policy
        consentError = consent.error
        services = factory(consent.policy)
        wireSpotlight()
    }

    // MARK: Session

    /// Scans the apps in the background before the first open, so the list is ready.
    func prewarm() {
        startScan(onOpen: true)
        loadHistory()
    }

    func open() {
        guard !isOpen else { return }
        isOpen = true
        generation += 1
        isExplainingConsent = false
        query = ""
        selection = 0
        recompute(keepSelection: false)
        loadHistory()
        startScan(onOpen: true)
        let interval = refreshInterval
        let token = generation
        refreshLoop?.cancel()
        refreshLoop = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: interval) } catch { return }
                guard let self, self.isOpen, self.generation == token else { return }
                self.startScan(onOpen: false)
            }
        }
    }

    /// Ends the session: stops Spotlight and the refresh loop. Late results are ignored.
    func close() {
        guard isOpen else { return }
        isOpen = false
        generation += 1
        refreshLoop?.cancel()
        refreshLoop = nil
        stopSpotlight()
        isExplainingConsent = false
        query = ""
        rows = []
        selection = 0
    }

    // MARK: Selection and actions

    var selectedRow: LaunchaRow? { rows.indices.contains(selection) ? rows[selection] : nil }

    func moveSelection(by delta: Int) {
        guard !rows.isEmpty else { return }
        selection = min(max(selection + delta, 0), rows.count - 1)
    }

    func select(_ id: LaunchaRow.ID) {
        if let index = rows.firstIndex(where: { $0.id == id }) { selection = index }
    }

    /// Opens the selected row, or reveals it in Finder. The panel closes first.
    /// Only a successful app open or activation is counted, once.
    @discardableResult
    func activateSelection(reveal: Bool = false) async -> LaunchOutcome? {
        guard isOpen, let row = selectedRow else { return nil }
        onRequestClose?()
        close()
        if reveal { return opener.reveal(row.url) }
        onWillOpen?()
        switch row.kind {
        case .app(let candidateID):
            let outcome = await opener.openApp(at: row.url, name: row.name)
            await record(outcome, id: candidateID)
            return outcome
        case .file:
            return await opener.openFile(row.url, name: row.name)
        }
    }

    /// Records a launch through selecta or launcha. Failed opens and reveals are not counted.
    func record(_ outcome: LaunchOutcome, id: String) async {
        guard outcome.counts else { return }
        historySerial += 1
        let serial = historySerial
        let snapshot = await historyStore.record(outcome, id: id)
        applyHistory(snapshot, serial: serial)
    }

    // MARK: Protected folders

    /// The user read the explanation and allowed Desktop, Documents and Downloads.
    func allowProtectedFolders() {
        setProtectedFolders(.allowed)
    }

    func revokeProtectedFolders() {
        setProtectedFolders(.needsConsent)
    }

    private func setProtectedFolders(_ policy: ProtectedFolderPolicy) {
        isExplainingConsent = false
        guard consent.set(policy) else {
            consentError = consent.error
            return
        }
        consentError = nil
        guard policy != protectedFolders else { return }
        protectedFolders = policy
        stopSpotlight()
        services.spotlight.onChange = nil
        services = makeServices(policy)
        wireSpotlight()
        if policy == .needsConsent {
            // Drop apps found in folders that are no longer allowed.
            let gate = LaunchaPathPolicy(home: home, protectedFolders: .needsConsent)
            apps.removeAll { gate.needsConsent($0.url) }
        }
        // Results of the old index must not land after this.
        appliedScan = scanSerial
        if isOpen { recompute(keepSelection: true) }
        startScan(onOpen: true)
    }

    // MARK: Messages

    /// Why the list is empty, or nil when it has rows.
    var statusMessage: Message? {
        guard rows.isEmpty else { return nil }
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if !hasIndex { return .info("Indexing apps…") }
        guard spotlightQuery != nil else {
            return .info(trimmed.isEmpty ? "No apps found." : "No apps match “\(trimmed)”.")
        }
        switch spotlight.status {
        case .idle, .searching: return .info("No apps match. Searching files…")
        case .results, .empty: return .info("No apps or files match “\(trimmed)”.")
        case .error(let message): return .problem("File search failed: \(message)")
        }
    }

    /// Set when a search skipped something other than protected folders.
    var incompleteMessage: String? {
        if spotlightQuery != nil, let issue = spotlight.issues.first(where: { $0.kind != .needsConsent }) {
            return issue.kind == .limit ? "Search incomplete: \(issue.message)"
                : "Search incomplete: some files could not be checked (\(issue.message))."
        }
        if let issue = indexIssues.first(where: { $0.kind != .needsConsent }) {
            return "App list may be incomplete: \(issue.message)"
        }
        return nil
    }

    /// Protected folders were skipped for this query. Never shown as a complete search.
    var showsConsentNotice: Bool {
        protectedFolders == .needsConsent && !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    // MARK: Private

    private func queryChanged() {
        guard isOpen else { return }
        isExplainingConsent = false
        recompute(keepSelection: false)
    }

    private func wireSpotlight() {
        services.spotlight.onChange = { [weak self] state in
            guard let self, self.isOpen, self.spotlightQuery != nil else { return }
            self.spotlight = state
            self.recompute(keepSelection: true)
        }
    }

    private func stopSpotlight() {
        spotlightQuery = nil
        services.spotlight.cancel()
        spotlight = LaunchaSpotlight.State()
    }

    /// Rebuilds the rows for the current query. Starts Spotlight only when a non-empty
    /// query matches no app, and cancels it as soon as an app matches.
    private func recompute(keepSelection: Bool) {
        guard isOpen else { return }
        let previous = keepSelection ? selectedRow?.id : nil
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let byID = Dictionary(apps.map { ($0.candidate.id, $0) }, uniquingKeysWith: { first, _ in first })
        let matches = LaunchaSearch.results(for: trimmed, in: apps.map(\.candidate), history: history, now: Date())
        let appRows = matches.compactMap { match -> LaunchaRow? in
            guard let app = byID[match.candidate.id] else { return nil }
            return LaunchaRow(id: match.candidate.id, kind: .app(candidateID: match.candidate.id),
                              name: match.candidate.name, url: app.url, detail: "")
        }
        // A query without letters or digits lists every app, so it never reaches Spotlight
        // unless the index is empty.
        let wantsFiles = !trimmed.isEmpty && hasIndex && appRows.isEmpty
        if wantsFiles {
            if spotlightQuery != trimmed {
                spotlightQuery = trimmed
                spotlight = LaunchaSpotlight.State()
                services.spotlight.search(trimmed)
            }
            rows = spotlight.files.map { file in
                LaunchaRow(id: "file:" + file.url.path, kind: .file, name: file.name, url: file.url,
                           detail: displayFolder(of: file.url))
            }
        } else {
            if spotlightQuery != nil { stopSpotlight() }
            rows = appRows
        }
        if let previous, let index = rows.firstIndex(where: { $0.id == previous }) {
            selection = index
        } else {
            selection = 0
        }
    }

    private func displayFolder(of url: URL) -> String {
        let folder = url.deletingLastPathComponent().path
        let base = home.standardizedFileURL.path
        let real = LaunchaPathPolicy.realURL(home)?.path ?? base
        for prefix in [real, base] where folder == prefix || folder.hasPrefix(prefix + "/") {
            return "~" + folder.dropFirst(prefix.count)
        }
        return folder
    }

    private func startScan(onOpen: Bool) {
        scanSerial += 1
        let serial = scanSerial
        let index = services.index
        isIndexing = true
        Task { [weak self] in
            let snapshot = onOpen ? await index.refreshOnOpen() : await index.refreshIfNeeded()
            self?.applyScan(snapshot, serial: serial, index: index)
        }
    }

    /// Late or replaced scans never overwrite newer data; a closed session is not redrawn.
    private func applyScan(_ snapshot: LaunchaAppIndex.Snapshot, serial: Int, index: LaunchaAppIndex) {
        if serial == scanSerial { isIndexing = false }
        guard serial > appliedScan, index === services.index else { return }
        appliedScan = serial
        apps = snapshot.apps
        indexIssues = snapshot.issues
        hasIndex = true
        recompute(keepSelection: true)
    }

    private func loadHistory() {
        historySerial += 1
        let serial = historySerial
        let store = historyStore
        Task { [weak self] in
            let snapshot = await store.load()
            self?.applyHistory(snapshot, serial: serial)
        }
    }

    private func applyHistory(_ snapshot: LaunchaHistoryStore.Snapshot, serial: Int) {
        guard serial > appliedHistory else { return }
        appliedHistory = serial
        history = snapshot.history
        historyIssue = snapshot.issues.first.map { "Launch history: \($0.message)" }
        recompute(keepSelection: true)
    }
}

// State and logic of the launcha panel: name search over the app index, the value of a
// calculation or a conversion, a Spotlight file search only when no app matches, protected-folder consent and
// launch history.
// No AppKit windows here, so it can be tested without a panel.
import AppKit
import Foundation
import Observation
import TingCore
import BobukUI

/// One line in the launcha list.
struct LaunchaRow: Identifiable, Equatable {
    enum Kind: Equatable {
        /// An indexed app. `candidateID` is the launch-history identity.
        case app(URL)
        case file(URL)
        case clipbawd
        case schedule
        case chatta
        case lowkeySite(URL)
        /// A micro-app or a broken micro-app file. A start goes to the micro-app flow.
        case micro(file: URL, start: LaunchaMicroStart, isWorking: Bool)
        /// The value of the query as a calculation or a conversion. Return copies it; the row
        /// name may show more, such as `4.572 m` for the value `4.572`.
        case calculation(value: String)
    }

    static let calculationID = "calculation"

    var id: String
    var kind: Kind
    var name: String
    /// The retained app bundle URL, the file URL, or the micro-app file URL.
    var url: URL? {
        switch kind {
        case .app(let url), .file(let url), .lowkeySite(let url), .micro(let url, _, _): url
        case .clipbawd, .schedule, .chatta, .calculation: nil
        }
    }
    var isFile: Bool { if case .file = kind { true } else { false } }
    /// Secondary text: the folder of a file, with `~` for the home folder, or the
    /// description of a micro-app, or why a micro-app file does not work.
    var detail: String
    /// The icon of a micro-app; `nil` shows the default one.
    var microIcon: MicroIcon?

    var isApp: Bool {
        if case .app = kind { return true }
        return false
    }

    var isMicro: Bool {
        if case .micro = kind { return true }
        return false
    }

    var isLowkeySite: Bool {
        if case .lowkeySite = kind { return true }
        return false
    }

    var isCalculation: Bool {
        if case .calculation = kind { return true }
        return false
    }

    /// False only for a broken micro-app file.
    var isWorking: Bool {
        if case .micro(_, _, let working) = kind { return working }
        return true
    }
}

/// A searchable source retains everything its row needs after ranking, including the exact bundle or file.
private enum LaunchaEntry {
    case app(IndexedLaunchaApp)
    case micro(LaunchaMicroCandidate)
    case site(LowkeySite)
    case clipbawd
    case schedule
    case chatta

    var candidate: LaunchaCandidate {
        switch self {
        case .app(let app): app.candidate
        case .micro(let micro): micro.candidate
        case .site(let site): site.candidate
        case .clipbawd: LaunchaCandidate(id: "ting:clipbawd", name: "Clipbawd", target: .url("ting:clipbawd"))
        case .schedule: LaunchaCandidate(id: "ting:schedule", name: "My Schedule", target: .url("ting:schedule"),
                                         searchNames: ["calendar", "events", "agenda", "availability", "daily plan", "today"])
        case .chatta: LaunchaCandidate(id: "ting:chatta", name: "Chatta", target: .url("ting:chatta"),
                                       searchNames: ["chat", "agent", "ai"])
        }
    }

    func row(microFolder: URL) -> LaunchaRow {
        let kind: LaunchaRow.Kind
        let detail: String
        switch self {
        case .app(let app):
            kind = .app(app.url)
            detail = ""
        case .micro(let micro):
            kind = .micro(file: microFolder.appendingPathComponent(micro.file), start: micro.start, isWorking: micro.isWorking)
            detail = micro.problem.map { "Not working: \($0)" } ?? micro.description
        case .site(let site):
            kind = .lowkeySite(site.url())
            detail = "lowkey · \(site.alias) · \(site.startURL.host ?? "")"
        case .clipbawd:
            kind = .clipbawd
            detail = "Clipboard history"
        case .schedule:
            kind = .schedule
            detail = "Upcoming events and availability"
        case .chatta:
            kind = .chatta
            detail = "AI agent chat"
        }
        let match = candidate
        var row = LaunchaRow(id: match.id, kind: kind, name: match.name, detail: detail)
        if case .micro(let micro) = self { row.microIcon = micro.icon }
        return row
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
    typealias FolderAccess = @MainActor ([URL]) -> Void

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
    /// Bumped only when `rows` actually changes, so views do not re-map row IDs on every body pass.
    private(set) var rowsVersion = 0
    private(set) var selection = 0
    private(set) var spotlight = LaunchaSpotlight.State()
    private(set) var indexIssues: [LaunchaServiceIssue] = []
    private(set) var isIndexing = false
    private(set) var hasIndex = false
    private(set) var isOpen = false
    private(set) var protectedFolders: ProtectedFolderPolicy
    /// iCloud Drive is searched too: its own opt-in, off by default.
    private(set) var searchesICloudDrive: Bool
    /// The explanation of protected-folder access is shown.
    var isExplainingConsent = false
    private(set) var consentError: String?
    private(set) var historyIssue: String?
    /// Bumped on every open.
    private(set) var generation = 0

    /// Asks the owner to hide the panel. The owner then calls `close()`.
    @ObservationIgnored var onRequestClose: (() -> Void)?
    /// Starts the micro-app flow for a micro-app or a broken file, after the panel closed.
    @ObservationIgnored var onStartMicro: ((LaunchaMicroStart) -> Void)?
    /// Copies the value of a calculation, after the panel closed.
    @ObservationIgnored var onCopyValue: ((String) -> Void)?
    @ObservationIgnored var onOpenClipbawd: (() -> Void)?
    @ObservationIgnored var onOpenSchedule: (() -> Void)?
    @ObservationIgnored var onOpenChatta: (() -> Void)?
    var clipbawdEnabled = false {
        didSet { if clipbawdEnabled != oldValue, isOpen { recompute(keepSelection: true) } }
    }
    var scheduleEnabled = false {
        didSet { if scheduleEnabled != oldValue, isOpen { recompute(keepSelection: true) } }
    }
    var chattaEnabled = false {
        didSet { if chattaEnabled != oldValue, isOpen { recompute(keepSelection: true) } }
    }
    /// A query of digits and an operator shows its value first (`launcha.calculator`).
    var calculator = true {
        didSet { if calculator != oldValue, isOpen { recompute(keepSelection: true) } }
    }
    /// Rank apps also by switching to them outside launcha (`launcha.appSwitching`). Turning it on
    /// starts watching which app comes to the front; turning it off stops and deletes that record.
    var appSwitching = false {
        didSet {
            guard appSwitching != oldValue else { return }
            if appSwitching { startWatchingApps() } else { stopWatchingApps() }
            refreshRunning()
            if isOpen { recompute(keepSelection: true) }
        }
    }
    /// Running apps first, last or anywhere (`launcha.runningApps`); only with `appSwitching`.
    var runningApps: RunningAppsOrder = .any {
        didSet {
            guard runningApps != oldValue else { return }
            refreshRunning()
            if isOpen { recompute(keepSelection: true) }
        }
    }
    /// A conversion such as `5 yd to m` or `now + 2 days` shows its value first (`launcha.converter`).
    var converter = true {
        didSet { if converter != oldValue, isOpen { recompute(keepSelection: true) } }
    }

    @ObservationIgnored private let makeServices: ServiceFactory
    @ObservationIgnored private var services: Services
    @ObservationIgnored private let opener: LaunchaOpening
    @ObservationIgnored let historyStore: LaunchaHistoryStore
    /// Apps brought to the front outside launcha, only while `appSwitching` is on.
    @ObservationIgnored let usageStore: LaunchaHistoryStore
    @ObservationIgnored private var usage = LaunchHistory()
    @ObservationIgnored private var usageSerial = 0
    @ObservationIgnored private var appliedUsage = 0
    @ObservationIgnored private var activationObserver: NSObjectProtocol?
    /// Candidate ids of the running apps; read on open and on every scan.
    @ObservationIgnored private let runningAppIDs: () -> Set<String>
    @ObservationIgnored private var running: Set<String> = []
    @ObservationIgnored private let consent: LaunchaConsentStore
    @ObservationIgnored private let requestFolderAccess: FolderAccess
    @ObservationIgnored private let home: URL
    @ObservationIgnored private let refreshInterval: Duration
    @ObservationIgnored private var apps: [IndexedLaunchaApp] = []
    @ObservationIgnored private var microApps: [LaunchaMicroCandidate] = []
    @ObservationIgnored private var microFolder: URL?
    @ObservationIgnored private var lowkeySites: [LowkeySite] = []
    @ObservationIgnored private let loadLowkeySites: () -> [LowkeySite]
    @ObservationIgnored private var history = LaunchHistory()
    @ObservationIgnored private var spotlightQuery: String?
    /// The user put the selection on a file (⌘↓, arrows): it stays on files while the query changes.
    @ObservationIgnored private var followsFiles = false
    /// The last finished file results, shown narrowed to the current query until Spotlight
    /// answers it, so file rows do not vanish on every keystroke.
    @ObservationIgnored private var pendingFiles: [LaunchaFileResult] = []
    @ObservationIgnored private var scanSerial = 0
    @ObservationIgnored private var appliedScan = 0
    @ObservationIgnored private var historySerial = 0
    @ObservationIgnored private var appliedHistory = 0
    @ObservationIgnored private var refreshLoop: Task<Void, Never>?

    init(opener: LaunchaOpening, historyStore: LaunchaHistoryStore, consent: LaunchaConsentStore,
         usageStore: LaunchaHistoryStore? = nil,
         home: URL = FileManager.default.homeDirectoryForCurrentUser,
         refreshInterval: Duration = .seconds(15),
         lowkeySites: @escaping () -> [LowkeySite] = { [] },
         runningAppIDs: @escaping () -> Set<String> = { [] },
         makeServices: ServiceFactory? = nil,
         requestFolderAccess: @escaping FolderAccess = LaunchaModel.readFolders) {
        self.opener = opener
        self.historyStore = historyStore
        self.usageStore = usageStore ?? LaunchaHistoryStore(
            url: historyStore.url.deletingLastPathComponent().appendingPathComponent("app-usage.json"))
        self.runningAppIDs = runningAppIDs
        self.consent = consent
        self.requestFolderAccess = requestFolderAccess
        self.home = home
        self.refreshInterval = refreshInterval
        self.loadLowkeySites = lowkeySites
        let factory = makeServices ?? { policy in
            Services(index: LaunchaAppIndex(home: home, protectedFolders: policy),
                     spotlight: LaunchaSpotlight(home: home, protectedFolders: policy))
        }
        self.makeServices = factory
        protectedFolders = consent.policy
        searchesICloudDrive = consent.iCloudDrive
        consentError = consent.error
        services = factory(consent.policy)
        wireSpotlight()
        // Also for consent saved by a version that never asked macOS.
        if consent.policy == .allowed { requestProtectedFolderAccess() }
        if consent.iCloudDrive { requestICloudDriveAccess() }
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
        followsFiles = false
        query = ""
        selection = 0
        lowkeySites = loadLowkeySites()
        refreshRunning()
        recompute(keepSelection: false)
        loadHistory()
        startScan(onOpen: true, refreshContext: false)
        let interval = refreshInterval
        let token = generation
        refreshLoop?.cancel()
        refreshLoop = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: interval) } catch { return }
                guard let self, self.isOpen, self.generation == token else { return }
                self.startScan(onOpen: false, refreshContext: true)
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
        services.spotlight.forget()
        isExplainingConsent = false
        followsFiles = false
        query = ""
        if !rows.isEmpty {
            rows = []
            rowsVersion += 1
        }
        selection = 0
    }

    /// The micro-apps to list, with the folder their files are in. Redraws an open list.
    func setMicroApps(_ candidates: [LaunchaMicroCandidate], folder: URL) {
        guard candidates != microApps || folder != microFolder else { return }
        microApps = candidates
        microFolder = folder
        if isOpen { recompute(keepSelection: true) }
    }

    // MARK: Selection and actions

    var selectedRow: LaunchaRow? { rows.indices.contains(selection) ? rows[selection] : nil }

    func moveSelection(by delta: Int) {
        guard !rows.isEmpty else { return }
        selection = PickerSelection.move(selection, by: delta, count: rows.count) ?? 0
        followsFiles = selectedRow?.isFile == true
    }

    private var firstFileIndex: Int? { rows.firstIndex(where: \.isFile) }

    /// ⌘↓ can do something: there is a query, and the first row is not already a file.
    var canJumpToFiles: Bool {
        !rows.isEmpty && firstFileIndex != 0 && !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// ⌘↓: select the first file and keep the selection on files while typing. Without files
    /// yet, it starts the file search; the selection moves to the first file when it arrives.
    func selectFirstFile() {
        guard isOpen, !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        followsFiles = true
        if let index = firstFileIndex {
            selection = index
        } else {
            recompute(keepSelection: true)
        }
    }

    func select(_ id: LaunchaRow.ID) {
        guard let index = rows.firstIndex(where: { $0.id == id }) else { return }
        selection = index
        followsFiles = rows[index].isFile
    }

    /// Opens the selected row, or reveals it in Finder. The panel closes first.
    /// Only a successful app open or activation is counted, once.
    @discardableResult
    func activateSelection(reveal: Bool = false) async -> LaunchOutcome? {
        guard isOpen, let row = selectedRow else { return nil }
        onRequestClose?()
        close()
        let outcome: LaunchOutcome
        switch row.kind {
        case .calculation(let value):
            onCopyValue?(value)
            return nil
        case .clipbawd:
            if !reveal { onOpenClipbawd?() }
            return nil
        case .schedule:
            if !reveal { onOpenSchedule?() }
            return nil
        case .chatta:
            if !reveal { onOpenChatta?() }
            return nil
        case .lowkeySite(let url):
            guard !reveal else { return nil }
            outcome = await opener.openLowkeySite(url, name: row.name)
        case .app(let url):
            if reveal { return opener.reveal(url) }
            outcome = await opener.openApp(at: url, name: row.name)
        case .file(let url):
            if reveal { return opener.reveal(url) }
            return await opener.openFile(url, name: row.name)
        case .micro(let file, let start, let isWorking):
            if reveal { return opener.reveal(file) }
            onStartMicro?(start)
            guard isWorking else { return .failed }
            outcome = .opened
        }
        await record(outcome, id: row.id)
        return outcome
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
        if policy == .allowed { requestProtectedFolderAccess() }
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

    /// Call only after the user read that macOS may ask about iCloud Drive.
    func setICloudDrive(_ allowed: Bool) {
        guard consent.setICloudDrive(allowed) else {
            consentError = consent.error
            return
        }
        consentError = nil
        guard allowed != searchesICloudDrive else { return }
        searchesICloudDrive = allowed
        stopSpotlight()
        services.spotlight.searchesICloudDrive = allowed
        if allowed { requestICloudDriveAccess() }
        if isOpen { recompute(keepSelection: true) }
    }

    /// Like the protected folders, macOS asks about iCloud Drive only when the app reads it.
    private func requestICloudDriveAccess() {
        requestFolderAccess([LaunchaPathPolicy(home: home).iCloudDriveURL])
    }

    /// macOS asks about a protected folder only when the app reads it, and Spotlight drops results
    /// from folders the app cannot read, so read each one: macOS then asks about every folder once.
    private func requestProtectedFolderAccess() {
        requestFolderAccess(LaunchaPathPolicy(home: home).protectedURLs)
    }

    /// Reads the folders one after another off the main thread; each read waits for its prompt.
    nonisolated static func readFolders(_ urls: [URL]) {
        Task.detached(priority: .utility) {
            for url in urls { _ = try? FileManager.default.contentsOfDirectory(atPath: url.path) }
        }
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
        services.spotlight.searchesICloudDrive = searchesICloudDrive
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
        pendingFiles = []
    }

    /// Rebuilds the rows for the current query: apps first, then files from Spotlight
    /// (see `wantsFiles`). Cancels Spotlight as soon as the query no longer wants files.
    private func recompute(keepSelection: Bool) {
        guard isOpen else { return }
        let previous = keepSelection ? selectedRow?.id : nil
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        var entries: [LaunchaEntry] = []
        if clipbawdEnabled { entries.append(.clipbawd) }
        if scheduleEnabled { entries.append(.schedule) }
        if chattaEnabled { entries.append(.chatta) }
        entries.append(contentsOf: microApps.map(LaunchaEntry.micro))
        entries.append(contentsOf: lowkeySites.map(LaunchaEntry.site))
        entries.append(contentsOf: apps.map(LaunchaEntry.app))
        let ranking = LaunchaRanking(history: history, usage: appSwitching ? usage : LaunchHistory(),
                                     running: running, runningOrder: appSwitching ? runningApps : .any)
        let matches = LaunchaSearch.ranked(for: trimmed, in: entries, ranking: ranking, now: Date(), candidate: \.candidate)
        let appRows = matches.map { $0.row(microFolder: microFolder ?? home) }
        if trimmed.isEmpty { followsFiles = false }
        var nextRows = appRows
        if wantsFiles(trimmed, appsMatch: !appRows.isEmpty) {
            if spotlightQuery != trimmed {
                // Finished results become the base; while a search is still running, keep the older base.
                if spotlight.status != .searching && spotlight.status != .idle { pendingFiles = spotlight.files }
                spotlightQuery = trimmed
                spotlight = LaunchaSpotlight.State()
                services.spotlight.search(trimmed)
            }
            let files = spotlight.status == .searching || spotlight.status == .idle
                ? pendingFiles.filter { Self.fileName($0.url, contains: trimmed) }
                : spotlight.files
            // Files go below apps, so the best app stays selected while they arrive.
            nextRows += files.map { file in
                LaunchaRow(id: "file:" + file.url.path, kind: .file(file.url), name: file.name,
                           detail: displayFolder(of: file.url))
            }
        } else if spotlightQuery != nil {
            stopSpotlight()
        }
        // A calculation or a conversion comes first, above the apps or files that match the same text.
        if calculator, let value = Calculator.evaluate(trimmed) {
            nextRows.insert(LaunchaRow(id: LaunchaRow.calculationID, kind: .calculation(value: value), name: value,
                                       detail: "Return copies the result"), at: 0)
        } else if converter, let result = Converter.evaluate(trimmed) {
            nextRows.insert(LaunchaRow(id: LaunchaRow.calculationID, kind: .calculation(value: result.value),
                                       name: result.display, detail: result.detail), at: 0)
        }
        if rows != nextRows {
            rows = nextRows
            rowsVersion += 1
        }
        let nextSelection: Int
        if let previous, let index = rows.firstIndex(where: { $0.id == previous }), !followsFiles || rows[index].isFile {
            nextSelection = index
        } else if followsFiles, let firstFile = firstFileIndex {
            nextSelection = firstFile
        } else {
            nextSelection = 0
        }
        if selection != nextSelection { selection = nextSelection }
    }

    /// Minimum query length that searches files while apps also match; shorter queries
    /// match too much of the home folder to be worth a Spotlight query per keystroke.
    static let filesBesideAppsMinLength = 3

    /// Files are searched when no app matches, while the selection follows files, or below
    /// the apps for a longer query. A query without letters or digits lists every app, so it
    /// never searches files on its own.
    private func wantsFiles(_ trimmed: String, appsMatch: Bool) -> Bool {
        guard !trimmed.isEmpty, hasIndex else { return false }
        guard appsMatch, !followsFiles else { return true }
        return trimmed.count >= Self.filesBesideAppsMinLength
            && trimmed.unicodeScalars.contains { CharacterSet.alphanumerics.contains($0) }
    }

    /// The local counterpart of the Spotlight predicate (`FSName CONTAINS[cd]`).
    static func fileName(_ url: URL, contains text: String) -> Bool {
        url.lastPathComponent.range(of: text, options: [.caseInsensitive, .diacriticInsensitive]) != nil
    }

    private func displayFolder(of url: URL) -> String {
        let folder = url.deletingLastPathComponent().path
        let base = home.standardizedFileURL.path
        let real = LaunchaPathPolicy.realURL(home)?.path ?? base
        for prefix in [real, base] {
            let iCloud = prefix + "/" + LaunchaPathPolicy.iCloudDrivePath
            if folder == iCloud || folder.hasPrefix(iCloud + "/") {
                return "iCloud Drive" + folder.dropFirst(iCloud.count)
            }
        }
        for prefix in [real, base] where folder == prefix || folder.hasPrefix(prefix + "/") {
            return "~" + folder.dropFirst(prefix.count)
        }
        return folder
    }

    private func startScan(onOpen: Bool, refreshContext: Bool = true) {
        if refreshContext {
            let nextSites = loadLowkeySites()
            let previousRunning = running
            refreshRunning()
            let contextChanged = nextSites != lowkeySites || running != previousRunning
            lowkeySites = nextSites
            if isOpen && contextChanged { recompute(keepSelection: true) }
        }
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
        let changed = !hasIndex || apps != snapshot.apps || indexIssues != snapshot.issues
        apps = snapshot.apps
        if indexIssues != snapshot.issues { indexIssues = snapshot.issues }
        if !hasIndex { hasIndex = true }
        if changed { recompute(keepSelection: true) }
    }

    private func loadHistory() {
        if appSwitching { loadUsage() }
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
        let nextIssue = snapshot.issues.first.map { "Launch history: \($0.message)" }
        let changed = history != snapshot.history || historyIssue != nextIssue
        history = snapshot.history
        if historyIssue != nextIssue { historyIssue = nextIssue }
        if changed { recompute(keepSelection: true) }
    }

    // MARK: App use outside launcha

    /// The ids of running regular apps, as launcha candidates.
    static func runningAppIDs(_ workspace: NSWorkspace = .shared) -> Set<String> {
        Set(workspace.runningApplications.filter { $0.activationPolicy == .regular }
            .compactMap(\.bundleIdentifier).map { LaunchaCandidate.app(bundleID: $0, name: "").id })
    }

    /// An app came to the front. Ting itself is not counted.
    func noteActivation(bundleID: String, at time: Date = Date()) {
        guard appSwitching, bundleID.lowercased() != Bundle.main.bundleIdentifier?.lowercased() else { return }
        let id = LaunchaCandidate.app(bundleID: bundleID, name: "").id
        usageSerial += 1
        let serial = usageSerial
        let store = usageStore
        Task { [weak self] in
            let snapshot = await store.recordUse(id: id, at: time)
            self?.applyUsage(snapshot, serial: serial)
        }
    }

    private func startWatchingApps() {
        loadUsage()
        guard activationObserver == nil else { return }
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] note in
                let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
                guard let bundleID = app?.bundleIdentifier else { return }
                MainActor.assumeIsolated { self?.noteActivation(bundleID: bundleID) }
            }
    }

    /// Stops watching and deletes the record of app use.
    private func stopWatchingApps() {
        if let activationObserver { NSWorkspace.shared.notificationCenter.removeObserver(activationObserver) }
        activationObserver = nil
        usage = LaunchHistory()
        usageSerial += 1
        let serial = usageSerial
        let store = usageStore
        Task { [weak self] in
            let snapshot = await store.clear()
            self?.applyUsage(snapshot, serial: serial)
        }
    }

    private func loadUsage() {
        usageSerial += 1
        let serial = usageSerial
        let store = usageStore
        Task { [weak self] in
            await store.reopen()
            let snapshot = await store.load()
            self?.applyUsage(snapshot, serial: serial)
        }
    }

    private func applyUsage(_ snapshot: LaunchaHistoryStore.Snapshot, serial: Int) {
        guard serial > appliedUsage else { return }
        appliedUsage = serial
        let changed = usage != snapshot.history
        usage = snapshot.history
        if isOpen && changed { recompute(keepSelection: true) }
    }

    private func refreshRunning() {
        running = appSwitching && runningApps != .any ? runningAppIDs() : []
    }
}

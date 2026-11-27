import Foundation

struct LaunchaFileResult: Equatable, Sendable {
    var url: URL
    var name: String
}

/// Own one instance per panel. Cancel whenever app matches take priority, and `forget` on close.
@MainActor
final class LaunchaSpotlight {
    /// A finished search, remembered until `forget()`.
    private struct Finished {
        let text: String
        let files: [LaunchaFileResult]
        let issues: [LaunchaServiceIssue]
        /// Every match is in `files`: fewer than the cap and nothing skipped or cut off.
        let complete: Bool
    }
    /// The most recent finished searches that `search` answers from without Spotlight.
    static let rememberedLimit = 32

    struct State: Equatable, Sendable {
        enum Status: Equatable, Sendable { case idle, searching, results, empty, error(String) }
        var status: Status = .idle
        var files: [LaunchaFileResult] = []
        /// An empty result with needsConsent is NOT a complete home search.
        var issues: [LaunchaServiceIssue] = []
    }
    typealias Provider = @Sendable (String) async throws -> [URL]
    private(set) var state = State()
    var onChange: ((State) -> Void)?
    private var policy: LaunchaPathPolicy
    /// iCloud Drive is searched too. Changing it forgets the remembered searches.
    var searchesICloudDrive: Bool {
        get { policy.iCloudDrive }
        set {
            guard newValue != policy.iCloudDrive else { return }
            policy.iCloudDrive = newValue
            forget()
        }
    }
    private let debounce: Duration
    private let timeout: Duration
    private let cap: Int
    private let provider: Provider?
    private var generation = UUID()
    private var work: Task<Void, Never>?
    private var deadline: Task<Void, Never>?
    private var query: NSMetadataQuery?
    private var observers: [NSObjectProtocol] = []
    /// Oldest first, at most `rememberedLimit`.
    private var remembered: [Finished] = []

    init(home: URL = FileManager.default.homeDirectoryForCurrentUser,
         protectedFolders: ProtectedFolderPolicy = .needsConsent,
         debounce: Duration = .milliseconds(200), timeout: Duration = .seconds(10),
         cap: Int = 50, provider: Provider? = nil) {
        policy = LaunchaPathPolicy(home: home, protectedFolders: protectedFolders)
        self.debounce = debounce
        self.timeout = timeout
        self.cap = max(1, cap)
        self.provider = provider
    }

    func cancel() {
        generation = UUID()
        stop()
        publish(State())
    }

    /// Ends the session: later searches ask Spotlight again, so files changed since show up.
    func forget() {
        remembered.removeAll()
    }

    /// Spotlight finds no name that contains a text ending in `_` or `.` (`img_` misses
    /// `k_IMG_0548.png`), so it gets the text without trailing punctuation. Results are then
    /// matched against the full text with `nameContains`.
    nonisolated static func spotlightText(_ text: String) -> String {
        var scalars = Substring(text).unicodeScalars
        while let last = scalars.last, !CharacterSet.alphanumerics.contains(last) { scalars.removeLast() }
        return String(scalars)
    }

    /// The local counterpart of the Spotlight predicate (`FSName CONTAINS[cd]`).
    nonisolated static func nameContains(_ name: String, _ text: String) -> Bool {
        name.range(of: text, options: [.caseInsensitive, .diacriticInsensitive]) != nil
    }

    /// The answer of a remembered search: the same text, or more text than a complete one,
    /// whose matches are all in it (`054` answers `0549`).
    private func rememberedAnswer(for text: String) -> (files: [LaunchaFileResult], issues: [LaunchaServiceIssue])? {
        if let same = remembered.last(where: { $0.text.compare(text, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame }) {
            return (same.files, same.issues)
        }
        guard let wider = remembered.last(where: { $0.complete && Self.nameContains(text, $0.text) }) else { return nil }
        return (wider.files.filter { Self.nameContains($0.url.lastPathComponent, text) }, wider.issues)
    }

    private func remember(_ text: String, files: [LaunchaFileResult], issues: [LaunchaServiceIssue]) {
        let complete = files.count < cap && issues.allSatisfy { $0.kind == .needsConsent }
        remembered.removeAll { $0.text == text }
        remembered.append(Finished(text: text, files: files, issues: issues, complete: complete))
        if remembered.count > Self.rememberedLimit { remembered.removeFirst(remembered.count - Self.rememberedLimit) }
    }

    func search(_ text: String) {
        cancel()
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        let token = generation
        let issues = policy.protectedFolders == .needsConsent ? policy.protectedURLs.map {
            LaunchaServiceIssue(kind: .needsConsent, url: $0, message: "Protected-folder search needs a user action.")
        } : []
        let spotlightText = Self.spotlightText(text)
        // Only punctuation: nothing Spotlight can match.
        guard !spotlightText.isEmpty else { return publish(State(status: .empty, issues: issues)) }
        if let answer = rememberedAnswer(for: text) {
            return publish(State(status: answer.files.isEmpty ? .empty : .results, files: answer.files, issues: answer.issues))
        }
        publish(State(status: .searching, issues: issues))
        work = Task { [weak self, debounce] in
            do { try await Task.sleep(for: debounce) } catch { return }
            guard let self, self.generation == token, !Task.isCancelled else { return }
            self.deadline = Task { [weak self, timeout] in
                do { try await Task.sleep(for: timeout) } catch { return }
                guard let self, self.generation == token else { return }
                self.fail("Spotlight search timed out.", token: token)
            }
            if let provider = self.provider {
                do {
                    let urls = try await provider(spotlightText).filter {
                        spotlightText == text || Self.nameContains($0.lastPathComponent, text)
                    }
                    guard !Task.isCancelled, self.generation == token else { return }
                    await self.complete(urls, text: text, token: token)
                } catch {
                    guard !Task.isCancelled else { return }
                    self.fail(error.localizedDescription, token: token, issue: .access(error, at: self.policy.home))
                }
            } else { self.startQuery(text, spotlightText: spotlightText, token: token) }
        }
    }

    /// Visible top-level folders of home that the policy allows, and iCloud Drive when it is on.
    /// Spotlight then never spends the inspection limit on the rest of `~/Library`, hidden
    /// folders or protected folders. Loose files directly in home are not searched.
    nonisolated static func searchScopes(_ policy: LaunchaPathPolicy) -> [URL] {
        let children = (try? FileManager.default.contentsOfDirectory(
            at: policy.home, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])) ?? []
        // iCloud Drive sits in hidden ~/Library, so the listing above never has it.
        let iCloud = policy.iCloudDrive ? [policy.iCloudDriveURL] : []
        return (children + iCloud).filter { url in
            (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true && policy.searchable(url)
        }.sorted { $0.path < $1.path }
    }

    private func startQuery(_ text: String, spotlightText: String, token: UUID) {
        let scopes = Self.searchScopes(policy)
        // An empty scope list would search the whole Mac.
        guard !scopes.isEmpty else {
            work = Task { [weak self] in await self?.complete([], text: text, token: token) }
            return
        }
        let query = NSMetadataQuery()
        // Wildcards in the user's input are literal, not Spotlight pattern operators.
        query.predicate = NSPredicate(format: "%K CONTAINS[cd] %@", NSMetadataItemFSNameKey, spotlightText)
        query.searchScopes = scopes
        // Recently changed files first, so the inspection limit drops old files, not late names.
        query.sortDescriptors = [NSSortDescriptor(key: NSMetadataItemFSContentChangeDateKey, ascending: false)]
        self.query = query
        observers.append(NotificationCenter.default.addObserver(forName: .NSMetadataQueryDidFinishGathering,
                                                                object: query, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.generation == token, let query = self.query else { return }
                query.disableUpdates()
                // Keep only names with the full text, then bound inspection too, not just the number displayed.
                var urls: [URL] = []
                for index in 0..<query.resultCount {
                    guard let item = query.result(at: index) as? NSMetadataItem,
                          let path = item.value(forAttribute: NSMetadataItemPathKey) as? String else { continue }
                    let name = item.value(forAttribute: NSMetadataItemFSNameKey) as? String ?? (path as NSString).lastPathComponent
                    guard spotlightText == text || Self.nameContains(name, text) else { continue }
                    guard urls.count < 2000 else {
                        self.state.issues.append(.init(kind: .limit, url: self.policy.home, message: "Spotlight inspection limit reached."))
                        break
                    }
                    urls.append(URL(fileURLWithPath: path))
                }
                self.stopQuery()
                self.work = Task { [weak self] in await self?.complete(urls, text: text, token: token) }
            }
        })
        if !query.start() { fail("Spotlight could not start the home search.", token: token) }
    }

    private func complete(_ urls: [URL], text: String, token: UUID) async {
        let policy = policy
        let cap = cap
        let filtered = Task.detached(priority: .userInitiated) { () -> ([LaunchaFileResult], [LaunchaServiceIssue]) in
            var files: [LaunchaFileResult] = []
            var issues: [LaunchaServiceIssue] = urls.count > 2000
                ? [.init(kind: .limit, url: policy.home, message: "Spotlight inspection limit reached.")]
                : []
            var seen: Set<String> = []
            for url in urls.prefix(2000) {
                guard !Task.isCancelled else { break }
                guard policy.lexicalSearchable(url) else { continue }
                guard let real = LaunchaPathPolicy.realURL(url) else {
                    issues.append(.access(NSError(domain: NSPOSIXErrorDomain, code: Int(errno)), at: url))
                    continue
                }
                guard policy.searchable(url) else { continue }
                guard seen.insert(real.path).inserted else { continue }
                do {
                    var excluded = false
                    // Finder-hidden directories and extensionless application packages also count.
                    for start in [url.standardizedFileURL, real] {
                        var ancestor = start
                        let home = start == real ? (LaunchaPathPolicy.realURL(policy.home) ?? policy.home) : policy.home.standardizedFileURL
                        // iCloud Drive sits in hidden ~/Library: check only the folders inside it.
                        let iCloud = home.appendingPathComponent(LaunchaPathPolicy.iCloudDrivePath)
                        let root = policy.contains(start, in: iCloud) ? iCloud : home
                        while ancestor.path != root.path && ancestor.path != "/" {
                            if Task.isCancelled { return (files, issues) }
                            let values = try ancestor.resourceValues(forKeys: [.isHiddenKey, .isApplicationKey])
                            if values.isHidden == true || values.isApplication == true { excluded = true; break }
                            ancestor.deleteLastPathComponent()
                        }
                        if excluded { break }
                    }
                    guard !excluded else { continue }
                    let values = try real.resourceValues(forKeys: [.localizedNameKey])
                    files.append(.init(url: real, name: values.localizedName ?? real.lastPathComponent))
                    if files.count == cap { break }
                } catch { issues.append(.access(error, at: real)) }
            }
            return (files, issues)
        }
        let (files, issues) = await withTaskCancellationHandler {
            await filtered.value
        } onCancel: { filtered.cancel() }
        guard generation == token, !Task.isCancelled else { return }
        let allIssues = state.issues + issues
        stop()
        remember(text, files: files, issues: allIssues)
        publish(State(status: files.isEmpty ? .empty : .results, files: files, issues: allIssues))
    }

    private func fail(_ message: String, token: UUID, issue: LaunchaServiceIssue? = nil) {
        guard generation == token else { return }
        let issues = state.issues + (issue.map { [$0] } ?? [])
        // Invalidate even a provider that ignores cancellation and returns later.
        generation = UUID()
        stop()
        publish(State(status: .error(message), issues: issues))
    }
    private func stopQuery() {
        query?.stop()
        query = nil
        observers.forEach(NotificationCenter.default.removeObserver)
        observers.removeAll()
    }
    private func stop() {
        work?.cancel(); work = nil
        deadline?.cancel(); deadline = nil
        stopQuery()
    }
    private func publish(_ state: State) { self.state = state; onChange?(state) }
    deinit {
        work?.cancel()
        deadline?.cancel()
        query?.stop()
        observers.forEach(NotificationCenter.default.removeObserver)
    }
}

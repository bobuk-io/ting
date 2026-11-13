import AppKit
import TingCore

struct IndexedLaunchaApp: Sendable {
    var candidate: LaunchaCandidate
    /// Always launch this URL, not a new bundle-ID lookup.
    var url: URL
}

/// Bounded scans run on this actor. Call refreshOnOpen for every panel opening.
/// While open, call refreshIfNeeded periodically; it scans at most once per minute.
actor LaunchaAppIndex {
    struct Snapshot: Sendable {
        var apps: [IndexedLaunchaApp]
        var issues: [LaunchaServiceIssue]
    }
    struct Limits: Sendable {
        var depth = 8
        var entries = 20_000
        var seconds: TimeInterval = 5
    }
    private let roots: [URL]
    private let policy: LaunchaPathPolicy
    private let limits: Limits
    private var cached = Snapshot(apps: [], issues: [])
    private var lastRefresh: Date?

    init(home: URL = FileManager.default.homeDirectoryForCurrentUser,
         protectedFolders: ProtectedFolderPolicy = .needsConsent, roots: [URL]? = nil, limits: Limits = Limits()) {
        self.roots = roots ?? [URL(fileURLWithPath: "/Applications"), URL(fileURLWithPath: "/System/Applications"),
                              home.appendingPathComponent("Applications"), home.appendingPathComponent("Desktop")]
        policy = LaunchaPathPolicy(home: home, protectedFolders: protectedFolders)
        self.limits = limits
    }

    func refreshIfNeeded(now: Date = Date()) -> Snapshot {
        if let lastRefresh, now.timeIntervalSince(lastRefresh) < 60 { return cached }
        return refreshOnOpen()
    }

    func refreshOnOpen() -> Snapshot {
        let fm = FileManager.default
        let deadline = Date().addingTimeInterval(limits.seconds)
        var result = Snapshot(apps: [], issues: [])
        var visited: Set<String> = []
        var ids: Set<String> = []
        var count = 0
        var stopped = false
        func walk(_ lexical: URL, depth: Int) {
            guard !stopped, !Task.isCancelled else { return }
            if policy.needsConsent(lexical) {
                result.issues.append(.init(kind: .needsConsent, url: lexical, message: "Folder access needs a user action."))
                return
            }
            let url = LaunchaPathPolicy.realURL(lexical) ?? lexical.standardizedFileURL
            if policy.needsConsent(url) {
                result.issues.append(.init(kind: .needsConsent, url: url, message: "Folder access needs a user action."))
                return
            }
            guard visited.insert(url.path).inserted else { return }
            count += 1
            guard count <= limits.entries, Date() < deadline else {
                stopped = true
                result.issues.append(.init(kind: .limit, url: url, message: "App index scan limit reached."))
                return
            }
            do {
                let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey, .localizedNameKey, .isHiddenKey])
                guard values.isDirectory == true, values.isHidden != true else { return }
                if url.pathExtension.lowercased() == "app" {
                    let bundle = Bundle(url: url)
                    let name = (bundle?.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
                        ?? values.localizedName.map { ($0 as NSString).deletingPathExtension }
                        ?? url.deletingPathExtension().lastPathComponent
                    let candidate: LaunchaCandidate
                    if let id = bundle?.bundleIdentifier, !id.isEmpty { candidate = .app(bundleID: id, name: name) }
                    else { candidate = LaunchaCandidate(id: "app-path:" + url.path, name: name, target: .url(url.absoluteString)) }
                    if ids.insert(candidate.id).inserted { result.apps.append(.init(candidate: candidate, url: url)) }
                    return
                }
                guard values.isPackage != true else { return }
                guard depth < limits.depth else {
                    result.issues.append(.init(kind: .limit, url: url, message: "App index depth limit reached."))
                    return
                }
                for child in try fm.contentsOfDirectory(at: url, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]).sorted(by: { $0.path < $1.path }) {
                    walk(child, depth: depth + 1)
                    if stopped || Task.isCancelled { break }
                }
            } catch {
                // Optional roots may not exist yet. Other failures must reach the caller.
                let ns = error as NSError
                if !(depth == 0 && ns.domain == NSCocoaErrorDomain && ns.code == NSFileReadNoSuchFileError) {
                    result.issues.append(.access(error, at: url))
                }
            }
        }
        for root in roots { walk(root, depth: 0) }
        if !Task.isCancelled { cached = result; lastRefresh = Date() }
        return result
    }

    func search(_ query: String, history: LaunchHistory, now: Date = Date()) -> [LaunchaMatch] {
        LaunchaSearch.results(for: query, in: cached.apps.map(\.candidate), history: history, now: now)
    }
}

/// NSCache bounds icon memory. Loading runs on a private queue, not on the UI thread.
final class LaunchaIconCache: @unchecked Sendable {
    private let cache = NSCache<NSURL, NSImage>()
    private let queue = DispatchQueue(label: "io.bobuk.ting.launcha-icons", qos: .userInitiated)
    init() { cache.countLimit = 256 }
    func icon(for url: URL) async -> NSImage {
        await withCheckedContinuation { continuation in
            queue.async { [self] in
                if let image = cache.object(forKey: url as NSURL) { continuation.resume(returning: image); return }
                let image = NSWorkspace.shared.icon(forFile: url.path)
                cache.setObject(image, forKey: url as NSURL)
                continuation.resume(returning: image)
            }
        }
    }
    func invalidate() { cache.removeAllObjects() }
}

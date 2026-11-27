import XCTest
import TingCore
@testable import Ting

/// Thread-safe record of the texts a Spotlight provider received.
private final class SpotlightTexts: @unchecked Sendable {
    private let lock = NSLock()
    private var texts: [String] = []
    func add(_ text: String) { lock.withLock { texts.append(text) } }
    var all: [String] { lock.withLock { texts } }
}

final class LaunchaServiceTests: XCTestCase {
    private func temporary() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("ting-services-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return try XCTUnwrap(LaunchaPathPolicy.realURL(url))
    }

    private func app(_ url: URL, id: String? = nil) throws {
        let contents = url.appendingPathComponent("Contents")
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        var info = ["CFBundleName": "Test", "CFBundleDisplayName": "Localized Test", "CFBundlePackageType": "APPL"]
        info["CFBundleIdentifier"] = id
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            .write(to: contents.appendingPathComponent("Info.plist"))
    }

    func testIndexPackagesUtilitiesCyclesAndIdentity() async throws {
        let root = try temporary()
        let apps = root.appendingPathComponent("Applications")
        let a = apps.appendingPathComponent("Utilities/A.app")
        try app(a, id: "io.bobuk.test")
        try app(a.appendingPathComponent("Contents/Hidden.app"), id: "io.bobuk.hidden")
        try app(apps.appendingPathComponent("Duplicate.app"), id: "io.bobuk.test")
        try app(apps.appendingPathComponent("Container.bundle/Nested.app"), id: "io.bobuk.packaged")
        try app(apps.appendingPathComponent(".hidden/Secret.app"), id: "io.bobuk.secret")
        let anonymous = apps.appendingPathComponent("NoID.app")
        try app(anonymous)
        try FileManager.default.createSymbolicLink(at: apps.appendingPathComponent("Loop"), withDestinationURL: apps)
        try FileManager.default.createSymbolicLink(at: apps.appendingPathComponent("Alias.app"), withDestinationURL: anonymous)
        let index = LaunchaAppIndex(home: root, roots: [apps])
        let result = await index.refreshOnOpen()
        XCTAssertEqual(result.apps.count, 2)
        XCTAssertTrue(result.apps.contains { $0.candidate.id == "app-path:" + anonymous.path && $0.url.path == anonymous.path })
        XCTAssertTrue(result.apps.allSatisfy { $0.candidate.name == "Localized Test" })
        XCTAssertTrue(result.issues.isEmpty)
        let matches = await index.search("localized", history: LaunchHistory())
        XCTAssertEqual(matches.count, 2)
        try FileManager.default.removeItem(at: anonymous)
        let refreshed = await index.refreshOnOpen()
        XCTAssertEqual(refreshed.apps.count, 1)
    }

    func testRefreshCacheAndCancelledScan() async throws {
        let root = try temporary()
        try app(root.appendingPathComponent("One.app"))
        let index = LaunchaAppIndex(home: root, roots: [root])
        let first = await index.refreshOnOpen()
        XCTAssertEqual(first.apps.count, 1)
        try app(root.appendingPathComponent("Two.app"))
        let cached = await index.refreshIfNeeded()
        XCTAssertEqual(cached.apps.count, 1)
        let cancelled = Task { await index.refreshOnOpen() }
        cancelled.cancel()
        _ = await cancelled.value
        let afterCancel = await index.search("", history: LaunchHistory())
        XCTAssertEqual(afterCancel.count, 1)
        let refreshed = await index.refreshOnOpen()
        XCTAssertEqual(refreshed.apps.count, 2)
    }

    func testDefaultIndexFindsFinderAndInstalledSafari() async throws {
        let index = LaunchaAppIndex(home: try temporary())
        _ = await index.refreshOnOpen()
        let finder = await index.search("Finder", history: LaunchHistory())
        XCTAssertEqual(finder.filter { $0.candidate.id == "app:com.apple.finder" }.count, 1)

        // Safari can be uninstalled on some systems.
        if ["/Applications/Safari.app", "/System/Applications/Safari.app"].contains(where: FileManager.default.fileExists(atPath:)) {
            let safari = await index.search("Safari", history: LaunchHistory())
            XCTAssertEqual(safari.filter { $0.candidate.id == "app:com.apple.safari" }.count, 1)
        }
    }

    func testIndexFollowsHiddenAppSymlinks() async throws {
        let home = try temporary()
        let apps = home.appendingPathComponent("Applications")
        let target = home.appendingPathComponent("Elsewhere/Browser.app")
        try app(target, id: "io.bobuk.browser")
        try FileManager.default.createDirectory(at: apps, withIntermediateDirectories: true)
        for name in ["Browser.app", "Another Link.app"] {
            let link = apps.appendingPathComponent(name)
            try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: "../Elsewhere/Browser.app")
            XCTAssertEqual(lchflags(link.path, UInt32(UF_HIDDEN)), 0)
        }
        let helpers = home.appendingPathComponent("Helpers")
        try app(helpers.appendingPathComponent("Helper.app"), id: "io.bobuk.helper")
        let hiddenFolderLink = apps.appendingPathComponent("Folder.app")
        try FileManager.default.createSymbolicLink(at: hiddenFolderLink, withDestinationURL: helpers)
        XCTAssertEqual(lchflags(hiddenFolderLink.path, UInt32(UF_HIDDEN)), 0)

        let index = LaunchaAppIndex(home: home, roots: [apps])
        let result = await index.refreshOnOpen()
        XCTAssertEqual(result.apps.map(\.url.path), [target.path])
        XCTAssertTrue(result.issues.isEmpty)
    }

    func testDesktopConsent() async throws {
        let home = try temporary()
        let desktop = home.appendingPathComponent("Desktop")
        try app(desktop.appendingPathComponent("Tool.app"))
        let gated = LaunchaAppIndex(home: home, roots: [desktop])
        let skipped = await gated.refreshOnOpen()
        XCTAssertEqual(skipped.issues.map(\.kind), [.needsConsent])
        XCTAssertTrue(skipped.apps.isEmpty)
        let allowed = LaunchaAppIndex(home: home, protectedFolders: .allowed, roots: [desktop])
        let indexed = await allowed.refreshOnOpen()
        XCTAssertEqual(indexed.apps.count, 1)
        XCTAssertTrue(indexed.issues.isEmpty)
    }

    func testIndexBoundsDepthToAppFolders() async throws {
        let root = try temporary()
        let direct = root.appendingPathComponent("Direct.app")
        let nested = root.appendingPathComponent("Utilities/Nested.app")
        let tooDeep = root.appendingPathComponent("Projects/Repo/Deep.app")
        try app(direct, id: "io.bobuk.direct")
        try app(nested, id: "io.bobuk.nested")
        try app(tooDeep, id: "io.bobuk.deep")
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("Utilities/Loop"), withDestinationURL: root)
        let index = LaunchaAppIndex(home: root, roots: [root])
        let result = await index.refreshOnOpen()
        XCTAssertEqual(Set(result.apps.map(\.url.path)), Set([direct.path, nested.path]))
        XCTAssertTrue(result.issues.isEmpty)

        // Adding an app in a watched subfolder invalidates the directory-stamp cache on next open.
        let added = root.appendingPathComponent("Utilities/Added.app")
        try app(added, id: "io.bobuk.added")
        let refreshed = await index.refreshOnOpen()
        XCTAssertEqual(Set(refreshed.apps.map(\.url.path)), Set([direct.path, nested.path, added.path]))
    }

    func testIndexBeyondFormerEntryLimit() async throws {
        let root = try temporary()
        let files = root.appendingPathComponent("Files")
        try FileManager.default.createDirectory(at: files, withIntermediateDirectories: true)
        for entry in 0..<20_001 {
            try Data().write(to: files.appendingPathComponent("file-\(entry)"))
        }
        let target = root.appendingPathComponent("Target.app")
        try app(target, id: "io.bobuk.target")
        // Scan the large root first so the target must come after the former cap.
        let index = LaunchaAppIndex(home: root, roots: [files, target])
        let result = await index.refreshOnOpen()
        XCTAssertEqual(result.apps.map(\.url.path), [target.path])
        XCTAssertTrue(result.issues.isEmpty)
    }

    func testPathRestrictionsIncludeSymlinks() throws {
        let home = try temporary()
        let outside = try temporary()
        let policy = LaunchaPathPolicy(home: home, protectedFolders: .allowed)
        for path in ["Library/a", ".secret/a", "Foo.app/Contents/a", "Desktop/.secret/a"] {
            XCTAssertFalse(policy.searchable(home.appendingPathComponent(path)))
        }
        XCTAssertFalse(policy.searchable(outside.appendingPathComponent("file")))
        for (name, destination) in [("escape", outside), ("library-link", home.appendingPathComponent("Library")), ("app-link", home.appendingPathComponent("Tool.app"))] {
            try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
            try Data().write(to: destination.appendingPathComponent("file"))
            try FileManager.default.createSymbolicLink(at: home.appendingPathComponent(name), withDestinationURL: destination)
            XCTAssertFalse(policy.searchable(home.appendingPathComponent(name + "/file")))
        }
        try FileManager.default.createDirectory(at: home.appendingPathComponent("Projects"), withIntermediateDirectories: true)
        try Data().write(to: home.appendingPathComponent("Projects/file"))
        XCTAssertTrue(policy.searchable(home.appendingPathComponent("Projects/file")))
        XCTAssertFalse(LaunchaPathPolicy(home: home).searchable(home.appendingPathComponent("Desktop/file")))
    }

    func testOnlyICloudDriveIsSearchableInLibraryAndOnlyWhenOn() throws {
        let home = try temporary()
        let library = home.appendingPathComponent("Library")
        for path in [LaunchaPathPolicy.iCloudDrivePath + "/Downloads", "Library/Mobile Documents/iCloud~com~example~app/Documents", "Library/Keychains"] {
            let folder = home.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try Data().write(to: folder.appendingPathComponent("file"))
        }
        let file = home.appendingPathComponent(LaunchaPathPolicy.iCloudDrivePath + "/Downloads/file")
        let on = LaunchaPathPolicy(home: home, iCloudDrive: true)
        XCTAssertTrue(on.searchable(file), "iCloud Drive does not need the protected-folder consent")
        XCTAssertFalse(on.searchable(library.appendingPathComponent("Mobile Documents/iCloud~com~example~app/Documents/file")))
        XCTAssertFalse(on.searchable(library.appendingPathComponent("Keychains/file")))
        XCTAssertFalse(on.searchable(home.appendingPathComponent(LaunchaPathPolicy.iCloudDrivePath + "/.Trash/file")))
        XCTAssertEqual(LaunchaSpotlight.searchScopes(on).map(\.path), [on.iCloudDriveURL.path])

        // Off by default, also with the protected folders allowed.
        let off = LaunchaPathPolicy(home: home, protectedFolders: .allowed)
        XCTAssertFalse(off.searchable(file))
        XCTAssertFalse(off.needsConsent(file))
        XCTAssertEqual(LaunchaSpotlight.searchScopes(off), [])
        XCTAssertEqual(off.protectedURLs.map(\.lastPathComponent), ["Desktop", "Documents", "Downloads"])
    }

    func testHistoryRecoveryIsolationAndSerializedWrites() async throws {
        let root = try temporary()
        let url = root.appendingPathComponent("history.json")
        let original = Data("broken history".utf8)
        try original.write(to: url)
        let store = LaunchaHistoryStore(url: url)
        let loaded = await store.load()
        XCTAssertEqual(loaded.issues.count, 1)
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(loaded.preservedOriginal)), original)
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<20 { group.addTask { _ = await store.record(.opened, id: "app:test") } }
        }
        let saved = try LaunchHistory.decode(Data(contentsOf: url))
        XCTAssertEqual(saved.entries["app:test"]?.events.count, 20)
        _ = await store.record(.failed, id: "ignored")
        _ = await store.record(.revealed, id: "ignored")
        XCTAssertEqual(try LaunchHistory.decode(Data(contentsOf: url)), saved)
        let isolated = LaunchaHistoryStore.defaultURL(environment: ["TING_CONFIG": root.appendingPathComponent("config.json").path], home: root)
        XCTAssertTrue(isolated.path.hasPrefix(root.path + "/config.json."))
        XCTAssertEqual(LaunchaHistoryStore.defaultURL(environment: [:], home: root).path,
                       root.appendingPathComponent("Library/Application Support/Ting/launcha-history.json").path)
    }

    func testFreshHistoryAndWriteFailure() async throws {
        let root = try temporary()
        let fresh = root.appendingPathComponent("new/history.json")
        let store = LaunchaHistoryStore(url: fresh)
        let empty = await store.load()
        XCTAssertTrue(empty.issues.isEmpty)
        _ = await store.record(.failed, id: "not-counted")
        XCTAssertFalse(FileManager.default.fileExists(atPath: fresh.path))
        _ = await store.record(.activated, id: "counted")
        XCTAssertEqual(try LaunchHistory.decode(Data(contentsOf: fresh)).entries.count, 1)
        let blocked = root.appendingPathComponent("blocked")
        try Data().write(to: blocked)
        let failed = LaunchaHistoryStore(url: blocked.appendingPathComponent("history.json"))
        let result = await failed.record(.opened, id: "memory-only")
        XCTAssertFalse(result.issues.isEmpty)
        XCTAssertEqual(result.history.entries.count, 1)
        XCTAssertEqual(LaunchaServiceIssue.access(CocoaError(.fileReadNoPermission), at: root).kind, .denied)
        XCTAssertEqual(LaunchaServiceIssue.access(NSError(domain: NSPOSIXErrorDomain, code: Int(EACCES)), at: root).kind, .denied)
    }

    @MainActor
    func testSpotlightDebounceCancelStaleAndCap() async throws {
        let home = try temporary()
        let first = home.appendingPathComponent("first.txt")
        let second = home.appendingPathComponent("second.txt")
        try Data().write(to: first)
        try Data().write(to: second)
        let service = LaunchaSpotlight(home: home, protectedFolders: .allowed, debounce: .milliseconds(10), cap: 1) { text in
            // Deliberately ignore cancellation to exercise the generation guard.
            try? await Task.sleep(for: text == "old" ? .milliseconds(180) : .milliseconds(20))
            return text == "old" ? [first] : [second, first]
        }
        service.search("old")
        try await Task.sleep(for: .milliseconds(30))
        service.search("new")
        try await Task.sleep(for: .milliseconds(250))
        XCTAssertEqual(service.state.status, .results)
        XCTAssertEqual(service.state.files.map(\.url), [second])
        service.search("old")
        service.cancel()
        try await Task.sleep(for: .milliseconds(250))
        XCTAssertEqual(service.state.status, .idle)
        service.search("   ")
        XCTAssertEqual(service.state.status, .idle)
    }

    func testSpotlightScopesSkipLibraryHiddenAppsAndProtectedFolders() throws {
        let home = try temporary()
        for folder in ["Library", ".hidden", "Projects", "Desktop", "Tool.app"] {
            try FileManager.default.createDirectory(at: home.appendingPathComponent(folder), withIntermediateDirectories: true)
        }
        try Data().write(to: home.appendingPathComponent("loose.txt"))
        let names = { (policy: ProtectedFolderPolicy) in
            LaunchaSpotlight.searchScopes(LaunchaPathPolicy(home: home, protectedFolders: policy)).map(\.lastPathComponent)
        }
        XCTAssertEqual(names(.needsConsent), ["Projects"])
        XCTAssertEqual(names(.allowed), ["Desktop", "Projects"])
    }

    /// Waits until a search started by `search` has finished.
    @MainActor
    private func finished(_ service: LaunchaSpotlight) async throws {
        for _ in 0..<300 where service.state.status == .searching { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertNotEqual(service.state.status, .searching, "search did not finish")
    }

    @MainActor
    func testSpotlightAnswersFromRememberedSearches() async throws {
        let home = try temporary()
        let names = ["k_IMG_0549.png", "0548-other.jpg", "notes.txt"]
        for name in names { try Data().write(to: home.appendingPathComponent(name)) }
        let files = names.map { home.appendingPathComponent($0) }
        let texts = SpotlightTexts()
        let service = LaunchaSpotlight(home: home, protectedFolders: .allowed, debounce: .zero) { text in
            texts.add(text)
            return files.filter { LaunchaSpotlight.nameContains($0.lastPathComponent, text) }
        }
        service.search("054")
        try await finished(service)
        XCTAssertEqual(service.state.files.count, 2)

        // `054` found every match (2 < cap): more text is answered from it at once.
        service.search("0549")
        XCTAssertEqual(service.state.files.map(\.name), ["k_IMG_0549.png"])
        service.search("05498")
        XCTAssertEqual(service.state.status, .empty)
        // Back to shorter text, and the same text again: also at once.
        service.search("0549")
        XCTAssertEqual(service.state.files.map(\.name), ["k_IMG_0549.png"])
        service.search("054")
        XCTAssertEqual(service.state.files.count, 2)
        XCTAssertEqual(texts.all, ["054"], "no Spotlight query for remembered answers")

        // Closing launcha forgets them.
        service.forget()
        service.search("054")
        XCTAssertEqual(service.state.status, .searching)
        try await finished(service)
        XCTAssertEqual(texts.all, ["054", "054"])
    }

    @MainActor
    func testSpotlightAsksAgainAfterAnIncompleteResultAndKeepsOnly32() async throws {
        let home = try temporary()
        let names = ["k_IMG_0549.png", "0549.jpg"]
        for name in names { try Data().write(to: home.appendingPathComponent(name)) }
        let files = names.map { home.appendingPathComponent($0) }
        let texts = SpotlightTexts()
        // A cap of 1 makes `054` incomplete: its one file may not be every match of `0549`.
        let service = LaunchaSpotlight(home: home, protectedFolders: .allowed, debounce: .zero, cap: 1) { text in
            texts.add(text)
            return files.filter { LaunchaSpotlight.nameContains($0.lastPathComponent, text) }
        }
        service.search("054")
        try await finished(service)
        XCTAssertEqual(service.state.files.count, 1)
        service.search("054")
        XCTAssertEqual(service.state.files.count, 1, "the same text is answered even when incomplete")
        service.search("0549")
        XCTAssertEqual(service.state.status, .searching)
        try await finished(service)
        XCTAssertEqual(texts.all, ["054", "0549"])

        // Only the 32 most recent searches are remembered. No text contains another, so each is asked.
        for index in 0...LaunchaSpotlight.rememberedLimit {
            service.search("q\(index)x")
            try await finished(service)
        }
        XCTAssertEqual(texts.all.count, 2 + LaunchaSpotlight.rememberedLimit + 1)
        service.search("q\(LaunchaSpotlight.rememberedLimit)x")
        XCTAssertEqual(service.state.status, .empty, "recent: remembered")
        service.search("q0x")
        XCTAssertEqual(service.state.status, .searching, "oldest: forgotten")
        service.cancel()
    }

    @MainActor
    func testSpotlightDropsTrailingPunctuationAndMatchesTheFullText() async throws {
        XCTAssertEqual(LaunchaSpotlight.spotlightText("img_"), "img")
        XCTAssertEqual(LaunchaSpotlight.spotlightText("0548."), "0548")
        XCTAssertEqual(LaunchaSpotlight.spotlightText("IMG_0"), "IMG_0")
        XCTAssertEqual(LaunchaSpotlight.spotlightText("_0548"), "_0548")
        XCTAssertEqual(LaunchaSpotlight.spotlightText("_."), "")
        let home = try temporary()
        let wanted = home.appendingPathComponent("k_IMG_0548.png")
        let other = home.appendingPathComponent("img-other.png")
        try Data().write(to: wanted)
        try Data().write(to: other)
        let texts = SpotlightTexts()
        let service = LaunchaSpotlight(home: home, protectedFolders: .allowed, debounce: .zero) { text in
            texts.add(text)
            return [wanted, other]
        }
        // Spotlight gets `img`; only names that contain `img_` are kept.
        service.search("img_")
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(service.state.status, .results)
        XCTAssertEqual(service.state.files.map(\.url.lastPathComponent), ["k_IMG_0548.png"])
        XCTAssertEqual(texts.all, ["img"])
        // Only punctuation: no Spotlight query, an empty result.
        service.search("_")
        XCTAssertEqual(service.state.status, .empty)
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(texts.all, ["img"])
    }

    func testFileRowsHighlightTheTypedTextWithPunctuation() {
        XCTAssertEqual(LaunchaRow.literalPositions(of: "img_", in: "k_IMG_0548.png"), [2, 3, 4, 5])
        XCTAssertEqual(LaunchaRow.literalPositions(of: "_0548.", in: "k_IMG_0548.png"), [5, 6, 7, 8, 9, 10])
        XCTAssertEqual(LaunchaRow.literalPositions(of: "cafe", in: "Café menu.pdf"), [0, 1, 2, 3])
        XCTAssertNil(LaunchaRow.literalPositions(of: "png", in: "k_IMG_0548"), "a hidden extension falls back to fuzzy")
        XCTAssertNil(LaunchaRow.literalPositions(of: "", in: "k_IMG_0548.png"))
    }

    @MainActor
    func testSpotlightIncompleteEmptyAndFailure() async throws {
        let home = try temporary()
        let service = LaunchaSpotlight(home: home, debounce: .zero) { _ in [] }
        service.search("missing")
        XCTAssertEqual(service.state.status, .searching)
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(service.state.status, .empty)
        XCTAssertEqual(service.state.issues.map(\.kind), [.needsConsent, .needsConsent, .needsConsent])
        let failure = LaunchaSpotlight(home: home, debounce: .zero) { _ in throw CocoaError(.fileReadNoPermission) }
        failure.search("failure")
        try await Task.sleep(for: .milliseconds(50))
        guard case .error = failure.state.status else { return XCTFail("Expected search error") }
        XCTAssertEqual(failure.state.issues.last?.kind, .denied)
        let timeout = LaunchaSpotlight(home: home, debounce: .zero, timeout: .milliseconds(10)) { _ in
            try? await Task.sleep(for: .milliseconds(100))
            return []
        }
        timeout.search("slow")
        try await Task.sleep(for: .milliseconds(150))
        guard case .error = timeout.state.status else { return XCTFail("Expected timeout, not stale empty") }
    }
}

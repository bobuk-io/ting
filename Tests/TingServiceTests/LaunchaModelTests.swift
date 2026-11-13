import XCTest
import TingCore
@testable import Ting

@MainActor
private final class FakeOpener: LaunchaOpening {
    var outcome: LaunchOutcome = .opened
    private(set) var opened: [URL] = []
    private(set) var files: [URL] = []
    private(set) var revealed: [URL] = []

    func openApp(at url: URL, name: String) async -> LaunchOutcome {
        opened.append(url)
        return outcome
    }

    func openFile(_ url: URL, name: String) async -> LaunchOutcome {
        files.append(url)
        return outcome
    }

    func reveal(_ url: URL) -> LaunchOutcome {
        revealed.append(url)
        return .revealed
    }
}

/// Thread-safe record of Spotlight provider calls.
private final class Calls: @unchecked Sendable {
    private let lock = NSLock()
    private var queries: [String] = []
    func add(_ query: String) { lock.withLock { queries.append(query) } }
    var all: [String] { lock.withLock { queries } }
}

@MainActor
final class LaunchaModelTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("ting-launcha-model-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        root = try XCTUnwrap(LaunchaPathPolicy.realURL(url))
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func app(_ name: String, id: String, in folder: URL) throws -> URL {
        let url = folder.appendingPathComponent(name + ".app")
        let contents = url.appendingPathComponent("Contents")
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        let info = ["CFBundleName": name, "CFBundleIdentifier": id, "CFBundlePackageType": "APPL"]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            .write(to: contents.appendingPathComponent("Info.plist"))
        return url
    }

    private struct Fixture {
        var model: LaunchaModel
        var opener: FakeOpener
        var calls: Calls
        var history: URL
        var consent: URL
    }

    private var policies: [ProtectedFolderPolicy] = []

    private func makeModel(files: [URL] = [], spotlightDelay: Duration = .zero) throws -> Fixture {
        let apps = root.appendingPathComponent("Applications")
        try FileManager.default.createDirectory(at: apps, withIntermediateDirectories: true)
        let opener = FakeOpener()
        let calls = Calls()
        let home = root!
        let historyURL = root.appendingPathComponent("history.json")
        let consentURL = root.appendingPathComponent("consent.json")
        let model = LaunchaModel(opener: opener, historyStore: LaunchaHistoryStore(url: historyURL),
                                 consent: LaunchaConsentStore(url: consentURL), home: home) { [weak self] policy in
            self?.policies.append(policy)
            let desktop = home.appendingPathComponent("Desktop")
            return LaunchaModel.Services(
                index: LaunchaAppIndex(home: home, protectedFolders: policy, roots: [apps, desktop]),
                spotlight: LaunchaSpotlight(home: home, protectedFolders: policy, debounce: .zero) { query in
                    calls.add(query)
                    if spotlightDelay > .zero { try? await Task.sleep(for: spotlightDelay) }
                    return files
                })
        }
        return Fixture(model: model, opener: opener, calls: calls, history: historyURL, consent: consentURL)
    }

    private func wait(_ message: String = "condition", timeout: Duration = .seconds(3),
                      until condition: () -> Bool) async throws {
        let clock = ContinuousClock()
        let end = clock.now + timeout
        while !condition() {
            guard clock.now < end else { return XCTFail("Timed out waiting for \(message)") }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    func testEmptyQueryRanksAppsAndSpotlightOnlyWithoutAppMatches() async throws {
        let apps = root.appendingPathComponent("Applications")
        try FileManager.default.createDirectory(at: apps, withIntermediateDirectories: true)
        let alpha = try app("Alpha", id: "io.bobuk.Alpha", in: apps)
        _ = try app("Beta", id: "io.bobuk.beta", in: apps)
        let note = root.appendingPathComponent("Projects/zeta-note.txt")
        try FileManager.default.createDirectory(at: note.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data().write(to: note)
        let fixture = try makeModel(files: [note])
        let model = fixture.model

        // History decides the order: Beta was launched, so it comes first.
        await model.record(.opened, id: "app:io.bobuk.beta")
        model.open()
        try await wait("index") { model.hasIndex && model.rows.count == 2 }
        XCTAssertEqual(model.rows.map(\.name), ["Beta", "Alpha"])
        XCTAssertEqual(model.rows.last?.url.path, alpha.path)
        XCTAssertTrue(fixture.calls.all.isEmpty)

        model.query = "alp"
        XCTAssertEqual(model.rows.map(\.name), ["Alpha"])
        XCTAssertTrue(fixture.calls.all.isEmpty, "Spotlight must not run while an app matches")

        model.query = "zeta"
        XCTAssertTrue(model.rows.isEmpty)
        try await wait("files") { model.rows.first?.kind == .file }
        XCTAssertEqual(fixture.calls.all, ["zeta"])
        XCTAssertEqual(model.rows.map(\.url.path), [note.path])
        XCTAssertEqual(model.rows.first?.detail, "~/Projects")
        XCTAssertTrue(model.showsConsentNotice, "Protected folders were skipped; the search is not complete")

        // An app match cancels the file search and hides its results.
        model.query = "be"
        XCTAssertEqual(model.rows.map(\.name), ["Beta"])
        XCTAssertEqual(model.spotlight.status, .idle)
        model.close()
    }

    func testIncompleteAndFailedStatesAreShown() async throws {
        let fixture = try makeModel(files: [])
        let model = fixture.model
        model.open()
        try await wait("index") { model.hasIndex }
        XCTAssertEqual(model.statusMessage, .info("No apps found."))
        model.query = "nothing"
        try await wait("empty search") { model.spotlight.status == .empty }
        XCTAssertEqual(model.statusMessage, .info("No apps or files match “nothing”."))
        XCTAssertEqual(Set(model.spotlight.issues.map(\.kind)), [.needsConsent])
        XCTAssertTrue(model.showsConsentNotice)
        XCTAssertNil(model.incompleteMessage)
        model.close()
    }

    func testClosedSessionIgnoresLateResults() async throws {
        let late = root.appendingPathComponent("late.txt")
        try Data().write(to: late)
        let fixture = try makeModel(files: [late], spotlightDelay: .milliseconds(150))
        let model = fixture.model
        model.open()
        try await wait("index") { model.hasIndex }
        model.query = "late"
        XCTAssertEqual(model.spotlight.status, .searching)
        model.close()
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertTrue(model.rows.isEmpty)
        XCTAssertEqual(model.query, "")
        XCTAssertEqual(model.spotlight.status, .idle)

        // A new session starts clean, with no results of the old query.
        model.open()
        XCTAssertTrue(model.rows.isEmpty)
        XCTAssertEqual(model.query, "")
        model.close()
    }

    func testOnlySuccessfulLaunchesCountOnceWithRetainedURL() async throws {
        let apps = root.appendingPathComponent("Applications")
        try FileManager.default.createDirectory(at: apps, withIntermediateDirectories: true)
        let tool = try app("Tool", id: "io.bobuk.Tool", in: apps)
        let fixture = try makeModel()
        let model = fixture.model
        var closeRequests = 0
        model.onRequestClose = { closeRequests += 1 }

        model.open()
        try await wait("index") { model.rows.count == 1 }
        var outcome = await model.activateSelection()
        XCTAssertEqual(outcome, .opened)
        XCTAssertEqual(fixture.opener.opened.map(\.path), [tool.path])
        XCTAssertFalse(model.isOpen)
        XCTAssertEqual(closeRequests, 1)
        var saved = try LaunchHistory.decode(Data(contentsOf: fixture.history))
        XCTAssertEqual(saved.entries["app:io.bobuk.tool"]?.events.count, 1, "Same identity as selecta: app: + lower-case bundle ID")

        fixture.opener.outcome = .failed
        model.open()
        try await wait("index") { model.rows.count == 1 }
        outcome = await model.activateSelection()
        XCTAssertEqual(outcome, .failed)

        model.open()
        try await wait("index") { model.rows.count == 1 }
        outcome = await model.activateSelection(reveal: true)
        XCTAssertEqual(outcome, .revealed)
        XCTAssertEqual(fixture.opener.revealed.map(\.path), [tool.path])

        fixture.opener.outcome = .activated
        model.open()
        try await wait("index") { model.rows.count == 1 }
        outcome = await model.activateSelection()
        XCTAssertEqual(outcome, .activated)

        saved = try LaunchHistory.decode(Data(contentsOf: fixture.history))
        XCTAssertEqual(saved.entries["app:io.bobuk.tool"]?.events.count, 2, "Failed opens and reveals are not counted")
        let closed = await model.activateSelection()
        XCTAssertNil(closed, "Nothing happens while closed")
    }

    func testSelectionMovesWithinBounds() async throws {
        let apps = root.appendingPathComponent("Applications")
        try FileManager.default.createDirectory(at: apps, withIntermediateDirectories: true)
        for name in ["A1", "A2", "A3"] { _ = try app(name, id: "io.bobuk." + name, in: apps) }
        let model = try makeModel().model
        model.open()
        try await wait("index") { model.rows.count == 3 }
        model.moveSelection(by: -1)
        XCTAssertEqual(model.selection, 0)
        model.moveSelection(by: 8)
        XCTAssertEqual(model.selection, 2)
        model.query = "a2"
        XCTAssertEqual(model.selection, 0, "A new query selects the first result")
        model.close()
    }

    func testConsentRecreatesServicesAndPersistsSeparately() async throws {
        let desktop = root.appendingPathComponent("Desktop")
        try FileManager.default.createDirectory(at: desktop, withIntermediateDirectories: true)
        _ = try app("DeskTool", id: "io.bobuk.desk", in: desktop)
        policies = []
        let fixture = try makeModel()
        let model = fixture.model
        model.open()
        try await wait("index") { model.hasIndex }
        XCTAssertTrue(model.rows.isEmpty, "Desktop needs consent first")
        XCTAssertEqual(model.indexIssues.map(\.kind), [.needsConsent])

        model.isExplainingConsent = true
        model.allowProtectedFolders()
        XCTAssertFalse(model.isExplainingConsent)
        XCTAssertEqual(model.protectedFolders, .allowed)
        XCTAssertEqual(policies, [.needsConsent, .allowed])
        try await wait("desktop app") { model.rows.map(\.name) == ["DeskTool"] }
        XCTAssertFalse(model.showsConsentNotice)

        // A fresh store reads the saved choice.
        XCTAssertEqual(LaunchaConsentStore(url: fixture.consent).policy, .allowed)

        model.revokeProtectedFolders()
        XCTAssertTrue(model.rows.isEmpty, "Apps from folders no longer allowed are dropped at once")
        XCTAssertEqual(LaunchaConsentStore(url: fixture.consent).policy, .needsConsent)
        model.close()
    }

    func testConsentStoreIsolationAndFailClosed() throws {
        let config = root.appendingPathComponent("ting-test.json")
        let isolated = LaunchaConsentStore.defaultURL(environment: ["TING_CONFIG": config.path], home: root)
        XCTAssertTrue(isolated.path.hasPrefix(config.path + "."))
        XCTAssertNotEqual(isolated, LaunchaHistoryStore.defaultURL(environment: ["TING_CONFIG": config.path], home: root))
        XCTAssertEqual(LaunchaConsentStore.defaultURL(environment: [:], home: root).path,
                       root.appendingPathComponent("Library/Application Support/Ting/launcha-consent.json").path)

        let fresh = LaunchaConsentStore(url: root.appendingPathComponent("missing.json"))
        XCTAssertEqual(fresh.policy, .needsConsent)
        XCTAssertNil(fresh.error)

        let broken = root.appendingPathComponent("broken.json")
        try Data("{\"protectedFolders\": tru".utf8).write(to: broken)
        let store = LaunchaConsentStore(url: broken)
        XCTAssertEqual(store.policy, .needsConsent)
        XCTAssertNotNil(store.error)

        let blocked = root.appendingPathComponent("blocked")
        try Data().write(to: blocked)
        let unwritable = LaunchaConsentStore(url: blocked.appendingPathComponent("consent.json"))
        XCTAssertFalse(unwritable.set(.allowed))
        XCTAssertEqual(unwritable.policy, .needsConsent, "The choice changes only when it was saved")
    }
}

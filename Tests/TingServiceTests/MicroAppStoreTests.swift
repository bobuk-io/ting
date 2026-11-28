import XCTest
import TingCore
@testable import Ting

/// Every test uses its own temporary folder as the config directory; the real `~/.config/ting`
/// is never touched.
@MainActor
final class MicroAppStoreTests: XCTestCase {
    private static let good = """
    format: ting.microapp/2
    description: Say hi.
    input: none
    command: echo hi
    output:
      to: [panel]

    """

    private func temporaryConfig() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ting-micro-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory.appendingPathComponent("config.json")
    }

    private func makeFolder(_ store: MicroAppStore) throws {
        try FileManager.default.createDirectory(at: store.folderURL, withIntermediateDirectories: true)
    }

    private func put(_ text: String, _ name: String, in store: MicroAppStore) throws {
        try Data(text.utf8).write(to: store.folderURL.appendingPathComponent(name))
    }

    private func log(_ store: MicroAppStore) throws -> String {
        try String(contentsOf: store.logURL, encoding: .utf8)
    }

    /// Waits for the next reload that `change` causes.
    private func change(_ store: MicroAppStore, _ what: String,
                        _ change: () throws -> Void) async throws -> (previous: MicroAppCatalog, current: MicroAppCatalog) {
        let reloaded = expectation(description: what)
        var result: (MicroAppCatalog, MicroAppCatalog)?
        store.watch { previous, current in
            guard result == nil else { return }
            result = (previous, current)
            reloaded.fulfill()
        }
        try change()
        await fulfillment(of: [reloaded], timeout: 5)
        return try XCTUnwrap(result)
    }

    func testPathsSitNextToTheConfigFile() throws {
        let config = try temporaryConfig()
        let store = MicroAppStore(configURL: config, environment: [:])
        XCTAssertEqual(store.folderURL.path, config.deletingLastPathComponent().appendingPathComponent("micro").path)
        XCTAssertEqual(store.logURL.path, config.deletingLastPathComponent().appendingPathComponent("micro-errors.log").path)
        // With TING_CONFIG, the config file name comes first, as for the launcha files.
        let environment = ["TING_CONFIG": "/tmp/ting-x/test.json"]
        let custom = MicroAppStore(configURL: ConfigStore.defaultURL(environment: environment), environment: environment)
        XCTAssertEqual(custom.folderURL.path, "/tmp/ting-x/test.json.micro")
        XCTAssertEqual(custom.logURL.path, "/tmp/ting-x/test.json.micro-errors.log")
        let other = ["TING_CONFIG": "/tmp/ting-x/other.json"]
        XCTAssertNotEqual(MicroAppStore(configURL: ConfigStore.defaultURL(environment: other), environment: other).folderURL, custom.folderURL)
    }

    /// The app reads the user's PATH again on each load: the first one at start and every load
    /// that the watch makes after a file change.
    func testEveryLoadCallsOnLoadAlsoFromTheWatch() async throws {
        let store = MicroAppStore(configURL: try temporaryConfig(), environment: [:])
        try makeFolder(store)
        var loads = 0
        store.onLoad = { loads += 1 }
        store.load()
        XCTAssertEqual(loads, 1)
        _ = try await change(store, "add a file") { try put(Self.good, "say-hi.yaml", in: store) }
        XCTAssertGreaterThanOrEqual(loads, 2)
        store.stopWatching()
    }

    func testMissingFolderIsAnEmptyList() throws {
        let store = MicroAppStore(configURL: try temporaryConfig(), environment: [:])
        let catalog = store.load()
        XCTAssertTrue(catalog.entries.isEmpty)
        XCTAssertTrue(catalog.issues.isEmpty)
        XCTAssertEqual(try log(store), "")
    }

    func testLoadsYamlFilesOnly() throws {
        let store = MicroAppStore(configURL: try temporaryConfig(), environment: [:])
        try makeFolder(store)
        try put(Self.good, "say-hi.yaml", in: store)
        try put(Self.good, "notes.txt", in: store)
        try put(Self.good, ".hidden.yaml", in: store)
        try FileManager.default.createDirectory(at: store.folderURL.appendingPathComponent("dir.yaml"), withIntermediateDirectories: true)
        let catalog = store.load()
        XCTAssertEqual(catalog.entries.map(\.file), ["say-hi.yaml"])
        XCTAssertEqual(catalog.apps.map(\.id), ["say-hi"])
    }

    func testLogListsProblemsAndIsEmptiedWhenFixed() throws {
        let store = MicroAppStore(configURL: try temporaryConfig(), environment: [:])
        try makeFolder(store)
        try put(Self.good, "fine.yaml", in: store)
        try put("format: ting.microapp/2\nid: Bad\n", "broken.yaml", in: store)
        let catalog = store.load()
        XCTAssertEqual(catalog.brokenFiles, ["broken.yaml"])
        let lines = try log(store).split(separator: "\n")
        XCTAssertEqual(lines.count, catalog.issues.count)
        XCTAssertGreaterThan(lines.count, 1)
        for (line, issue) in zip(lines, catalog.issues) {
            XCTAssertEqual(String(line), "broken.yaml:\(issue.line): \(issue.message)")
        }
        try put(Self.good, "broken.yaml", in: store)
        XCTAssertTrue(store.load().issues.isEmpty)
        XCTAssertEqual(try log(store), "")
    }

    func testLiveAddChangeAndRemove() async throws {
        let store = MicroAppStore(configURL: try temporaryConfig(), environment: [:])
        defer { store.stopWatching() }
        XCTAssertTrue(store.load().entries.isEmpty)

        // The folder appears with a good file.
        var step = try await change(store, "add") {
            try makeFolder(store)
            try put(Self.good, "say-hi.yaml", in: store)
        }
        if step.current.apps.isEmpty {
            // The folder event can come before the file is written.
            step = try await change(store, "add file") { try put(Self.good + "\n", "say-hi.yaml", in: store) }
        }
        XCTAssertEqual(store.catalog.apps.map(\.id), ["say-hi"])

        // Another file is added.
        step = try await change(store, "add second") { try put(Self.good, "second.yaml", in: store) }
        XCTAssertEqual(step.current.apps.map(\.id), ["say-hi", "second"])
        XCTAssertNil(step.current.toastMessage(since: step.previous))

        // A file is changed in place and breaks: the change brings a toast.
        step = try await change(store, "break") {
            let handle = try FileHandle(forWritingTo: store.folderURL.appendingPathComponent("second.yaml"))
            try handle.seekToEnd()
            try handle.write(contentsOf: Data("unknown: 1\n".utf8))
            try handle.close()
        }
        XCTAssertEqual(step.current.brokenFiles, ["second.yaml"])
        XCTAssertNotNil(step.current.toastMessage(since: step.previous))
        XCTAssertTrue(try log(store).hasPrefix("second.yaml:"))

        // The broken file is removed.
        step = try await change(store, "remove") {
            try FileManager.default.removeItem(at: store.folderURL.appendingPathComponent("second.yaml"))
        }
        XCTAssertEqual(step.current.entries.map(\.file), ["say-hi.yaml"])
        XCTAssertTrue(step.current.issues.isEmpty)
        XCTAssertEqual(try log(store), "")
    }

    func testMaxTimeLimitControlsCatalogValidationAndAppModelReloadsOnChange() throws {
        let configURL = try temporaryConfig()
        let store = MicroAppStore(configURL: configURL, environment: [:])
        try makeFolder(store)
        let longApp = """
        format: ting.microapp/2
        description: Deploy over SSH.
        timeout: 900
        input: none
        command: echo deploy
        output:
          to: [panel]

        """
        try put(longApp, "deploy.yaml", in: store)

        // Default 300s cap rejects timeout: 900.
        XCTAssertEqual(store.load().brokenFiles, ["deploy.yaml"])

        // Raising maxTimeLimit allows it to load cleanly.
        store.maxTimeLimit = 1200
        let catalog = store.load()
        XCTAssertTrue(catalog.issues.isEmpty)
        XCTAssertEqual(catalog.apps.first?.timeLimit, 900)

        // AppModel reloads micro-apps automatically when config.microApps.maxTimeout changes.
        let model = AppModel(presentsWindows: false, store: ConfigStore(url: configURL))
        let appMicroDir = MicroAppStore.folderURL(configURL: configURL, environment: ["TING_CONFIG": configURL.path])
        try FileManager.default.createDirectory(at: appMicroDir, withIntermediateDirectories: true)
        try Data(longApp.utf8).write(to: appMicroDir.appendingPathComponent("deploy.yaml"))
        model.reload()
        XCTAssertFalse(model.microAppIssues.isEmpty)

        model.update { $0.microApps.maxTimeout = 1800 }
        XCTAssertTrue(model.microAppIssues.isEmpty)
        XCTAssertEqual(model.microApps.first?.app?.timeLimit, 900)
    }
}

@MainActor final class MicroIconSettingsTests: XCTestCase {
    /// An icon set in Settings is written to `microIcons` and reaches the leader menu at once; the micro-app file is not touched.
    func testSettingAnIconReachesTheLeaderMenuAndKeepsTheFile() throws {
        _ = NSApplication.shared
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ting-micro-icon-" + UUID().uuidString)
        let store = ConfigStore(url: dir.appendingPathComponent("config.json"))
        let folder = MicroAppStore.folderURL(configURL: store.url)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        let file = folder.appendingPathComponent("a.yaml")
        let text = "format: ting.microapp/2\nicon: 🌐\ndescription: d\ninput: none\ncommand: x\n"
        try text.write(to: file, atomically: true, encoding: .utf8)
        let model = AppModel(presentsWindows: false, store: store)
        model.reload()
        XCTAssertEqual(model.leader.session.microApps.icon("a"), .glyph("🌐"))

        model.setMicroIcon("🚀", for: "a")
        XCTAssertEqual(model.config.microIcons, ["a": "🚀"])
        XCTAssertEqual(model.microCatalog.icon("a"), .glyph("🚀"))
        XCTAssertEqual(model.leader.session.microApps.icon("a"), .glyph("🚀"))
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), text)

        model.setMicroIcon(nil, for: "a")
        XCTAssertEqual(model.config.microIcons, [:])
        XCTAssertEqual(model.leader.session.microApps.icon("a"), .glyph("🌐"))
    }
}

// Loads and watches the micro-apps folder (`micro/` next to the config file) and writes
// `micro-errors.log` next to the config file on each load.
import Foundation
import TingCore

@MainActor
final class MicroAppStore {
    /// Larger files are reported, not read.
    nonisolated static let maxFileSize = MicroAppChecker.maxFileSize

    let folderURL: URL
    let logURL: URL
    /// Maximum allowed `timeout` when checking micro-app files (`Config.microApps.maxTimeout`).
    var maxTimeLimit: Int = MicroAppChecker.maxTimeLimit
    private(set) var catalog = MicroAppCatalog()
    /// Called on each load of the folder, also the loads that the watch makes.
    var onLoad: (() -> Void)?

    private var sources: [DispatchSourceFileSystemObject] = []
    private var pendingReload: DispatchWorkItem?
    private var onChange: ((_ previous: MicroAppCatalog, _ current: MicroAppCatalog) -> Void)?

    /// `micro/` and `micro-errors.log` next to the config file. With `TING_CONFIG` set, both get
    /// the config file name in front, like the launcha files: `TING_CONFIG=/tmp/ting-test.json`
    /// uses `/tmp/ting-test.json.micro/` and `/tmp/ting-test.json.micro-errors.log`, so two
    /// overrides in one directory never share a folder.
    init(configURL: URL, environment: [String: String] = ProcessInfo.processInfo.environment) {
        folderURL = Self.folderURL(configURL: configURL, environment: environment)
        if let override = environment["TING_CONFIG"], !override.isEmpty {
            logURL = configURL.appendingPathExtension("micro-errors.log")
        } else {
            logURL = configURL.deletingLastPathComponent().appendingPathComponent("micro-errors.log")
        }
    }

    /// The micro-apps folder of a config file, without making a store (and without reading anything).
    nonisolated static func folderURL(configURL: URL, environment: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        if let override = environment["TING_CONFIG"], !override.isEmpty {
            return configURL.appendingPathExtension("micro")
        }
        return configURL.deletingLastPathComponent().appendingPathComponent("micro", isDirectory: true)
    }

    /// `libs/` inside the micro-apps folder: the library files.
    var librariesURL: URL { folderURL.appendingPathComponent(MicroAppLibraries.folderName, isDirectory: true) }

    var displayPath: String { Self.display(folderURL) }
    var logDisplayPath: String { Self.display(logURL) }

    private static func display(_ url: URL) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return url.path.hasPrefix(home + "/") ? "~" + url.path.dropFirst(home.count) : url.path
    }

    /// Reads every `*.yaml` file of the folder. A missing folder gives an empty list, not an error.
    @discardableResult
    func load() -> MicroAppCatalog {
        onLoad?()
        let libraries = MicroAppLibraries.read(folder: librariesURL)
        catalog = MicroAppCatalog.build(hashed: readFiles(libraries: libraries))
        catalog.libraryIssues = MicroAppCatalog.checkLibraries(libraries, maxTimeLimit: maxTimeLimit)
        writeLog()
        return catalog
    }

    /// Installs without running or approving the app. Check the live folder, not the watched
    /// snapshot: a local file may have appeared while the download was in flight.
    func installFromGallery(_ data: Data, listing: MicroAppGallery.Listing) throws {
        try listing.validate(data, maxTimeLimit: maxTimeLimit)
        try SafeFile.prepareDirectory(folderURL)
        let existing = readFiles(libraries: MicroAppLibraries.read(folder: librariesURL))
        guard !existing.contains(where: { file, result, _ in
            if file == listing.fileName { return true }
            switch result {
            case .success(let app): return app.id == listing.id
            case .failure(let problem): return problem.id == listing.id
            }
        }) else { throw MicroAppGallery.Problem.alreadyExists }

        let destination = folderURL.appendingPathComponent(listing.fileName)
        let staged = folderURL.appendingPathComponent(".gallery-\(UUID().uuidString)")
        try SafeFile.write(data, to: staged)
        defer { try? FileManager.default.removeItem(at: staged) }
        // A hard link publishes the complete file atomically and fails if anything (even a
        // dangling symlink) already occupies the destination. The watcher ignores the stage file.
        guard link(staged.path, destination.path) == 0 else {
            let code = errno
            if code == EEXIST { throw MicroAppGallery.Problem.alreadyExists }
            throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
        }
    }

    /// Loads again after every change in the folder, in its files, or when the folder appears
    /// or disappears. `onChange` gets the list before and after the change.
    func watch(onChange: @escaping (_ previous: MicroAppCatalog, _ current: MicroAppCatalog) -> Void) {
        self.onChange = onChange
        rewatch()
    }

    func stopWatching() {
        onChange = nil
        pendingReload?.cancel()
        sources.forEach { $0.cancel() }
        sources = []
    }

    // MARK: Private

    private func readFiles(libraries: MicroAppLibraries) -> [(file: String, result: Result<MicroApp, MicroAppFailure>, hash: String)] {
        let manager = FileManager.default
        guard let names = try? manager.contentsOfDirectory(atPath: folderURL.path) else { return [] }
        return names.filter(Self.isMicroAppFile).compactMap { name in
            let url = folderURL.appendingPathComponent(name)
            var isDirectory: ObjCBool = false
            guard manager.fileExists(atPath: url.path, isDirectory: &isDirectory), !isDirectory.boolValue else { return nil }
            func failure(_ message: String, hash: String = "") -> (String, Result<MicroApp, MicroAppFailure>, String) {
                (name, .failure(MicroAppFailure(issues: [MicroAppIssue(file: name, line: 1, message: message)])), hash)
            }
            let size = (try? manager.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
            if size > Self.maxFileSize { return failure(MicroAppChecker.tooLargeMessage) }
            do {
                let data = try Data(contentsOf: url)
                // The hash is of exactly the bytes that were checked, so an approval covers what runs.
                let hash = MicroAppApprovals.hash(data)
                guard let text = String(data: data, encoding: .utf8) else { return failure(MicroAppChecker.notUTF8Message, hash: hash) }
                return (name, MicroAppChecker.check(text, fileName: name, libraries: libraries, maxTimeLimit: maxTimeLimit), hash)
            } catch {
                return failure("cannot read the file: \(error.localizedDescription)")
            }
        }
    }

    nonisolated static func isMicroAppFile(_ name: String) -> Bool {
        !name.hasPrefix(".") && name.hasSuffix("." + MicroAppChecker.fileExtension)
    }

    /// Written again on each load; empty when all files are good. Skipped when the config
    /// directory does not exist. An unchanged log is left alone: writing it would wake the
    /// directory watch and load again in a loop.
    private func writeLog() {
        let directory = logURL.deletingLastPathComponent()
        guard FileManager.default.fileExists(atPath: directory.path) else { return }
        let data = Data(catalog.logText.utf8)
        if FileManager.default.fileExists(atPath: logURL.path), (try? Data(contentsOf: logURL)) == data { return }
        // In place: a log needs no atomic replace, and no rename event wakes the directory watch.
        try? data.write(to: logURL)
    }

    private func rewatch() {
        sources.forEach { $0.cancel() }
        sources = []
        guard onChange != nil else { return }
        // The config directory, for the folder appearing or disappearing.
        var paths = [folderURL.deletingLastPathComponent().path, folderURL.path]
        // Each file, for in-place saves that do not touch the folder.
        if let names = try? FileManager.default.contentsOfDirectory(atPath: folderURL.path) {
            paths += names.filter(Self.isMicroAppFile).map { folderURL.appendingPathComponent($0).path }
        }
        // The libraries folder and its files: a change of a library changes the micro-apps that use it.
        paths.append(librariesURL.path)
        if let names = try? FileManager.default.contentsOfDirectory(atPath: librariesURL.path) {
            paths += names.filter(Self.isMicroAppFile).map { librariesURL.appendingPathComponent($0).path }
        }
        sources = paths.compactMap(makeSource)
    }

    private func makeSource(path: String) -> DispatchSourceFileSystemObject? {
        let descriptor = open(path, O_EVTONLY)
        guard descriptor >= 0 else { return nil }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: descriptor,
                                                               eventMask: [.write, .delete, .rename, .extend],
                                                               queue: .main)
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.scheduleReload() }
        }
        source.setCancelHandler { close(descriptor) }
        source.resume()
        return source
    }

    /// Coalesces bursts of events from one save.
    private func scheduleReload() {
        pendingReload?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self, let onChange = self.onChange else { return }
                let previous = self.catalog
                let current = self.load()
                self.rewatch()
                if current != previous { onChange(previous, current) }
            }
        }
        pendingReload = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work)
    }
}

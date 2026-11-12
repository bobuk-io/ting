// Reads, writes and watches the config file (`~/.config/ting/config.json`, or `$TING_CONFIG`).
import Foundation
import TingCore

@MainActor
final class ConfigStore {
    enum LoadError: Error {
        case missing
        case unreadable(String)
        case invalid(ConfigError)

        var message: String {
            switch self {
            case .missing: "The config file is missing. Ting keeps the last good settings."
            case .unreadable(let reason): "Cannot read the config file: \(reason)"
            case .invalid(.invalidFormat(let reason)): "Config error: \(reason)"
            case .invalid(.unsupportedVersion(let version)): "Config version \(version) needs a newer Ting."
            }
        }
    }

    let url: URL
    private var directorySource: DispatchSourceFileSystemObject?
    private var fileSource: DispatchSourceFileSystemObject?
    private var pendingReload: DispatchWorkItem?
    private var onChange: (() -> Void)?

    init(url: URL = ConfigStore.defaultURL()) {
        self.url = url
    }

    /// `$TING_CONFIG` when set (handy for manual checks), else `~/.config/ting/config.json`.
    nonisolated static func defaultURL(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        if let override = environment["TING_CONFIG"], !override.isEmpty {
            return URL(fileURLWithPath: (override as NSString).expandingTildeInPath).standardizedFileURL
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/ting/config.json")
    }

    var displayPath: String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return url.path.hasPrefix(home + "/") ? "~" + url.path.dropFirst(home.count) : url.path
    }

    var fileExists: Bool { FileManager.default.fileExists(atPath: url.path) }

    func load() -> Result<Config, LoadError> {
        guard fileExists else { return .failure(.missing) }
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            return .failure(.unreadable(error.localizedDescription))
        }
        do {
            return .success(try ConfigCodec.decode(data))
        } catch let error as ConfigError {
            return .failure(.invalid(error))
        } catch {
            return .failure(.unreadable(error.localizedDescription))
        }
    }

    /// Atomic write; creates the directory when needed.
    func write(_ config: Config) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try ConfigCodec.encode(config).write(to: url, options: .atomic)
        watchFile()
    }

    /// Watches the directory (editors often replace the file) and the file itself (in-place saves).
    func watch(onChange: @escaping () -> Void) {
        self.onChange = onChange
        directorySource?.cancel()
        directorySource = makeSource(path: url.deletingLastPathComponent().path)
        watchFile()
    }

    private func watchFile() {
        guard onChange != nil else { return }
        fileSource?.cancel()
        fileSource = makeSource(path: url.path)
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
                guard let self else { return }
                self.watchFile()
                self.onChange?()
            }
        }
        pendingReload = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work)
    }
}

import Darwin
import Foundation
import TingCore

/// Headless front end to the exact engine used by Ting. No config, approvals, remembered values,
/// clipboard reads/writes or panels. Naming a file with `run` explicitly authorizes its execution.
package enum MicroAppCLI {
    package static let usage = """
    Usage:
      ting-micro check [--libs DIR] FILE.yaml [FILE.yaml ...]
      ting-micro check-config [CONFIG.json]
      ting-micro run FILE.yaml [--param NAME=VALUE ...] [--context SOURCE.FIELD=VALUE ...] [--input TEXT] [--timeout SECONDS]
                     [--libs DIR] [--verbose] [--allow-effects]

    check-config reads config.json (default: $TING_CONFIG, else ~/.config/ting/config.json) and
    reports format errors, binding problems and micro bindings or microHotkeys to ids that the
    micro-apps folder next to it does not have. It changes nothing.
    Libraries (call, inherit) come from libs/ next to FILE.yaml, or from --libs DIR.
    A file inside a folder named libs is checked as a library.

    Input: piped stdin, or --input TEXT; empty when stdin is a terminal.
    Output: the final result on stdout; diagnostics and optional step progress on stderr.
    YAML output.to is ignored: the clipboard is never read or changed.
    Context: run never reads the active app, Finder, the browser or the selection. --context gives
    a value, such as --context app.name=Safari; every other value of the file's context is empty.
    keys and paste steps never send anything: each prints a note on stderr and passes its input on.
    ask, choose and preview require Ting's interactive panel; run rejects them before running any steps.
    --allow-effects permits open, notify and lowkey steps (disabled by default).
    Shell/Python and HTTP/AI steps run with your full rights and may change files or cost money.
    Environment variables come from this terminal, not a second login shell.
    No config, approvals or remembered values are read or written.

    Exit codes: 0 success, 1 script/check failure, 2 usage/input error, 124 timeout, 130 cancelled.
    """

    struct Options: Equatable {
        var file: String
        var params: [String: String] = [:]
        var context = MicroAppContext()
        var input: String?
        var timeout: TimeInterval?
        var verbose = false
        var allowEffects = false
        var libs: String?
    }

    struct UsageError: Error, CustomStringConvertible {
        var description: String
        init(_ text: String) { description = text }
    }

    static func parse(_ args: [String], maxTimeLimit: Int = MicroAppChecker.maxTimeLimit) throws -> Options {
        guard let file = args.first, !file.hasPrefix("-") else { throw UsageError("run needs a YAML file") }
        var options = Options(file: file)
        var i = 1
        while i < args.count {
            let flag = args[i]
            i += 1
            switch flag {
            case "--verbose": options.verbose = true
            case "--allow-effects": options.allowEffects = true
            case "--libs":
                guard i < args.count else { throw UsageError("--libs needs a folder") }
                options.libs = args[i]; i += 1
            case "--param", "--context", "--input", "--timeout":
                guard i < args.count else { throw UsageError("\(flag) needs a value") }
                let value = args[i]; i += 1
                switch flag {
                case "--param":
                    guard let eq = value.firstIndex(of: "="), eq != value.startIndex else {
                        throw UsageError("--param needs NAME=VALUE")
                    }
                    let name = String(value[..<eq])
                    guard options.params[name] == nil else { throw UsageError("duplicate parameter `\(name)`") }
                    options.params[name] = String(value[value.index(after: eq)...])
                case "--context":
                    guard let eq = value.firstIndex(of: "="), eq != value.startIndex else {
                        throw UsageError("--context needs SOURCE.FIELD=VALUE, such as app.name=Safari")
                    }
                    let name = String(value[..<eq])
                    let parts = name.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
                    guard parts.count == 2, let source = MicroAppContextSource(rawValue: parts[0]),
                          let field = MicroAppContextField(source: source, name: parts[1]) else {
                        let known = MicroAppContextField.all.map(\.description).joined(separator: ", ")
                        throw UsageError("unknown context value `\(name)`; use one of: \(known)")
                    }
                    guard options.context.values[field] == nil else { throw UsageError("duplicate context value `\(name)`") }
                    options.context[field] = String(value[value.index(after: eq)...])
                case "--input":
                    guard options.input == nil else { throw UsageError("--input was given twice") }
                    options.input = value
                default:
                    guard let n = Int(value), (1...maxTimeLimit).contains(n) else {
                        throw UsageError("--timeout must be from 1 to \(maxTimeLimit) seconds")
                    }
                    options.timeout = TimeInterval(n)
                }
            default: throw UsageError("unknown option `\(flag)`")
            }
        }
        return options
    }

    static func load(_ file: String, libs: String? = nil, maxTimeLimit: Int = MicroAppChecker.maxTimeLimit) throws -> MicroApp {
        guard file.hasSuffix(".yaml") else { throw UsageError("a script file must end in .yaml") }
        let handle: FileHandle
        do { handle = try FileHandle(forReadingFrom: URL(fileURLWithPath: file)) }
        catch { throw UsageError("cannot read \(file): \(error.localizedDescription)") }
        defer { try? handle.close() }
        let data = try handle.read(upToCount: MicroAppChecker.maxFileSize + 1) ?? Data()
        guard data.count <= MicroAppChecker.maxFileSize else { throw UsageError(MicroAppChecker.tooLargeMessage) }
        guard let text = String(data: data, encoding: .utf8) else { throw UsageError(MicroAppChecker.notUTF8Message) }
        let folder = libs.map { URL(fileURLWithPath: $0, isDirectory: true) } ?? MicroAppCheckCommand.libraryFolder(for: file)
        return try MicroAppChecker.check(text, fileName: file, libraries: MicroAppLibraries.read(folder: folder),
                                         maxTimeLimit: maxTimeLimit).get()
    }

    static func validate(_ options: Options, app: MicroApp) throws {
        for name in options.params.keys.sorted() where !app.params.contains(where: { $0.name == name }) {
            throw UsageError("unknown parameter `\(name)`")
        }
        for param in app.params {
            let value = options.params[param.name] ?? param.defaultValue
            if param.required && (value == nil || value!.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) {
                throw UsageError("missing required parameter: --param \(param.name)=VALUE")
            }
            if case .choice(let choices) = param.kind, let value, !choices.contains(value) {
                throw UsageError("parameter `\(param.name)` must be one of: \(choices.joined(separator: ", "))")
            }
        }
        let sources = app.requiredContext
        for field in options.context.values.keys.sorted(by: { $0.description < $1.description }) where !sources.contains(field.source) {
            throw UsageError("the file does not read `\(field.source.rawValue)`: add it to `context:` or leave out --context \(field)")
        }
        if app.allSteps.contains(where: { [.ask, .choose, .preview].contains($0.kind) }) {
            throw UsageError("ask, choose and preview steps require Ting's interactive panel; no steps were run")
        }
        if !options.allowEffects {
            if let step = app.allSteps.first(where: { [.open, .notify, .lowkey].contains($0.kind) }) {
                throw UsageError("`\(step.kind.rawValue)` requires --allow-effects; no steps were run")
            }
            if app.allSteps.contains(where: {
                if case .chatta(let c) = $0.action, c.access == .write { return true }
                return false
            }) {
                throw UsageError("`chatta` with `access: write` requires --allow-effects; no steps were run")
            }
        }
    }

    package static func main(_ args: [String]) async -> Int32 {
        if args.isEmpty || args == ["--help"] || args == ["-h"] {
            out(usage + "\n")
            return 0
        }
        if args.first == "check-config" {
            return checkConfig(Array(args.dropFirst()))
        }
        if args.first == "check" || args.first == "--check" {
            var files = Array(args.dropFirst())
            var libs: String?
            if let at = files.firstIndex(of: "--libs") {
                guard at + 1 < files.count else { err("ting-micro: --libs needs a folder\n"); return 2 }
                libs = files[at + 1]
                files.removeSubrange(at...(at + 1))
            }
            let maxTimeLimit = configuredMaxTimeLimit()
            let report = MicroAppCheckCommand.run(files, read: { path in
                let handle = try FileHandle(forReadingFrom: URL(fileURLWithPath: path))
                defer { try? handle.close() }
                return try handle.read(upToCount: MicroAppChecker.maxFileSize + 1) ?? Data()
            }, libraries: { path in
                MicroAppLibraries.read(folder: libs.map { URL(fileURLWithPath: $0, isDirectory: true) }
                    ?? MicroAppCheckCommand.libraryFolder(for: path))
            }, maxTimeLimit: maxTimeLimit)
            // Uses the same checker as Ting --check, including duplicate-id validation.
            report.output.forEach { out($0 + "\n") }
            report.errors.forEach { err($0.replacingOccurrences(of: "Ting --check", with: "ting-micro check") + "\n") }
            return report.exitCode
        }
        do {
            guard args.first == "run" else { throw UsageError("expected `run` or `check`; use --help") }
            let maxTimeLimit = configuredMaxTimeLimit()
            let options = try parse(Array(args.dropFirst()), maxTimeLimit: maxTimeLimit)
            let app = try load(options.file, libs: options.libs, maxTimeLimit: maxTimeLimit)
            try validate(options, app: app)
            let input: String
            if let text = options.input { input = text }
            else if isatty(STDIN_FILENO) == 0 {
                let bytes = FileHandle.standardInput.readDataToEndOfFile()
                guard let text = String(data: bytes, encoding: .utf8) else { throw UsageError("stdin is not UTF-8 text") }
                input = text
            } else { input = "" }
            var runner = MicroAppRunner()
            let environment = ProcessInfo.processInfo.environment
            let path = environment["PATH"] ?? MicroAppRunRules.defaultPATH
            runner.environment = environment
            runner.path = { path }
            runner.timeLimit = options.timeout
            runner.chattaDefaults = configuredChattaDefaults()
            // CLI runs in the current folder, like other console programs.
            runner.workingDirectory = FileManager.default.currentDirectoryPath
            // Keys and text would go to this terminal: the console tool only says what Ting would send.
            runner.keyboard = { action in err("ting-micro: \(action.summary): not sent; only Ting sends to an app\n") }
            let verbose = options.verbose
            let progress: (@Sendable (MicroAppRunProgress) -> Void)?
            if verbose {
                progress = { update in
                    if update.liveOutput == nil { err(update.label + "\n") }
                }
            } else { progress = nil }
            let task = Task<MicroAppRunResult, Never> {
                await runner.run(app, values: options.params, stdin: input, context: options.context, progress: progress)
            }
            // Dispatch signal handlers cancel the task, which stops child process groups and HTTP.
            signal(SIGINT, SIG_IGN)
            signal(SIGTERM, SIG_IGN)
            let signals = [SIGINT, SIGTERM].map { number in
                let source = DispatchSource.makeSignalSource(signal: number, queue: .global())
                source.setEventHandler { task.cancel() }
                source.resume()
                return source
            }
            let result = await task.value
            signals.forEach { $0.cancel() }
            return report(result)
        } catch let failure as MicroAppFailure {
            err(failure.description + "\n")
            return 1
        } catch {
            err("ting-micro: \(error)\n")
            return 2
        }
    }

    /// The default config file: `$TING_CONFIG`, else `~/.config/ting/config.json`.
    static func defaultConfigPath(environment: [String: String] = ProcessInfo.processInfo.environment) -> String {
        if let override = environment["TING_CONFIG"], !override.isEmpty { return override }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config/ting/config.json").path
    }

    /// Reads `microApps.maxTimeout` from the default config file, falling back to `MicroAppChecker.maxTimeLimit`.
    static func configuredMaxTimeLimit(environment: [String: String] = ProcessInfo.processInfo.environment) -> Int {
        let path = defaultConfigPath(environment: environment)
        guard let data = FileManager.default.contents(atPath: path),
              let config = try? ConfigCodec.decode(data) else { return MicroAppChecker.maxTimeLimit }
        return config.microApps.maxTimeout
    }

    /// Reads `chatta` defaults from the default config file, falling back to `ChattaSettings()`.
    static func configuredChattaDefaults(environment: [String: String] = ProcessInfo.processInfo.environment) -> ChattaSettings {
        let path = defaultConfigPath(environment: environment)
        guard let data = FileManager.default.contents(atPath: path),
              let config = try? ConfigCodec.decode(data) else { return ChattaSettings() }
        return config.chatta
    }

    /// The micro-apps folder of a config file, as Ting finds it.
    static func microFolder(configPath: String, environment: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        let url = URL(fileURLWithPath: configPath)
        if let override = environment["TING_CONFIG"], !override.isEmpty, override == configPath { return url.appendingPathExtension("micro") }
        return url.deletingLastPathComponent().appendingPathComponent("micro", isDirectory: true)
    }

    static func checkConfig(_ args: [String]) -> Int32 {
        guard args.count <= 1, !(args.first?.hasPrefix("-") ?? false) else {
            err("usage: ting-micro check-config [CONFIG.json]\n")
            return 2
        }
        let path = args.first ?? defaultConfigPath()
        guard let data = FileManager.default.contents(atPath: path) else {
            err("ting-micro check-config: cannot read \(path)\n")
            return 2
        }
        let config: Config
        do {
            config = try ConfigCodec.decode(data)
        } catch ConfigError.invalidFormat(let reason) {
            out("\(path): \(reason)\n")
            return 1
        } catch ConfigError.unsupportedVersion(let version) {
            out("\(path): version \(version) is newer than this Ting understands\n")
            return 1
        } catch {
            out("\(path): \(error)\n")
            return 1
        }
        var problems = ConfigValidator.validate(config).map { issue in
            issue.sequence.isEmpty ? issue.message : "\(issue.sequence.joined(separator: " ")): \(issue.message)"
        }
        // Micro-app bindings must name a micro-app that loads.
        let folder = microFolder(configPath: path)
        let libraries = MicroAppLibraries.read(folder: folder.appendingPathComponent(MicroAppLibraries.folderName))
        let files = ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? [])
            .filter { $0.hasSuffix(".yaml") && !$0.hasPrefix(".") }.sorted()
            .compactMap { name -> (name: String, text: String)? in
                guard let data = FileManager.default.contents(atPath: folder.appendingPathComponent(name).path),
                      let text = String(data: data, encoding: .utf8) else { return nil }
                return (name, text)
            }
        let catalog = MicroAppCatalog.load(files, libraries: libraries, maxTimeLimit: config.microApps.maxTimeout)
        func walk(_ items: [Item], _ prefix: [String]) {
            for item in items {
                let sequence = prefix + [item.key]
                switch item.action {
                case .group(let children): walk(children, sequence)
                case .micro(let id):
                    if let problem = catalog.resolve(id).problem(id: id, folder: folder.path) {
                        problems.append("\(sequence.joined(separator: " ")): \(problem)")
                    }
                default: break
                }
            }
        }
        walk(config.items, [])
        for shortcut in config.microHotkeys where shortcut.hasTarget {
            if let problem = catalog.resolve(shortcut.micro).problem(id: shortcut.micro, folder: folder.path) {
                problems.append("\(shortcut.hotkey.display): \(problem)")
            }
        }
        for (micro, icon) in config.microIcons.sorted(by: { $0.key < $1.key }) where MicroIcon(icon) == nil {
            problems.append("microIcons: the icon of `\(micro)` must be \(MicroIcon.rule)")
        }
        if problems.isEmpty {
            out("\(path): ok\n")
            return 0
        }
        problems.forEach { out("\(path): \($0)\n") }
        return 1
    }

    static func report(_ result: MicroAppRunResult) -> Int32 {
        switch result {
        case .success(let output):
            if !output.stdout.isEmpty { out(output.stdout + "\n") }
            if !output.stderr.isEmpty { err(output.stderr) }
            if output.stdoutCut || output.stderrCut { err(MicroAppResultPlan.cutNote() + "\n") }
            return 0
        case .cancelled: err("cancelled\n"); return 130
        case .timeout(let output):
            err("timeout\n" + output.stderr + output.stdout + "\n")
            return 124
        case .toolNotFound(let name): err("tool not found: \(name)\n"); return 1
        case .failure(let code, let output):
            err("exit \(code)\n" + output.stderr + output.stdout + "\n")
            return 1
        case .stepFailed(let failure):
            err("\(failure.stepNote): \(failure.note)\n" + failure.output.stderr + "\n" + failure.output.stdout)
            if !failure.output.stdout.isEmpty { err("\n") }
            if failure.note.hasPrefix("stopped after ") { return 124 }
            return 1
        }
    }

    static func out(_ text: String) { FileHandle.standardOutput.write(Data(text.utf8)) }
    static func err(_ text: String) { FileHandle.standardError.write(Data(text.utf8)) }
}

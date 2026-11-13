import Foundation

/// One binding: a key and what it does.
public struct Item: Equatable, Sendable, Codable {
    public enum Action: Equatable, Sendable {
        case group([Item])
        /// Bundle identifier, e.g. "com.apple.Safari".
        case app(String)
        /// Absolute URL string, e.g. "https://github.com".
        case url(String)
    }

    /// A `SequenceKey` name.
    public var key: String
    public var label: String
    public var action: Action

    public init(key: String, label: String, action: Action) {
        self.key = key
        self.label = label
        self.action = action
    }

    public static func group(_ key: String, _ label: String, _ items: [Item]) -> Item { Item(key: key, label: label, action: .group(items)) }
    public static func app(_ key: String, _ label: String, _ bundleID: String) -> Item { Item(key: key, label: label, action: .app(bundleID)) }
    public static func url(_ key: String, _ label: String, _ url: String) -> Item { Item(key: key, label: label, action: .url(url)) }

    public var isGroup: Bool {
        if case .group = action { return true }
        return false
    }
    /// Children of a group; nil for an action.
    public var children: [Item]? {
        if case .group(let items) = action { return items }
        return nil
    }

    // JSON: {"key": "a", "label": "Apps", "items": [...]} | {..., "app": "com.x"} | {..., "url": "https://..."}.
    // Decoding: exactly one of "items"/"app"/"url" must be present; "key" is normalized with
    // SequenceKey.normalize ("A" → "a"); an invalid key or a wrong number of action fields throws
    // DecodingError.dataCorrupted. "label" is optional and defaults to "".
    // Unknown fields are ignored. Encoding writes "key", "label" and exactly one action field.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: ItemCodingKeys.self)
        let rawKey = try container.decode(String.self, forKey: .key)
        guard let key = SequenceKey.normalize(rawKey) else {
            throw DecodingError.dataCorruptedError(forKey: .key, in: container,
                                                   debugDescription: "Invalid key \"\(rawKey)\". Use a letter, a digit, space, return or f1...f20.")
        }
        let items = try container.decodeIfPresent([Item].self, forKey: .items)
        let app = try container.decodeIfPresent(String.self, forKey: .app)
        let url = try container.decodeIfPresent(String.self, forKey: .url)
        let actions: [Action] = [items.map(Action.group), app.map(Action.app), url.map(Action.url)].compactMap { $0 }
        guard actions.count == 1, let action = actions.first else {
            throw DecodingError.dataCorrupted(DecodingError.Context(
                codingPath: container.codingPath,
                debugDescription: "Item \"\(rawKey)\" needs exactly one of \"items\", \"app\" or \"url\"."))
        }
        self.key = key
        self.label = try container.decodeIfPresent(String.self, forKey: .label) ?? ""
        self.action = action
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: ItemCodingKeys.self)
        try container.encode(key, forKey: .key)
        try container.encode(label, forKey: .label)
        switch action {
        case .group(let items): try container.encode(items, forKey: .items)
        case .app(let bundleID): try container.encode(bundleID, forKey: .app)
        case .url(let url): try container.encode(url, forKey: .url)
        }
    }

    private enum ItemCodingKeys: String, CodingKey {
        case key, label, items, app, url
    }
}

public enum UnknownKeyBehavior: String, Codable, Sendable, CaseIterable {
    case shake, close
}

public enum Appearance: String, Codable, Sendable, CaseIterable {
    case dark, light
}

/// Launcha settings: the name search panel.
/// JSON: {"hotkey": Hotkey string or null, "doubleTap": Bool, "doubleTapWindow": seconds}.
/// Every key is optional when decoding; a missing key takes the default below.
public struct LaunchaSettings: Equatable, Sendable, Codable {
    /// Allowed range of `doubleTapWindow`. Decoding clamps to it.
    public static let doubleTapWindowRange: ClosedRange<Double> = 0.1...1.0

    /// Separate global hotkey for launcha. nil (default) means no separate hotkey.
    public var hotkey: Hotkey? = nil
    /// A double tap of the leader opens launcha. On by default.
    public var doubleTap: Bool = true
    /// Maximum seconds between the two leader presses of a double tap.
    public var doubleTapWindow: Double = 0.3

    public init() {}

    private enum CodingKeys: String, CodingKey {
        case hotkey, doubleTap, doubleTapWindow
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = LaunchaSettings()
        hotkey = try container.decodeIfPresent(Hotkey.self, forKey: .hotkey)
        doubleTap = try container.decodeIfPresent(Bool.self, forKey: .doubleTap) ?? defaults.doubleTap
        let window = try container.decodeIfPresent(Double.self, forKey: .doubleTapWindow) ?? defaults.doubleTapWindow
        let range = LaunchaSettings.doubleTapWindowRange
        doubleTapWindow = min(max(window, range.lowerBound), range.upperBound)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        if let hotkey {
            try container.encode(hotkey, forKey: .hotkey)
        } else {
            try container.encodeNil(forKey: .hotkey)
        }
        try container.encode(doubleTap, forKey: .doubleTap)
        try container.encode(doubleTapWindow, forKey: .doubleTapWindow)
    }
}

/// The whole config file (`~/.config/ting/config.json`).
/// JSON keys: "version", "leader" (Hotkey string or null), "showDelay", "unknownKey",
/// "appearance", "launchAtLogin", "showMenuBarIcon", "showPanelHeader", "playSound",
/// "launcha" (`LaunchaSettings`), "items".
/// Every key is optional when decoding; a missing key takes the default below.
public struct Config: Equatable, Sendable, Codable {
    public static let currentVersion = 1

    public var version: Int = Config.currentVersion
    /// There is no default leader: nil until the user records one.
    public var leader: Hotkey? = nil
    /// Seconds before the menu becomes visible. Clamped to 0...2 when decoding.
    public var showDelay: Double = 0.25
    public var unknownKey: UnknownKeyBehavior = .shake
    /// Dark by default.
    public var appearance: Appearance = .dark
    public var launchAtLogin: Bool = false
    public var showMenuBarIcon: Bool = true
    /// Show the title row above selecta and launcha panels.
    public var showPanelHeader: Bool = true
    public var playSound: Bool = true
    /// Launcha settings. Older files without "launcha" get the defaults.
    public var launcha: LaunchaSettings = LaunchaSettings()
    public var items: [Item] = []

    public init() {}

    /// Sample config written on first launch: leader nil, a few groups
    /// ("a" Apps with Safari/Terminal/Finder, "w" Web with GitHub), valid per ConfigValidator.
    public static var sample: Config {
        var config = Config()
        config.items = [
            .group("a", "Apps", [
                .app("s", "Safari", "com.apple.Safari"),
                .app("t", "Terminal", "com.apple.Terminal"),
                .app("f", "Finder", "com.apple.finder"),
            ]),
            .group("w", "Web", [
                .url("g", "GitHub", "https://github.com"),
            ]),
        ]
        return config
    }

    private enum ConfigCodingKeys: String, CodingKey {
        case version, leader, showDelay, unknownKey, appearance, launchAtLogin, showMenuBarIcon, showPanelHeader, playSound, launcha, items
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: ConfigCodingKeys.self)
        let defaults = Config()
        version = try container.decodeIfPresent(Int.self, forKey: .version) ?? defaults.version
        leader = try container.decodeIfPresent(Hotkey.self, forKey: .leader)
        let delay = try container.decodeIfPresent(Double.self, forKey: .showDelay) ?? defaults.showDelay
        showDelay = min(max(delay, 0), 2)
        unknownKey = try container.decodeIfPresent(UnknownKeyBehavior.self, forKey: .unknownKey) ?? defaults.unknownKey
        appearance = try container.decodeIfPresent(Appearance.self, forKey: .appearance) ?? defaults.appearance
        launchAtLogin = try container.decodeIfPresent(Bool.self, forKey: .launchAtLogin) ?? defaults.launchAtLogin
        showMenuBarIcon = try container.decodeIfPresent(Bool.self, forKey: .showMenuBarIcon) ?? defaults.showMenuBarIcon
        showPanelHeader = try container.decodeIfPresent(Bool.self, forKey: .showPanelHeader) ?? defaults.showPanelHeader
        playSound = try container.decodeIfPresent(Bool.self, forKey: .playSound) ?? defaults.playSound
        launcha = try container.decodeIfPresent(LaunchaSettings.self, forKey: .launcha) ?? defaults.launcha
        items = try container.decodeIfPresent([Item].self, forKey: .items) ?? defaults.items
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: ConfigCodingKeys.self)
        try container.encode(version, forKey: .version)
        if let leader {
            try container.encode(leader, forKey: .leader)
        } else {
            try container.encodeNil(forKey: .leader)
        }
        try container.encode(showDelay, forKey: .showDelay)
        try container.encode(unknownKey, forKey: .unknownKey)
        try container.encode(appearance, forKey: .appearance)
        try container.encode(launchAtLogin, forKey: .launchAtLogin)
        try container.encode(showMenuBarIcon, forKey: .showMenuBarIcon)
        try container.encode(showPanelHeader, forKey: .showPanelHeader)
        try container.encode(playSound, forKey: .playSound)
        try container.encode(launcha, forKey: .launcha)
        try container.encode(items, forKey: .items)
    }
}

public enum ConfigError: Error, Equatable {
    /// Not JSON, or the JSON does not match the format. The string is a human-readable reason.
    case invalidFormat(String)
    /// "version" is greater than Config.currentVersion.
    case unsupportedVersion(Int)
}

public enum ConfigCodec {
    /// Decodes a config. Throws `ConfigError` only (wraps any DecodingError as `.invalidFormat`).
    public static func decode(_ data: Data) throws -> Config {
        let decoder = JSONDecoder()
        do {
            if let version = try decoder.decode(VersionProbe.self, from: data).version, version > Config.currentVersion {
                throw ConfigError.unsupportedVersion(version)
            }
            return try decoder.decode(Config.self, from: data)
        } catch let error as ConfigError {
            throw error
        } catch let error as DecodingError {
            throw ConfigError.invalidFormat(reason(for: error))
        } catch {
            throw ConfigError.invalidFormat(error.localizedDescription)
        }
    }

    /// Pretty-printed JSON with sorted keys, without escaped slashes, ending with "\n".
    /// `decode(encode(c)) == c` for every config.
    public static func encode(_ config: Config) -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        // Encoding a Config cannot fail: every field is a plain JSON value.
        var data = (try? encoder.encode(config)) ?? Data("{}".utf8)
        data.append(contentsOf: Array("\n".utf8))
        return data
    }

    /// Reads only "version", so a newer file is reported as such before its format is checked.
    private struct VersionProbe: Decodable {
        var version: Int?
    }

    private static func reason(for error: DecodingError) -> String {
        func at(_ path: [CodingKey], _ message: String) -> String {
            let location = path.reduce(into: "") { result, key in
                if let index = key.intValue {
                    result += "[\(index)]"
                } else {
                    result += result.isEmpty ? key.stringValue : "." + key.stringValue
                }
            }
            return location.isEmpty ? message : "\(location): \(message)"
        }
        switch error {
        case .dataCorrupted(let context):
            if context.codingPath.isEmpty, context.underlyingError != nil { return "Not valid JSON." }
            return at(context.codingPath, context.debugDescription)
        case .keyNotFound(let key, let context):
            return at(context.codingPath, "Missing \"\(key.stringValue)\".")
        case .typeMismatch(_, let context), .valueNotFound(_, let context):
            return at(context.codingPath, context.debugDescription)
        @unknown default:
            return error.localizedDescription
        }
    }
}

public struct ConfigIssue: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        /// Two items in one group use the same key.
        case duplicateKey
        /// An app with an empty bundle identifier, or a url with an empty string.
        case emptyTarget
        /// A url that does not parse as a URL with a scheme.
        case invalidURL
        /// The config has no leader yet.
        case missingLeader
        /// The leader is not `isValid`.
        case invalidLeader
        /// The launcha hotkey is not `isValid` (for example a modifier on its own).
        case invalidLaunchaHotkey
        /// The launcha hotkey is the same as the leader.
        case launchaHotkeyConflict
    }

    public var kind: Kind
    /// Key sequence of the item. Empty for leader and launcha hotkey issues.
    public var sequence: [String]
    public var message: String

    public init(kind: Kind, sequence: [String], message: String) {
        self.kind = kind
        self.sequence = sequence
        self.message = message
    }
}

public enum ConfigValidator {
    /// Leader issues first, then launcha hotkey issues, then all item issues depth-first in item order. For a duplicate key, report one issue per duplicate
    /// after the first, with the duplicate's sequence.
    public static func validate(_ config: Config) -> [ConfigIssue] {
        var issues: [ConfigIssue] = []
        if let leader = config.leader {
            if !leader.isValid {
                issues.append(ConfigIssue(kind: .invalidLeader, sequence: [],
                                          message: "\(leader.display) cannot be a leader. Choose a key that is not a modifier."))
            }
        } else {
            issues.append(ConfigIssue(kind: .missingLeader, sequence: [], message: "No leader key yet."))
        }
        if let hotkey = config.launcha.hotkey {
            if !hotkey.isValid {
                issues.append(ConfigIssue(kind: .invalidLaunchaHotkey, sequence: [],
                                          message: "\(hotkey.display) cannot open launcha. Choose a key that is not a modifier."))
            } else if hotkey == config.leader {
                issues.append(ConfigIssue(kind: .launchaHotkeyConflict, sequence: [],
                                          message: "\(hotkey.display) is already the leader. Choose another key for launcha."))
            }
        }
        validate(config.items, prefix: [], into: &issues)
        return issues
    }

    private static func validate(_ items: [Item], prefix: [String], into issues: inout [ConfigIssue]) {
        var seen: Set<String> = []
        for item in items {
            let sequence = prefix + [item.key]
            let name = sequence.map(SequenceKey.display).joined(separator: " ")
            if !seen.insert(item.key).inserted {
                issues.append(ConfigIssue(kind: .duplicateKey, sequence: sequence,
                                          message: "\(name) is used more than once."))
            }
            switch item.action {
            case .group(let children):
                validate(children, prefix: sequence, into: &issues)
            case .app(let bundleID):
                if bundleID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    issues.append(ConfigIssue(kind: .emptyTarget, sequence: sequence, message: "\(name) has no application."))
                }
            case .url(let url):
                if url.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    issues.append(ConfigIssue(kind: .emptyTarget, sequence: sequence, message: "\(name) has no URL."))
                } else if URL(string: url)?.scheme?.isEmpty ?? true {
                    issues.append(ConfigIssue(kind: .invalidURL, sequence: sequence, message: "\(name) has an invalid URL: \(url)"))
                }
            }
        }
    }
}

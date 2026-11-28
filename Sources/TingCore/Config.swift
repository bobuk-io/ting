import Foundation

/// A Ting window a binding can open.
public enum TingPanel: String, Equatable, Sendable, Codable, CaseIterable {
    case launcha, clipbawd, schedule, chatta
}

/// One binding: a key and what it does.
public struct Item: Equatable, Sendable, Codable {
    public enum Action: Equatable, Sendable {
        case group([Item])
        /// Bundle identifier, e.g. "com.apple.Safari".
        case app(String)
        /// Absolute URL string, e.g. "https://github.com".
        case url(String)
        /// A micro-app id, e.g. "format-json". The micro-app does not have to be loaded.
        case micro(String)
        /// A Ting window: launcha, clipbawd, schedule or chatta.
        case open(TingPanel)
        /// Move or resize the focused macOS window.
        case window(WindowCommand)
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
    public static func micro(_ key: String, _ label: String, _ id: String) -> Item { Item(key: key, label: label, action: .micro(id)) }
    public static func open(_ key: String, _ label: String, _ panel: TingPanel) -> Item { Item(key: key, label: label, action: .open(panel)) }
    public static func window(_ key: String, _ label: String, _ command: WindowCommand) -> Item {
        Item(key: key, label: label, action: .window(command))
    }

    public var isGroup: Bool {
        if case .group = action { return true }
        return false
    }
    /// Children of a group; nil for an action.
    public var children: [Item]? {
        if case .group(let items) = action { return items }
        return nil
    }

    // JSON: {"key": "a", "label": "Apps", "items": [...]} | {..., "app": "com.x"} | {..., "url": "https://..."}
    // | {..., "micro": "format-json"} | {..., "open": "clipbawd"} | {..., "window": "left-half"}.
    // Decoding: exactly one of "items"/"app"/"url"/"micro"/"open" must be present; "key" is normalized with
    // SequenceKey.normalize ("A" → "a"); an invalid key or a wrong number of action fields throws
    // DecodingError.dataCorrupted. "label" is optional and defaults to "".
    // Unknown fields are ignored. Encoding writes "key", "label" and exactly one action field.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: ItemCodingKeys.self)
        let rawKey = try container.decode(String.self, forKey: .key)
        guard let key = SequenceKey.normalize(rawKey) else {
            throw DecodingError.dataCorruptedError(forKey: .key, in: container,
                                                   debugDescription: "Invalid key \"\(rawKey)\". Use any key but Esc, Delete and the arrows: a letter, a digit, a sign such as [ or /, space, return, tab, f1...f24 or stop.")
        }
        let items = try container.decodeIfPresent([Item].self, forKey: .items)
        let app = try container.decodeIfPresent(String.self, forKey: .app)
        let url = try container.decodeIfPresent(String.self, forKey: .url)
        let micro = try container.decodeIfPresent(String.self, forKey: .micro)
        let open = try container.decodeIfPresent(TingPanel.self, forKey: .open)
        let window = try container.decodeIfPresent(WindowCommand.self, forKey: .window)
        let actions: [Action] = [items.map(Action.group), app.map(Action.app), url.map(Action.url), micro.map(Action.micro),
                                 open.map(Action.open), window.map(Action.window)]
            .compactMap { $0 }
        guard actions.count == 1, let action = actions.first else {
            throw DecodingError.dataCorrupted(DecodingError.Context(
                codingPath: container.codingPath,
                debugDescription: "Item \"\(rawKey)\" needs exactly one of \"items\", \"app\", \"url\", \"micro\", \"open\" or \"window\"."))
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
        case .micro(let id): try container.encode(id, forKey: .micro)
        case .open(let panel): try container.encode(panel, forKey: .open)
        case .window(let command): try container.encode(command, forKey: .window)
        }
    }

    private enum ItemCodingKeys: String, CodingKey {
        case key, label, items, app, url, micro, open, window
    }
}

public enum UnknownKeyBehavior: String, Codable, Sendable, CaseIterable {
    case shake, close
}

public enum Appearance: String, Codable, Sendable, CaseIterable {
    case system, light, dark
}

/// Where launcha ranks apps that are already running, when `LaunchaSettings.appSwitching` is on.
public enum RunningAppsOrder: String, Codable, Sendable, CaseIterable {
    /// Running apps first within each match group.
    case higher
    /// Running apps last within each match group: launcha is mostly for apps that are not open.
    case lower
    /// No preference (default).
    case any
}

/// Launcha settings: the name search panel.
/// JSON: {"hotkey": Hotkey string or null, "doubleTap": Bool, "doubleTapWindow": seconds, "calculator": Bool,
///       "converter": Bool, "appSwitching": Bool, "runningApps": "higher" | "lower" | "any"}.
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
    /// A query of digits and an operator shows its value first. On by default.
    public var calculator: Bool = true
    /// A conversion such as `5 yd to m`, `255 to hex` or `now + 2 days` shows its value first. On by default.
    public var converter: Bool = true
    /// Rank apps also by how often you switch to them outside launcha. Off by default: Ting then
    /// keeps a local record of the apps you bring to the front.
    public var appSwitching: Bool = false
    /// Where running apps go in the results. Used only with `appSwitching`. An unknown value reads as `.any`.
    public var runningApps: RunningAppsOrder = .any

    public init() {}

    private enum CodingKeys: String, CodingKey {
        case hotkey, doubleTap, doubleTapWindow, calculator, converter, appSwitching, runningApps
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = LaunchaSettings()
        hotkey = try container.decodeIfPresent(Hotkey.self, forKey: .hotkey)
        doubleTap = try container.decodeIfPresent(Bool.self, forKey: .doubleTap) ?? defaults.doubleTap
        let window = try container.decodeIfPresent(Double.self, forKey: .doubleTapWindow) ?? defaults.doubleTapWindow
        let range = LaunchaSettings.doubleTapWindowRange
        doubleTapWindow = min(max(window, range.lowerBound), range.upperBound)
        calculator = try container.decodeIfPresent(Bool.self, forKey: .calculator) ?? defaults.calculator
        converter = try container.decodeIfPresent(Bool.self, forKey: .converter) ?? defaults.converter
        appSwitching = try container.decodeIfPresent(Bool.self, forKey: .appSwitching) ?? defaults.appSwitching
        runningApps = (try? container.decodeIfPresent(String.self, forKey: .runningApps))
            .flatMap { $0.flatMap(RunningAppsOrder.init(rawValue:)) } ?? defaults.runningApps
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
        try container.encode(calculator, forKey: .calculator)
        try container.encode(converter, forKey: .converter)
        try container.encode(appSwitching, forKey: .appSwitching)
        try container.encode(runningApps, forKey: .runningApps)
    }
}

/// Micro-apps settings: maximum allowed run timeout and result panel layout.
/// JSON: {"maxTimeout": seconds, "resultWidth": points, "resultTextSize": points}.
/// Every key is optional when decoding; a missing key takes the default below.
public struct MicroAppsSettings: Equatable, Sendable, Codable {
    /// Default maximum `timeout` a micro-app file may ask for, in seconds.
    public static let defaultMaxTimeout = MicroAppChecker.maxTimeLimit
    /// Allowed range of `maxTimeout`. Decoding clamps to it.
    public static let maxTimeoutRange: ClosedRange<Int> = 60...86_400

    /// Default width of the micro-app result card, in points.
    public static let defaultResultWidth = 580
    /// Allowed range of `resultWidth`. Decoding clamps to it.
    public static let resultWidthRange: ClosedRange<Int> = 480...1200

    /// Default body text size of the micro-app result panel, in points.
    public static let defaultResultTextSize = 13
    /// Allowed range of `resultTextSize`. Decoding clamps to it.
    public static let resultTextSizeRange: ClosedRange<Int> = 11...24

    /// Longest `timeout` a micro-app file may ask for, in seconds. A micro-app still defaults to
    /// 60s and may set any whole number of seconds from 1 up to this limit.
    public var maxTimeout: Int = defaultMaxTimeout
    /// Width of the micro-app result card, in points.
    public var resultWidth: Int = defaultResultWidth
    /// Body text size in the micro-app result panel, in points.
    public var resultTextSize: Int = defaultResultTextSize

    public init() {}

    private enum CodingKeys: String, CodingKey {
        case maxTimeout, resultWidth, resultTextSize
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = MicroAppsSettings()
        let timeout = try container.decodeIfPresent(Int.self, forKey: .maxTimeout) ?? defaults.maxTimeout
        maxTimeout = min(max(timeout, Self.maxTimeoutRange.lowerBound), Self.maxTimeoutRange.upperBound)
        let width = try container.decodeIfPresent(Int.self, forKey: .resultWidth) ?? defaults.resultWidth
        resultWidth = min(max(width, Self.resultWidthRange.lowerBound), Self.resultWidthRange.upperBound)
        let textSize = try container.decodeIfPresent(Int.self, forKey: .resultTextSize) ?? defaults.resultTextSize
        resultTextSize = min(max(textSize, Self.resultTextSizeRange.lowerBound), Self.resultTextSizeRange.upperBound)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(maxTimeout, forKey: .maxTimeout)
        try container.encode(resultWidth, forKey: .resultWidth)
        try container.encode(resultTextSize, forKey: .resultTextSize)
    }
}

/// Chatta settings: AI agent chat window and defaults for `chatta:` micro-app steps.
/// JSON: {"hotkey": Hotkey string or null, "agent": preset id or null, "model": String or null,
///        "effort": String or null, "idleTimeoutMinutes": Int (0 = never), "allowTools": Bool}.
/// Every key is optional when decoding; a missing key takes the default below.
public struct ChattaSettings: Equatable, Sendable, Codable {
    /// Default inactivity minutes before closing an idle agent subprocess.
    public static let defaultIdleTimeoutMinutes = 15
    /// Allowed range of `idleTimeoutMinutes` (0 disables idle disconnect). Decoding clamps to it.
    public static let idleTimeoutMinutesRange: ClosedRange<Int> = 0...240
    /// Allowed reasoning effort levels for ACP agents.
    public static let effortChoices = ["low", "medium", "high", "xhigh", "max"]

    /// Separate global hotkey for Chatta. nil (default) means no separate hotkey.
    public var hotkey: Hotkey? = nil
    /// Preferred ACP agent preset id (e.g. "antigravity", "codex", "claude"). nil auto-detects.
    public var agent: String? = nil
    /// Optional default model ID or name substring pre-selected on connect and in `chatta:` steps.
    public var model: String? = nil
    /// Optional default reasoning effort ("low", "medium", "high", "xhigh", "max").
    public var effort: String? = nil
    /// Minutes of inactivity in `.ready` state before closing the agent subprocess (0 = never).
    public var idleTimeoutMinutes: Int = defaultIdleTimeoutMinutes
    /// Allow built-in agent tools (such as web search) in Chatta's Chat mode. Off by default.
    public var allowTools: Bool = false
    /// Size of the chat text, 1 = 100% (`ChatTextScale.range`). ⌘+ / ⌘− / ⌘0 in the window change it.
    public var textScale: Double = ChatTextScale.standard
    /// The key that sends from the composer: ⌘↩ (default) or ↩.
    public var sendKey: ChatSendKey = .commandReturn

    public var idleTimeout: Duration? {
        idleTimeoutMinutes > 0 ? .seconds(idleTimeoutMinutes * 60) : nil
    }

    public init() {}

    private enum CodingKeys: String, CodingKey {
        case hotkey, agent, model, effort, idleTimeoutMinutes, allowTools, textScale, sendKey
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = ChattaSettings()
        hotkey = try container.decodeIfPresent(Hotkey.self, forKey: .hotkey)
        let rawAgent = try container.decodeIfPresent(String.self, forKey: .agent)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        agent = rawAgent.flatMap { $0.isEmpty ? nil : $0 }
        let rawModel = try container.decodeIfPresent(String.self, forKey: .model)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        model = rawModel.flatMap { $0.isEmpty ? nil : $0 }
        let rawEffort = try container.decodeIfPresent(String.self, forKey: .effort)?
            .trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        effort = rawEffort.flatMap { Self.effortChoices.contains($0) ? $0 : nil }
        let minutes = try container.decodeIfPresent(Int.self, forKey: .idleTimeoutMinutes) ?? defaults.idleTimeoutMinutes
        idleTimeoutMinutes = min(max(minutes, Self.idleTimeoutMinutesRange.lowerBound), Self.idleTimeoutMinutesRange.upperBound)
        allowTools = try container.decodeIfPresent(Bool.self, forKey: .allowTools) ?? defaults.allowTools
        textScale = ChatTextScale.clamped(try container.decodeIfPresent(Double.self, forKey: .textScale) ?? defaults.textScale)
        // An unknown key name keeps the default instead of rejecting the whole file.
        let rawSendKey = try container.decodeIfPresent(String.self, forKey: .sendKey)
        sendKey = rawSendKey.flatMap(ChatSendKey.init(rawValue:)) ?? defaults.sendKey
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        if let hotkey {
            try container.encode(hotkey, forKey: .hotkey)
        } else {
            try container.encodeNil(forKey: .hotkey)
        }
        try container.encodeIfPresent(agent, forKey: .agent)
        try container.encodeIfPresent(model, forKey: .model)
        try container.encodeIfPresent(effort, forKey: .effort)
        try container.encode(idleTimeoutMinutes, forKey: .idleTimeoutMinutes)
        try container.encode(allowTools, forKey: .allowTools)
        try container.encode(textScale, forKey: .textScale)
        try container.encode(sendKey, forKey: .sendKey)
    }
}

/// Schedule settings: nil means every current and future calendar; an array is an explicit selection.
/// JSON: {"calendars": [EventKit calendar identifiers] or null}.
public struct ScheduleSettings: Equatable, Sendable, Codable {
    private var calendarIDs: [String]?
    public var calendars: [String]? {
        get { calendarIDs }
        set { calendarIDs = newValue.map(Self.normalized) }
    }

    public init(calendars: [String]? = nil) {
        calendarIDs = calendars.map(Self.normalized)
    }

    private enum CodingKeys: String, CodingKey { case calendars }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if container.contains(.calendars), !(try container.decodeNil(forKey: .calendars)) {
            calendarIDs = Self.normalized(try container.decode([String].self, forKey: .calendars))
        } else {
            calendarIDs = nil
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        if let calendarIDs {
            try container.encode(calendarIDs, forKey: .calendars)
        } else {
            try container.encodeNil(forKey: .calendars)
        }
    }

    private static func normalized(_ ids: [String]) -> [String] { Array(Set(ids)).sorted() }
}

/// The whole config file (`~/.config/ting/config.json`).
/// JSON keys: "version", "leader" and "alternateLeader" (Hotkey strings or null), "showDelay", "unknownKey",
/// "appearance", "launchAtLogin", "showMenuBarIcon", "showPanelHeader", "playSound", "extendedKeys",
/// "sound", "soundVolume", "launcha" (`LaunchaSettings`), "clipbawd" (`ClipbawdSettings`),
/// "microApps" (`MicroAppsSettings`), "schedule" (`ScheduleSettings`), "chatta" (`ChattaSettings`),
/// "windowManagement" (`WindowManagementSettings`), "appHotkeys", "microHotkeys", "microIcons", "items".
/// Every key is optional when decoding; a missing key takes the default below.
public struct Config: Equatable, Sendable, Codable {
    public static let currentVersion = 1

    public var version: Int = Config.currentVersion
    /// There is no default leader: nil until the user records one.
    public var leader: Hotkey? = nil
    public var alternateLeader: Hotkey?

    /// Distinct configured leader keys, in settings order.
    public var leaders: [Hotkey] {
        [leader, alternateLeader == leader ? nil : alternateLeader].compactMap { $0 }
    }

    public var leaderDisplay: String { leaders.map(\.display).joined(separator: " or ") }

    /// Seconds before the menu becomes visible. Clamped to 0...2 when decoding.
    public var showDelay: Double = 0
    public var unknownKey: UnknownKeyBehavior = .shake
    /// Dark by default.
    public var appearance: Appearance = .dark
    /// Theme preset and custom light/dark panel and accent colors (Amber by default).
    public var theme: ThemePaletteConfig = ThemePaletteConfig(preset: .amber)
    public var launchAtLogin: Bool = false
    public var showMenuBarIcon: Bool = true
    /// Show the title row above selecta and launcha panels.
    public var showPanelHeader: Bool = true
    public var playSound: Bool = true
    /// Extended key capture: read keys that macOS never reports (Stop, Again, Undo, F21…) straight
    /// from the keyboards through HID, so they can be leaders, hotkeys and menu keys. Needs Input
    /// Monitoring, so it is off by default.
    public var extendedKeys: Bool = false
    /// Name of a system sound without extension, e.g. "Glass". Played when `playSound` is on.
    public var sound: String = SystemSounds.defaultName
    /// Volume of `sound`, relative to the system output volume. Clamped to 0...1 when decoding.
    public var soundVolume: Double = 0.5
    /// Launcha settings. Older files without "launcha" get the defaults.
    public var launcha: LaunchaSettings = LaunchaSettings()
    /// clipbawd settings. Older files without "clipbawd" get the defaults.
    public var clipbawd: ClipbawdSettings = ClipbawdSettings()
    /// Micro-apps settings. Older files without "microApps" get the defaults.
    public var microApps: MicroAppsSettings = MicroAppsSettings()
    /// My Schedule calendar selection. Older files without "schedule" show every calendar.
    public var schedule: ScheduleSettings = ScheduleSettings()
    /// Chatta settings. Older files without "chatta" get the defaults.
    public var chatta: ChattaSettings = ChattaSettings()
    /// Focused-window commands, gaps and direct hotkeys. Older files get the defaults.
    public var windowManagement: WindowManagementSettings = WindowManagementSettings()
    /// Direct global shortcuts assigned from launcha; older files default to none.
    public var appHotkeys: [AppShortcut] = []
    /// Direct global shortcuts that start micro-apps; written by hand, older files default to none.
    public var microHotkeys: [MicroShortcut] = []
    /// Micro-app id → icon (`MicroIcon` text), set in Settings; wins over the `icon` key of the file.
    public var microIcons: [String: String] = [:]
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
        case version, leader, alternateLeader, showDelay, unknownKey, appearance, theme
        case launchAtLogin, showMenuBarIcon, showPanelHeader, playSound, sound, soundVolume, extendedKeys
        case launcha, clipbawd, microApps, schedule, chatta, windowManagement
        case appHotkeys, microHotkeys, microIcons, items
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: ConfigCodingKeys.self)
        let defaults = Config()
        version = try container.decodeIfPresent(Int.self, forKey: .version) ?? defaults.version
        leader = try container.decodeIfPresent(Hotkey.self, forKey: .leader)
        alternateLeader = try container.decodeIfPresent(Hotkey.self, forKey: .alternateLeader)
        let delay = try container.decodeIfPresent(Double.self, forKey: .showDelay) ?? defaults.showDelay
        showDelay = min(max(delay, 0), 2)
        unknownKey = try container.decodeIfPresent(UnknownKeyBehavior.self, forKey: .unknownKey) ?? defaults.unknownKey
        appearance = try container.decodeIfPresent(Appearance.self, forKey: .appearance) ?? defaults.appearance
        theme = try container.decodeIfPresent(ThemePaletteConfig.self, forKey: .theme) ?? defaults.theme
        launchAtLogin = try container.decodeIfPresent(Bool.self, forKey: .launchAtLogin) ?? defaults.launchAtLogin
        showMenuBarIcon = try container.decodeIfPresent(Bool.self, forKey: .showMenuBarIcon) ?? defaults.showMenuBarIcon
        showPanelHeader = try container.decodeIfPresent(Bool.self, forKey: .showPanelHeader) ?? defaults.showPanelHeader
        playSound = try container.decodeIfPresent(Bool.self, forKey: .playSound) ?? defaults.playSound
        extendedKeys = try container.decodeIfPresent(Bool.self, forKey: .extendedKeys) ?? defaults.extendedKeys
        sound = try container.decodeIfPresent(String.self, forKey: .sound) ?? defaults.sound
        let volume = try container.decodeIfPresent(Double.self, forKey: .soundVolume) ?? defaults.soundVolume
        soundVolume = min(max(volume, 0), 1)
        launcha = try container.decodeIfPresent(LaunchaSettings.self, forKey: .launcha) ?? defaults.launcha
        clipbawd = try container.decodeIfPresent(ClipbawdSettings.self, forKey: .clipbawd) ?? defaults.clipbawd
        microApps = try container.decodeIfPresent(MicroAppsSettings.self, forKey: .microApps) ?? defaults.microApps
        schedule = try container.decodeIfPresent(ScheduleSettings.self, forKey: .schedule) ?? defaults.schedule
        chatta = try container.decodeIfPresent(ChattaSettings.self, forKey: .chatta) ?? defaults.chatta
        windowManagement = try container.decodeIfPresent(WindowManagementSettings.self, forKey: .windowManagement)
            ?? defaults.windowManagement
        appHotkeys = try container.decodeIfPresent([AppShortcut].self, forKey: .appHotkeys) ?? defaults.appHotkeys
        microHotkeys = try container.decodeIfPresent([MicroShortcut].self, forKey: .microHotkeys) ?? defaults.microHotkeys
        microIcons = try container.decodeIfPresent([String: String].self, forKey: .microIcons) ?? defaults.microIcons
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
        try container.encodeIfPresent(alternateLeader, forKey: .alternateLeader)
        try container.encode(showDelay, forKey: .showDelay)
        try container.encode(unknownKey, forKey: .unknownKey)
        try container.encode(appearance, forKey: .appearance)
        try container.encode(theme, forKey: .theme)
        try container.encode(launchAtLogin, forKey: .launchAtLogin)
        try container.encode(showMenuBarIcon, forKey: .showMenuBarIcon)
        try container.encode(showPanelHeader, forKey: .showPanelHeader)
        try container.encode(playSound, forKey: .playSound)
        try container.encode(sound, forKey: .sound)
        try container.encode(soundVolume, forKey: .soundVolume)
        try container.encode(extendedKeys, forKey: .extendedKeys)
        try container.encode(launcha, forKey: .launcha)
        try container.encode(clipbawd, forKey: .clipbawd)
        try container.encode(microApps, forKey: .microApps)
        try container.encode(schedule, forKey: .schedule)
        try container.encode(chatta, forKey: .chatta)
        try container.encode(windowManagement, forKey: .windowManagement)
        try container.encode(appHotkeys, forKey: .appHotkeys)
        try container.encode(microHotkeys, forKey: .microHotkeys)
        if !microIcons.isEmpty { try container.encode(microIcons, forKey: .microIcons) }
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
        /// An app with an empty bundle identifier, a url with an empty string, or a micro-app binding without an id.
        case emptyTarget
        /// A url that does not parse as a URL with a scheme.
        case invalidURL
        /// The config has no leader yet.
        case missingLeader
        /// The leader is not `isValid`.
        case invalidLeader
        case invalidAlternateLeader
        /// The launcha hotkey is not `isValid` (for example a modifier on its own).
        case invalidLaunchaHotkey
        /// The launcha hotkey is the same as the leader.
        case launchaHotkeyConflict
        /// The clipbawd hotkey is not `isValid`.
        case invalidClipbawdHotkey
        /// The clipbawd hotkey is the same as the leader or the launcha hotkey.
        case clipbawdHotkeyConflict
        /// The chatta hotkey is not `isValid`.
        case invalidChattaHotkey
        /// The chatta hotkey conflicts with another reserved launcher hotkey.
        case chattaHotkeyConflict
        /// Invalid, reserved or duplicate application hotkey assignment.
        case appHotkey
        /// Invalid, reserved or duplicate focused-window hotkey assignment.
        case windowHotkey
        /// Invalid, reserved or duplicate micro-app hotkey assignment.
        case microHotkey
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
    /// Leader issues first, then launcha and clipbawd hotkey issues, then micro-app and app hotkey issues, then all item issues depth-first in item order. For a duplicate key, report one issue per duplicate
    /// after the first, with the duplicate's sequence.
    public static func validate(_ config: Config) -> [ConfigIssue] {
        HotkeyAssignments(config).issues + bindingIssues(in: config)
    }

    public static func bindingIssues(in config: Config) -> [ConfigIssue] {
        var issues: [ConfigIssue] = []
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
            case .open, .window:
                break
            case .micro(let id):
                // An id that is not loaded is fine: the binding shows as not working until the file appears.
                if id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    issues.append(ConfigIssue(kind: .emptyTarget, sequence: sequence, message: "\(name) has no micro-app."))
                }
            }
        }
    }
}

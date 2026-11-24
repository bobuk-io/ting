/// Declaration order is the precedence used when reading a hand-written config.
public enum LauncherHotkey: CaseIterable, Sendable {
    case leader, alternateLeader, launcha, clipbawd, chatta

    public func configured(in config: Config) -> Hotkey? {
        switch self {
        case .leader: config.leader
        case .alternateLeader: config.alternateLeader
        case .launcha: config.launcha.hotkey
        case .clipbawd: config.clipbawd.activeHotkey
        case .chatta: config.chatta.hotkey
        }
    }

    public var role: String {
        switch self {
        case .leader, .alternateLeader: "be a leader"
        case .launcha: "open launcha"
        case .clipbawd: "open clipbawd"
        case .chatta: "open chatta"
        }
    }

    public static func owner(of key: Hotkey, in config: Config, excluding edited: Self? = nil) -> Self? {
        allCases.first { $0 != edited && $0.configured(in: config) == key }
    }

    public func conflict(for key: Hotkey) -> String {
        switch self {
        case .leader, .alternateLeader: "\(key.display) is already a leader key."
        case .launcha: "\(key.display) already opens launcha."
        case .clipbawd: "\(key.display) already opens clipbawd."
        case .chatta: "\(key.display) already opens chatta."
        }
    }

    fileprivate func issue(conflict: Bool) -> ConfigIssue.Kind {
        switch self {
        case .leader: .invalidLeader
        case .alternateLeader: .invalidAlternateLeader
        case .launcha: conflict ? .launchaHotkeyConflict : .invalidLaunchaHotkey
        case .clipbawd: conflict ? .clipbawdHotkeyConflict : .invalidClipbawdHotkey
        case .chatta: conflict ? .chattaHotkeyConflict : .invalidChattaHotkey
        }
    }
}

/// Winners and diagnostics from the same walk, independent of macOS registration.
public struct HotkeyAssignments: Sendable {
    public private(set) var launchers: [LauncherHotkey: Hotkey] = [:]
    public private(set) var windows: [WindowShortcut] = []
    public private(set) var applications: [AppShortcut] = []
    public private(set) var windowProblems: [WindowCommand: String] = [:]
    public private(set) var issues: [ConfigIssue] = []

    public init(_ config: Config) {
        if config.leaders.isEmpty {
            issues.append(ConfigIssue(kind: .missingLeader, sequence: [], message: "No leader key yet."))
        }
        for slot in LauncherHotkey.allCases {
            guard let key = slot.configured(in: config) else { continue }
            if !key.isValid {
                issues.append(ConfigIssue(kind: slot.issue(conflict: false), sequence: [],
                    message: "\(key.display) cannot \(slot.role). Choose a key that is not a modifier."))
            } else if let owner = LauncherHotkey.owner(of: key, in: config), owner != slot {
                issues.append(ConfigIssue(kind: slot.issue(conflict: true), sequence: [], message: owner.conflict(for: key)))
            } else {
                launchers[slot] = key
            }
        }

        var windowCommands: Set<WindowCommand> = []
        var windowKeys: Set<Hotkey> = []
        for shortcut in config.windowManagement.shortcuts {
            let reason: String
            if windowCommands.contains(shortcut.command) {
                reason = "This command is assigned more than once."
            } else if !shortcut.hotkey.isValid {
                reason = WindowShortcutRules.Problem.invalidKey.description
            } else if let owner = LauncherHotkey.owner(of: shortcut.hotkey, in: config) {
                reason = owner.conflict(for: shortcut.hotkey)
            } else if windowKeys.contains(shortcut.hotkey) {
                reason = "A window shortcut is assigned more than once."
            } else {
                windowCommands.insert(shortcut.command)
                windowKeys.insert(shortcut.hotkey)
                windows.append(shortcut)
                continue
            }
            let message = "\(shortcut.command.title): \(reason)"
            windowProblems[shortcut.command] = message
            issues.append(ConfigIssue(kind: .windowHotkey, sequence: [], message: message))
        }

        var ids: Set<String> = []
        var keys: Set<Hotkey> = []
        for shortcut in config.appHotkeys {
            let reason: String
            if !shortcut.hasValidTarget {
                reason = AppShortcutRules.Problem.invalidTarget.description
            } else if !shortcut.hotkey.isValid {
                reason = AppShortcutRules.Problem.invalidKey.description
            } else if let owner = LauncherHotkey.owner(of: shortcut.hotkey, in: config) {
                reason = owner.conflict(for: shortcut.hotkey)
            } else if let window = windows.first(where: { $0.hotkey == shortcut.hotkey }) {
                reason = AppShortcutRules.Problem.window(window.command.title).description
            } else if ids.contains(shortcut.id) || keys.contains(shortcut.hotkey) {
                reason = "An application or shortcut is assigned more than once."
            } else {
                ids.insert(shortcut.id)
                keys.insert(shortcut.hotkey)
                applications.append(shortcut)
                continue
            }
            issues.append(ConfigIssue(kind: .appHotkey, sequence: [], message: "\(shortcut.name): \(reason)"))
        }
    }
}

import Foundation

/// A direct global shortcut for an app selected in launcha, independent of leader sequences.
public struct AppShortcut: Equatable, Sendable, Codable, Identifiable {
    /// The same stable identity used by launcha's index and launch history.
    public var id: String
    public var name: String
    /// Retain the indexed app path; do not resolve another copy by bundle identifier.
    public var path: String
    public var hotkey: Hotkey

    public init(id: String, name: String, path: String, hotkey: Hotkey) {
        self.id = id
        self.name = name
        self.path = path
        self.hotkey = hotkey
    }

    public var hasValidTarget: Bool {
        !id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        (path as NSString).isAbsolutePath && (path as NSString).pathExtension.lowercased() == "app"
    }
}

public enum AppShortcutRules {
    public enum Problem: Error, Equatable, Sendable, CustomStringConvertible {
        case invalidKey, invalidTarget, leader, launcha, clipbawd, chatta, window(String)

        public var description: String {
            switch self {
            case .invalidKey: "Press a non-modifier key, optionally with modifiers."
            case .invalidTarget: "Choose an application with an absolute .app path."
            case .leader: "This key is reserved for the leader. Choose another shortcut."
            case .launcha: "This key is reserved for launcha. Choose another shortcut."
            case .clipbawd: "This key is reserved for clipbawd. Choose another shortcut."
            case .chatta: "This key is reserved for chatta. Choose another shortcut."
            case .window(let name): "This key already runs \(name). Choose another shortcut."
            }
        }
    }

    public static func problem(for hotkey: Hotkey, in config: Config) -> Problem? {
        if !hotkey.isValid { return .invalidKey }
        switch LauncherHotkey.owner(of: hotkey, in: config) {
        case .leader, .alternateLeader: return .leader
        case .launcha: return .launcha
        case .clipbawd: return .clipbawd
        case .chatta: return .chatta
        case nil: break
        }
        if let shortcut = config.windowManagement.shortcuts.first(where: { $0.hotkey == hotkey }) {
            return .window(shortcut.command.title)
        }
        return nil
    }

    /// Validate before mutation: rejection must never delete a previous assignment.
    public static func assign(_ shortcut: AppShortcut, in config: inout Config) throws {
        guard shortcut.hasValidTarget else { throw Problem.invalidTarget }
        if let problem = problem(for: shortcut.hotkey, in: config) { throw problem }
        config.appHotkeys.removeAll { $0.id == shortcut.id || $0.hotkey == shortcut.hotkey }
        config.appHotkeys.append(shortcut)
    }

    /// First valid assignment wins in a hand-written file. Reserved keys always win over apps.
    public static func active(in config: Config) -> [AppShortcut] {
        HotkeyAssignments(config).applications
    }
}

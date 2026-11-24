import Foundation

public enum SettingsPage: String, CaseIterable, Identifiable, Sendable {
    case general, activation, bindings, windows, clipbawd, chatta, microApps, advanced
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .general: "General"
        case .activation: "Keys & Launch"
        case .bindings: "Bindings"
        case .windows: "Windows"
        case .clipbawd: "Clipbawd"
        case .chatta: "Chatta"
        case .microApps: "Micro-apps"
        case .advanced: "Advanced"
        }
    }
    public var symbol: String {
        switch self {
        case .general: "gearshape"
        case .activation: "command"
        case .bindings: "keyboard"
        case .windows: "rectangle.split.2x1"
        case .clipbawd: "list.clipboard"
        case .chatta: "sparkles"
        case .microApps: "square.stack.3d.up"
        case .advanced: "wrench.and.screwdriver"
        }
    }
}

/// Search points to real sections, rather than matching only category names.
public struct SettingsSearchItem: Identifiable, Equatable, Sendable {
    public let id: String
    public let page: SettingsPage
    public let title: String
    public let keywords: String
}

public enum SettingsCatalog {
    public static let items: [SettingsSearchItem] = [
        .init(id: "appearance", page: .general, title: "Appearance and theme", keywords: "system light dark theme preset palette color accent panel header selecta"),
        .init(id: "system", page: .general, title: "Login and menu bar", keywords: "launch startup icon system"),
        .init(id: "sound", page: .general, title: "Sound and volume", keywords: "ting audio mute play"),
        .init(id: "updates", page: .general, title: "Updates and version", keywords: "automatic check homebrew sparkle"),
        .init(id: "activation", page: .activation, title: "Leader keys and menu delay", keywords: "activation second alternate unknown shake close shortcut hotkey"),
        .init(id: "launcha", page: .activation, title: "launcha",
              keywords: "hotkey double tap interval calculator converter units dates protected folders "
                + "desktop documents downloads search access rank ranking frequent usage switch switching running open apps fuzzy"),
        .init(id: "bindings", page: .bindings, title: "Bindings and app shortcuts", keywords: "sequence group application key url open direct hotkey conflict window resize move"),
        .init(id: "windows", page: .windows, title: "Window management", keywords: "window resize move half quarter third maximize center restore display monitor screen hotkey shortcut gap tile"),
        .init(id: "clipbawd", page: .clipbawd, title: "Clipboard and hotkey", keywords: "clipbawd enable recording copy paste image video markdown"),
        .init(id: "storage", page: .clipbawd, title: "Clipboard history storage", keywords: "persistent persistence disk memory count size megabytes mib mb days age retention clear limit"),
        .init(id: "privacy", page: .clipbawd, title: "Clipboard privacy and exclusions", keywords: "never keep apps prefixes passwords private windows incognito browser automation permission"),
        .init(id: "links", page: .clipbawd, title: "Link previews", keywords: "clipboard clipbawd fetch titles icons images network"),
        .init(id: "chatta", page: .chatta, title: "Chatta agent chat",
              keywords: "chatta ai agent chat acp antigravity codex claude pi kimi gemini opencode model effort hotkey idle timeout sandbox tools web search configure"),
        .init(id: "micro-apps", page: .microApps, title: "Micro-apps and permissions",
              keywords: "folder yaml errors broken reload agent prompt accessibility automation timeout max width text font size panel result"),
        .init(id: "config", page: .advanced, title: "Configuration file", keywords: "json path location finder editor reload ting_config"),
        .init(id: "backup", page: .advanced, title: "Import and export", keywords: "backup configuration json restore"),
    ]

    public static func search(_ query: String) -> [SettingsSearchItem] {
        let words = NameMatcher.words(in: NameMatcher.fold(query))
        guard !words.isEmpty else { return items }
        return items.filter { item in
            let haystack = NameMatcher.fold("\(item.title) \(item.page.title) \(item.keywords)")
            return words.allSatisfy { haystack.contains($0) }
        }
    }
}

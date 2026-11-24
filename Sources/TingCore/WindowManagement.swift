import Foundation

/// A command that moves or resizes the focused macOS window.
public enum WindowCommand: String, CaseIterable, Codable, Identifiable, Sendable {
    case leftHalf = "left-half"
    case rightHalf = "right-half"
    case topHalf = "top-half"
    case bottomHalf = "bottom-half"
    case topLeftQuarter = "top-left-quarter"
    case topRightQuarter = "top-right-quarter"
    case bottomLeftQuarter = "bottom-left-quarter"
    case bottomRightQuarter = "bottom-right-quarter"
    case firstThird = "first-third"
    case centerThird = "center-third"
    case lastThird = "last-third"
    case maximize
    case center
    case restore
    case previousDisplay = "previous-display"
    case nextDisplay = "next-display"

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .leftHalf: "Left Half"
        case .rightHalf: "Right Half"
        case .topHalf: "Top Half"
        case .bottomHalf: "Bottom Half"
        case .topLeftQuarter: "Top Left Quarter"
        case .topRightQuarter: "Top Right Quarter"
        case .bottomLeftQuarter: "Bottom Left Quarter"
        case .bottomRightQuarter: "Bottom Right Quarter"
        case .firstThird: "First Third"
        case .centerThird: "Center Third"
        case .lastThird: "Last Third"
        case .maximize: "Maximize"
        case .center: "Center"
        case .restore: "Restore"
        case .previousDisplay: "Previous Display"
        case .nextDisplay: "Next Display"
        }
    }

    public var detail: String {
        switch self {
        case .leftHalf, .rightHalf, .topHalf, .bottomHalf: "Fill one half of the current display."
        case .topLeftQuarter, .topRightQuarter, .bottomLeftQuarter, .bottomRightQuarter:
            "Fill one quarter of the current display."
        case .firstThird, .centerThird, .lastThird: "Fill one third of the current display."
        case .maximize: "Fill the usable area of the current display."
        case .center: "Keep the current size and center the window."
        case .restore: "Return to the frame before Ting first moved this window."
        case .previousDisplay, .nextDisplay: "Move to another display and keep the relative position."
        }
    }
}

/// A direct global shortcut for one window command, independent of leader sequences.
public struct WindowShortcut: Equatable, Codable, Identifiable, Sendable {
    public var command: WindowCommand
    public var hotkey: Hotkey

    public init(command: WindowCommand, hotkey: Hotkey) {
        self.command = command
        self.hotkey = hotkey
    }

    public var id: WindowCommand { command }
}

/// Window movement preferences. Missing values in older configs get these defaults.
public struct WindowManagementSettings: Equatable, Codable, Sendable {
    public static let gapRange: ClosedRange<Double> = 0...64

    /// Space in points at screen edges and between adjacent tiles.
    public var gap: Double = 0
    public var shortcuts: [WindowShortcut] = []

    public init() {}

    private enum CodingKeys: String, CodingKey { case gap, shortcuts }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = WindowManagementSettings()
        let gap = try container.decodeIfPresent(Double.self, forKey: .gap) ?? defaults.gap
        self.gap = min(max(gap, Self.gapRange.lowerBound), Self.gapRange.upperBound)
        shortcuts = try container.decodeIfPresent([WindowShortcut].self, forKey: .shortcuts) ?? defaults.shortcuts
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(gap, forKey: .gap)
        try container.encode(shortcuts, forKey: .shortcuts)
    }
}

public enum WindowShortcutRules {
    public enum Problem: Error, Equatable, Sendable, CustomStringConvertible {
        case invalidKey
        case leader
        case launcha
        case clipbawd
        case chatta
        case window(String)
        case application(String)

        public var description: String {
            switch self {
            case .invalidKey: "Press a non-modifier key, optionally with modifiers."
            case .leader: "This key is reserved for the leader. Choose another shortcut."
            case .launcha: "This key is reserved for launcha. Choose another shortcut."
            case .clipbawd: "This key is reserved for clipbawd. Choose another shortcut."
            case .chatta: "This key is reserved for chatta. Choose another shortcut."
            case .window(let name): "This key already runs \(name). Choose another shortcut."
            case .application(let name): "This key already opens \(name). Choose another shortcut."
            }
        }
    }

    public static func problem(for hotkey: Hotkey, command: WindowCommand, in config: Config) -> Problem? {
        if !hotkey.isValid { return .invalidKey }
        switch LauncherHotkey.owner(of: hotkey, in: config) {
        case .leader, .alternateLeader: return .leader
        case .launcha: return .launcha
        case .clipbawd: return .clipbawd
        case .chatta: return .chatta
        case nil: break
        }
        if let existing = config.windowManagement.shortcuts.first(where: { $0.command != command && $0.hotkey == hotkey }) {
            return .window(existing.command.title)
        }
        if let app = config.appHotkeys.first(where: { $0.hotkey == hotkey }) {
            return .application(app.name)
        }
        return nil
    }

    /// Validate before mutation: rejection must never delete the previous assignment.
    public static func assign(command: WindowCommand, hotkey: Hotkey?, in config: inout Config) throws {
        var next = config
        next.windowManagement.shortcuts.removeAll { $0.command == command }
        if let hotkey {
            if let problem = problem(for: hotkey, command: command, in: next) { throw problem }
            next.windowManagement.shortcuts.append(WindowShortcut(command: command, hotkey: hotkey))
        }
        config = next
    }
}

/// Platform-neutral rectangle math for window placement.
public struct WindowRect: Equatable, Codable, Sendable {
    public var originX: Double
    public var originY: Double
    public var width: Double
    public var height: Double

    public init(originX: Double, originY: Double, width: Double, height: Double) {
        self.originX = originX
        self.originY = originY
        self.width = width
        self.height = height
    }

    public var minX: Double { originX }
    public var minY: Double { originY }
    public var maxX: Double { originX + width }
    public var maxY: Double { originY + height }
    public var midX: Double { originX + width / 2 }
    public var midY: Double { originY + height / 2 }
}

public enum WindowGeometry {
    /// The destination of a command on `visibleFrame`. Display movement and restore need service state.
    public static func frame(for command: WindowCommand, current: WindowRect,
                             visibleFrame: WindowRect, gap rawGap: Double) -> WindowRect? {
        let gap = max(0, rawGap)
        let available = inset(visibleFrame, by: gap)
        let two = columns(in: available, count: 2, gap: gap)
        let three = columns(in: available, count: 3, gap: gap)
        let rows = rows(in: available, count: 2, gap: gap)

        switch command {
        case .leftHalf: return two[0]
        case .rightHalf: return two[1]
        case .topHalf: return rows[1]
        case .bottomHalf: return rows[0]
        case .topLeftQuarter: return intersection(two[0], rows[1])
        case .topRightQuarter: return intersection(two[1], rows[1])
        case .bottomLeftQuarter: return intersection(two[0], rows[0])
        case .bottomRightQuarter: return intersection(two[1], rows[0])
        case .firstThird: return three[0]
        case .centerThird: return three[1]
        case .lastThird: return three[2]
        case .maximize: return available
        case .center:
            let width = min(max(1, current.width), available.width)
            let height = min(max(1, current.height), available.height)
            return WindowRect(originX: available.midX - width / 2, originY: available.midY - height / 2,
                              width: width, height: height)
        case .restore, .previousDisplay, .nextDisplay: return nil
        }
    }

    /// Keeps a window's relative center while moving it to another display. Its size is preserved
    /// when possible and reduced only when it cannot fit in the destination's usable area.
    public static func movedFrame(_ current: WindowRect, from source: WindowRect,
                                  to destination: WindowRect, gap rawGap: Double) -> WindowRect {
        let gap = max(0, rawGap)
        let source = inset(source, by: gap)
        let destination = inset(destination, by: gap)
        let xFraction = source.width > 0 ? (current.midX - source.minX) / source.width : 0.5
        let yFraction = source.height > 0 ? (current.midY - source.minY) / source.height : 0.5
        let width = min(max(1, current.width), destination.width)
        let height = min(max(1, current.height), destination.height)
        let centerX = destination.minX + min(max(xFraction, 0), 1) * destination.width
        let centerY = destination.minY + min(max(yFraction, 0), 1) * destination.height
        return WindowRect(
            originX: min(max(centerX - width / 2, destination.minX), destination.maxX - width),
            originY: min(max(centerY - height / 2, destination.minY), destination.maxY - height),
            width: width,
            height: height)
    }

    private static func inset(_ rect: WindowRect, by amount: Double) -> WindowRect {
        let xInset = min(max(0, amount), max(0, (rect.width - 1) / 2))
        let yInset = min(max(0, amount), max(0, (rect.height - 1) / 2))
        return WindowRect(originX: rect.originX + xInset, originY: rect.originY + yInset,
                          width: max(1, rect.width - xInset * 2), height: max(1, rect.height - yInset * 2))
    }

    private static func columns(in rect: WindowRect, count: Int, gap: Double) -> [WindowRect] {
        let totalGap = gap * Double(count - 1)
        let width = max(1, (rect.width - totalGap) / Double(count))
        return (0..<count).map { index in
            WindowRect(originX: rect.minX + Double(index) * (width + gap), originY: rect.minY,
                       width: width, height: rect.height)
        }
    }

    private static func rows(in rect: WindowRect, count: Int, gap: Double) -> [WindowRect] {
        let totalGap = gap * Double(count - 1)
        let height = max(1, (rect.height - totalGap) / Double(count))
        return (0..<count).map { index in
            WindowRect(originX: rect.minX, originY: rect.minY + Double(index) * (height + gap),
                       width: rect.width, height: height)
        }
    }

    private static func intersection(_ lhs: WindowRect, _ rhs: WindowRect) -> WindowRect {
        let minX = max(lhs.minX, rhs.minX)
        let minY = max(lhs.minY, rhs.minY)
        return WindowRect(originX: minX, originY: minY, width: max(1, min(lhs.maxX, rhs.maxX) - minX),
                          height: max(1, min(lhs.maxY, rhs.maxY) - minY))
    }
}

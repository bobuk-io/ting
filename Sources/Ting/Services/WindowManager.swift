import AppKit
import ApplicationServices
import TingCore

@MainActor
protocol WindowManaging: AnyObject {
    func run(_ command: WindowCommand, gap: Double) async throws
}

enum WindowManagementError: LocalizedError, Equatable {
    case accessibility
    case noFocusedApplication
    case noFocusedWindow
    case windowCannotMove
    case windowCannotResize
    case frameUnavailable
    case noOtherDisplay
    case noRestoreFrame
    case operationFailed

    var errorDescription: String? {
        switch self {
        case .accessibility: "Allow Accessibility to move and resize windows."
        case .noFocusedApplication: "No application is active."
        case .noFocusedWindow: "The active application has no movable window."
        case .windowCannotMove: "This window does not allow other apps to move it."
        case .windowCannotResize: "This window does not allow other apps to resize it."
        case .frameUnavailable: "Ting could not read this window's frame."
        case .noOtherDisplay: "There is no other display."
        case .noRestoreFrame: "Ting has no saved frame for this window yet."
        case .operationFailed: "macOS did not move or resize the window."
        }
    }
}

/// Converts between Accessibility's top-left desktop coordinates and AppKit's bottom-left coordinates.
enum WindowCoordinates {
    static func appKitRect(from accessibilityRect: CGRect, primaryTop: CGFloat) -> CGRect {
        CGRect(x: accessibilityRect.minX, y: primaryTop - accessibilityRect.maxY,
               width: accessibilityRect.width, height: accessibilityRect.height)
    }

    static func accessibilityRect(from appKitRect: CGRect, primaryTop: CGFloat) -> CGRect {
        CGRect(x: appKitRect.minX, y: primaryTop - appKitRect.maxY,
               width: appKitRect.width, height: appKitRect.height)
    }
}

/// Moves the focused window through the public macOS Accessibility API.
///
/// Only the permission check, the frontmost app and the display layout are read on the main
/// thread. The Accessibility calls for another app's window run off the main thread, so an app
/// that does not answer can never freeze Ting's panels. A window of Ting itself (Settings is in
/// front while you record a window hotkey) is the exception: macOS answers those calls inside
/// Ting by calling AppKit directly, which must happen on the main thread.
@MainActor
final class WindowManager: WindowManaging {
    private let worker = WindowAccessibilityWorker()

    /// Ting's own windows are AppKit windows of this process: move them on the main thread.
    nonisolated static func runsOnMainThread(pid: pid_t) -> Bool {
        pid == ProcessInfo.processInfo.processIdentifier
    }

    func run(_ command: WindowCommand, gap: Double) async throws {
        guard AXIsProcessTrusted() else { throw WindowManagementError.accessibility }
        guard let app = NSWorkspace.shared.frontmostApplication else {
            throw WindowManagementError.noFocusedApplication
        }
        let pid = app.processIdentifier
        let displays = NSScreen.screens.map { WindowDisplay(frame: $0.frame, visibleFrame: $0.visibleFrame) }
        if Self.runsOnMainThread(pid: pid) {
            try worker.run(command, gap: gap, pid: pid, displays: displays)
            return
        }
        try await Task.detached(priority: .userInitiated) { [worker] in
            try worker.run(command, gap: gap, pid: pid, displays: displays)
        }.value
    }
}

/// A display as AppKit reports it, copied on the main thread.
struct WindowDisplay: Sendable {
    var frame: CGRect
    var visibleFrame: CGRect
}

/// Runs the Accessibility calls of window commands on the thread it is called from, and keeps the
/// frames that `restore` returns to. Safe to call from any thread: only the saved frames are shared,
/// under a lock.
final class WindowAccessibilityWorker: @unchecked Sendable {
    private struct WindowIdentity: Hashable {
        var pid: pid_t
        var elementHash: Int
    }

    /// Seconds an unresponsive app may take to answer one Accessibility call.
    static let messagingTimeout: Float = 1
    /// Saved frames kept for `restore`; beyond this the oldest are forgotten.
    static let restoreLimit = 64

    private let lock = NSLock()
    private var restoreFrames: [WindowIdentity: CGRect] = [:]
    private var restoreOrder: [WindowIdentity] = []

    func run(_ command: WindowCommand, gap: Double, pid: pid_t, displays: [WindowDisplay]) throws {
        let application = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(application, Self.messagingTimeout)
        guard let window = element(application, kAXFocusedWindowAttribute)
                ?? element(application, kAXMainWindowAttribute) else {
            throw WindowManagementError.noFocusedWindow
        }
        AXUIElementSetMessagingTimeout(window, Self.messagingTimeout)
        let identity = WindowIdentity(pid: pid, elementHash: Int(CFHash(window)))
        let accessibilityFrame = try frame(of: window)
        guard let primary = displays.first(where: { $0.frame.origin == .zero }) ?? displays.first else {
            throw WindowManagementError.operationFailed
        }
        let primaryTop = primary.frame.maxY
        let current = WindowCoordinates.appKitRect(from: accessibilityFrame, primaryTop: primaryTop)
        guard let screenIndex = displayIndex(containing: current, among: displays) else {
            throw WindowManagementError.operationFailed
        }
        let screen = displays[screenIndex]

        if command == .restore {
            guard let original = savedFrame(for: identity) else { throw WindowManagementError.noRestoreFrame }
            try setFrame(original, of: window, primaryTop: primaryTop)
            forget(identity)
            return
        }

        let hadRestoreFrame = !remember(current, for: identity)
        do {
            let destination: CGRect
            switch command {
            case .previousDisplay, .nextDisplay:
                guard displays.count > 1 else { throw WindowManagementError.noOtherDisplay }
                let ordered = displays.indices.sorted {
                    let lhs = displays[$0].frame, rhs = displays[$1].frame
                    if lhs.minX != rhs.minX { return lhs.minX < rhs.minX }
                    return lhs.maxY > rhs.maxY
                }
                guard let index = ordered.firstIndex(of: screenIndex) else {
                    throw WindowManagementError.operationFailed
                }
                let offset = command == .previousDisplay ? -1 : 1
                let next = displays[ordered[(index + offset + ordered.count) % ordered.count]]
                destination = cgRect(WindowGeometry.movedFrame(
                    windowRect(current), from: windowRect(screen.visibleFrame),
                    to: windowRect(next.visibleFrame), gap: gap))
            case .restore:
                throw WindowManagementError.noRestoreFrame
            default:
                guard let calculated = WindowGeometry.frame(for: command, current: windowRect(current),
                                                            visibleFrame: windowRect(screen.visibleFrame), gap: gap) else {
                    throw WindowManagementError.operationFailed
                }
                destination = cgRect(calculated)
            }
            try setFrame(destination, of: window, primaryTop: primaryTop)
        } catch {
            if !hadRestoreFrame { forget(identity) }
            throw error
        }
    }

    private func savedFrame(for identity: WindowIdentity) -> CGRect? {
        lock.withLock { restoreFrames[identity] }
    }

    /// Saves the frame before Ting first moves the window. Returns false when one was already saved.
    private func remember(_ frame: CGRect, for identity: WindowIdentity) -> Bool {
        lock.withLock {
            guard restoreFrames[identity] == nil else { return false }
            restoreFrames[identity] = frame
            restoreOrder.append(identity)
            while restoreOrder.count > Self.restoreLimit {
                restoreFrames[restoreOrder.removeFirst()] = nil
            }
            return true
        }
    }

    private func forget(_ identity: WindowIdentity) {
        lock.withLock {
            restoreFrames[identity] = nil
            restoreOrder.removeAll { $0 == identity }
        }
    }

    private func frame(of window: AXUIElement) throws -> CGRect {
        guard let positionValue = attribute(window, kAXPositionAttribute),
              let sizeValue = attribute(window, kAXSizeAttribute),
              CFGetTypeID(positionValue) == AXValueGetTypeID(),
              CFGetTypeID(sizeValue) == AXValueGetTypeID() else {
            throw WindowManagementError.frameUnavailable
        }
        let positionAXValue = unsafeDowncast(positionValue, to: AXValue.self)
        let sizeAXValue = unsafeDowncast(sizeValue, to: AXValue.self)
        var position = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(positionAXValue, .cgPoint, &position),
              AXValueGetValue(sizeAXValue, .cgSize, &size) else {
            throw WindowManagementError.frameUnavailable
        }
        return CGRect(origin: position, size: size)
    }

    private func setFrame(_ appKitFrame: CGRect, of window: AXUIElement, primaryTop: CGFloat) throws {
        guard isSettable(kAXPositionAttribute, on: window) else { throw WindowManagementError.windowCannotMove }
        guard isSettable(kAXSizeAttribute, on: window) else { throw WindowManagementError.windowCannotResize }
        let accessibilityFrame = WindowCoordinates.accessibilityRect(from: appKitFrame, primaryTop: primaryTop)
        var position = accessibilityFrame.origin
        var size = accessibilityFrame.size
        guard let positionValue = AXValueCreate(.cgPoint, &position),
              let sizeValue = AXValueCreate(.cgSize, &size) else {
            throw WindowManagementError.operationFailed
        }
        // Resize before moving: moved first at its old size, a window can straddle two displays,
        // and some apps (Zed) then settle on a different size than requested. Resize again on the
        // destination, which macOS may have constrained while the window crossed displays.
        guard AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, sizeValue) == .success,
              AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, positionValue) == .success,
              AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, sizeValue) == .success else {
            throw WindowManagementError.operationFailed
        }
    }

    private func isSettable(_ name: String, on element: AXUIElement) -> Bool {
        var settable = DarwinBoolean(false)
        return AXUIElementIsAttributeSettable(element, name as CFString, &settable) == .success && settable.boolValue
    }

    private func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value
    }

    private func element(_ element: AXUIElement, _ name: String) -> AXUIElement? {
        guard let value = attribute(element, name), CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return unsafeDowncast(value, to: AXUIElement.self)
    }

    private func displayIndex(containing window: CGRect, among displays: [WindowDisplay]) -> Int? {
        displays.indices.max { intersectionArea(window, displays[$0].frame) < intersectionArea(window, displays[$1].frame) }
    }

    private func intersectionArea(_ lhs: CGRect, _ rhs: CGRect) -> CGFloat {
        let intersection = lhs.intersection(rhs)
        return intersection.isNull ? 0 : intersection.width * intersection.height
    }

    private func windowRect(_ rect: CGRect) -> WindowRect {
        WindowRect(originX: rect.minX, originY: rect.minY, width: rect.width, height: rect.height)
    }

    private func cgRect(_ rect: WindowRect) -> CGRect {
        CGRect(x: rect.originX, y: rect.originY, width: rect.width, height: rect.height)
    }
}

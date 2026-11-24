import AppKit
import ApplicationServices
import TingCore

@MainActor
protocol WindowManaging: AnyObject {
    func run(_ command: WindowCommand, gap: Double) throws
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
@MainActor
final class WindowManager: WindowManaging {
    private struct WindowIdentity: Hashable {
        var pid: pid_t
        var elementHash: Int
    }

    private var restoreFrames: [WindowIdentity: CGRect] = [:]

    func run(_ command: WindowCommand, gap: Double) throws {
        guard AXIsProcessTrusted() else { throw WindowManagementError.accessibility }
        guard let app = NSWorkspace.shared.frontmostApplication else {
            throw WindowManagementError.noFocusedApplication
        }
        let application = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(application, 1)
        guard let window = element(application, kAXFocusedWindowAttribute)
                ?? element(application, kAXMainWindowAttribute) else {
            throw WindowManagementError.noFocusedWindow
        }
        let identity = WindowIdentity(pid: app.processIdentifier, elementHash: Int(CFHash(window)))
        let accessibilityFrame = try frame(of: window)
        let screens = NSScreen.screens
        guard let primary = screens.first(where: { $0.frame.origin == .zero }) ?? screens.first else {
            throw WindowManagementError.operationFailed
        }
        let current = WindowCoordinates.appKitRect(from: accessibilityFrame, primaryTop: primary.frame.maxY)
        guard let screen = screen(containing: current, among: screens) else {
            throw WindowManagementError.operationFailed
        }

        if command == .restore {
            guard let original = restoreFrames[identity] else { throw WindowManagementError.noRestoreFrame }
            try setFrame(original, of: window, primaryTop: primary.frame.maxY)
            restoreFrames[identity] = nil
            return
        }

        let hadRestoreFrame = restoreFrames[identity] != nil
        if !hadRestoreFrame { restoreFrames[identity] = current }
        do {
            let destination: CGRect
            switch command {
            case .previousDisplay, .nextDisplay:
                guard screens.count > 1 else { throw WindowManagementError.noOtherDisplay }
                let ordered = screens.sorted {
                    if $0.frame.minX != $1.frame.minX { return $0.frame.minX < $1.frame.minX }
                    return $0.frame.maxY > $1.frame.maxY
                }
                guard let index = ordered.firstIndex(where: { $0 === screen }) else {
                    throw WindowManagementError.operationFailed
                }
                let offset = command == .previousDisplay ? -1 : 1
                let nextIndex = (index + offset + ordered.count) % ordered.count
                destination = cgRect(WindowGeometry.movedFrame(
                    windowRect(current), from: windowRect(screen.visibleFrame),
                    to: windowRect(ordered[nextIndex].visibleFrame), gap: gap))
            case .restore:
                throw WindowManagementError.noRestoreFrame
            default:
                guard let calculated = WindowGeometry.frame(for: command, current: windowRect(current),
                                                            visibleFrame: windowRect(screen.visibleFrame), gap: gap) else {
                    throw WindowManagementError.operationFailed
                }
                destination = cgRect(calculated)
            }
            try setFrame(destination, of: window, primaryTop: primary.frame.maxY)
        } catch {
            if !hadRestoreFrame { restoreFrames[identity] = nil }
            throw error
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
        // Some apps adjust their minimum size. Position again after resizing so the requested edge stays pinned.
        guard AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, positionValue) == .success,
              AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, sizeValue) == .success,
              AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, positionValue) == .success else {
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

    private func screen(containing window: CGRect, among screens: [NSScreen]) -> NSScreen? {
        screens.max { intersectionArea(window, $0.frame) < intersectionArea(window, $1.frame) }
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

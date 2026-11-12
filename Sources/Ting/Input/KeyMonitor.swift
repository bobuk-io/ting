// Key event plumbing shared by the recorders and the leader panel.
import AppKit
import CoreGraphics
import TingCore

extension ModifierSet {
    init(_ flags: NSEvent.ModifierFlags) {
        self = []
        if flags.contains(.control) { insert(.control) }
        if flags.contains(.option) { insert(.option) }
        if flags.contains(.shift) { insert(.shift) }
        if flags.contains(.command) { insert(.command) }
        if flags.contains(.function) { insert(.function) }
    }

    init(_ flags: CGEventFlags) {
        self = []
        if flags.contains(.maskControl) { insert(.control) }
        if flags.contains(.maskAlternate) { insert(.option) }
        if flags.contains(.maskShift) { insert(.shift) }
        if flags.contains(.maskCommand) { insert(.command) }
        if flags.contains(.maskSecondaryFn) { insert(.function) }
    }
}

/// Owns an NSEvent local monitor (keyDown + flagsChanged) for the lifetime of a recorder.
@MainActor
final class KeyMonitor {
    private var token: Any?

    func start(_ handler: @escaping (NSEvent) -> NSEvent?) {
        stop()
        token = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged], handler: handler)
    }

    func stop() {
        if let token { NSEvent.removeMonitor(token) }
        token = nil
    }
}

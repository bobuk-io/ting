import AppKit
import XCTest
import TingCore
@testable import Ting

@MainActor
final class LeaderPanelDispatchTests: XCTestCase {
    func testCommandShortcutsRemainSwallowed() throws {
        _ = NSApplication.shared
        let panel = LeaderPanel()
        var delivered = false
        panel.onKeyDown = { _ in delivered = true }
        let event = try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0,
            windowNumber: panel.windowNumber, context: nil, characters: "q",
            charactersIgnoringModifiers: "q", isARepeat: false, keyCode: 12))
        XCTAssertTrue(panel.performKeyEquivalent(with: event))
        XCTAssertFalse(delivered)
    }

    func testSettingsShortcutMatchesOnlyPlainCommandComma() {
        XCTAssertTrue(SettingsOpener.isShortcut(latin: ",", flags: .command))
        // Device-dependent bits such as caps lock do not matter.
        XCTAssertTrue(SettingsOpener.isShortcut(latin: ",", flags: [.command, .capsLock]))
        XCTAssertFalse(SettingsOpener.isShortcut(latin: ",", flags: [.command, .shift]))
        XCTAssertFalse(SettingsOpener.isShortcut(latin: ",", flags: []))
        XCTAssertFalse(SettingsOpener.isShortcut(latin: "q", flags: .command))
        XCTAssertFalse(SettingsOpener.isShortcut(latin: nil, flags: .command))
    }

    func testCommandCommaInSelectaOpensSettings() throws {
        _ = NSApplication.shared
        // The panel reads the key by the Latin layout; skip on a Mac whose ASCII layout puts no "," on key 43.
        try XCTSkipUnless(KeyTranslator.latin(43) == ",")
        let panel = LeaderPanel()
        var opened = 0
        var delivered = false
        panel.onOpenSettings = { opened += 1 }
        panel.onKeyDown = { _ in delivered = true }
        func press(_ chars: String, _ code: UInt16, repeat isARepeat: Bool = false) throws -> Bool {
            let event = try XCTUnwrap(NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0,
                windowNumber: panel.windowNumber, context: nil, characters: chars,
                charactersIgnoringModifiers: chars, isARepeat: isARepeat, keyCode: code))
            return panel.performKeyEquivalent(with: event)
        }
        XCTAssertTrue(try press(",", 43))
        XCTAssertEqual(opened, 1)
        // A held key does not open Settings again; ⌘Q stays swallowed and opens nothing.
        XCTAssertTrue(try press(",", 43, repeat: true))
        XCTAssertTrue(try press("q", 12))
        XCTAssertEqual(opened, 1)
        XCTAssertFalse(delivered)
    }

    func testOpeningSettingsFromALauncherClosesTheLaunchers() {
        _ = NSApplication.shared
        let model = AppModel(presentsWindows: false)
        var opened = 0
        model.settingsOpener = { opened += 1 }
        model.launcha.open()
        XCTAssertTrue(model.launcha.isOpen)
        model.openSettingsFromLauncher()
        XCTAssertFalse(model.launcha.isOpen)
        XCTAssertFalse(model.leader.isOpen)
        XCTAssertFalse(model.clipbawdPanel.isOpen)
        XCTAssertEqual(opened, 1)
    }

    func testKeyEquivalentDispatchReachesSelectaExactlyOnce() throws {
        _ = NSApplication.shared
        let controller = LeaderController(presentsWindow: false)
        var config = Config()
        let first = Item(key: "a", label: "A", action: .url("https://example.com/a"))
        let second = Item(key: "b", label: "B", action: .url("https://example.com/b"))
        config.items = [first, second]
        controller.configure(config)
        controller.leaderPressed(at: 1)
        controller.leaderReleased()
        let panel = LeaderPanel()
        var delivered: [UInt16] = []
        var ran: [Item] = []
        panel.onKeyDown = { delivered.append($0.keyCode); controller.handleKeyDown($0) }
        controller.onRun = { ran.append($0) }
        // AppKit tries key equivalents before normal window dispatch. Never post system events.
        for (code, text, flags) in [(UInt16(125), "\u{F701}", NSEvent.ModifierFlags([.function, .numericPad])),
                                    (UInt16(36), "\r", NSEvent.ModifierFlags())] {
            let event = try XCTUnwrap(NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0,
                windowNumber: panel.windowNumber, context: nil, characters: text,
                charactersIgnoringModifiers: text, isARepeat: false, keyCode: code))
            if !panel.performKeyEquivalent(with: event) { panel.sendEvent(event) }
        }
        XCTAssertEqual(delivered, [125, 36])
        XCTAssertEqual(ran, [second])
    }
}

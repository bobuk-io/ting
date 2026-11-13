import AppKit
import XCTest
import TingCore
@testable import Ting

@MainActor
private final class FakeRecorder: HotkeyRecordingOwner {
    let gate: HotkeyRecordingGate
    private(set) var isRecording = false
    private(set) var cancels = 0

    init(gate: HotkeyRecordingGate) { self.gate = gate }

    func start() {
        isRecording = true
        gate.begin(self)
    }

    func cancel() {
        cancels += 1
        guard isRecording else { return }
        isRecording = false
        gate.end(self)
    }
}

@MainActor
final class HotkeyRecordingGateTests: XCTestCase {
    func testSecondRecordingCancelsFirstAndKeepsHotkeysOff() {
        var changes: [Bool] = []
        let gate = HotkeyRecordingGate { changes.append($0) }
        let leader = FakeRecorder(gate: gate)
        let launcha = FakeRecorder(gate: gate)

        leader.start()
        XCTAssertEqual(changes, [true])
        launcha.start()
        // The first recording stopped; the hotkeys never came back on in between.
        XCTAssertFalse(leader.isRecording)
        XCTAssertTrue(gate.isActive)
        XCTAssertEqual(changes, [true])

        // A late cancel of the old recorder does nothing.
        leader.cancel()
        XCTAssertTrue(gate.isActive)
        XCTAssertEqual(changes, [true])

        launcha.cancel()
        XCTAssertFalse(gate.isActive)
        XCTAssertEqual(changes, [true, false])
    }

    func testEndFromNonOwnerIsIgnored() {
        var changes: [Bool] = []
        let gate = HotkeyRecordingGate { changes.append($0) }
        let owner = FakeRecorder(gate: gate)
        let other = FakeRecorder(gate: gate)
        owner.start()
        gate.end(other)
        XCTAssertTrue(gate.isActive)
        gate.end(owner)
        gate.end(owner)
        XCTAssertFalse(gate.isActive)
        XCTAssertEqual(changes, [true, false])
    }

    func testRestartBySameOwnerDoesNotCancelItself() {
        var changes: [Bool] = []
        let gate = HotkeyRecordingGate { changes.append($0) }
        let owner = FakeRecorder(gate: gate)
        owner.start()
        owner.start()
        XCTAssertEqual(owner.cancels, 0)
        XCTAssertEqual(changes, [true])
    }

    func testDeallocatedOwnerDoesNotLeaveHotkeysOffForever() {
        var changes: [Bool] = []
        let gate = HotkeyRecordingGate { changes.append($0) }
        var owner: FakeRecorder? = FakeRecorder(gate: gate)
        owner?.start()
        owner = nil
        let next = FakeRecorder(gate: gate)
        next.start()
        next.cancel()
        XCTAssertFalse(gate.isActive)
        XCTAssertEqual(changes, [true, false])
    }
}

final class LaunchaPanelKeyRouteTests: XCTestCase {
    private func route(_ keyCode: UInt16, _ latin: String? = nil, _ flags: NSEvent.ModifierFlags) -> LaunchaPanel.KeyEquivalentRoute {
        LaunchaPanel.route(keyCode: keyCode, latin: latin, flags: flags)
    }

    func testCommandArrowsAndDeletesGoToTheEditor() {
        let editing: [UInt16] = [51, 117, 123, 124, 125, 126]
        let combos: [NSEvent.ModifierFlags] = [.command, [.command, .shift], [.command, .option],
                                               [.command, .shift, .option]]
        for keyCode in editing {
            for flags in combos {
                XCTAssertEqual(route(keyCode, nil, flags), .editor, "key \(keyCode) flags \(flags)")
            }
        }
    }

    func testPlainEditingIsNotTouched() {
        XCTAssertEqual(route(0, "a", []), .editor)
        XCTAssertEqual(route(51, nil, []), .editor)
        XCTAssertEqual(route(123, nil, .shift), .editor)
        XCTAssertEqual(route(51, nil, .option), .editor)
    }

    func testTextCommandsAndReveal() {
        XCTAssertEqual(route(9, "v", .command), .action(#selector(NSText.paste(_:))))
        XCTAssertEqual(route(6, "z", [.command, .shift]), .action(NSSelectorFromString("redo:")))
        XCTAssertEqual(route(36, nil, .command), .reveal)
        XCTAssertEqual(route(76, nil, .command), .reveal)
        XCTAssertEqual(route(36, nil, [.command, .shift]), .swallow)
    }

    func testAppCommandsAreSwallowed() {
        XCTAssertEqual(route(12, "q", .command), .swallow)
        XCTAssertEqual(route(13, "w", .command), .swallow)
        XCTAssertEqual(route(43, ",", .command), .swallow)
        XCTAssertEqual(route(4, "h", .command), .swallow)
    }
}

@MainActor
final class LeaderTokenLabelTests: XCTestCase {
    func testDefaultLabelsNameTheKeyAndDoubleTap() {
        XCTAssertEqual(LeaderToken.label(leader: "⌥Space", taps: 1, description: nil), "Leader key ⌥Space")
        XCTAssertEqual(LeaderToken.label(leader: "⌥Space", taps: 2, description: nil), "Leader key ⌥Space, pressed twice")
        XCTAssertEqual(LeaderToken.label(leader: "", taps: 1, description: nil), "Leader key")
        XCTAssertEqual(LeaderToken.label(leader: "⌥Space", taps: 2, description: "Open launcha"), "Open launcha")
    }

    func testLaunchaDescriptionNamesTheRealKeys() {
        var config = Config()
        XCTAssertEqual(LaunchaController.tokenDescription(config), "Open launcha")
        config.leader = .combo(keyCode: 49, modifiers: [.option])
        let leader = config.leader!.display
        XCTAssertEqual(LaunchaController.tokenDescription(config), "Open launcha: \(leader) pressed twice")
        config.launcha.hotkey = .combo(keyCode: 40, modifiers: [.command])
        let hotkey = config.launcha.hotkey!.display
        XCTAssertEqual(LaunchaController.tokenDescription(config),
                       "Open launcha: \(leader) pressed twice, or \(hotkey)")
        config.launcha.doubleTap = false
        XCTAssertEqual(LaunchaController.tokenDescription(config), "Open launcha: \(hotkey)")
    }
}

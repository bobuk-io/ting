import AppKit
import XCTest
import TingCore
@testable import Ting

@MainActor
final class WindowManagerTests: XCTestCase {
    private final class FakeWindowManager: WindowManaging {
        var calls: [(WindowCommand, Double)] = []
        var error: Error?

        func run(_ command: WindowCommand, gap: Double) throws {
            if let error { throw error }
            calls.append((command, gap))
        }
    }

    private func model(windowManager: WindowManaging, hotkeys: HotkeyService? = nil) throws -> AppModel {
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ting-window-tests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return AppModel(presentsWindows: false, store: ConfigStore(url: directory.appendingPathComponent("config.json")),
                        hotkeys: hotkeys, windowManager: windowManager)
    }

    private func key(_ value: String) -> Hotkey { Hotkey(string: value)! }

    func testAccessibilityAndAppKitCoordinatesRoundTripAcrossPrimaryTop() {
        let accessibility = CGRect(x: -1200, y: 100, width: 800, height: 600)
        let appKit = WindowCoordinates.appKitRect(from: accessibility, primaryTop: 1080)
        XCTAssertEqual(appKit, CGRect(x: -1200, y: 380, width: 800, height: 600))
        XCTAssertEqual(WindowCoordinates.accessibilityRect(from: appKit, primaryTop: 1080), accessibility)
    }

    func testModelRunsACommandWithConfiguredGapAndHandlesPermission() throws {
        let manager = FakeWindowManager()
        let model = try model(windowManager: manager)
        model.update { $0.windowManagement.gap = 13 }
        model.runWindowCommand(.topRightQuarter)
        XCTAssertEqual(manager.calls.map { $0.0 }, [.topRightQuarter])
        XCTAssertEqual(manager.calls.first?.1, 13)

        manager.error = WindowManagementError.accessibility
        model.runWindowCommand(.leftHalf)
        XCTAssertEqual(manager.calls.map { $0.0 }, [.topRightQuarter])
    }

    func testDirectWindowHotkeyRegistersAndDispatchesOncePerHold() async throws {
        let manager = FakeWindowManager()
        let service = HotkeyService(register: { _, _ in .active })
        let model = try model(windowManager: manager, hotkeys: service)
        model.update {
            $0.leader = self.key("home")
            $0.windowManagement.gap = 7
            $0.windowManagement.shortcuts = [.init(command: .leftHalf, hotkey: self.key("cmd+f12"))]
        }
        service.onPress = { [weak model] in model?.hotkeyPressed($0, at: $1) }
        service.onRelease = { [weak model] in model?.hotkeyReleased($0) }

        XCTAssertEqual(HotkeyService.Slot(rawValue: HotkeyService.Slot.windowBaseID), .window(0))
        XCTAssertEqual(service.hotkey(.window(0)), key("cmd+f12"))
        service.receive(.window(0), pressed: true)
        service.receive(.window(0), pressed: true)
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(manager.calls.map { $0.0 }, [.leftHalf])
        XCTAssertEqual(manager.calls.first?.1, 7)
        service.receive(.window(0), pressed: false)
        service.receive(.window(0), pressed: true)
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(manager.calls.map { $0.0 }, [.leftHalf, .leftHalf])
    }

    func testWindowHotkeyOSConflictAppearsOnTheCommand() throws {
        let manager = FakeWindowManager()
        let service = HotkeyService(register: { hotkey, _ in
            hotkey == self.key("cmd+f12") ? .failed("Already used by another app.") : .active
        })
        let model = try model(windowManager: manager, hotkeys: service)
        model.update {
            $0.leader = self.key("home")
            $0.windowManagement.shortcuts = [.init(command: .maximize, hotkey: self.key("cmd+f12"))]
        }
        XCTAssertEqual(model.windowHotkeyProblem(.maximize), "Already used by another app.")
        XCTAssertTrue(model.needsAttention)
    }
}

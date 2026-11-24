import Foundation
import Testing
@testable import TingCore

@Suite struct WindowGeometryTests {
    private let screen = WindowRect(originX: 0, originY: 0, width: 1000, height: 800)
    private let current = WindowRect(originX: 100, originY: 120, width: 300, height: 200)

    @Test func halvesQuartersAndThirdsHonorOneGap() throws {
        let left = try #require(WindowGeometry.frame(for: .leftHalf, current: current, visibleFrame: screen, gap: 10))
        let right = try #require(WindowGeometry.frame(for: .rightHalf, current: current, visibleFrame: screen, gap: 10))
        #expect(left == WindowRect(originX: 10, originY: 10, width: 485, height: 780))
        #expect(right == WindowRect(originX: 505, originY: 10, width: 485, height: 780))
        #expect(right.minX - left.maxX == 10)

        let topLeft = try #require(WindowGeometry.frame(for: .topLeftQuarter, current: current,
                                                        visibleFrame: screen, gap: 10))
        #expect(topLeft == WindowRect(originX: 10, originY: 405, width: 485, height: 385))
        let bottomRight = try #require(WindowGeometry.frame(for: .bottomRightQuarter, current: current,
                                                            visibleFrame: screen, gap: 10))
        #expect(bottomRight == WindowRect(originX: 505, originY: 10, width: 485, height: 385))

        let thirds = [WindowCommand.firstThird, .centerThird, .lastThird].compactMap {
            WindowGeometry.frame(for: $0, current: current, visibleFrame: screen, gap: 10)
        }
        #expect(thirds == [
            WindowRect(originX: 10, originY: 10, width: 320, height: 780),
            WindowRect(originX: 340, originY: 10, width: 320, height: 780),
            WindowRect(originX: 670, originY: 10, width: 320, height: 780),
        ])
    }

    @Test func maximizeAndCenterStayInsideTheUsableFrame() throws {
        #expect(WindowGeometry.frame(for: .maximize, current: current, visibleFrame: screen, gap: 12)
                == WindowRect(originX: 12, originY: 12, width: 976, height: 776))
        #expect(WindowGeometry.frame(for: .center, current: current, visibleFrame: screen, gap: 0)
                == WindowRect(originX: 350, originY: 300, width: 300, height: 200))

        let oversized = WindowRect(originX: -100, originY: -100, width: 1400, height: 900)
        #expect(WindowGeometry.frame(for: .center, current: oversized, visibleFrame: screen, gap: 10)
                == WindowRect(originX: 10, originY: 10, width: 980, height: 780))
    }

    @Test func displayMovementPreservesSizeAndRelativeCenter() {
        let destination = WindowRect(originX: 1000, originY: 100, width: 800, height: 600)
        let moved = WindowGeometry.movedFrame(current, from: screen, to: destination, gap: 10)
        #expect(moved.width == current.width)
        #expect(moved.height == current.height)
        #expect(moved.minX >= 1010 && moved.maxX <= 1790)
        #expect(moved.minY >= 110 && moved.maxY <= 690)

        let tiny = WindowRect(originX: -500, originY: 0, width: 200, height: 150)
        let reduced = WindowGeometry.movedFrame(current, from: screen, to: tiny, gap: 10)
        #expect(reduced == WindowRect(originX: -490, originY: 10, width: 180, height: 130))
    }

    @Test func statefulCommandsDoNotInventAFrame() {
        for command in [WindowCommand.restore, .previousDisplay, .nextDisplay] {
            #expect(WindowGeometry.frame(for: command, current: current, visibleFrame: screen, gap: 0) == nil)
        }
    }
}

@Suite struct WindowManagementConfigTests {
    private func key(_ value: String) -> Hotkey { Hotkey(string: value)! }

    @Test func oldConfigDefaultsAndNewConfigRoundTrips() throws {
        let old = try ConfigCodec.decode(Data("{}".utf8))
        #expect(old.windowManagement == WindowManagementSettings())

        var config = Config()
        config.windowManagement.gap = 14
        config.windowManagement.shortcuts = [
            WindowShortcut(command: .leftHalf, hotkey: key("option+cmd+left")),
            WindowShortcut(command: .rightHalf, hotkey: key("option+cmd+right")),
        ]
        config.items = [.window("h", "Left Half", .leftHalf)]
        let decoded = try ConfigCodec.decode(ConfigCodec.encode(config))
        #expect(decoded == config)
        #expect(decoded.items == [.window("h", "Left Half", .leftHalf)])
    }

    @Test func gapClampsAndUnknownCommandIsInvalid() throws {
        let low = try ConfigCodec.decode(Data(#"{"windowManagement":{"gap":-4}}"#.utf8))
        let high = try ConfigCodec.decode(Data(#"{"windowManagement":{"gap":1000}}"#.utf8))
        #expect(low.windowManagement.gap == WindowManagementSettings.gapRange.lowerBound)
        #expect(high.windowManagement.gap == WindowManagementSettings.gapRange.upperBound)
        #expect(throws: (any Error).self) {
            try ConfigCodec.decode(Data(#"{"items":[{"key":"w","window":"sideways"}]}"#.utf8))
        }
    }

    @Test func shortcutAssignmentProtectsEveryExistingOwner() throws {
        var config = Config()
        config.leader = key("home")
        config.launcha.hotkey = key("cmd+space")
        config.appHotkeys = [.init(id: "app:Editor", name: "Editor", path: "/Applications/Editor.app",
                                    hotkey: key("cmd+f12"))]
        try WindowShortcutRules.assign(command: .leftHalf, hotkey: key("cmd+f13"), in: &config)
        let saved = config
        for hotkey in [key("home"), key("cmd+space"), key("cmd+f12")] {
            #expect(throws: (any Error).self) {
                try WindowShortcutRules.assign(command: .rightHalf, hotkey: hotkey, in: &config)
            }
            #expect(config == saved)
        }
        try WindowShortcutRules.assign(command: .leftHalf, hotkey: nil, in: &config)
        #expect(config.windowManagement.shortcuts.isEmpty)
    }

    @Test func importedAssignmentsGiveWindowsPrecedenceOverApps() {
        var config = Config()
        config.leader = key("home")
        config.windowManagement.shortcuts = [
            .init(command: .leftHalf, hotkey: key("cmd+f12")),
            .init(command: .rightHalf, hotkey: key("cmd+f12")),
            .init(command: .leftHalf, hotkey: key("cmd+f13")),
        ]
        config.appHotkeys = [
            .init(id: "app:One", name: "One", path: "/Applications/One.app", hotkey: key("cmd+f12")),
            .init(id: "app:Two", name: "Two", path: "/Applications/Two.app", hotkey: key("cmd+f14")),
        ]
        let assignments = HotkeyAssignments(config)
        #expect(assignments.windows == [.init(command: .leftHalf, hotkey: key("cmd+f12"))])
        #expect(assignments.applications.map(\.name) == ["Two"])
        #expect(assignments.issues.filter { $0.kind == .windowHotkey }.count == 2)
        #expect(assignments.issues.filter { $0.kind == .appHotkey }.count == 1)
    }
}

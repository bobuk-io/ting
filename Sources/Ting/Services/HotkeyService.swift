// Global hotkeys: launchers plus direct application and focused-window shortcuts.
// Each is any non-modifier key, alone or with modifiers. Registered through BobukKit's
// `GlobalHotkeyCenter` (Carbon `RegisterEventHotKey`, no Accessibility or Input Monitoring
// permission, press and release). This layer adds Ting's slots and the role messages.
import AppKit
import BobukSystem
import TingCore

@MainActor
final class HotkeyService {
    /// The hotkeys Ting registers. The raw value is the Carbon hotkey id.
    enum Slot: Hashable, Sendable {
        case leader, alternateLeader
        case launcha
        case clipbawd
        case chatta
        case application(Int)
        case window(Int)

        /// Far above any application index, with window commands in their own range below it.
        static let windowBaseID: UInt32 = 0x4000_0000
        static let clipbawdID: UInt32 = 0x7FFF_0000

        init(_ launcher: LauncherHotkey) {
            switch launcher {
            case .leader: self = .leader
            case .alternateLeader: self = .alternateLeader
            case .launcha: self = .launcha
            case .clipbawd: self = .clipbawd
            case .chatta: self = .chatta
            }
        }

        var rawValue: UInt32 {
            switch self {
            case .alternateLeader: Self.clipbawdID + 1
            case .chatta: Self.clipbawdID + 2
            case .leader: 1
            case .launcha: 2
            case .clipbawd: Self.clipbawdID
            case .application(let index): UInt32(index) + 3
            case .window(let index): Self.windowBaseID + UInt32(index)
            }
        }

        init?(rawValue: UInt32) {
            switch rawValue {
            case 0: return nil
            case 1: self = .leader
            case 2: self = .launcha
            case Self.clipbawdID: self = .clipbawd
            case Self.clipbawdID + 1: self = .alternateLeader
            case Self.clipbawdID + 2: self = .chatta
            case Self.windowBaseID..<Self.clipbawdID: self = .window(Int(rawValue - Self.windowBaseID))
            default: self = .application(Int(rawValue - 3))
            }
        }

        var role: String {
            switch self {
            case .leader, .alternateLeader: "be a leader"
            case .launcha: "open launcha"
            case .clipbawd: "open clipbawd"
            case .chatta: "open chatta"
            case .application: "open an application"
            case .window: "move a window"
            }
        }
    }

    typealias Status = GlobalHotkeyCenter.Status

    /// A registered hotkey was pressed. The time is in seconds since system start.
    var onPress: ((Slot, TimeInterval) -> Void)?
    /// A registered hotkey was released.
    var onRelease: ((Slot) -> Void)?
    var onStatusChange: ((Slot, Status) -> Void)?

    private let center: GlobalHotkeyCenter
    /// Every assigned hotkey, also those that failed: a later slot must not take the same key.
    private var hotkeys: [Slot: Hotkey] = [:]
    /// Ting's own refusals (not a valid key, already used by another slot); never sent to Carbon.
    private var refusals: [Slot: String] = [:]
    /// The last status reported through `onStatusChange`.
    private var reported: [Slot: Status] = [:]

    static let signature = OSType(fourCharacterCode: "TING") // 0x5449_4E47

    /// `register` is the test backend instead of real global shortcuts.
    init(register: ((Hotkey, Slot) -> Status)? = nil) {
        let backend: ((Hotkey, UInt32) -> Status)? = register.map { register in
            { hotkey, id in register(hotkey, Slot(rawValue: id) ?? .leader) }
        }
        center = GlobalHotkeyCenter(signature: Self.signature, register: backend)
        center.onStatusChange = { [weak self] id, _ in
            guard let self, let slot = Slot(rawValue: id) else { return }
            self.report(slot)
        }
    }

    func status(_ slot: Slot) -> Status {
        if let reason = refusals[slot] { return .failed(reason) }
        return center.status(slot.rawValue)
    }

    func hotkey(_ slot: Slot) -> Hotkey? { hotkeys[slot] }

    /// Activates `hotkey` in `slot`, replacing the previous one. nil turns the slot off.
    /// A slot that goes off while its key is down reports a release, so callers never keep
    /// a stale "held" state.
    func activate(_ hotkey: Hotkey?, for slot: Slot) {
        if let hotkey, hotkey == hotkeys[slot], status(slot) == .active { return }
        deactivate(slot)
        guard let hotkey else { return }
        hotkeys[slot] = hotkey
        guard hotkey.isValid, case .combo = hotkey else {
            return refuse(slot, "\(hotkey.display) cannot \(slot.role). Choose a key that is not a modifier.")
        }
        if let other = hotkeys.keys.first(where: { $0 != slot && hotkeys[$0] == hotkey }) {
            let role: String
            switch other {
            case .leader, .alternateLeader: role = "the leader"
            case .launcha: role = "launcha"
            case .clipbawd: role = "clipbawd"
            case .chatta: role = "chatta"
            case .application: role = "another application"
            case .window: role = "another window command"
            }
            return refuse(slot, "\(hotkey.display) is already used for \(role).")
        }
        // Direct actions run once per hold; launcher hotkeys see Carbon's repeats.
        let repeats: Bool
        switch slot {
        case .application, .window: repeats = false
        default: repeats = true
        }
        center.register(hotkey, id: slot.rawValue, repeats: repeats,
                        onPress: { [weak self] time in self?.onPress?(slot, time) },
                        onRelease: { [weak self] in self?.onRelease?(slot) })
    }

    /// Release all changed slots before claiming any key, including swaps on config reload.
    func apply(_ assignments: HotkeyAssignments?) {
        var desired: [(Slot, Hotkey)] = []
        if let assignments {
            for launcher in LauncherHotkey.allCases {
                if let key = assignments.launchers[launcher] { desired.append((Slot(launcher), key)) }
            }
            for (index, shortcut) in assignments.windows.enumerated() {
                desired.append((.window(index), shortcut.hotkey))
            }
            for (index, shortcut) in assignments.applications.enumerated() {
                desired.append((.application(index), shortcut.hotkey))
            }
        }
        let keys = Dictionary(uniqueKeysWithValues: desired)
        for (slot, hotkey) in hotkeys where keys[slot] != hotkey {
            deactivate(slot)
        }
        for (slot, key) in desired { activate(key, for: slot) }
    }

    /// Probe an OS conflict while Ting's registrations are suspended for recording.
    func checkAvailable(_ hotkey: Hotkey) -> String? {
        let slot = Slot.application(Int(UInt32.max - 3))
        activate(hotkey, for: slot)
        defer { deactivate(slot) }
        if case .failed(let reason) = status(slot) { return reason }
        return nil
    }

    /// Delivers a press or release as Carbon does (tests). A held application shortcut reports once.
    func receive(_ slot: Slot, pressed: Bool, at time: TimeInterval = 0) {
        center.receive(slot.rawValue, pressed: pressed, at: time)
    }

    private func deactivate(_ slot: Slot) {
        hotkeys[slot] = nil
        refusals[slot] = nil
        // The center reports the release of a key that is down and the new status.
        center.unregister(slot.rawValue)
        report(slot)
    }

    private func refuse(_ slot: Slot, _ reason: String) {
        refusals[slot] = reason
        report(slot)
    }

    private func report(_ slot: Slot) {
        let status = status(slot)
        guard reported[slot] != status else { return }
        reported[slot] = status
        onStatusChange?(slot, status)
    }
}

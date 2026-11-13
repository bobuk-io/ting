// Global hotkeys: the leader and the optional launcha hotkey. Each is any non-modifier key,
// alone or with modifiers. Registered with Carbon `RegisterEventHotKey`, which needs no
// Accessibility or Input Monitoring permission. Carbon reports both press and release.
import AppKit
import Carbon
import OSLog
import TingCore

private let log = Logger(subsystem: "io.bobuk.ting", category: "hotkey")

@MainActor
final class HotkeyService {
    /// The hotkeys Ting registers. The raw value is the Carbon hotkey id.
    enum Slot: UInt32, CaseIterable, Sendable {
        case leader = 1
        case launcha = 2

        var role: String {
            switch self {
            case .leader: "be a leader"
            case .launcha: "open launcha"
            }
        }
    }

    enum Status: Equatable {
        /// No hotkey, paused, or recording a new hotkey.
        case inactive
        case active
        /// Registration failed; the text says why.
        case failed(String)
    }

    /// A registered hotkey was pressed. The time is in seconds since system start.
    var onPress: ((Slot, TimeInterval) -> Void)?
    /// A registered hotkey was released.
    var onRelease: ((Slot) -> Void)?
    var onStatusChange: ((Slot, Status) -> Void)?

    private var registrations: [Slot: Registration] = [:]
    private var statuses: [Slot: Status] = [:]
    private var handlerRef: EventHandlerRef?

    private struct Registration {
        var hotkey: Hotkey
        var ref: EventHotKeyRef?
    }

    /// The C callback cannot capture context; it reaches the single service through this.
    private static weak var shared: HotkeyService?

    init() {
        HotkeyService.shared = self
    }

    func status(_ slot: Slot) -> Status { statuses[slot] ?? .inactive }

    func hotkey(_ slot: Slot) -> Hotkey? { registrations[slot]?.hotkey }

    /// Activates `hotkey` in `slot`, replacing the previous one. nil turns the slot off.
    /// A slot that goes off while its key is down reports a release, so callers never keep
    /// a stale "held" state.
    func activate(_ hotkey: Hotkey?, for slot: Slot) {
        if let hotkey, hotkey == registrations[slot]?.hotkey, status(slot) == .active { return }
        deactivate(slot)
        guard let hotkey else { return }
        registrations[slot] = Registration(hotkey: hotkey, ref: nil)
        guard hotkey.isValid, case .combo(let keyCode, let modifiers) = hotkey else {
            setStatus(.failed("\(hotkey.display) cannot \(slot.role). Choose a key that is not a modifier."), for: slot)
            return
        }
        if let other = Slot.allCases.first(where: { $0 != slot && registrations[$0]?.hotkey == hotkey }) {
            setStatus(.failed("\(hotkey.display) is already used for \(other == .leader ? "the leader" : "launcha")."), for: slot)
            return
        }
        register(keyCode: keyCode, modifiers: modifiers, display: hotkey.display, slot: slot)
    }

    private func deactivate(_ slot: Slot) {
        let hadRef = registrations[slot]?.ref != nil
        if let ref = registrations[slot]?.ref { UnregisterEventHotKey(ref) }
        registrations[slot] = nil
        setStatus(.inactive, for: slot)
        // Carbon sends no release for a hotkey that is gone.
        if hadRef { onRelease?(slot) }
    }

    private func setStatus(_ status: Status, for slot: Slot) {
        guard statuses[slot] != status else { return }
        statuses[slot] = status
        log.info("Hotkey \(slot.rawValue) \(self.registrations[slot]?.hotkey.string ?? "none", privacy: .public): \(String(describing: status), privacy: .public)")
        onStatusChange?(slot, status)
    }

    private func register(keyCode: UInt16, modifiers: ModifierSet, display: String, slot: Slot) {
        installCarbonHandler()
        var carbonModifiers: UInt32 = 0
        if modifiers.contains(.command) { carbonModifiers |= UInt32(cmdKey) }
        if modifiers.contains(.shift) { carbonModifiers |= UInt32(shiftKey) }
        if modifiers.contains(.option) { carbonModifiers |= UInt32(optionKey) }
        if modifiers.contains(.control) { carbonModifiers |= UInt32(controlKey) }
        let id = EventHotKeyID(signature: HotkeyService.signature, id: slot.rawValue)
        var ref: EventHotKeyRef?
        let result = RegisterEventHotKey(UInt32(keyCode), carbonModifiers, id, GetApplicationEventTarget(),
                                         OptionBits(kEventHotKeyExclusive), &ref)
        if result == noErr, let ref {
            registrations[slot]?.ref = ref
            setStatus(.active, for: slot)
        } else if result == OSStatus(eventHotKeyExistsErr) {
            setStatus(.failed("\(display) is already used by another app."), for: slot)
        } else {
            setStatus(.failed("Cannot register \(display) (error \(result))."), for: slot)
        }
    }

    private static let signature = OSType(0x5449_4E47) // 'TING'

    private func installCarbonHandler() {
        guard handlerRef == nil else { return }
        var specs = [
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased)),
        ]
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ -> OSStatus in
            guard let event else { return OSStatus(eventNotHandledErr) }
            var id = EventHotKeyID()
            let status = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                           nil, MemoryLayout<EventHotKeyID>.size, nil, &id)
            guard status == noErr, id.signature == HotkeyService.signature,
                  let slot = Slot(rawValue: id.id) else { return OSStatus(eventNotHandledErr) }
            let kind = GetEventKind(event)
            let time = GetEventTime(event)
            MainActor.assumeIsolated {
                guard let service = HotkeyService.shared, service.registrations[slot]?.ref != nil else { return }
                if kind == UInt32(kEventHotKeyPressed) {
                    log.debug("Hotkey \(slot.rawValue) pressed")
                    service.onPress?(slot, time)
                } else if kind == UInt32(kEventHotKeyReleased) {
                    service.onRelease?(slot)
                }
            }
            return noErr
        }, specs.count, &specs, nil, &handlerRef)
    }
}

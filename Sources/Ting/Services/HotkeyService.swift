// The global leader hotkey: any non-modifier key, alone or with modifiers.
// Registered with Carbon `RegisterEventHotKey`, which needs no Accessibility or Input Monitoring permission.
import AppKit
import Carbon
import OSLog
import TingCore

private let log = Logger(subsystem: "io.bobuk.ting", category: "hotkey")

@MainActor
final class HotkeyService {
    enum Status: Equatable {
        /// No leader, paused, or recording a new leader.
        case inactive
        case active
        /// Registration failed; the text says why.
        case failed(String)
    }

    var onLeader: (() -> Void)?
    var onStatusChange: ((Status) -> Void)?

    private(set) var status: Status = .inactive {
        didSet {
            guard status != oldValue else { return }
            log.info("Leader \(self.hotkey?.string ?? "none", privacy: .public): \(String(describing: self.status), privacy: .public)")
            onStatusChange?(status)
        }
    }

    private var hotkey: Hotkey?
    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?

    /// The C callback cannot capture context; it reaches the single service through this.
    private static weak var shared: HotkeyService?

    init() {
        HotkeyService.shared = self
    }

    /// Activates `hotkey`, replacing the previous one. nil turns the leader off.
    func activate(_ hotkey: Hotkey?) {
        if hotkey == self.hotkey, status == .active { return }
        deactivate()
        self.hotkey = hotkey
        guard let hotkey else { return }
        guard hotkey.isValid, case .combo(let keyCode, let modifiers) = hotkey else {
            status = .failed("\(hotkey.display) cannot be a leader. Choose a key that is not a modifier.")
            return
        }
        registerCombo(keyCode: keyCode, modifiers: modifiers, display: hotkey.display)
    }

    private func deactivate() {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        hotKeyRef = nil
        hotkey = nil
        status = .inactive
    }

    private func registerCombo(keyCode: UInt16, modifiers: ModifierSet, display: String) {
        installCarbonHandler()
        var carbonModifiers: UInt32 = 0
        if modifiers.contains(.command) { carbonModifiers |= UInt32(cmdKey) }
        if modifiers.contains(.shift) { carbonModifiers |= UInt32(shiftKey) }
        if modifiers.contains(.option) { carbonModifiers |= UInt32(optionKey) }
        if modifiers.contains(.control) { carbonModifiers |= UInt32(controlKey) }
        let id = EventHotKeyID(signature: OSType(0x5449_4E47), id: 1) // 'TING'
        var ref: EventHotKeyRef?
        let result = RegisterEventHotKey(UInt32(keyCode), carbonModifiers, id, GetApplicationEventTarget(),
                                         OptionBits(kEventHotKeyExclusive), &ref)
        if result == noErr, let ref {
            hotKeyRef = ref
            status = .active
        } else if result == OSStatus(eventHotKeyExistsErr) {
            status = .failed("\(display) is already used by another app.")
        } else {
            status = .failed("Cannot register \(display) (error \(result)).")
        }
    }

    private func installCarbonHandler() {
        guard handlerRef == nil else { return }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, _ -> OSStatus in
            MainActor.assumeIsolated {
                log.debug("Leader pressed")
                HotkeyService.shared?.onLeader?()
            }
            return noErr
        }, 1, &spec, nil, &handlerRef)
    }
}

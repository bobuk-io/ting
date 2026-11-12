// Ting: a leader-key launcher that lives in the menu bar (LSUIElement, no Dock icon).
import AppKit
import SwiftUI

@main
struct TingApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Settings {
            SettingsRoot()
                .environment(AppModel.shared)
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let model = AppModel.shared
    private var statusItem: StatusItemController?
    private lazy var welcome = WelcomeWindowController(model: model)

    func applicationDidFinishLaunching(_ notification: Notification) {
        model.start()
        _ = UpdateService.shared
        statusItem = StatusItemController(model: model,
                                          openSettings: { SettingsOpener.open() },
                                          openWelcome: { [weak self] in self?.welcome.show() })
        if model.config.leader == nil { welcome.show() }
    }

    /// Opening Ting again (Finder, Spotlight) shows Settings, or Welcome when there is no leader yet.
    /// This is the way back when the menu-bar icon is hidden.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if model.config.leader == nil { welcome.show() } else { SettingsOpener.open() }
        return false
    }
}

/// Opens the SwiftUI Settings scene from AppKit code.
@MainActor
enum SettingsOpener {
    static func open() {
        // LSUIElement apps are not active by default; without this Settings opens behind other windows.
        NSApp.activate()
        // macOS 14+ ignores `showSettingsWindow:`; the app menu's Settings item still works.
        if let item = settingsItem(in: NSApp.mainMenu), let menu = item.menu {
            menu.performActionForItem(at: menu.index(of: item))
        } else {
            NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
        }
        DispatchQueue.main.async {
            NSApp.windows.first { $0.identifier?.rawValue.contains("Settings") == true }?.makeKeyAndOrderFront(nil)
        }
    }

    private static func settingsItem(in menu: NSMenu?) -> NSMenuItem? {
        guard let menu else { return nil }
        for item in menu.items {
            if item.keyEquivalent == ",", item.keyEquivalentModifierMask == .command { return item }
            if let found = settingsItem(in: item.submenu) { return found }
        }
        return nil
    }
}

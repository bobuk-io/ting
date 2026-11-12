// The menu-bar item: a template Ting mark, dimmed when the leader is off, and the status menu.
import AppKit
import Observation
import TingCore

@MainActor
final class StatusItemController: NSObject, NSMenuDelegate {
    private let model: AppModel
    private let statusItem: NSStatusItem
    /// Opens Settings / Welcome; provided by the app delegate.
    private let openSettings: () -> Void
    private let openWelcome: () -> Void

    init(model: AppModel, openSettings: @escaping () -> Void, openWelcome: @escaping () -> Void) {
        self.model = model
        self.openSettings = openSettings
        self.openWelcome = openWelcome
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        super.init()
        statusItem.button?.image = StatusIcon.image
        statusItem.button?.setAccessibilityLabel("Ting")
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
        observe()
    }

    /// Re-renders the button whenever the model changes.
    private func observe() {
        withObservationTracking {
            updateButton()
        } onChange: { [weak self] in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.observe() } }
        }
    }

    private func updateButton() {
        statusItem.isVisible = model.config.showMenuBarIcon
        let problem = model.configError != nil || model.hotkeyProblem != nil
        statusItem.button?.appearsDisabled = !model.isLeaderActive
        statusItem.button?.toolTip = model.isPaused ? "Ting is paused"
            : model.config.leader == nil ? "Ting: no leader key yet"
            : problem ? "Ting: needs attention" : "Ting: \(model.leaderDisplay)"
    }

    // MARK: Menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        let leaderItem = NSMenuItem(title: "Leader: \(model.leaderDisplay)", action: nil, keyEquivalent: "")
        if model.config.leader == nil {
            leaderItem.title = "Leader: Not set — Choose…"
            leaderItem.action = #selector(chooseLeader)
            leaderItem.target = self
        }
        menu.addItem(leaderItem)
        if let problem = model.hotkeyProblem {
            menu.addItem(note(problem, symbol: "exclamationmark.triangle"))
        }
        if let error = model.configError ?? model.issues.first(where: { $0.kind != .missingLeader })?.message {
            menu.addItem(note(error, symbol: "exclamationmark.triangle"))
        }

        menu.addItem(.separator())
        let pause = item("Pause Ting", #selector(togglePause))
        pause.state = model.isPaused ? .on : .off
        menu.addItem(pause)

        menu.addItem(.separator())
        menu.addItem(item("Settings…", #selector(showSettings), key: ","))
        menu.addItem(item("Open Config File", #selector(openConfig)))
        menu.addItem(item("Reload Config", #selector(reloadConfig)))

        menu.addItem(.separator())
        menu.addItem(item("About Ting", #selector(showAbout)))
        if UpdateService.shared.isAvailable {
            menu.addItem(item("Check for Updates…", #selector(checkForUpdates)))
        }
        menu.addItem(item("Quit Ting", #selector(quit), key: "q"))
    }

    private func item(_ title: String, _ action: Selector, key: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        return item
    }

    /// A disabled, wrapped line of text (errors).
    private func note(_ text: String, symbol: String) -> NSMenuItem {
        let item = NSMenuItem(title: text, action: nil, keyEquivalent: "")
        item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        let shown = text.count > 90 ? String(text.prefix(89)) + "…" : text
        item.title = shown
        item.toolTip = text
        return item
    }

    @objc private func chooseLeader() { openWelcome() }
    @objc private func togglePause() { model.isPaused.toggle() }
    @objc private func showSettings() { openSettings() }
    @objc private func openConfig() { model.openConfigFile() }
    @objc private func reloadConfig() { model.reload() }

    @objc private func checkForUpdates() { UpdateService.shared.checkForUpdates() }

    @objc private func showAbout() {
        NSApp.activate()
        NSApp.orderFrontStandardAboutPanel(nil)
    }

    @objc private func quit() { NSApp.terminate(nil) }
}

/// Template menu-bar icon: a tuning fork, the source of the "ting" sound,
/// with two short ticks for its vibration.
enum StatusIcon {
    static let image: NSImage = {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { rect in
            let s = rect.width / 18
            func point(_ x: CGFloat, _ y: CGFloat) -> NSPoint { NSPoint(x: x * s, y: y * s) }
            NSColor.black.setStroke()

            let fork = NSBezierPath()
            fork.move(to: point(5.5, 16.5))
            fork.line(to: point(5.5, 9.5))
            fork.appendArc(withCenter: point(9, 9.5), radius: 3.5 * s, startAngle: 180, endAngle: 360)
            fork.line(to: point(12.5, 16.5))
            fork.move(to: point(9, 6))
            fork.line(to: point(9, 1.5))
            fork.lineWidth = 1.8 * s
            fork.lineCapStyle = .round
            fork.lineJoinStyle = .round
            fork.stroke()

            for x in [2.2, 15.8] as [CGFloat] {
                let tick = NSBezierPath()
                tick.move(to: point(x, 14.5))
                tick.line(to: point(x, 11.5))
                tick.lineWidth = 1.3 * s
                tick.lineCapStyle = .round
                tick.stroke()
            }
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "Ting"
        return image
    }()
}

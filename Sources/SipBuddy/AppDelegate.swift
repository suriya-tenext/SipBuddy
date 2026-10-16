import AppKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let state = AppState.shared
    private var statusItem: NSStatusItem!
    private var buddy: BuddyController!
    private var settingsWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        buddy = BuddyController()
        buddy.openSettings = { [weak self] in self?.openSettings() }

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.title = "💧"
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu

        if CommandLine.arguments.contains("--settings") { openSettings() }
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        for r in state.reminders where r.enabled {
            let mins = max(0, Int(ceil(r.nextDue.timeIntervalSinceNow / 60)))
            let when = mins == 0 ? "now" : "in \(mins) min"
            let item = NSMenuItem(title: "\(r.emoji) \(r.title) · \(when) · \(state.count(for: r.id)) today",
                                  action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
        }
        if !state.reminders.isEmpty { menu.addItem(.separator()) }

        menu.addItem(item("Done ✓", #selector(done), "d"))
        if state.pausedUntil.map({ $0 > Date() }) == true {
            menu.addItem(item("Resume reminders", #selector(resume)))
        } else {
            menu.addItem(item("Pause for 1 hour", #selector(pause)))
        }
        menu.addItem(item(buddy.isVisible ? "Hide buddy" : "Show buddy", #selector(toggleBuddy)))
        menu.addItem(.separator())
        menu.addItem(item("Settings…", #selector(settings), ","))
        menu.addItem(item("Quit SipBuddy", #selector(quit), "q"))
    }

    private func item(_ title: String, _ action: Selector, _ key: String = "") -> NSMenuItem {
        let i = NSMenuItem(title: title, action: action, keyEquivalent: key)
        i.target = self
        return i
    }

    @objc private func done() { buddy.completeNow() }
    @objc private func pause() { state.pausedUntil = Date().addingTimeInterval(3600) }
    @objc private func resume() { state.pausedUntil = nil }
    @objc private func toggleBuddy() { buddy.toggleVisible() }
    @objc private func settings() { openSettings() }
    @objc private func quit() { NSApp.terminate(nil) }

    func openSettings() {
        if settingsWindow == nil {
            let window = NSWindow(contentViewController: NSHostingController(rootView: SettingsView()))
            window.title = "SipBuddy"
            window.styleMask = [.titled, .closable, .miniaturizable]
            window.isReleasedWhenClosed = false
            window.center()
            settingsWindow = window
        }
        NSApp.activate()
        settingsWindow?.makeKeyAndOrderFront(nil)
    }
}

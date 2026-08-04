import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let keepAwake = KeepAwake()
    private var statusItem: NSStatusItem!
    private var sectionHeader: NSMenuItem!
    private var durationItems: [NSMenuItem] = []
    private var deactivateSeparator: NSMenuItem!
    private var deactivateItem: NSMenuItem!
    private var displaySleepItem: NSMenuItem!
    private var menuRefreshTimer: Timer?
    private var menuIsOpen = false

    private static let durations: [(title: String, minutes: Int?)] = [
        ("Indefinitely", nil),
        ("15 Minutes", 15),
        ("30 Minutes", 30),
        ("1 Hour", 60),
        ("2 Hours", 120),
        ("4 Hours", 240),
    ]

    func applicationDidFinishLaunching(_ notification: Notification) {
        keepAwake.onChange = { [weak self] in self?.refreshUI() }
        buildStatusItem()
        handleLaunchArguments()
        refreshUI()
    }

    func applicationWillTerminate(_ notification: Notification) {
        keepAwake.deactivate()
    }

    // MARK: - Menu

    private func buildStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)

        let menu = NSMenu()
        menu.delegate = self
        menu.autoenablesItems = false

        // Single header line: section label when off, live status when on.
        sectionHeader = NSMenuItem(title: "Keep Awake For", action: nil, keyEquivalent: "")
        sectionHeader.isEnabled = false
        menu.addItem(sectionHeader)
        for (index, duration) in Self.durations.enumerated() {
            let item = NSMenuItem(title: duration.title,
                                  action: #selector(activateFromMenu(_:)),
                                  keyEquivalent: "")
            item.target = self
            item.tag = index
            item.indentationLevel = 1
            menu.addItem(item)
            durationItems.append(item)
        }

        // Deactivate (and its separator) only exist visually while a session runs.
        deactivateSeparator = .separator()
        menu.addItem(deactivateSeparator)
        deactivateItem = NSMenuItem(title: "Deactivate",
                                    action: #selector(deactivate),
                                    keyEquivalent: "")
        deactivateItem.target = self
        menu.addItem(deactivateItem)
        menu.addItem(.separator())

        displaySleepItem = NSMenuItem(title: "Keep Display Awake",
                                      action: #selector(toggleDisplaySleep),
                                      keyEquivalent: "")
        displaySleepItem.target = self
        menu.addItem(displaySleepItem)
        menu.addItem(.separator())

        let quit = NSMenuItem(title: "Quit Espresso",
                              action: #selector(NSApplication.terminate(_:)),
                              keyEquivalent: "q")
        quit.target = NSApp
        menu.addItem(quit)

        statusItem.menu = menu
    }

    func menuWillOpen(_ menu: NSMenu) {
        refreshUI()  // sync geometry (hidden rows) while still "closed"
        menuIsOpen = true
        // Keep the countdown live while the menu is held open. Must run in
        // .common mode: .default does not fire during menu tracking.
        let t = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            self?.refreshUI()
        }
        RunLoop.main.add(t, forMode: .common)
        menuRefreshTimer = t
    }

    func menuDidClose(_ menu: NSMenu) {
        menuRefreshTimer?.invalidate()
        menuRefreshTimer = nil
        menuIsOpen = false
        refreshUI()
    }

    // MARK: - Actions

    @objc private func activateFromMenu(_ sender: NSMenuItem) {
        guard Self.durations.indices.contains(sender.tag) else { return }
        keepAwake.activate(minutes: Self.durations[sender.tag].minutes)
    }

    @objc private func deactivate() {
        keepAwake.deactivate()
    }

    @objc private func toggleDisplaySleep() {
        keepAwake.allowDisplaySleep.toggle()
    }

    // MARK: - UI state

    private func refreshUI() {
        let active = keepAwake.isActive
        let symbol = active ? "cup.and.saucer.fill" : "cup.and.saucer"
        let description = active ? "Espresso: keeping Mac awake" : "Espresso: inactive"
        statusItem.button?.image = NSImage(systemSymbolName: symbol,
                                           accessibilityDescription: description)
        statusItem.button?.toolTip = description

        if !active {
            sectionHeader.title = "Keep Awake For"
        } else if let remaining = keepAwake.remaining {
            sectionHeader.title = "Keeping Awake — \(Self.format(remaining)) left"
        } else {
            sectionHeader.title = "Keeping Awake — Indefinitely"
        }
        for (index, item) in durationItems.enumerated() {
            let isCurrent = active && Self.durations[index].minutes == keepAwake.sessionMinutes
            item.state = isCurrent ? .on : .off
        }
        if menuIsOpen {
            // Never add/remove rows mid-track — a session expiring with the
            // menu open would shift items under the cursor. Gray out in place.
            deactivateItem.isEnabled = active
        } else {
            deactivateItem.isEnabled = true
            deactivateItem.isHidden = !active
            deactivateSeparator.isHidden = !active
        }
        // Positive framing: checked means the display is kept on.
        displaySleepItem.state = keepAwake.allowDisplaySleep ? .off : .on
    }

    private static func format(_ interval: TimeInterval) -> String {
        // Round up so remaining time is never understated ("1m" means at most
        // one minute truly remains).
        let totalMinutes = max(1, Int((interval / 60).rounded(.up)))
        let hours = totalMinutes / 60
        let minutes = totalMinutes % 60
        if hours > 0 {
            return minutes > 0 ? "\(hours)h \(minutes)m" : "\(hours)h"
        }
        return "\(minutes)m"
    }

    // MARK: - Launch arguments

    /// `--activate [minutes]` starts a session at launch (indefinite when no
    /// valid minute count follows). Useful for scripting and testing.
    private func handleLaunchArguments() {
        let args = CommandLine.arguments
        guard let flagIndex = args.firstIndex(of: "--activate") else { return }
        var minutes: Int?
        if args.indices.contains(flagIndex + 1) {
            minutes = Int(args[flagIndex + 1])
        }
        keepAwake.activate(minutes: minutes)
    }
}

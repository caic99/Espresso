import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let keepAwake = KeepAwake()
    private let lidBlocker = LidSleepBlocker()
    private let powerSource = PowerSource()
    private var statusItem: NSStatusItem!
    private var sectionHeader: NSMenuItem!
    private var indefiniteItem: NSMenuItem!
    private var durationSlider: NSSlider!
    private var sliderHoursLabel: NSTextField!
    private var sliderMinutesLabel: NSTextField!
    private var deactivateItem: NSMenuItem!
    private var displaySleepItem: NSMenuItem!
    private var lidBlockItem: NSMenuItem!
    private var menuRefreshTimer: Timer?
    private var menuIsOpen = false

    /// Snap points for the duration slider, in minutes (15 m – 8 h).
    private static let sliderStops = [15, 30, 45, 60, 90, 120, 180, 240, 300, 360, 480]
    private static let sliderIndexKey = "sliderIndex"
    private static let defaultSliderIndex = 3  // 1 Hour

    func applicationDidFinishLaunching(_ notification: Notification) {
        lidBlocker.reconcileAtLaunch()
        keepAwake.onChange = { [weak self] in
            guard let self else { return }
            if !self.keepAwake.isActive {
                self.disengageLidBlockOrWarn()
            }
            self.refreshUI()
        }
        powerSource.onChange = { [weak self] in
            guard let self else { return }
            // Safety: never keep the lid block armed on battery.
            if !PowerSource.isOnAC() {
                self.disengageLidBlockOrWarn()
            }
            self.refreshUI()
        }
        powerSource.startObserving()
        buildStatusItem()
        handleLaunchArguments()
        refreshUI()
    }

    func applicationWillTerminate(_ notification: Notification) {
        lidBlocker.disengage()
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

        // Lives in the top session group; only visible while a session runs.
        deactivateItem = NSMenuItem(title: "Deactivate",
                                    action: #selector(deactivate),
                                    keyEquivalent: "")
        deactivateItem.target = self
        deactivateItem.indentationLevel = 1
        deactivateItem.image = NSImage(systemSymbolName: "moon.zzz",
                                       accessibilityDescription: "Deactivate")
        menu.addItem(deactivateItem)

        indefiniteItem = NSMenuItem(title: "Indefinitely",
                                    action: #selector(activateIndefinitely),
                                    keyEquivalent: "")
        indefiniteItem.target = self
        indefiniteItem.indentationLevel = 1
        indefiniteItem.image = NSImage(systemSymbolName: "infinity",
                                       accessibilityDescription: "Indefinitely")
        menu.addItem(indefiniteItem)

        // Timed sessions: a native slider snapping to sliderStops. Dragging
        // previews the duration in the trailing label; releasing starts the
        // session and closes the menu.
        let sliderItem = NSMenuItem()
        sliderItem.view = makeSliderRow()
        menu.addItem(sliderItem)
        menu.addItem(.separator())

        displaySleepItem = NSMenuItem(title: "Keep Display Awake",
                                      action: #selector(toggleDisplaySleep),
                                      keyEquivalent: "")
        displaySleepItem.target = self
        menu.addItem(displaySleepItem)

        lidBlockItem = NSMenuItem(title: "Block Lid-Close Sleep",
                                  action: #selector(toggleLidBlock),
                                  keyEquivalent: "")
        lidBlockItem.target = self
        lidBlockItem.toolTip = "Keep the Mac awake with the lid closed. Requires AC power; "
            + "turns off automatically when the session ends or power is unplugged."
        menu.addItem(lidBlockItem)
        menu.addItem(.separator())

        let quit = NSMenuItem(title: "Quit Espresso",
                              action: #selector(NSApplication.terminate(_:)),
                              keyEquivalent: "q")
        quit.target = NSApp
        menu.addItem(quit)

        statusItem.menu = menu
    }

    private func makeSliderRow() -> NSView {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 260, height: 30))

        let defaults = UserDefaults.standard
        let stored = defaults.object(forKey: Self.sliderIndexKey) == nil
            ? Self.defaultSliderIndex
            : defaults.integer(forKey: Self.sliderIndexKey)
        let index = min(max(stored, 0), Self.sliderStops.count - 1)

        let slider = NSSlider(value: Double(index), minValue: 0,
                              maxValue: Double(Self.sliderStops.count - 1),
                              target: self, action: #selector(sliderChanged(_:)))
        slider.numberOfTickMarks = Self.sliderStops.count
        slider.allowsTickMarkValuesOnly = true
        slider.isContinuous = true
        slider.controlSize = .small
        slider.frame = NSRect(x: 22, y: 4, width: 164, height: 22)
        slider.setAccessibilityLabel("Keep awake duration")
        container.addSubview(slider)

        // Two fixed columns so hours and minutes stay aligned while dragging.
        let parts = Self.hourMinuteParts(Self.sliderStops[index])
        let hoursLabel = Self.makeValueLabel(parts.hours)
        hoursLabel.frame = NSRect(x: 188, y: 7, width: 26, height: 16)
        container.addSubview(hoursLabel)

        let minutesLabel = Self.makeValueLabel(parts.minutes)
        minutesLabel.frame = NSRect(x: 216, y: 7, width: 32, height: 16)
        container.addSubview(minutesLabel)

        durationSlider = slider
        sliderHoursLabel = hoursLabel
        sliderMinutesLabel = minutesLabel
        return container
    }

    private static func makeValueLabel(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .monospacedDigitSystemFont(ofSize: 13, weight: .regular)
        label.textColor = .secondaryLabelColor
        label.alignment = .right
        return label
    }

    /// Splits a duration into fixed columns — ("", "45m"), ("1h", "30m"),
    /// ("2h", "") — blank when the component is zero.
    private static func hourMinuteParts(_ minutes: Int) -> (hours: String, minutes: String) {
        let h = minutes / 60
        let m = minutes % 60
        return (h > 0 ? "\(h)h" : "", m > 0 ? "\(m)m" : "")
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

    @objc private func activateIndefinitely() {
        keepAwake.activate(minutes: nil)
    }

    @objc private func sliderChanged(_ sender: NSSlider) {
        let index = min(max(Int(sender.doubleValue.rounded()), 0), Self.sliderStops.count - 1)
        let minutes = Self.sliderStops[index]
        let parts = Self.hourMinuteParts(minutes)
        sliderHoursLabel.stringValue = parts.hours
        sliderMinutesLabel.stringValue = parts.minutes
        UserDefaults.standard.set(index, forKey: Self.sliderIndexKey)

        // Continuous action fires throughout the drag; commit on release.
        // A nil event covers programmatic/accessibility adjustment.
        let event = NSApp.currentEvent
        if event == nil || event?.type == .leftMouseUp || event?.type == .rightMouseUp {
            keepAwake.activate(minutes: minutes)
            statusItem.menu?.cancelTracking()
        }
    }

    @objc private func deactivate() {
        keepAwake.deactivate()
    }

    @objc private func toggleDisplaySleep() {
        keepAwake.allowDisplaySleep.toggle()
    }

    @objc private func toggleLidBlock() {
        if lidBlocker.isEngaged {
            disengageLidBlockOrWarn()
        } else if keepAwake.isActive {
            guard PowerSource.isOnAC() else {
                showAlert("Connect to power first",
                          "Blocking lid-close sleep on battery risks draining the battery "
                          + "or overheating in a bag, so Espresso only allows it on AC power.")
                return
            }
            if !lidBlocker.engage() {
                showAlert("Passwordless sudo needed",
                          "Blocking lid-close sleep runs \"pmset disablesleep\" as root, and "
                          + "Espresso only engages it when it can also release it unattended "
                          + "(session end, unplug, quit). Set that up once in Terminal:\n\n"
                          + "echo \"$USER ALL=(root) NOPASSWD: /usr/bin/pmset disablesleep 0, "
                          + "/usr/bin/pmset disablesleep 1\" | sudo tee /etc/sudoers.d/espresso-lidsleep")
            } else if !PowerSource.isOnAC() || !keepAwake.isActive {
                // Guards changed while the privileged command ran.
                lidBlocker.disengage()
            }
        }
        refreshUI()
    }

    private func disengageLidBlockOrWarn() {
        if !lidBlocker.disengage() {
            showAlert("Lid-sleep block is still on",
                      "Espresso couldn't clear \"pmset disablesleep\". Run "
                      + "\"sudo pmset disablesleep 0\" in Terminal to restore normal lid behavior.")
        }
    }

    private func showAlert(_ message: String, _ informative: String) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = message
        alert.informativeText = informative
        alert.runModal()
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
        indefiniteItem.state = (active && keepAwake.sessionMinutes == nil) ? .on : .off
        if menuIsOpen {
            // Never add/remove rows mid-track — a session expiring with the
            // menu open would shift items under the cursor. Gray out in place.
            deactivateItem.isEnabled = active
        } else {
            deactivateItem.isEnabled = true
            deactivateItem.isHidden = !active
        }
        // Positive framing: checked means the display is kept on.
        displaySleepItem.state = keepAwake.allowDisplaySleep ? .off : .on
        lidBlockItem.state = lidBlocker.isEngaged ? .on : .off
        // Always leave an engaged block manually clearable.
        lidBlockItem.isEnabled = (active && PowerSource.isOnAC()) || lidBlocker.isEngaged
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
    /// valid minute count follows); adding `--block-lid` also engages the
    /// lid-close block (AC power required). Useful for scripting and testing.
    private func handleLaunchArguments() {
        let args = CommandLine.arguments
        guard let flagIndex = args.firstIndex(of: "--activate") else { return }
        var minutes: Int?
        if args.indices.contains(flagIndex + 1) {
            minutes = Int(args[flagIndex + 1])
        }
        keepAwake.activate(minutes: minutes)
        if args.contains("--block-lid"), keepAwake.isActive, PowerSource.isOnAC() {
            lidBlocker.engage()
            if !PowerSource.isOnAC() || !keepAwake.isActive {
                lidBlocker.disengage()
            }
        }
    }
}

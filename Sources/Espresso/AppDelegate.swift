import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let keepAwake = KeepAwake()
    private let lidBlocker = LidSleepBlocker()
    private let powerSource = PowerSource()
    private var statusItem: NSStatusItem!
    private var sectionHeader: NSMenuItem!
    private var headerIconView: NSImageView!
    private var headerTitleLabel: NSTextField!
    private var headerSubtitleLabel: NSTextField!
    private var indefiniteItem: NSMenuItem!
    private var durationSlider: DurationSlider!
    private var sliderValueLabel: NSTextField!
    private var sleepInfo = SleepInfo.none
    private var deactivateItem: NSMenuItem!
    private var displaySleepItem: NSMenuItem!
    private var lidBlockItem: NSMenuItem!
    private var menuRefreshTimer: Timer?
    private var menuIsOpen = false

    /// Snap points for the duration slider, in minutes (15 m – 24 h).
    /// Every stop is pure minutes or whole hours, so the value label is
    /// always a single short unit ("45m", "2h").
    private static let sliderStops = [15, 30, 45, 60, 120, 240, 480, 720, 1440]
    private static let sliderIndexKey = "sliderIndex"
    private static let defaultSliderIndex = 3  // 1 Hour
    private static let blockLidSleepKey = "blockLidSleep"

    /// Lid-close blocking during sessions is on unless the user unchecked it.
    private var blockLidSleepPreferred: Bool {
        UserDefaults.standard.object(forKey: Self.blockLidSleepKey) == nil
            ? true
            : UserDefaults.standard.bool(forKey: Self.blockLidSleepKey)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        lidBlocker.reconcileAtLaunch()
        sleepInfo = SleepInfo.current()
        keepAwake.onChange = { [weak self] in
            guard let self else { return }
            if !self.keepAwake.isActive {
                self.disengageLidBlockOrWarn()
            } else {
                self.engageLidBlockIfAppropriate()
            }
            self.refreshUI()
        }
        powerSource.onChange = { [weak self] in
            guard let self else { return }
            // Safety: never keep the lid block armed on battery; rearm on AC.
            if !PowerSource.isOnAC() {
                self.disengageLidBlockOrWarn()
            } else {
                self.engageLidBlockIfAppropriate()
            }
            self.sleepInfo = SleepInfo.current()  // AC/battery profiles differ
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

        // Status header: custom view so it renders in solid label color
        // instead of the dimmed look AppKit forces on disabled items.
        sectionHeader = NSMenuItem()
        sectionHeader.isEnabled = false
        sectionHeader.view = makeHeaderRow()
        menu.addItem(sectionHeader)

        // Lives in the top session group; only visible while a session runs.
        deactivateItem = NSMenuItem(title: "Deactivate",
                                    action: #selector(deactivate),
                                    keyEquivalent: "")
        deactivateItem.target = self
        deactivateItem.indentationLevel = 1
        deactivateItem.image = NSImage(systemSymbolName: "stop.circle",
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
        lidBlockItem.toolTip = "Keep the Mac awake with the lid closed during sessions "
            + "(on by default). Engages only on AC power and releases automatically "
            + "when the session ends, power is unplugged, or Espresso quits."
        menu.addItem(lidBlockItem)
        menu.addItem(.separator())

        let quit = NSMenuItem(title: "Quit Espresso",
                              action: #selector(NSApplication.terminate(_:)),
                              keyEquivalent: "q")
        quit.target = NSApp
        menu.addItem(quit)

        statusItem.menu = menu
    }

    private func makeHeaderRow() -> NSView {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 260, height: 36))

        let icon = NSImageView(frame: NSRect(x: 14, y: 9, width: 18, height: 18))
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 14, weight: .medium)
        icon.contentTintColor = .labelColor
        container.addSubview(icon)

        let title = NSTextField(labelWithString: "")
        title.font = .systemFont(ofSize: 13)
        title.textColor = .labelColor
        title.lineBreakMode = .byTruncatingTail
        title.frame = NSRect(x: 38, y: 18, width: 214, height: 16)
        container.addSubview(title)

        let subtitle = NSTextField(labelWithString: "")
        subtitle.font = .systemFont(ofSize: 11)
        subtitle.textColor = .secondaryLabelColor
        subtitle.lineBreakMode = .byTruncatingTail
        subtitle.frame = NSRect(x: 38, y: 4, width: 214, height: 13)
        container.addSubview(subtitle)

        headerIconView = icon
        headerTitleLabel = title
        headerSubtitleLabel = subtitle
        return container
    }

    private func makeSliderRow() -> NSView {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 260, height: 30))

        let defaults = UserDefaults.standard
        let stored = defaults.object(forKey: Self.sliderIndexKey) == nil
            ? Self.defaultSliderIndex
            : defaults.integer(forKey: Self.sliderIndexKey)
        let index = min(max(stored, 0), Self.sliderStops.count - 1)

        let slider = DurationSlider(value: Double(index), minValue: 0,
                                    maxValue: Double(Self.sliderStops.count - 1),
                                    target: self, action: #selector(sliderChanged(_:)))
        slider.onCommit = { [weak self] in self?.commitSliderSelection() }
        slider.numberOfTickMarks = Self.sliderStops.count
        slider.allowsTickMarkValuesOnly = true
        slider.isContinuous = true
        slider.controlSize = .small
        slider.frame = NSRect(x: 22, y: 4, width: 190, height: 22)
        slider.setAccessibilityLabel("Keep awake duration")
        container.addSubview(slider)

        let label = Self.makeValueLabel(Self.durationLabel(Self.sliderStops[index]))
        label.frame = NSRect(x: 216, y: 7, width: 36, height: 16)
        container.addSubview(label)

        durationSlider = slider
        sliderValueLabel = label
        return container
    }

    private static func makeValueLabel(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .monospacedDigitSystemFont(ofSize: 13, weight: .regular)
        label.textColor = .secondaryLabelColor
        label.alignment = .right
        return label
    }

    private static func durationLabel(_ minutes: Int) -> String {
        minutes < 60 ? "\(minutes)m" : "\(minutes / 60)h"
    }

    func menuWillOpen(_ menu: NSMenu) {
        sleepInfo = SleepInfo.current()
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

    /// Continuous action: preview only. The commit comes from DurationSlider's
    /// explicit end-of-gesture callback, never inferred from event state.
    @objc private func sliderChanged(_ sender: NSSlider) {
        let index = min(max(Int(sender.doubleValue.rounded()), 0), Self.sliderStops.count - 1)
        sliderValueLabel.stringValue = Self.durationLabel(Self.sliderStops[index])
        UserDefaults.standard.set(index, forKey: Self.sliderIndexKey)
    }

    private func commitSliderSelection() {
        let index = min(max(Int(durationSlider.doubleValue.rounded()), 0), Self.sliderStops.count - 1)
        keepAwake.activate(minutes: Self.sliderStops[index])
        // The menu stays open — the header flips to the live countdown.
    }

    @objc private func deactivate() {
        keepAwake.deactivate()
    }

    @objc private func toggleDisplaySleep() {
        keepAwake.allowDisplaySleep.toggle()
    }

    @objc private func toggleLidBlock() {
        let displayedOn = keepAwake.isActive ? lidBlocker.isEngaged : blockLidSleepPreferred
        let wantOn = !displayedOn
        UserDefaults.standard.set(wantOn, forKey: Self.blockLidSleepKey)
        if wantOn {
            engageLidBlockIfAppropriate(interactive: true)
        } else {
            disengageLidBlockOrWarn()
        }
        refreshUI()
    }

    /// Engage the lid block when the preference, an active session, and AC
    /// power line up. Alerts only on a user-initiated toggle; auto paths stay
    /// quiet and the live checkmark reflects the truth instead.
    private func engageLidBlockIfAppropriate(interactive: Bool = false) {
        guard blockLidSleepPreferred, keepAwake.isActive, !lidBlocker.isEngaged else { return }
        guard PowerSource.isOnAC() else {
            if interactive {
                showAlert("Connect to power first",
                          "Blocking lid-close sleep on battery risks draining the battery or "
                          + "overheating in a bag. It will engage automatically on AC power.")
            }
            return
        }
        if !lidBlocker.engage() {
            if interactive {
                showAlert("Passwordless sudo needed",
                          "Blocking lid-close sleep runs \"pmset disablesleep\" as root, and "
                          + "Espresso only engages it when it can also release it unattended "
                          + "(session end, unplug, quit). Set that up once in Terminal:\n\n"
                          + "echo \"$USER ALL=(root) NOPASSWD: /usr/bin/pmset disablesleep 0, "
                          + "/usr/bin/pmset disablesleep 1\" | sudo tee /etc/sudoers.d/espresso-lidsleep")
            }
        } else if !PowerSource.isOnAC() || !keepAwake.isActive {
            // Guards changed while the privileged command ran.
            lidBlocker.disengage()
        }
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

    /// Prefers a newer symbol, degrading gracefully where the OS lacks it
    /// (NSImage returns nil for unknown names) so the 13.0 target holds.
    private static func symbolImage(_ preferred: String, fallback: String,
                                    description: String) -> NSImage? {
        NSImage(systemSymbolName: preferred, accessibilityDescription: description)
            ?? NSImage(systemSymbolName: fallback, accessibilityDescription: description)
    }

    private func refreshUI() {
        let active = keepAwake.isActive
        let description = active ? "Espresso: keeping Mac awake" : "Espresso: inactive"
        statusItem.button?.image = active
            ? Self.symbolImage("cup.and.heat.waves.fill", fallback: "cup.and.saucer.fill",
                               description: description)
            : NSImage(systemSymbolName: "cup.and.saucer", accessibilityDescription: description)
        statusItem.button?.toolTip = description

        // The header doubles as a state beacon: steaming coffee when on, moon when off.
        headerIconView.image = active
            ? Self.symbolImage("cup.and.heat.waves.fill", fallback: "cup.and.saucer.fill",
                               description: "Awake")
            : NSImage(systemSymbolName: "moon.zzz", accessibilityDescription: "Sleep allowed")
        if !active {
            headerTitleLabel.stringValue = "Not Keeping Awake"
        } else if let remaining = keepAwake.remaining {
            headerTitleLabel.stringValue = "Keeping Awake — \(Self.format(remaining)) left"
        } else {
            headerTitleLabel.stringValue = "Keeping Awake — Indefinitely"
        }
        // Symmetric detail line in both states, short enough to never truncate;
        // app names live in the tooltip.
        if active {
            headerSubtitleLabel.stringValue = keepAwake.allowDisplaySleep
                ? "Mac stays awake · display may sleep"
                : "Mac and display stay awake"
            headerSubtitleLabel.toolTip = nil
        } else {
            headerSubtitleLabel.stringValue = offStateDetail()
            headerSubtitleLabel.toolTip = sleepInfo.preventers.isEmpty ? nil
                : "Mac held awake by " + sleepInfo.preventers.joined(separator: ", ")
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
        // While a session runs, show the actual engagement; otherwise the
        // preference (what the next session will do).
        lidBlockItem.state = (active ? lidBlocker.isEngaged : blockLidSleepPreferred) ? .on : .off
    }

    /// "Display sleeps in 42m · Mac sleeps in 55m" — live countdowns from the
    /// active pmset profile and the current HID idle time; names the apps
    /// holding the system awake when idle sleep is externally prevented.
    private func offStateDetail() -> String {
        let idle = SleepInfo.idleSeconds()
        var parts: [String] = []
        if sleepInfo.displaySleepMinutes > 0 {
            let remaining = max(0, TimeInterval(sleepInfo.displaySleepMinutes * 60) - idle)
            parts.append("Display sleeps in \(Self.format(remaining))")
        } else {
            parts.append("Display never sleeps")
        }
        if !sleepInfo.preventers.isEmpty {
            parts.append("Mac kept awake")
        } else if sleepInfo.systemSleepMinutes > 0 {
            let remaining = max(0, TimeInterval(sleepInfo.systemSleepMinutes * 60) - idle)
            parts.append("Mac in \(Self.format(remaining))")
        } else {
            parts.append("Mac never sleeps")
        }
        return parts.joined(separator: " · ")
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

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
    private var sessionToggleItem: NSMenuItem!
    private var displaySleepItem: NSMenuItem!
    private var lidBlockItem: NSMenuItem!
    private var menuRefreshTimer: Timer?
    private var menuIsOpen = false
    private var autoEngageFailed = false
    /// Whether passwordless `pmset disablesleep` is set up (probed, then
    /// corrected by real engage results and the setup flow).
    private var lidRuleReady = false
    private var lidBlockSuppressedThisSession = false

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
        lidRuleReady = LidSleepSetup.probeReady()
        sleepInfo = SleepInfo.current()
        keepAwake.onChange = { [weak self] in
            guard let self else { return }
            if !self.keepAwake.isActive {
                self.autoEngageFailed = false
                self.lidBlockSuppressedThisSession = false
                self.disengageLidBlockOrWarn()
            } else {
                self.engageLidBlockIfAppropriate()
            }
            self.refreshUI()
        }
        powerSource.onChange = { [weak self] in
            guard let self else { return }
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

        // Session toggle: "Keep Awake for <slider time>" when idle,
        // "Deactivate" while running. ⌘C fires it while the menu is open.
        sessionToggleItem = NSMenuItem(title: L("Keep Awake"),
                                       action: #selector(toggleSession),
                                       keyEquivalent: "c")
        sessionToggleItem.target = self
        menu.addItem(sessionToggleItem)

        indefiniteItem = NSMenuItem(title: L("Indefinitely"),
                                    action: #selector(activateIndefinitely),
                                    keyEquivalent: "")
        indefiniteItem.target = self
        indefiniteItem.image = NSImage(systemSymbolName: "infinity",
                                       accessibilityDescription: L("Indefinitely"))
        menu.addItem(indefiniteItem)

        // Timed sessions: a native slider snapping to sliderStops. Dragging
        // previews the duration in the trailing label; releasing starts the
        // session and closes the menu.
        let sliderItem = NSMenuItem()
        sliderItem.view = makeSliderRow()
        menu.addItem(sliderItem)
        menu.addItem(.separator())

        // Scope hint: the two toggles below only take effect during sessions.
        let optionsHeader: NSMenuItem
        if #available(macOS 14.0, *) {
            optionsHeader = NSMenuItem.sectionHeader(title: L("While Keeping Awake"))
        } else {
            optionsHeader = NSMenuItem(title: L("While Keeping Awake"), action: nil, keyEquivalent: "")
            optionsHeader.isEnabled = false
        }
        menu.addItem(optionsHeader)

        displaySleepItem = NSMenuItem(title: L("Keep Display Awake"),
                                      action: #selector(toggleDisplaySleep),
                                      keyEquivalent: "")
        displaySleepItem.target = self
        displaySleepItem.image = NSImage(systemSymbolName: "display",
                                         accessibilityDescription: L("Keep Display Awake"))
        menu.addItem(displaySleepItem)

        lidBlockItem = NSMenuItem(title: L("Block Lid-Close Sleep"),
                                  action: #selector(toggleLidBlock),
                                  keyEquivalent: "")
        lidBlockItem.target = self
        lidBlockItem.image = Self.symbolImage("macbook", fallback: "laptopcomputer",
                                              description: L("Block Lid-Close Sleep"))
        lidBlockItem.toolTip = L("Keep the Mac awake with the lid closed during sessions "
            + "(on by default, AC or battery). Releases automatically when the session "
            + "ends, Espresso quits, or Low Power Mode turns on.")
        menu.addItem(lidBlockItem)
        menu.addItem(.separator())

        let quit = NSMenuItem(title: L("Quit Espresso"),
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
        // Size the value label for the widest localized stop ("24h" vs
        // "24小时"); the slider takes the rest of the row.
        let label = Self.makeValueLabel(Self.durationLabel(Self.sliderStops[index]))
        let labelWidth = Self.sliderStops.map { minutes -> CGFloat in
            (Self.durationLabel(minutes) as NSString).size(withAttributes: [.font: label.font!]).width
        }.max()!.rounded(.up) + 4
        let labelX = 252 - labelWidth
        label.frame = NSRect(x: labelX, y: 7, width: labelWidth, height: 16)
        container.addSubview(label)

        slider.frame = NSRect(x: 22, y: 4, width: labelX - 6 - 22, height: 22)
        slider.setAccessibilityLabel(L("Keep awake duration"))
        container.addSubview(slider)

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
        minutes < 60 ? L("%dm", minutes) : L("%dh", minutes / 60)
    }

    func menuWillOpen(_ menu: NSMenu) {
        sleepInfo = SleepInfo.current()
        if !lidRuleReady {
            lidRuleReady = LidSleepSetup.probeReady()  // picks up a rule added by hand
        }
        refreshUI()
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
        refreshUI()  // unfreeze the session toggle for the next open
    }

    // MARK: - Actions

    @objc private func activateIndefinitely() {
        startSession(minutes: nil)
    }

    /// Restarting a session in place never passes through an inactive
    /// onChange, so clear the per-session lid-block backoff here.
    private func startSession(minutes: Int?) {
        autoEngageFailed = false
        keepAwake.activate(minutes: minutes)
    }

    /// Continuous action: preview only. The commit comes from DurationSlider's
    /// explicit end-of-gesture callback, never inferred from event state.
    @objc private func sliderChanged(_ sender: NSSlider) {
        let index = min(max(Int(sender.doubleValue.rounded()), 0), Self.sliderStops.count - 1)
        sliderValueLabel.stringValue = Self.durationLabel(Self.sliderStops[index])
        UserDefaults.standard.set(index, forKey: Self.sliderIndexKey)
        refreshUI()  // keep the "Keep Awake for …" toggle title in sync
    }

    private func commitSliderSelection() {
        let index = min(max(Int(durationSlider.doubleValue.rounded()), 0), Self.sliderStops.count - 1)
        startSession(minutes: Self.sliderStops[index])
        // The menu stays open — the header flips to the live countdown.
    }

    @objc private func toggleSession() {
        if keepAwake.isActive {
            keepAwake.deactivate()
        } else {
            commitSliderSelection()
        }
    }

    @objc private func toggleDisplaySleep() {
        keepAwake.allowDisplaySleep.toggle()
    }

    /// The checkmark: actual engagement during a session; otherwise whether
    /// the next session will block (preference on and setup done).
    private var lidBlockDisplayedOn: Bool {
        keepAwake.isActive ? lidBlocker.isEngaged : (blockLidSleepPreferred && lidRuleReady)
    }

    /// Clicks always flip what the checkmark shows. Turning it on before
    /// setup opens the setup offer; declining that turns the preference off,
    /// so the checkmark never claims a block that can't happen.
    @objc private func toggleLidBlock() {
        guard !LidSleepSetup.isRunning else { return }
        let wantOn = !lidBlockDisplayedOn
        autoEngageFailed = false
        lidBlockSuppressedThisSession = false
        UserDefaults.standard.set(wantOn, forKey: Self.blockLidSleepKey)
        if !wantOn {
            disengageLidBlockOrWarn()
        } else if !lidRuleReady {
            offerLidSleepSetup()
        } else {
            engageLidBlockIfAppropriate(interactive: true)
        }
        refreshUI()
    }

    /// Engage the lid block whenever the preference and an active session
    /// line up — on AC or battery alike; Low Power Mode (which ends the
    /// session), session end, and quit are the release paths. Alerts only on
    /// a user-initiated toggle; auto paths stay quiet, back off after a
    /// failure, and the live checkmark reflects the truth instead.
    private func engageLidBlockIfAppropriate(interactive: Bool = false, afterSetup: Bool = false) {
        guard blockLidSleepPreferred, keepAwake.isActive, !lidBlocker.isEngaged,
              !lidBlockSuppressedThisSession else { return }
        if !interactive && autoEngageFailed { return }
        if !lidBlocker.engage() {
            // The session may have ended while the privileged command ran
            // (waitUntilExit pumps the run loop): engage() then honored the
            // latched disengage. Not a sudo failure — no backoff, no alert.
            guard keepAwake.isActive else { return }
            autoEngageFailed = true
            lidRuleReady = false
            if interactive {
                if afterSetup {
                    declineLidBlock()
                    showAlert(L("Lid-close blocking is still unavailable"),
                              L("Espresso installed its rule at %@, but "
                                + "“sudo -n pmset disablesleep” still asks for a password, so "
                                + "another sudoers setting takes precedence. Run “sudo -l” in "
                                + "Terminal to see which rules apply to you.",
                                LidSleepSetup.sudoersPath))
                } else {
                    offerLidSleepSetup()
                }
            }
        } else {
            lidRuleReady = true
            if !keepAwake.isActive {
                // The session ended while the privileged command ran.
                lidBlocker.disengage()
            }
        }
    }

    /// Espresso only engages the root flag when it can also release it with
    /// nobody at the keyboard, so engaging needs passwordless access to
    /// exactly `pmset disablesleep`. Offer to install that rule ourselves.
    private func offerLidSleepSetup() {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = L("Allow Espresso to block lid-close sleep?")
        alert.informativeText = L("This needs a one-time administrator approval. Espresso adds a "
            + "rule that lets it run only “pmset disablesleep” without a password, so it can "
            + "always release the block on its own when a session ends, you quit, or Low Power "
            + "Mode turns on.")
        alert.addButton(withTitle: L("Set Up…"))
        alert.addButton(withTitle: L("Not Now"))
        guard alert.runModal() == .alertFirstButtonReturn else {
            declineLidBlock()
            refreshUI()
            return
        }

        LidSleepSetup.install { [weak self] outcome in
            guard let self else { return }
            switch outcome {
            case .installed:
                self.lidRuleReady = true
                self.autoEngageFailed = false
                self.engageLidBlockIfAppropriate(interactive: true, afterSetup: true)
            case .cancelled:
                self.declineLidBlock()
            case .failed(let message):
                self.declineLidBlock()
                self.showAlert(L("Setup didn't complete"),
                               (message.isEmpty ? "" : message + "\n\n")
                               + L("You can add the rule by hand in Terminal:") + "\n\n"
                               + LidSleepSetup.manualCommand)
            }
            self.refreshUI()
        }
        refreshUI()  // "Waiting for Administrator Approval…" while the prompt is up
    }

    /// Declining (or failing) setup turns the preference off, so the menu
    /// shows the truth; one click on the item offers setup again.
    private func declineLidBlock() {
        UserDefaults.standard.set(false, forKey: Self.blockLidSleepKey)
        autoEngageFailed = false
    }

    private func disengageLidBlockOrWarn() {
        if !lidBlocker.disengage() {
            showAlert(L("Lid-sleep block is still on"),
                      L("Espresso couldn’t clear “pmset disablesleep”. Run "
                        + "“sudo pmset disablesleep 0” in Terminal to restore normal lid behavior."))
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
        let description = active ? L("Espresso: keeping Mac awake") : L("Espresso: inactive")
        statusItem.button?.image = active
            ? Self.symbolImage("cup.and.heat.waves.fill", fallback: "cup.and.saucer.fill",
                               description: description)
            : NSImage(systemSymbolName: "cup.and.saucer", accessibilityDescription: description)
        statusItem.button?.toolTip = description

        // The header doubles as a state beacon: steaming coffee when on, moon when off.
        headerIconView.image = active
            ? Self.symbolImage("cup.and.heat.waves.fill", fallback: "cup.and.saucer.fill",
                               description: L("Awake"))
            : NSImage(systemSymbolName: "moon.zzz", accessibilityDescription: L("Sleep allowed"))
        if !active {
            headerTitleLabel.stringValue = L("Not Keeping Awake")
        } else if let remaining = keepAwake.remaining {
            headerTitleLabel.stringValue = L("Keeping Awake — %@ left", Self.format(remaining))
        } else {
            headerTitleLabel.stringValue = L("Keeping Awake — Indefinitely")
        }
        // Symmetric detail line in both states, short enough to never truncate;
        // app names live in the tooltip.
        if active {
            headerSubtitleLabel.stringValue = keepAwake.allowDisplaySleep
                ? L("Mac stays awake · display may sleep")
                : L("Mac and display stay awake")
            headerSubtitleLabel.toolTip = nil
        } else {
            headerSubtitleLabel.stringValue = offStateDetail()
            headerSubtitleLabel.toolTip = sleepInfo.preventers.isEmpty ? nil
                : L("Mac held awake by %@", ListFormatter.localizedString(byJoining: sleepInfo.preventers))
        }
        indefiniteItem.state = (active && keepAwake.sessionMinutes == nil) ? .on : .off
        if active {
            sessionToggleItem.isEnabled = true
            sessionToggleItem.title = L("Deactivate")
            sessionToggleItem.image = NSImage(systemSymbolName: "stop.circle",
                                              accessibilityDescription: L("Deactivate"))
        } else if menuIsOpen, sessionToggleItem.title == L("Deactivate") {
            // Session ended while the menu is open: freeze the row disabled
            // rather than flipping the click's meaning under the cursor.
            sessionToggleItem.isEnabled = false
        } else {
            sessionToggleItem.isEnabled = true
            let index = min(max(Int(durationSlider.doubleValue.rounded()), 0),
                            Self.sliderStops.count - 1)
            sessionToggleItem.title = L("Keep Awake for %@", Self.durationLabel(Self.sliderStops[index]))
            sessionToggleItem.image = NSImage(systemSymbolName: "play.circle",
                                              accessibilityDescription: L("Activate"))
        }
        // Positive framing: checked means the display is kept on.
        displaySleepItem.state = keepAwake.allowDisplaySleep ? .off : .on
        // While a session runs, show the actual engagement; otherwise the
        // preference (what the next session will do).
        lidBlockItem.state = lidBlockDisplayedOn ? .on : .off
        if LidSleepSetup.isRunning {
            lidBlockItem.isEnabled = false
            lidBlockItem.title = L("Waiting for Administrator Approval…")
        } else {
            // Ellipsis = clicking opens a dialog (the one-time setup offer).
            lidBlockItem.isEnabled = true
            lidBlockItem.title = (!lidRuleReady && !lidBlocker.isEngaged)
                ? L("Block Lid-Close Sleep…") : L("Block Lid-Close Sleep")
        }
    }

    /// "Display sleeps in 42m · Mac sleeps in 55m" — live countdowns from the
    /// active pmset profile and the current HID idle time; names the apps
    /// holding the system awake when idle sleep is externally prevented.
    private func offStateDetail() -> String {
        let idle = SleepInfo.idleSeconds()
        var parts: [String] = []
        if sleepInfo.displaySleepMinutes > 0 {
            let remaining = max(0, TimeInterval(sleepInfo.displaySleepMinutes * 60) - idle)
            parts.append(L("Display sleeps in %@", Self.format(remaining)))
        } else {
            parts.append(L("Display never sleeps"))
        }
        if !sleepInfo.preventers.isEmpty {
            parts.append(L("Mac kept awake"))
        } else if sleepInfo.systemSleepMinutes > 0 {
            let remaining = max(0, TimeInterval(sleepInfo.systemSleepMinutes * 60) - idle)
            parts.append(L("Mac in %@", Self.format(remaining)))
        } else {
            parts.append(L("Mac never sleeps"))
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
            return minutes > 0 ? L("%dh %dm", hours, minutes) : L("%dh", hours)
        }
        return L("%dm", minutes)
    }

    // MARK: - Launch arguments

    /// `--activate [minutes]` starts a session at launch (indefinite when no
    /// valid minute count follows). The default-on preference engages the
    /// lid block with it; `--no-block-lid` suppresses that for the launched
    /// session only, and `--block-lid` forces it even when the preference is
    /// off.
    private func handleLaunchArguments() {
        let args = CommandLine.arguments
        guard let flagIndex = args.firstIndex(of: "--activate") else { return }
        if args.contains("--no-block-lid") {
            lidBlockSuppressedThisSession = true  // cleared when the session ends
        }
        var minutes: Int?
        if args.indices.contains(flagIndex + 1) {
            minutes = Int(args[flagIndex + 1])
        }
        keepAwake.activate(minutes: minutes)
        if args.contains("--block-lid"), keepAwake.isActive {
            lidBlockSuppressedThisSession = false
            lidBlocker.engage()
            if !keepAwake.isActive {
                lidBlocker.disengage()
            }
        }
    }
}

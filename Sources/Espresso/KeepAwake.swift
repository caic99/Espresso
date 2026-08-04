import AppKit
import IOKit.pwr_mgt

/// Owns the IOKit power assertion and the optional session-expiry timer.
final class KeepAwake {
    static let allowDisplaySleepKey = "allowDisplaySleep"

    init() {
        // The assertion only blocks *idle* sleep; the Mac can still be put to
        // sleep manually mid-session, and the CFRunLoopTimer deadline does not
        // advance during sleep on Intel. Re-check the wall clock at wake.
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            self?.handleWake()
        }
    }

    private var assertionID: IOPMAssertionID = 0
    private var timer: Timer?
    private(set) var endDate: Date?
    private(set) var isActive = false
    /// Minute count the current session was started with; nil for indefinite
    /// sessions or when inactive. Lets the menu checkmark the active duration.
    private(set) var sessionMinutes: Int?

    /// Called on every state change so the UI can refresh.
    var onChange: (() -> Void)?

    /// When true, only system idle sleep is prevented; the display may still
    /// turn off. Default (false) matches `caffeinate -d`: display stays on.
    var allowDisplaySleep: Bool {
        get { UserDefaults.standard.bool(forKey: Self.allowDisplaySleepKey) }
        set {
            UserDefaults.standard.set(newValue, forKey: Self.allowDisplaySleepKey)
            if isActive { reassert() }
            onChange?()
        }
    }

    /// Seconds until the current timed session ends; nil when inactive or indefinite.
    var remaining: TimeInterval? {
        guard isActive, let endDate else { return nil }
        return max(0, endDate.timeIntervalSinceNow)
    }

    /// Start (or restart) a session. `minutes == nil` means indefinite.
    func activate(minutes: Int?) {
        releaseSession()
        if createAssertion() {
            isActive = true
            if let minutes, minutes > 0 {
                sessionMinutes = minutes
                let end = Date().addingTimeInterval(TimeInterval(minutes) * 60)
                endDate = end
                scheduleExpiry(at: end)
            }
        }
        onChange?()
    }

    func deactivate() {
        releaseSession()
        onChange?()
    }

    private func scheduleExpiry(at end: Date) {
        timer?.invalidate()
        let t = Timer(fire: end, interval: 0, repeats: false) { [weak self] _ in
            self?.deactivate()
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func handleWake() {
        guard isActive, let endDate else { return }
        if endDate.timeIntervalSinceNow <= 0 {
            deactivate()
        } else {
            scheduleExpiry(at: endDate)
        }
    }

    private func releaseSession() {
        timer?.invalidate()
        timer = nil
        endDate = nil
        sessionMinutes = nil
        if isActive {
            IOPMAssertionRelease(assertionID)
            assertionID = 0
            isActive = false
        }
    }

    private func createAssertion() -> Bool {
        let type = allowDisplaySleep
            ? kIOPMAssertionTypePreventUserIdleSystemSleep
            : kIOPMAssertionTypePreventUserIdleDisplaySleep
        let result = IOPMAssertionCreateWithName(
            type as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            "Espresso keep-awake session" as CFString,
            &assertionID)
        return result == kIOReturnSuccess
    }

    /// Swap the assertion type in place when the display-sleep option changes
    /// mid-session, keeping the existing timer.
    private func reassert() {
        guard isActive else { return }
        IOPMAssertionRelease(assertionID)
        assertionID = 0
        if !createAssertion() {
            releaseSession()
        }
    }
}

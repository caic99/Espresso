import Foundation
import IOKit.pwr_mgt

/// Owns the IOKit power assertion and the optional session-expiry timer.
final class KeepAwake {
    static let allowDisplaySleepKey = "allowDisplaySleep"

    private var assertionID: IOPMAssertionID = 0
    private var timer: Timer?
    private(set) var endDate: Date?
    private(set) var isActive = false

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
                let end = Date().addingTimeInterval(TimeInterval(minutes) * 60)
                endDate = end
                let t = Timer(fire: end, interval: 0, repeats: false) { [weak self] _ in
                    self?.deactivate()
                }
                RunLoop.main.add(t, forMode: .common)
                timer = t
            }
        }
        onChange?()
    }

    func deactivate() {
        releaseSession()
        onChange?()
    }

    private func releaseSession() {
        timer?.invalidate()
        timer = nil
        endDate = nil
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

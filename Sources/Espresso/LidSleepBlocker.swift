import Foundation

/// Toggles the root-only global "SleepDisabled" power setting (the same knob
/// as `sudo pmset disablesleep 1`) so the Mac stays awake with the lid closed.
/// The flag is system-global and outlives the process, so every engage must be
/// paired with a disengage — the app does this on session end, quit, and AC
/// unplug. If the app dies while engaged, `sudo pmset disablesleep 0` (or a
/// reboot) restores normal lid behavior.
final class LidSleepBlocker {
    private(set) var isEngaged = false

    @discardableResult
    func engage() -> Bool {
        guard !isEngaged else { return true }
        isEngaged = setSleepDisabled(true)
        return isEngaged
    }

    func disengage() {
        guard isEngaged else { return }
        if setSleepDisabled(false) {
            isEngaged = false
        }
    }

    /// Tries passwordless sudo first (instant when a sudoers rule allows it),
    /// then falls back to the standard macOS administrator-password dialog.
    private func setSleepDisabled(_ disabled: Bool) -> Bool {
        let value = disabled ? "1" : "0"
        if run("/usr/bin/sudo", ["-n", "/usr/bin/pmset", "disablesleep", value]) {
            return true
        }
        let script = "do shell script \"/usr/bin/pmset disablesleep \(value)\" with administrator privileges"
        return run("/usr/bin/osascript", ["-e", script])
    }

    private func run(_ path: String, _ arguments: [String]) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return false }
        process.waitUntilExit()
        return process.terminationStatus == 0
    }
}

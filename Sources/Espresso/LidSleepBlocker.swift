import Foundation

/// Toggles the root-only global "SleepDisabled" power setting (the same knob
/// as `sudo pmset disablesleep 1`) so the Mac stays awake with the lid closed.
///
/// The flag is system-global and outlives the process, so the unwind must be
/// guaranteed to run unattended: engage() only succeeds via passwordless
/// `sudo -n` — never an interactive prompt — which proves the automatic
/// disengage paths (session end, quit, AC unplug) can also succeed with
/// nobody at the keyboard. If the app dies while engaged, `sudo pmset
/// disablesleep 0` (or a reboot) restores normal lid behavior, and
/// reconcileAtLaunch() cleans it up on the next start.
final class LidSleepBlocker {
    private(set) var isEngaged = false
    private var isEngaging = false
    private var disengageRequested = false

    /// Adopt — and immediately try to clear — a SleepDisabled flag left over
    /// from a previous crashed instance. Call before anything else at launch.
    func reconcileAtLaunch() {
        guard Self.systemFlagIsSet() else { return }
        isEngaged = true
        disengage()
    }

    @discardableResult
    func engage() -> Bool {
        guard !isEngaged else { return true }
        isEngaging = true
        disengageRequested = false
        let ok = setSleepDisabled(true)
        isEngaging = false
        // A disengage request (session end, AC unplug) arrived while the
        // privileged command ran — honor it instead of finishing the engage.
        if ok && disengageRequested {
            _ = setSleepDisabled(false)
            return false
        }
        isEngaged = ok
        return ok
    }

    /// Returns true when the block is (or will be) off; false means the
    /// system flag is still set and the caller should surface that loudly.
    @discardableResult
    func disengage() -> Bool {
        if isEngaging {
            disengageRequested = true
            return true
        }
        guard isEngaged else { return true }
        if setSleepDisabled(false) {
            isEngaged = false
        }
        return !isEngaged
    }

    /// Unprivileged read of the live system flag.
    static func systemFlagIsSet() -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
        process.arguments = ["-g"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return false }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let output = String(data: data, encoding: .utf8) ?? ""
        return output.range(of: #"SleepDisabled\s+1"#, options: .regularExpression) != nil
    }

    private func setSleepDisabled(_ disabled: Bool) -> Bool {
        run("/usr/bin/sudo", ["-n", "/usr/bin/pmset", "disablesleep", disabled ? "1" : "0"])
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

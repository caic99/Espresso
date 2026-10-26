import Foundation

/// One-time setup that lets Espresso toggle `pmset disablesleep` without a
/// password: installs a sudoers drop-in scoped to exactly
/// `pmset disablesleep 0` and `pmset disablesleep 1` for the current user.
/// Runs in a background `osascript` behind the standard macOS administrator
/// prompt, so the app stays responsive while the password dialog is up.
enum LidSleepSetup {
    /// One file per user, so one account's setup never replaces another's
    /// rule. The "zz-" prefix makes it load after other drop-ins: sudoers
    /// applies the last matching rule. No "." in the name, or sudo skips it.
    static let sudoersPath = "/etc/sudoers.d/zz-espresso-lidsleep-\(getuid())"

    /// `#uid` names the user numerically, so there is no username to escape.
    static let rule = "#\(getuid()) ALL=(root) NOPASSWD: "
        + "/usr/bin/pmset disablesleep 0, /usr/bin/pmset disablesleep 1"

    /// The same rule, for doing it by hand in Terminal.
    static let manualCommand = "echo \"#$(id -u) ALL=(root) NOPASSWD: "
        + "/usr/bin/pmset disablesleep 0, /usr/bin/pmset disablesleep 1\" "
        + "| sudo tee /etc/sudoers.d/zz-espresso-lidsleep-$(id -u)"

    enum Outcome {
        case installed
        case cancelled
        case failed(String)
    }

    private static var running: Process?

    static var isRunning: Bool { running != nil }

    /// Whether sudo will run `pmset disablesleep` for us without a password.
    /// `sudo -n -l` succeeds only when listing needs no password (some
    /// NOPASSWD rule applies) and the command is permitted; an unrelated
    /// NOPASSWD rule can make this optimistic, which the engage path catches.
    static func probeReady() -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sudo")
        process.arguments = ["-n", "-l", "/usr/bin/pmset", "disablesleep", "1"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return false }
        process.waitUntilExit()
        return process.terminationStatus == 0
    }

    /// Shell script run as root. The rule is validated with `visudo` before
    /// it goes live, so a malformed file can never break sudo.
    static func installScript(rule: String, target: String) -> String {
        "tmp=$(/usr/bin/mktemp /tmp/espresso-sudoers.XXXXXX) || exit 1; "
            + "printf '%s\\n' '\(rule)' > \"$tmp\" && /usr/sbin/visudo -cf \"$tmp\" >/dev/null"
            + " && /usr/bin/install -m 0440 -o root -g wheel \"$tmp\" '\(target)'; "
            + "rc=$?; /bin/rm -f \"$tmp\"; exit $rc"
    }

    static func appleScriptLiteral(_ s: String) -> String {
        "\"" + s.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    static func appleScript(rule: String, target: String) -> String {
        let prompt = "Espresso needs your password once so it can block lid-close sleep. "
            + "It will only be allowed to run “pmset disablesleep”."
        return "do shell script \(appleScriptLiteral(installScript(rule: rule, target: target)))"
            + " with prompt \(appleScriptLiteral(prompt)) with administrator privileges"
    }

    /// Calls `completion` on the main queue.
    static func install(completion: @escaping (Outcome) -> Void) {
        guard running == nil else { return }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", appleScript(rule: rule, target: sudoersPath)]
        let errPipe = Pipe()
        process.standardOutput = FileHandle.nullDevice
        process.standardError = errPipe
        process.terminationHandler = { p in
            let err = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(),
                             encoding: .utf8) ?? ""
            let outcome: Outcome
            if p.terminationStatus == 0 {
                outcome = .installed
            } else if err.contains("-128") {  // errAEUserCanceled
                outcome = .cancelled
            } else {
                outcome = .failed(err.trimmingCharacters(in: .whitespacesAndNewlines))
            }
            DispatchQueue.main.async {
                running = nil
                completion(outcome)
            }
        }
        do {
            try process.run()
            running = process
        } catch {
            completion(.failed(error.localizedDescription))
        }
    }
}

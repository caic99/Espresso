import Foundation
import IOKit

/// How the system is configured to idle-sleep (from `pmset -g`, reflecting
/// the active AC/battery profile) and how long the user has been idle —
/// used to explain what will happen while Espresso holds no assertion.
struct SleepInfo {
    var displaySleepMinutes: Int   // 0 = never
    var systemSleepMinutes: Int    // 0 = never
    /// Non-system processes currently holding idle-sleep assertions.
    var preventers: [String]

    static let none = SleepInfo(displaySleepMinutes: 0, systemSleepMinutes: 0, preventers: [])

    /// Transient system daemons that routinely hold assertions (powerd keeps
    /// the system up while the display is on) — not meaningful "apps".
    private static let systemDaemons: Set<String> = [
        "powerd", "sharingd", "runningboardd", "mDNSResponder", "backupd",
        "useractivityd", "bluetoothd", "apsd",
    ]

    static func current() -> SleepInfo {
        var info = SleepInfo.none
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
        process.arguments = ["-g"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return info }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        for line in (String(data: data, encoding: .utf8) ?? "").split(separator: "\n") {
            let fields = line.split(separator: " ", omittingEmptySubsequences: true)
            guard fields.count >= 2 else { continue }
            if fields[0] == "displaysleep" {
                info.displaySleepMinutes = Int(fields[1]) ?? 0
            } else if fields[0] == "sleep" {
                info.systemSleepMinutes = Int(fields[1]) ?? 0
                if let range = line.range(of: #"sleep prevented by [^)]+"#,
                                          options: .regularExpression) {
                    info.preventers = line[range]
                        .replacingOccurrences(of: "sleep prevented by ", with: "")
                        .split(separator: ",")
                        .map { $0.trimmingCharacters(in: .whitespaces) }
                        .filter { !systemDaemons.contains($0) }
                }
            }
        }
        return info
    }

    /// Seconds since the last keyboard/mouse/trackpad event.
    static func idleSeconds() -> TimeInterval {
        let service = IOServiceGetMatchingService(kIOMainPortDefault,
                                                  IOServiceMatching("IOHIDSystem"))
        guard service != 0 else { return 0 }
        defer { IOObjectRelease(service) }
        guard let prop = IORegistryEntryCreateCFProperty(
                service, "HIDIdleTime" as CFString, kCFAllocatorDefault, 0)?
                .takeRetainedValue(),
              let nanoseconds = (prop as? NSNumber)?.doubleValue
        else { return 0 }
        return nanoseconds / 1_000_000_000
    }
}

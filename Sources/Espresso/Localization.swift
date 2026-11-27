import Foundation

/// Localized UI text. The English text is the key, so a missing translation
/// falls back to English; the system language picks the .lproj.
func L(_ key: String) -> String {
    NSLocalizedString(key, comment: "")
}

/// Localized format string, e.g. L("Keep Awake for %@", "2h").
func L(_ key: String, _ args: CVarArg...) -> String {
    String(format: NSLocalizedString(key, comment: ""), arguments: args)
}

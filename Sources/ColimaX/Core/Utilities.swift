import AppKit
import Foundation

enum Format {
    static func bytes(_ value: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: value, countStyle: .memory)
    }

    static func percent(_ value: Double) -> String {
        String(format: "%.1f%%", value)
    }

    /// Identifier-like numbers (port, PID, exit code, errno, uid…) as plain digits without grouping
    /// separators. An Int interpolated into `String(localized:)` / `Text("…")` is formatted per locale
    /// (vi: 3307 → "3.307"), so pass this string (the key uses %@) instead of the Int.
    static func digits(_ value: some BinaryInteger) -> String {
        String(value)
    }

    /// 2.0 → "2", 2.5 → "2.5" (for CLI arguments: one decimal place, always a dot).
    static func decimal(_ value: Double) -> String {
        value.rounded() == value ? String(Int(value)) : String(format: "%.1f", locale: Locale(identifier: "en_US_POSIX"), value)
    }

    // Formatters are created once and reused (these Foundation formatters are thread-safe).
    nonisolated(unsafe) private static let relativeFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter
    }()
    nonisolated(unsafe) private static let isoFractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
    nonisolated(unsafe) private static let isoPlain: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    static func relative(_ date: Date) -> String {
        relativeFormatter.localizedString(for: date, relativeTo: .now)
    }

    /// Parses ISO 8601 (with or without fractional seconds, as Docker returns).
    static func date(iso: String?) -> Date? {
        guard let iso, !iso.isEmpty, !iso.hasPrefix("0001-01-01") else { return nil }
        if let date = isoFractional.date(from: iso) { return date }
        if let date = isoPlain.date(from: iso) { return date }
        // Docker returns nanoseconds (9 digits); ISO8601DateFormatter only accepts up to milliseconds.
        if let dot = iso.firstIndex(of: "."), let zone = iso[dot...].firstIndex(where: { $0 == "Z" || $0 == "+" || $0 == "-" }) {
            let trimmed = String(iso[..<dot]) + String(iso[dot..<zone].prefix(4)) + String(iso[zone...])
            return isoFractional.date(from: trimmed)
        }
        return nil
    }

    static func relative(iso: String?) -> String {
        guard let iso else { return "—" }
        return date(iso: iso).map(relative) ?? iso
    }
}

/// Confirmation dialogs, mainly for destructive operations (delete, prune, reset).
@MainActor
enum Confirm {
    struct Result {
        let confirmed: Bool
        let checkboxOn: Bool
    }

    static func destructive(_ title: String, message: String, button: String = String(localized: "Delete")) -> Bool {
        ask(title, message: message, button: button).confirmed
    }

    static func ask(_ title: String, message: String, button: String, checkbox: String? = nil, destructive: Bool = true) -> Result {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = destructive ? .critical : .warning
        let primary = alert.addButton(withTitle: button)
        if destructive { primary.hasDestructiveAction = true }
        alert.addButton(withTitle: String(localized: "Cancel"))
        if let checkbox {
            alert.showsSuppressionButton = true
            alert.suppressionButton?.title = checkbox
            alert.suppressionButton?.state = .off
        }
        NSApp.activate(ignoringOtherApps: true)
        let response = alert.runModal()
        return Result(
            confirmed: response == .alertFirstButtonReturn,
            checkboxOn: alert.suppressionButton?.state == .on
        )
    }
}

extension Confirm {
    /// Strong confirmation: the user must type `expected` exactly (e.g. the container name) to proceed.
    static func typed(_ title: String, message: String, expected: String, button: String) -> Bool {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message + "\n\n" + String(localized: "Type “\(expected)” to confirm.")
        alert.alertStyle = .critical
        let primary = alert.addButton(withTitle: button)
        primary.hasDestructiveAction = true
        alert.addButton(withTitle: String(localized: "Cancel"))
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
        field.placeholderString = expected
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return false }
        return field.stringValue.trimmingCharacters(in: .whitespaces) == expected
    }
}

@MainActor
enum Pasteboard {
    static func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

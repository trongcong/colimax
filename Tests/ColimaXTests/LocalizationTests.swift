import XCTest
#if SWIFT_PACKAGE
@testable import ColimaX
#endif

/// G18: checks the Vietnamese translation file in the repo (no .app bundle needed).
final class LocalizationTests: XCTestCase {
    private static let repoRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent() // ColimaXTests
        .deletingLastPathComponent() // Tests
        .deletingLastPathComponent()

    private func loadStrings(_ language: String) throws -> [String: String] {
        let url = Self.repoRoot.appendingPathComponent("Resources/\(language).lproj/Localizable.strings")
        let dictionary = try XCTUnwrap(NSDictionary(contentsOf: url), "\(url.path) failed to parse")
        return try XCTUnwrap(dictionary as? [String: String])
    }

    /// Format specifiers, sorted, with positional indices (`1$`) stripped; `%%` is not counted.
    private func specifiers(_ text: String) -> [String] {
        let regex = try! NSRegularExpression(pattern: #"%%|%(?:\d+\$)?(@|lld|llu|ld|lu|lf|d|i|u|f|s)"#)
        let range = NSRange(text.startIndex..., in: text)
        return regex.matches(in: text, range: range).compactMap { match in
            let r = match.range(at: 1)
            guard r.location != NSNotFound, let swiftRange = Range(r, in: text) else { return nil }
            return String(text[swiftRange])
        }.sorted()
    }

    func testVietnameseStringsParse() throws {
        let strings = try loadStrings("vi")
        XCTAssertGreaterThan(strings.count, 300, "vi.lproj has too few translations")
        for (key, value) in strings {
            XCTAssertFalse(key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, "empty key")
            XCTAssertFalse(value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, "empty translation for \(key)")
        }
    }

    func testFormatSpecifiersMatch() throws {
        for (key, value) in try loadStrings("vi") {
            XCTAssertEqual(specifiers(key), specifiers(value), "format specifiers differ: \(key) → \(value)")
            XCTAssertEqual(key.components(separatedBy: "%%").count, value.components(separatedBy: "%%").count,
                           "%% count differs: \(key) → \(value)")
        }
    }

    func testEnglishBundleExists() {
        let url = Self.repoRoot.appendingPathComponent("Resources/en.lproj/Localizable.strings")
        XCTAssertNotNil(NSDictionary(contentsOf: url), "en.lproj must exist and parse (it may be empty)")
    }

    func testSpecifierHelper() {
        XCTAssertEqual(specifiers("Delete %@ (%lld%%) %1$@"), ["@", "@", "lld"])
    }

    /// Ports and exit codes must not use locale number grouping (vi: 3307 -> "3.307").
    func testIdentifierNumbersAreNotGrouped() {
        let vi = Locale(identifier: "vi")
        let port = 3307
        XCTAssertEqual(Format.digits(port), "3307")
        XCTAssertEqual(Format.digits(Int32(-9)), "-9")
        // Interpolating an Int directly gets locale grouping; this is the bug to avoid.
        XCTAssertEqual(String(localized: "Port \(port) declared more than once", locale: vi), "Port 3.307 declared more than once")
        let fixed = String(localized: "Port \(Format.digits(port)) declared more than once", locale: vi)
        XCTAssertTrue(fixed.contains("3307") && !fixed.contains("3.307"), fixed)
        let menu = String(localized: "Open localhost:\(Format.digits(port))", locale: vi)
        XCTAssertTrue(menu.hasSuffix("localhost:3307"), menu)
    }

    func testPortConflictTitleUsesPlainDigits() throws {
        let json = #"{"Id":"db","Name":"/db","State":{"Running":false},"HostConfig":{"PortBindings":{"3306/tcp":[{"HostIp":"","HostPort":"13307"}]}}}"#
        let details = try JSONDecoder().decode(ContainerDetails.self, from: Data(json.utf8))
        let items = PortDiagnostics.check([details]) { _ in true }
        let title = try XCTUnwrap(items.first?.title)
        XCTAssertTrue(title.contains("13307"), title)
    }

    func testLanguageMapping() {
        XCTAssertNil(AppLanguage.system.appleLanguages)
        XCTAssertEqual(AppLanguage.en.appleLanguages, ["en"])
        XCTAssertEqual(AppLanguage.vi.appleLanguages, ["vi"])
    }

    /// Every vi string with a port / localhost takes the port as a string (`%@` + `Format.digits`), not a
    /// locale-formatted number; rendering with 3307 must give "3307", not "3.307".
    func testVietnamesePortStringsRenderPlainDigits() throws {
        let strings = try loadStrings("vi")
        let portKeys = strings.keys.filter { key in
            let lower = key.lowercased()
            return (lower.contains("port %@") || lower.contains("localhost:%@")) && key.contains("%")
        }
        XCTAssertGreaterThanOrEqual(portKeys.count, 3, "expected to find port strings (\(portKeys))")
        for key in portKeys {
            let value = try XCTUnwrap(strings[key])
            XCTAssertFalse(specifiers(key).contains { ["lld", "ld", "d", "i", "u", "llu", "lu"].contains($0) }, "port must be %@: \(key)")
            let args = specifiers(value).map { _ in "3307" as CVarArg }
            let rendered = String(format: value, locale: Locale(identifier: "vi"), arguments: args)
            XCTAssertTrue(rendered.contains("3307") && !rendered.contains("3.307"), rendered)
        }
        let menu = try XCTUnwrap(strings["Open localhost:%@"])
        XCTAssertEqual(String(format: menu, "3307"), "Mở localhost:3307")
    }
}

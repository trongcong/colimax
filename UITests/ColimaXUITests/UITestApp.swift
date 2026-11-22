import AppKit
import XCTest

/// Launches the UI-test build of ColimaX (`build/ColimaX-UITest.app`, compiled with
/// `-D COLIMAX_UI_TESTING`) with in-memory fixtures instead of Colima / Docker.
enum UITestApp {
    /// `COLIMAX_UITEST_APP` (set by `scripts/ui-tests.sh` via `TEST_RUNNER_COLIMAX_UITEST_APP`) or
    /// `<repo>/build/ColimaX-UITest.app`.
    static var url: URL {
        if let path = ProcessInfo.processInfo.environment["COLIMAX_UITEST_APP"], !path.isEmpty {
            return URL(fileURLWithPath: path)
        }
        return URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // ColimaXUITests
            .deletingLastPathComponent() // UITests
            .deletingLastPathComponent() // repository root
            .appendingPathComponent("build/ColimaX-UITest.app")
    }

    /// - Parameters:
    ///   - screen: `Screen` raw value to open at launch (skips navigating through the Go menu).
    ///   - scenario: `UITestScenario` raw value in the app (`vm-stopped`, `slow-op`, `no-brew`, …).
    ///   - environment: extra launch environment (e.g. `COLIMAX_UI_TEST_OPEN_FILE`, `DOCKER_CONFIG`).
    ///   - language: UI language (`en`, `vi`).
    @MainActor
    static func launch(screen: String? = nil, scenario: String? = nil, environment: [String: String] = [:],
                       language: String = "en") -> XCUIApplication {
        let app = XCUIApplication(url: url)
        app.launchEnvironment["COLIMAX_UI_TEST_FIXTURES"] = "1"
        if let screen { app.launchEnvironment["COLIMAX_UI_TEST_SCREEN"] = screen }
        if let scenario { app.launchEnvironment["COLIMAX_UI_TEST_SCENARIO"] = scenario }
        app.launchEnvironment.merge(environment) { _, new in new }
        // Fixed UI language, no restored windows, no window animations: predictable and fast. The Setup
        // Assistant always opens at launch when tools are missing (whatever an earlier run saved).
        app.launchArguments += ["-AppleLanguages", "(\(language))", "-ApplePersistenceIgnoreState", "YES",
                                "-NSAutomaticWindowAnimationsEnabled", "NO", "-hideSetupAtLaunch", "NO"]
        app.launch()
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 10), "main window did not appear")
        return app
    }
}

extension XCUIApplication {
    /// Opens a screen through the "Go" menu.
    func go(to screen: String) {
        menuBars.menuBarItems["Go"].click()
        menuBars.menuItems[screen].click()
        XCTAssertTrue(tables.firstMatch.waitForExistence(timeout: 5), "\(screen) table did not appear")
    }

    /// The cell text showing `name` in the window's table / list (container, volume, image, project) (clicking / right-clicking it acts on
    /// its row). Matched on label or value: SwiftUI table cells expose their text in either, depending on
    /// the macOS version.
    func containerRow(_ name: String) -> XCUIElement {
        let text = NSPredicate(format: "label == %@ OR value == %@", name, name)
        return windows.firstMatch.descendants(matching: .staticText).matching(text).firstMatch
    }

    /// Waits for a container row; on timeout fails with a dump of the window's accessibility tree, so the
    /// failure text says what the table actually exposes.
    @discardableResult
    func waitForRow(_ name: String, timeout: TimeInterval = 5, file: StaticString = #filePath, line: UInt = #line) -> XCUIElement {
        waitForContainer(name, timeout: timeout, file: file, line: line)
    }

    @discardableResult
    func waitForContainer(_ name: String, timeout: TimeInterval = 5, file: StaticString = #filePath, line: UInt = #line) -> XCUIElement {
        let row = containerRow(name)
        if !row.waitForExistence(timeout: timeout) {
            let tree = windows.firstMatch.debugDescription
            XCTFail("container \(name) not found. Window tree:\n\(tree.prefix(4000))", file: file, line: line)
        }
        return row
    }

    /// Any element with this accessibility identifier (selectable text is not always a StaticText).
    func element(_ identifier: String) -> XCUIElement {
        windows.firstMatch.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    /// Selects a tab of the container details pane (segmented picker).
    func openDetailsTab(_ title: String) {
        let segment = windows.firstMatch.radioButtons[title]
        if segment.waitForExistence(timeout: 3) { segment.click() } else { windows.firstMatch.buttons[title].click() }
    }

    /// Waits until `element` disappears; returns as soon as it does (no fixed delay).
    func waitForDisappearance(_ element: XCUIElement, timeout: TimeInterval = 5) -> Bool {
        let gone = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: element)
        return XCTWaiter().wait(for: [gone], timeout: timeout) == .completed
    }

    /// The modal alert currently shown (NSAlert run modally).
    var alertDialog: XCUIElement { dialogs.firstMatch }

    /// A toolbar button of the main window, by title.
    func toolbarButton(_ title: String) -> XCUIElement {
        let inToolbar = windows.firstMatch.toolbars.buttons[title]
        return inToolbar.exists ? inToolbar : windows.firstMatch.buttons[title].firstMatch
    }

    /// Waits until the main window's title is `title` (the navigation title of the current screen).
    @discardableResult
    func waitForWindowTitle(_ title: String, timeout: TimeInterval = 5) -> Bool {
        let predicate = NSPredicate(format: "title == %@", title)
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: windows.firstMatch)
        return XCTWaiter().wait(for: [expectation], timeout: timeout) == .completed
    }

    /// Opens an item of the app menu (the one named after the app).
    func clickAppMenuItem(_ title: String) {
        menuBars.menuBarItems.element(boundBy: 1).click()
        menuBars.menuItems[title].click()
    }

    /// Replaces the content of a text field.
    func replaceText(in field: XCUIElement, with text: String) {
        field.click()
        field.typeKey("a", modifierFlags: .command)
        field.typeKey(.delete, modifierFlags: [])
        paste(text, into: field)
    }

    /// Enters `text` by pasting it: `typeText` goes through the active input source, and an input
    /// method such as Vietnamese Telex rewrites it ("nginx" → "ngĩn").
    func paste(_ text: String, into field: XCUIElement) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        field.click()
        field.typeKey("v", modifierFlags: .command)
    }

    /// Text shown in the main window (label or value contains `text`). Scoped to the window: querying
    /// the whole app (menus, menu bar extra) is much slower.
    func windowText(_ text: String) -> XCUIElement {
        windows.firstMatch.elementContaining(text)
    }

    /// Scrolls the scroll view under `element` until the element lies entirely inside the window
    /// (macOS UI tests do not scroll by themselves, and an element showing only a few pixels still
    /// counts as hittable while a click at its center lands outside the window).
    func reveal(_ element: XCUIElement) {
        let window = windows.firstMatch
        let scrollView = window.scrollViews.containing(.any, identifier: element.identifier).firstMatch
        func visible() -> Bool { window.frame.insetBy(dx: 0, dy: 4).contains(element.frame) }
        // Try one direction, then the other (the sign of a scroll delta depends on system settings).
        for deltaY in Array(repeating: -120.0, count: 8) + Array(repeating: 120.0, count: 16) where !visible() {
            scrollView.scroll(byDeltaX: 0, deltaY: deltaY)
        }
        XCTAssertTrue(visible(), "could not scroll \(element.identifier) into view: \(element.frame) in \(window.frame)")
    }
}

/// Waits until `predicate` holds for `element` (e.g. "isEnabled == true").
@MainActor
func waitUntil(_ element: XCUIElement, _ predicate: String, timeout: TimeInterval = 5) -> Bool {
    let expectation = XCTNSPredicateExpectation(predicate: NSPredicate(format: predicate), object: element)
    return XCTWaiter().wait(for: [expectation], timeout: timeout) == .completed
}

extension XCUIElement {
    /// Displayed text: the value for selectable / editable text, otherwise the label.
    var text: String {
        if let value = value as? String, !value.isEmpty { return value }
        return label
    }

    /// Any descendant whose label or value contains `text`.
    func elementContaining(_ text: String) -> XCUIElement {
        descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@", text, text)).firstMatch
    }

    /// State of a checkbox / switch (value 1 or "1").
    var isOn: Bool {
        if let number = value as? NSNumber { return number.boolValue }
        return (value as? String) == "1"
    }
}

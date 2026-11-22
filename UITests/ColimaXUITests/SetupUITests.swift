import XCTest

/// Setup Assistant (G26) states, driven by the `UITestScenario` fixtures: nothing installed, tools
/// missing, compose plugin not loaded, no profile yet, everything installed. Nothing is installed for
/// real: `brew install` is a fake stream and the docker CLI config goes to a temporary `DOCKER_CONFIG`.
@MainActor
final class SetupUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() async throws {
        continueAfterFailure = false
    }

    override func tearDown() async throws {
        app?.terminate()
    }

    private func tool(_ name: String, _ state: String) -> XCUIElement {
        app.element("setup.tool.\(name).\(state)")
    }

    private func waitForSheet(file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(app.element("setup.tool.Homebrew.ok").waitForExistence(timeout: 10) || app.element("setup.tool.Homebrew.missing").exists,
                      "Setup Assistant did not open. Window tree:\n\(app.windows.firstMatch.debugDescription.prefix(4000))",
                      file: file, line: line)
    }

    func testAllToolsInstalledShowsGreenRowsAndDoesNotOpenAtLaunch() {
        app = UITestApp.launch()
        XCTAssertFalse(app.element("setup.allInstalled").waitForExistence(timeout: 2), "nothing missing: no sheet at launch")

        app.clickAppMenuItem("Setup Assistant…")
        XCTAssertTrue(app.element("setup.allInstalled").waitForExistence(timeout: 5))
        for name in ["Homebrew", "Colima", "Docker CLI", "Docker Compose"] {
            XCTAssertTrue(tool(name, "ok").exists, "\(name) should be green")
        }
        app.windows.firstMatch.sheets.firstMatch.buttons["Done"].click()
    }

    func testNoHomebrewShowsTheInstallCommandAndNoInstallButton() {
        app = UITestApp.launch(scenario: "no-brew")
        waitForSheet()
        XCTAssertTrue(tool("Homebrew", "missing").exists, "the sheet opens at launch when tools are missing")
        XCTAssertTrue(app.element("setup.copyBrewCommand").exists, "the official install command can be copied")
        XCTAssertTrue(app.windowText("raw.githubusercontent.com/Homebrew/install").exists, "the official command is shown")
        XCTAssertTrue(app.links["Homebrew installation guide (brew.sh)"].exists, "with a link to brew.sh")
        XCTAssertFalse(app.buttons["Install with Homebrew"].exists, "Homebrew itself is never installed by the app")
    }

    func testMissingToolsInstallAsksWithTheExactCommandThenRefreshes() {
        app = UITestApp.launch(scenario: "missing-tools")
        waitForSheet()
        XCTAssertTrue(tool("Docker CLI", "missing").exists)
        XCTAssertTrue(tool("Docker Compose", "missing").exists)
        let install = app.buttons["Install with Homebrew"]
        XCTAssertTrue(install.exists)
        let alert = app.alertDialog

        install.click()
        XCTAssertTrue(alert.waitForExistence(timeout: 5), "installing asks first")
        XCTAssertTrue(alert.staticTexts["Install with Homebrew?"].exists)
        XCTAssertTrue(alert.elementContaining("brew install docker docker-compose").exists, "the dialog shows the exact command")
        alert.buttons["Cancel"].click()
        XCTAssertTrue(app.waitForDisappearance(alert))
        XCTAssertTrue(tool("Docker CLI", "missing").exists, "Cancel installs nothing")

        install.click()
        XCTAssertTrue(alert.waitForExistence(timeout: 5))
        alert.buttons["Install"].click()
        XCTAssertTrue(app.windowText("==> Installing docker").waitForExistence(timeout: 5), "the brew log streams in the sheet")
        XCTAssertTrue(app.element("setup.allInstalled").waitForExistence(timeout: 10), "afterwards the rows refresh")
        XCTAssertTrue(tool("Docker CLI", "ok").exists)
        XCTAssertTrue(tool("Docker Compose", "ok").exists)
    }

    func testConfigurePluginUpdatesTheDockerConfigAndKeepsOtherKeys() throws {
        let configDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("colimax-uitest-docker-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: configDirectory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: configDirectory) }
        let config = configDirectory.appendingPathComponent("config.json")
        try Data(#"{"auths":{"registry.example":{}},"currentContext":"colima"}"#.utf8).write(to: config)

        app = UITestApp.launch(scenario: "compose-plugin", environment: ["DOCKER_CONFIG": configDirectory.path])
        waitForSheet()
        XCTAssertTrue(tool("Docker Compose", "needsSetup").exists, "installed but not loaded")
        let alert = app.alertDialog

        app.buttons["Configure Plugin"].click()
        XCTAssertTrue(alert.waitForExistence(timeout: 5), "changing the docker config asks first")
        XCTAssertTrue(alert.staticTexts["Configure the Compose plugin?"].exists)
        alert.buttons["Configure"].click()
        XCTAssertTrue(app.element("setup.allInstalled").waitForExistence(timeout: 10), "docker compose works afterwards")

        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: config)) as? [String: Any])
        XCTAssertEqual(object["cliPluginsExtraDirs"] as? [String], ["/opt/homebrew/lib/docker/cli-plugins"])
        XCTAssertNotNil(object["auths"], "other keys are kept")
        XCTAssertEqual(object["currentContext"] as? String, "colima")
        XCTAssertTrue(FileManager.default.fileExists(atPath: configDirectory.appendingPathComponent("config.json.colimax-backup").path),
                      "the previous file is backed up")
    }

    func testNoProfileStartColimaStartsTheDefaultProfile() {
        app = UITestApp.launch(scenario: "no-profile")
        app.clickAppMenuItem("Setup Assistant…")
        let start = app.buttons["Start Colima"]
        XCTAssertTrue(start.waitForExistence(timeout: 5), "with no profile the assistant offers to start one")
        start.click()
        let operation = app.element("setup.operation.title")
        XCTAssertTrue(operation.waitForExistence(timeout: 5), "the operation shows in the sheet")
        XCTAssertEqual(operation.text, "Start default")
        XCTAssertTrue(app.element("setup.allInstalled").waitForExistence(timeout: 10), "profile default now exists")
        XCTAssertFalse(start.exists)
    }
}

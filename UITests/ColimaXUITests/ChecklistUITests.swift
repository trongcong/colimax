import XCTest

/// Items of the manual pre-release checklist (docs/TESTING.md) that are about UI wiring: shortcuts,
/// waiting states, confirmations, forms and sheets. Runs against fixtures (`UITestFixtures`, optionally a
/// `UITestScenario`), never against a real VM.
@MainActor
final class ChecklistUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() async throws {
        continueAfterFailure = false
    }

    override func tearDown() async throws {
        app?.terminate()
    }

    private func launch(screen: String? = nil, scenario: String? = nil, environment: [String: String] = [:],
                        language: String = "en") {
        app = UITestApp.launch(screen: screen, scenario: scenario, environment: environment, language: language)
    }

    /// Writes a temporary file for `COLIMAX_UI_TEST_OPEN_FILE` (the app's open panel returns it).
    private func temporaryFile(_ name: String, _ content: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("colimax-uitest-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent(name)
        try Data(content.utf8).write(to: url)
        return url
    }

    // MARK: - Launch and navigation

    func testShortcutsOpenScreensInSidebarOrder() {
        launch()
        let order = ["Dashboard", "Monitoring", "Diagnostics", "Containers", "Compose", "Images", "Volumes", "Networks", "Storage"]
        for (index, title) in order.enumerated() {
            app.typeKey(String(index + 1), modifierFlags: .command)
            XCTAssertTrue(app.waitForWindowTitle(title), "⌘\(index + 1) should open \(title), window title is \(app.windows.firstMatch.title)")
        }

        app.menuBars.menuBarItems["Go"].click()
        XCTAssertTrue(app.menuBars.menuItems["Runtime Settings"].exists, "the Go menu lists Runtime Settings")
        app.menuBars.menuItems["Runtime Settings"].click()
        XCTAssertTrue(app.waitForWindowTitle("Runtime Settings"))

        let windowsBefore = app.windows.count
        app.menuBars.menuBarItems.element(boundBy: 1).click()
        let settingsItem = app.menuBars.menuItems.matching(NSPredicate(format: "title BEGINSWITH 'Settings'")).firstMatch
        XCTAssertTrue(settingsItem.exists, "the app menu has Settings…")
        settingsItem.click()
        let settingsOpened = XCTNSPredicateExpectation(predicate: NSPredicate(format: "count > %d", windowsBefore), object: app.windows)
        XCTAssertEqual(XCTWaiter().wait(for: [settingsOpened], timeout: 5), .completed, "⌘, opens the Settings window")
    }

    func testDockerScreensWaitWhileVMIsStopped() {
        launch(screen: "containers", scenario: "vm-stopped")
        XCTAssertTrue(app.windowText("VM default is not running").waitForExistence(timeout: 5),
                      "a stopped VM shows a waiting state on Docker screens")
        XCTAssertTrue(app.windows.firstMatch.buttons["Start"].exists, "with a Start button")
        XCTAssertFalse(app.element("banner.error").exists, "not an error")

        app.typeKey("6", modifierFlags: .command) // Images
        XCTAssertTrue(app.waitForWindowTitle("Images"))
        XCTAssertTrue(app.windowText("VM default is not running").waitForExistence(timeout: 5))
        XCTAssertFalse(app.element("banner.error").exists)
    }

    // MARK: - Long operations

    /// Starts `Stop default`, which never finishes in the `slow-op` scenario.
    private func startHangingStop() {
        let stop = app.buttons["toolbar.vm.stop"]
        XCTAssertTrue(stop.waitForExistence(timeout: 5))
        stop.click()
        let alert = app.alertDialog
        XCTAssertTrue(alert.waitForExistence(timeout: 5), "running containers: stopping asks first")
        alert.buttons["Stop"].click()
        XCTAssertTrue(app.element("operation.cancel").waitForExistence(timeout: 5), "the operation runs and can be cancelled")
        XCTAssertEqual(app.element("operation.title").text, "Stop default")
    }

    func testCancellingALongOperationAsksAndMarksItCancelled() {
        launch(scenario: "slow-op")
        startHangingStop()
        let alert = app.alertDialog

        app.element("operation.cancel").click()
        XCTAssertTrue(alert.waitForExistence(timeout: 5), "cancelling asks first")
        XCTAssertTrue(alert.staticTexts["Cancel Stop default?"].exists)
        alert.buttons["Cancel"].click()
        XCTAssertTrue(app.waitForDisappearance(alert))
        XCTAssertTrue(app.element("operation.cancel").exists, "answering Cancel keeps the operation running")

        app.element("operation.cancel").click()
        XCTAssertTrue(alert.waitForExistence(timeout: 5))
        alert.buttons["Cancel Operation"].click()
        XCTAssertTrue(app.element("operation.cancelled").waitForExistence(timeout: 5), "the state changes to Cancelled")
        XCTAssertFalse(app.element("operation.cancel").exists)
    }

    func testQuitDuringALongOperationAsksFirst() {
        launch(scenario: "slow-op")
        startHangingStop()
        let alert = app.alertDialog

        app.typeKey("q", modifierFlags: .command)
        XCTAssertTrue(alert.waitForExistence(timeout: 5), "quitting while an operation runs asks first")
        XCTAssertTrue(alert.staticTexts["Quit while “Stop default” is running?"].exists)
        alert.buttons["Cancel"].click()
        XCTAssertTrue(app.waitForDisappearance(alert))
        XCTAssertNotEqual(app.state, .notRunning, "Cancel keeps the app open")
        XCTAssertTrue(app.element("operation.cancel").exists, "and the operation running")

        app.typeKey("q", modifierFlags: .command)
        XCTAssertTrue(alert.waitForExistence(timeout: 5))
        alert.buttons["Cancel Operation and Quit"].click()
        XCTAssertTrue(app.wait(for: .notRunning, timeout: 10), "confirming cancels the operation and quits")
    }

    func testQuitWithoutOperationQuitsAtOnce() {
        launch()
        app.typeKey("q", modifierFlags: .command)
        XCTAssertTrue(app.wait(for: .notRunning, timeout: 5), "no running operation: quits without asking")
    }

    // MARK: - Runtime Settings

    func testInvalidProfileNameIsBlocked() {
        launch(screen: "runtime")
        let newProfile = app.windows.firstMatch.buttons["New Profile…"]
        XCTAssertTrue(newProfile.waitForExistence(timeout: 5))
        newProfile.click()

        let name = app.element("createProfile.name")
        XCTAssertTrue(name.waitForExistence(timeout: 5), "create profile sheet did not open")
        let create = app.element("createProfile.create")
        XCTAssertFalse(create.isEnabled, "empty name: Create is disabled")

        app.replaceText(in: name, with: "bad name/..")
        XCTAssertTrue(app.element("createProfile.error").waitForExistence(timeout: 3), "an invalid name shows an error")
        XCTAssertFalse(create.isEnabled, "and blocks Create")

        app.replaceText(in: name, with: "default")
        XCTAssertTrue(app.element("createProfile.error").waitForExistence(timeout: 3), "an existing profile name is blocked")
        XCTAssertFalse(create.isEnabled)

        app.replaceText(in: name, with: "work_2")
        XCTAssertTrue(app.waitForDisappearance(app.element("createProfile.error"), timeout: 3))
        XCTAssertTrue(create.isEnabled, "a valid new name enables Create")
        app.windows.firstMatch.sheets.firstMatch.buttons["Cancel"].click()
        XCTAssertFalse(app.element("operation.title").exists, "Cancel creates nothing")
    }

    func testCPUChangeOnRunningVMAsksToRestart() {
        launch(screen: "runtime")
        let increase = app.element("runtime.cpus.increase")
        XCTAssertTrue(increase.waitForExistence(timeout: 5), "CPU stepper not found")
        increase.click()

        let apply = app.element("runtime.apply")
        XCTAssertTrue(apply.isEnabled)
        XCTAssertEqual(apply.label, "Apply", "a CPU change does not recreate the VM")
        apply.click()
        let alert = app.alertDialog
        XCTAssertTrue(alert.waitForExistence(timeout: 5), "applying to a running VM asks to restart it")
        XCTAssertTrue(alert.staticTexts["Restart the VM?"].exists)
        alert.buttons["Cancel"].click()
        XCTAssertTrue(app.waitForDisappearance(alert))
        XCTAssertFalse(app.element("operation.title").exists, "Cancel applies nothing")
    }

    func testArchChangeAsksToRecreateWithDataOption() {
        launch(screen: "runtime")
        let arch = app.element("runtime.arch")
        XCTAssertTrue(arch.waitForExistence(timeout: 5), "Arch picker not found")
        arch.click()
        app.menuItems["x86_64"].click()

        let apply = app.element("runtime.apply")
        XCTAssertEqual(apply.label, "Reset VM & Apply…", "changing arch recreates the VM")
        apply.click()
        let alert = app.alertDialog
        XCTAssertTrue(alert.waitForExistence(timeout: 5))
        XCTAssertTrue(alert.staticTexts["Reset VM default?"].exists)
        XCTAssertTrue(alert.checkBoxes["Also delete runtime data (containers, images, volumes)"].exists,
                      "recreating offers to delete the data")
        alert.buttons["Cancel"].click()
        XCTAssertTrue(app.waitForDisappearance(alert))
        XCTAssertFalse(app.element("operation.title").exists)
    }

    func testShrinkingTheDiskNeedsTheTypedProfileNameAndUnlockResets() {
        launch(screen: "runtime")
        let decrease = app.element("runtime.disk.decrease")
        XCTAssertTrue(decrease.waitForExistence(timeout: 5), "disk stepper not found")
        XCTAssertFalse(decrease.isEnabled, "the disk cannot shrink by default")

        let unlock = app.element("runtime.allowShrink")
        unlock.click()
        XCTAssertTrue(unlock.isOn)
        XCTAssertTrue(decrease.isEnabled, "unlocking allows a smaller disk")
        decrease.click()

        let alert = app.alertDialog
        let apply = app.element("runtime.apply")
        XCTAssertTrue(waitUntil(apply, "label == 'Reset VM & Apply…' AND isEnabled == true"),
                      "a smaller disk recreates the VM; Apply is \(apply.label), enabled \(apply.isEnabled)")
        app.reveal(apply)
        apply.click()
        XCTAssertTrue(alert.waitForExistence(timeout: 5), "shrinking asks for a typed confirmation")
        XCTAssertTrue(alert.staticTexts["Shrink disk of default from 100 GiB to 90 GiB?"].exists)
        app.paste("wrong", into: alert.textFields.firstMatch)
        alert.buttons["Delete Data & Recreate"].click()
        XCTAssertTrue(app.waitForDisappearance(alert))
        XCTAssertFalse(app.element("operation.title").exists, "a wrong name does nothing")

        // Leaving the screen turns the unlock off again.
        app.typeKey("1", modifierFlags: .command)
        XCTAssertTrue(app.waitForWindowTitle("Dashboard"))
        app.menuBars.menuBarItems["Go"].click()
        app.menuBars.menuItems["Runtime Settings"].click()
        XCTAssertTrue(app.element("runtime.allowShrink").waitForExistence(timeout: 5))
        XCTAssertFalse(app.element("runtime.allowShrink").isOn, "the unlock does not survive leaving the screen")
        XCTAssertFalse(app.element("runtime.disk.decrease").isEnabled)

        app.element("runtime.allowShrink").click()
        app.element("runtime.disk.decrease").click()
        XCTAssertTrue(waitUntil(app.element("runtime.apply"), "label == 'Reset VM & Apply…' AND isEnabled == true"))
        app.reveal(app.element("runtime.apply"))
        app.element("runtime.apply").click()
        XCTAssertTrue(alert.waitForExistence(timeout: 5))
        app.paste("default", into: alert.textFields.firstMatch)
        alert.buttons["Delete Data & Recreate"].click()
        let operation = app.element("operation.title")
        XCTAssertTrue(operation.waitForExistence(timeout: 5), "the typed profile name recreates the VM")
        XCTAssertTrue(operation.text.contains("default"), operation.text)
    }

    // MARK: - Containers

    func testCopyKeyValueIsUnavailableWhileTheSecretIsMasked() {
        launch(screen: "containers")
        app.waitForContainer("db").click()
        app.openDetailsTab("Info")
        let secret = app.element("env.value.POSTGRES_PASSWORD")
        XCTAssertTrue(secret.waitForExistence(timeout: 5))

        // Right-click the variable name: the value is selectable text, which has its own text menu.
        app.element("env.key.POSTGRES_PASSWORD").rightClick()
        XCTAssertTrue(app.menuItems["Copy Name"].waitForExistence(timeout: 3))
        XCTAssertFalse(app.menuItems["Copy KEY=VALUE"].exists, "a masked secret cannot be copied with its value")
        app.typeKey(.escape, modifierFlags: [])

        app.element("env.showSecrets").click()
        app.element("env.key.POSTGRES_PASSWORD").rightClick()
        XCTAssertTrue(app.menuItems["Copy KEY=VALUE"].waitForExistence(timeout: 3), "revealed: Copy KEY=VALUE is offered")
        app.typeKey(.escape, modifierFlags: [])
    }

    func testDatabaseRestoreRequiresTheTypedContainerName() throws {
        let dump = try temporaryFile("db-postgres.sql", """
        --
        -- PostgreSQL database cluster dump
        --
        SELECT 1;
        --
        -- PostgreSQL database cluster dump complete
        --

        """)
        launch(screen: "containers", environment: ["COLIMAX_UI_TEST_OPEN_FILE": dump.path])
        let alert = app.alertDialog

        app.waitForContainer("db").rightClick()
        app.menuItems["Restore PostgreSQL…"].click()
        XCTAssertTrue(alert.waitForExistence(timeout: 5), "restoring asks for a typed confirmation")
        XCTAssertTrue(alert.staticTexts["Restore into db?"].exists)
        app.paste("dbx", into: alert.textFields.firstMatch)
        alert.buttons["Restore"].click()
        XCTAssertTrue(app.waitForDisappearance(alert))
        XCTAssertFalse(app.element("flash.message").exists, "a wrong name restores nothing")

        app.containerRow("db").rightClick()
        app.menuItems["Restore PostgreSQL…"].click()
        XCTAssertTrue(alert.waitForExistence(timeout: 5))
        app.paste("db", into: alert.textFields.firstMatch)
        alert.buttons["Restore"].click()
        let flash = app.element("flash.message")
        XCTAssertTrue(flash.waitForExistence(timeout: 10), "the exact name restores the dump")
        XCTAssertTrue(flash.label.contains("db-postgres.sql") || flash.text.contains("db-postgres.sql"), flash.debugDescription)
    }

    func testDatabaseRestorePreflightErrorAppearsBeforeThePrompt() throws {
        let truncated = try temporaryFile("truncated.sql", "--\n-- PostgreSQL database cluster dump\n--\nCREATE TABLE half (\n")
        launch(screen: "containers", environment: ["COLIMAX_UI_TEST_OPEN_FILE": truncated.path])

        app.waitForContainer("db").rightClick()
        app.menuItems["Restore PostgreSQL…"].click()
        let error = app.element("banner.error")
        XCTAssertTrue(error.waitForExistence(timeout: 5), "an incomplete dump is rejected")
        XCTAssertTrue(error.text.contains("Restore cancelled"), error.text)
        XCTAssertFalse(app.alertDialog.exists, "no confirmation prompt for a file that failed the check")
    }

    // MARK: - Images

    func testPullIsDisabledForInvalidReferencesAndArchColumnWarns() {
        launch(screen: "images")
        app.waitForRow("legacy/app:1.0")
        let warnings = app.windows.firstMatch.descendants(matching: .any).matching(identifier: "image.archWarning")
        let found = XCTNSPredicateExpectation(predicate: NSPredicate(format: "count == 1"), object: warnings)
        XCTAssertEqual(XCTWaiter().wait(for: [found], timeout: 5), .completed, "only the amd64 image is flagged")

        app.toolbarButton("Pull").click()
        let reference = app.element("pull.reference")
        XCTAssertTrue(reference.waitForExistence(timeout: 5), "pull sheet did not open")
        let pull = app.element("pull.confirm")
        app.replaceText(in: reference, with: "Not A Valid Ref!!")
        XCTAssertTrue(waitUntil(pull, "isEnabled == false"), "an invalid reference cannot be pulled")
        app.replaceText(in: reference, with: "nginx:1.27")
        XCTAssertTrue(waitUntil(pull, "isEnabled == true"), "a valid reference can be pulled; field: \(reference.text)")
        pull.click()
        let operation = app.element("operation.title")
        XCTAssertTrue(operation.waitForExistence(timeout: 5), "progress shows in the panel at the bottom")
        XCTAssertEqual(operation.text, "Pull nginx:1.27")
    }

    func testScanWithoutScannerShowsInstallInstructions() {
        launch(screen: "images")
        app.waitForRow("nginx:latest").rightClick()
        app.menuItems["Scan for Vulnerabilities…"].click()
        XCTAssertTrue(app.windowText("No scanner installed").waitForExistence(timeout: 5))
        XCTAssertTrue(app.windowText("brew install trivy").exists, "the sheet says how to install Trivy")
        app.windows.firstMatch.sheets.firstMatch.buttons["Close"].click()
    }

    // MARK: - Networks

    func testCreateNetworkFormAndDeleteAndPruneAskFirst() {
        launch(screen: "networks")
        app.waitForRow("app-net")
        app.toolbarButton("Create").click()

        let name = app.element("network.name")
        XCTAssertTrue(name.waitForExistence(timeout: 5), "create network sheet did not open")
        let create = app.element("network.create")
        app.replaceText(in: name, with: "colimax-ui-net")
        app.replaceText(in: app.element("network.subnet"), with: "not-a-cidr")
        XCTAssertTrue(app.element("network.subnetError").waitForExistence(timeout: 3), "an invalid subnet shows an error")
        XCTAssertFalse(create.isEnabled)
        app.replaceText(in: app.element("network.subnet"), with: "172.30.0.0/16")
        app.replaceText(in: app.element("network.gateway"), with: "172.30.0.1")
        XCTAssertTrue(create.isEnabled, "a valid subnet / gateway enables Create")
        create.click()
        app.waitForRow("colimax-ui-net")

        let alert = app.alertDialog
        app.containerRow("colimax-ui-net").rightClick()
        app.menuItems["Delete…"].click()
        XCTAssertTrue(alert.waitForExistence(timeout: 5), "deleting a network asks first")
        XCTAssertTrue(alert.staticTexts["Delete network colimax-ui-net?"].exists)
        alert.buttons["Cancel"].click()
        XCTAssertTrue(app.waitForDisappearance(alert))
        XCTAssertTrue(app.containerRow("colimax-ui-net").exists, "Cancel keeps the network")

        app.toolbarButton("Prune").click()
        XCTAssertTrue(alert.waitForExistence(timeout: 5), "pruning networks asks first")
        XCTAssertTrue(alert.staticTexts["Prune unused networks?"].exists)
        alert.buttons["Cancel"].click()
        XCTAssertTrue(app.waitForDisappearance(alert))
        XCTAssertFalse(app.element("flash.message").exists, "Cancel must not prune")
    }

    // MARK: - Compose

    /// Only Cancel is exercised: confirming would run the real `docker compose` CLI.
    func testRebuildServiceAsksFirst() throws {
        launch(screen: "compose")
        app.waitForRow("shop").click()
        guard app.element("compose.more").waitForExistence(timeout: 5), app.element("compose.more").isEnabled else {
            throw XCTSkip("docker compose CLI not available on this machine")
        }
        // The project's container table lists its containers by name (web, db).
        let web = app.waitForRow("web")
        web.rightClick()
        let rebuild = app.menuItems["Rebuild & Recreate Service…"]
        XCTAssertTrue(rebuild.waitForExistence(timeout: 3))
        guard rebuild.isEnabled else { throw XCTSkip("compose actions disabled on this machine") }
        rebuild.click()

        let alert = app.alertDialog
        XCTAssertTrue(alert.waitForExistence(timeout: 5), "rebuilding a service asks first")
        XCTAssertTrue(alert.staticTexts["Rebuild service web?"].exists)
        alert.buttons["Cancel"].click()
        XCTAssertTrue(app.waitForDisappearance(alert))
        XCTAssertFalse(app.element("operation.title").exists, "Cancel must not run compose")
    }

    // MARK: - Elasticsearch

    func testSnapshotsWithoutPathRepoShowGuidance() {
        launch(screen: "containers", scenario: "elasticsearch")
        app.waitForContainer("search").rightClick()
        app.menuItems["Snapshots…"].click()
        XCTAssertTrue(app.windowText("has no path.repo").waitForExistence(timeout: 10),
                      "a cluster without path.repo explains how to add it")
    }

    // MARK: - Language

    func testVietnameseUIIsTranslated() {
        launch(language: "vi")
        XCTAssertTrue(app.windows.firstMatch.staticTexts["Tổng quan"].waitForExistence(timeout: 5), "sidebar section Overview in Vietnamese")
        XCTAssertTrue(app.windows.firstMatch.staticTexts["Công cụ"].exists, "sidebar section Tools in Vietnamese")
        XCTAssertFalse(app.windows.firstMatch.staticTexts["Overview"].exists, "no English section title left")
    }
}

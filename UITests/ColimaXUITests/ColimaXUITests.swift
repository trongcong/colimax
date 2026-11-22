import XCTest

/// End-to-end checks of the UI safety rails that unit tests cannot see: destructive actions ask
/// first (and Cancel really cancels), and secrets in container environments stay masked.
/// Runs against fixtures (see `UITestFixtures` in the app), never against a real VM.
@MainActor
final class ColimaXUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() async throws {
        continueAfterFailure = false
    }

    /// Launches straight into the screen under test.
    private func launch(screen: String? = nil) {
        app = UITestApp.launch(screen: screen)
    }

    override func tearDown() async throws {
        app?.terminate()
    }

    // MARK: - Destructive confirmations

    func testRemoveContainerCancelKeepsContainer() {
        launch(screen: "containers")
        let row = app.waitForContainer("worker")
        row.rightClick()
        app.menuItems["Remove…"].click()

        let alert = app.alertDialog
        XCTAssertTrue(alert.waitForExistence(timeout: 5), "removing a container must ask first")
        XCTAssertTrue(alert.staticTexts["Remove container worker?"].exists)
        alert.buttons["Cancel"].click()

        XCTAssertTrue(app.waitForDisappearance(alert), "the alert closes")
        XCTAssertTrue(app.containerRow("worker").exists, "Cancel must not remove the container")
    }

    func testRemoveContainerConfirmRemovesIt() {
        launch(screen: "containers")
        let row = app.waitForContainer("worker")
        row.rightClick()
        app.menuItems["Remove…"].click()

        let alert = app.alertDialog
        XCTAssertTrue(alert.waitForExistence(timeout: 5), "remove confirmation did not appear")
        alert.buttons["Remove"].click()

        XCTAssertTrue(app.waitForDisappearance(app.containerRow("worker")), "the removed container leaves the list")
        XCTAssertTrue(app.containerRow("web").exists, "only the chosen container is removed")
    }

    func testStopVMWithRunningContainersAsksFirst() {
        launch()
        let stop = app.buttons["toolbar.vm.stop"]
        XCTAssertTrue(stop.waitForExistence(timeout: 5))
        stop.click()

        let alert = app.alertDialog
        XCTAssertTrue(alert.waitForExistence(timeout: 5), "stopping a VM with running containers must ask first")
        XCTAssertTrue(alert.staticTexts["Stop default?"].exists)
        alert.buttons["Cancel"].click()

        XCTAssertTrue(app.waitForDisappearance(alert), "the alert closes")
        XCTAssertTrue(app.buttons["toolbar.vm.stop"].exists, "Cancel keeps the VM running")
    }

    func testDeleteProfileAsksFirst() {
        launch(screen: "runtime")
        let delete = app.element("runtime.deleteProfile")
        XCTAssertTrue(delete.waitForExistence(timeout: 5), "Delete Profile button not found")

        delete.click()
        let alert = app.alertDialog
        XCTAssertTrue(alert.waitForExistence(timeout: 5), "deleting a profile must ask first")
        XCTAssertTrue(alert.staticTexts["Delete profile default?"].exists)
        alert.buttons["Cancel"].click()
        XCTAssertTrue(app.waitForDisappearance(alert), "the alert closes")
        XCTAssertFalse(app.element("operation.title").exists, "Cancel must not start the delete")

        delete.click()
        XCTAssertTrue(alert.waitForExistence(timeout: 5))
        alert.buttons["Delete"].click()
        let operation = app.element("operation.title")
        XCTAssertTrue(operation.waitForExistence(timeout: 5), "confirming starts the delete")
        XCTAssertEqual(operation.text, "Delete profile default")
    }

    func testDeleteAndPruneVolumesAsk() {
        launch(screen: "volumes")
        let row = app.waitForRow("db-data")

        row.rightClick()
        app.menuItems["Delete…"].click()
        let alert = app.alertDialog
        XCTAssertTrue(alert.waitForExistence(timeout: 5), "deleting a volume must ask first")
        XCTAssertTrue(alert.staticTexts["Delete volume db-data?"].exists)
        alert.buttons["Cancel"].click()
        XCTAssertTrue(app.waitForDisappearance(alert))
        XCTAssertTrue(app.containerRow("db-data").exists, "Cancel keeps the volume")

        app.element("volumes.prune").click()
        XCTAssertTrue(alert.waitForExistence(timeout: 5), "pruning volumes must ask first")
        XCTAssertTrue(alert.staticTexts["Prune unused volumes?"].exists)
        alert.buttons["Cancel"].click()
        XCTAssertTrue(app.waitForDisappearance(alert))
        XCTAssertFalse(app.element("flash.message").exists, "Cancel must not prune")

        app.containerRow("db-data").rightClick()
        app.menuItems["Delete…"].click()
        XCTAssertTrue(alert.waitForExistence(timeout: 5))
        alert.buttons["Delete"].click()
        XCTAssertTrue(app.waitForDisappearance(app.containerRow("db-data")), "confirming deletes the volume")
    }

    func testPruneAllImagesAsksFirst() {
        launch(screen: "images")
        app.waitForRow("nginx:latest")
        let alert = app.alertDialog

        openPruneAll()
        XCTAssertTrue(alert.waitForExistence(timeout: 5), "pruning images must ask first")
        XCTAssertTrue(alert.staticTexts["Prune all unused images?"].exists)
        alert.buttons["Cancel"].click()
        XCTAssertTrue(app.waitForDisappearance(alert))
        XCTAssertFalse(app.element("flash.message").exists, "Cancel must not prune")

        openPruneAll()
        XCTAssertTrue(alert.waitForExistence(timeout: 5))
        alert.buttons["Prune"].click()
        let flash = app.element("flash.message")
        XCTAssertTrue(flash.waitForExistence(timeout: 5), "confirming prunes and reports the freed space")
        XCTAssertTrue(flash.text.contains("Freed") || flash.label.contains("Freed"), flash.debugDescription)
    }

    private func openPruneAll() {
        let menu = app.element("images.prune")
        XCTAssertTrue(menu.waitForExistence(timeout: 5), "Prune menu not found")
        menu.click()
        app.menuItems["Prune All Unused Images…"].click()
    }

    /// Only Cancel is exercised: confirming would run the real `docker compose` CLI.
    func testComposeDownAsksFirst() throws {
        launch(screen: "compose")
        app.waitForRow("shop").click()
        let more = app.element("compose.more")
        XCTAssertTrue(more.waitForExistence(timeout: 5), "project actions menu not found")
        guard more.isEnabled else { throw XCTSkip("docker compose CLI not available on this machine") }

        more.click()
        app.menuItems["Down (remove containers + networks)…"].click()
        let alert = app.alertDialog
        XCTAssertTrue(alert.waitForExistence(timeout: 5), "compose down must ask first")
        XCTAssertTrue(alert.staticTexts["docker compose down shop?"].exists)
        alert.buttons["Cancel"].click()
        XCTAssertTrue(app.waitForDisappearance(alert))
        XCTAssertFalse(app.element("operation.title").exists, "Cancel must not run compose down")
    }

    // MARK: - Secret masking

    func testDatabasePasswordIsMaskedUntilRevealed() {
        let password = "fixture-password-123" // UITestFixtures.databasePassword
        launch(screen: "containers")
        app.waitForContainer("db").click()
        app.openDetailsTab("Info") // the details pane opens on Logs

        let value = app.element("env.value.POSTGRES_PASSWORD")
        XCTAssertTrue(value.waitForExistence(timeout: 5), "env value not found. Window tree:\n\(app.windows.firstMatch.debugDescription.suffix(4000))")
        XCTAssertNotEqual(value.text, password, "secret must be masked by default")
        XCTAssertFalse(app.windows.firstMatch.descendants(matching: .any)
            .matching(NSPredicate(format: "label == %@ OR value == %@", password, password)).firstMatch.exists,
            "the raw secret must not be anywhere on screen")
        XCTAssertEqual(app.element("env.value.POSTGRES_USER").text, "app", "non-secret values are shown")

        app.element("env.showSecrets").click()
        XCTAssertEqual(app.element("env.value.POSTGRES_PASSWORD").text, password, "Show Secrets reveals the value")

        app.element("env.showSecrets").click()
        XCTAssertNotEqual(app.element("env.value.POSTGRES_PASSWORD").text, password, "hiding again masks it")
    }

}

import XCTest
#if SWIFT_PACKAGE
@testable import ColimaX
#endif

final class SetupTests: XCTestCase {
    private func report(brew: Bool = true, colima: Bool = true, docker: Bool = true, compose: Bool = true, plugin: Bool = false) -> PrerequisiteReport {
        PrerequisiteReport(
            brewPath: brew ? "/opt/homebrew/bin/brew" : nil,
            colimaPath: colima ? "/opt/homebrew/bin/colima" : nil,
            dockerPath: docker ? "/opt/homebrew/bin/docker" : nil,
            composeAvailable: compose,
            composePluginDirectory: plugin ? "/opt/homebrew/lib/docker/cli-plugins" : nil
        )
    }

    func testCompleteReportNeedsNothing() {
        let r = report()
        XCTAssertTrue(r.isComplete)
        XCTAssertEqual(r.missingFormulae, [])
        XCTAssertFalse(r.needsComposePluginConfig)
    }

    func testFreshMacMissesEverything() {
        let r = report(brew: false, colima: false, docker: false, compose: false)
        XCTAssertFalse(r.isComplete)
        XCTAssertFalse(r.hasBrew)
        XCTAssertEqual(r.missingFormulae, ["colima", "docker", "docker-compose"])
        XCTAssertFalse(r.needsComposePluginConfig)
    }

    func testInstalledComposePluginNotLoadedNeedsConfigNotReinstall() {
        let r = report(compose: false, plugin: true)
        XCTAssertFalse(r.isComplete)
        XCTAssertEqual(r.missingFormulae, [])
        XCTAssertTrue(r.needsComposePluginConfig)
    }

    func testPluginWithoutDockerCLIInstallsDockerFirst() {
        let r = report(docker: false, compose: false, plugin: true)
        XCTAssertEqual(r.missingFormulae, ["docker"])
        XCTAssertFalse(r.needsComposePluginConfig)
    }

    func testInstallArgumentsOnlyAllowKnownFormulae() {
        XCTAssertEqual(Prerequisites.installArguments(["docker-compose", "colima", "colima", "rm -rf /", "--force"]),
                       ["install", "colima", "docker-compose"])
        XCTAssertEqual(Prerequisites.installArguments([]), ["install"])
    }

    func testHomebrewPrefixesAndPluginDirectory() {
        XCTAssertEqual(Prerequisites.homebrewPrefixes(brewPath: "/opt/homebrew/bin/brew"), ["/opt/homebrew", "/usr/local"])
        XCTAssertEqual(Prerequisites.homebrewPrefixes(brewPath: "/Users/me/brew/bin/brew"), ["/Users/me/brew", "/opt/homebrew", "/usr/local"])
        XCTAssertEqual(Prerequisites.homebrewPrefixes(brewPath: nil), ["/opt/homebrew", "/usr/local"])

        let found = Prerequisites.composePluginDirectory(brewPath: nil) { $0 == "/usr/local/lib/docker/cli-plugins/docker-compose" }
        XCTAssertEqual(found, "/usr/local/lib/docker/cli-plugins")
        XCTAssertNil(Prerequisites.composePluginDirectory(brewPath: nil) { _ in false })
    }

    func testAddingPluginDirectoryKeepsOtherKeysAndDeduplicates() throws {
        let dir = "/opt/homebrew/lib/docker/cli-plugins"
        let original = Data(#"{"currentContext":"colima","auths":{"ghcr.io":{}},"cliPluginsExtraDirs":["/x"]}"#.utf8)
        let updated = try Prerequisites.addingPluginDirectory(dir, to: original)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: updated) as? [String: Any])
        XCTAssertEqual(object["currentContext"] as? String, "colima")
        XCTAssertNotNil(object["auths"] as? [String: Any])
        XCTAssertEqual(object["cliPluginsExtraDirs"] as? [String], ["/x", dir])

        let again = try Prerequisites.addingPluginDirectory(dir, to: updated)
        let object2 = try XCTUnwrap(JSONSerialization.jsonObject(with: again) as? [String: Any])
        XCTAssertEqual(object2["cliPluginsExtraDirs"] as? [String], ["/x", dir])
    }

    func testAddingPluginDirectoryToMissingOrEmptyConfig() throws {
        for input in [nil, Data(), Data("  \n".utf8)] as [Data?] {
            let out = try Prerequisites.addingPluginDirectory("/p", to: input)
            let object = try XCTUnwrap(JSONSerialization.jsonObject(with: out) as? [String: Any])
            XCTAssertEqual(object["cliPluginsExtraDirs"] as? [String], ["/p"])
        }
    }

    func testAddingPluginDirectoryRejectsNonObjectConfig() {
        for bad in ["[1,2]", "not json", "\"text\""] {
            XCTAssertThrowsError(try Prerequisites.addingPluginDirectory("/p", to: Data(bad.utf8)), bad)
        }
    }

    func testConfigureComposePluginWritesBackupAndPrivateFile() throws {
        let dir = TestSupport.tempRoot.appendingPathComponent("colimax-setup-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let config = dir.appendingPathComponent("config.json")
        let original = Data(#"{"currentContext":"colima"}"#.utf8)
        try original.write(to: config)

        try Prerequisites.configureComposePlugin(directory: "/opt/homebrew/lib/docker/cli-plugins", configDirectory: dir)

        XCTAssertEqual(try Data(contentsOf: dir.appendingPathComponent("config.json.colimax-backup")), original)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: config)) as? [String: Any])
        XCTAssertEqual(object["currentContext"] as? String, "colima")
        XCTAssertEqual(object["cliPluginsExtraDirs"] as? [String], ["/opt/homebrew/lib/docker/cli-plugins"])
        let perms = try FileManager.default.attributesOfItem(atPath: config.path)[.posixPermissions] as? Int
        XCTAssertEqual(perms, 0o600)
    }

    func testConfigureComposePluginCreatesMissingDirectory() throws {
        let root = TestSupport.tempRoot.appendingPathComponent("colimax-setup-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let dir = root.appendingPathComponent(".docker")
        try Prerequisites.configureComposePlugin(directory: "/p", configDirectory: dir)
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent("config.json").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("config.json.colimax-backup").path))
    }
}

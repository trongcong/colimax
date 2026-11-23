import XCTest
#if SWIFT_PACKAGE
@testable import ColimaX
#endif

/// Switching from OrbStack / Docker Desktop (G27): report logic, config edits, the live switcher on a
/// temporary docker config directory, and `SetupModel` with a fake switcher.
final class RuntimeSwitchTests: XCTestCase {
    private let socket = "/Users/me/.colima/default/docker.sock"
    private let orbSocket = "/Users/me/.orbstack/run/docker.sock"

    private func report(
        profile: String = "default", current: String? = "orbstack", contexts: [DockerContextInfo]? = nil,
        installed: [InstalledRuntime] = [InstalledRuntime(runtime: .orbStack, appPath: "/Applications/OrbStack.app", isRunning: true)],
        docker: String? = "/opt/homebrew/Cellar/docker/28.0.0/bin/docker", credsStore: String? = nil,
        desktopHelper: Bool = false, plugins: [PluginLink] = [], defaultSocket: String? = nil
    ) -> RuntimeSwitchReport {
        RuntimeSwitchReport(
            profile: profile, profileSocket: socket, installed: installed, dockerCLIPath: docker,
            currentContextName: current,
            contexts: contexts ?? [
                DockerContextInfo(name: "colima", endpoint: "unix://\(socket)"),
                DockerContextInfo(name: "orbstack", endpoint: "unix://\(orbSocket)"),
            ],
            credsStore: credsStore, desktopHelperInstalled: desktopHelper, plugins: plugins, defaultSocketTarget: defaultSocket
        )
    }

    // MARK: Report

    func testOrbStackContextNeedsSwitchToColimaContext() {
        let r = report()
        XCTAssertEqual(r.currentContextOwner, .orbStack)
        XCTAssertFalse(r.currentContextTargetsProfile)
        XCTAssertEqual(r.colimaContext?.name, "colima")
        XCTAssertTrue(r.needsContextSwitch)
        XCTAssertFalse(r.colimaContextMissing)
        XCTAssertTrue(r.needsAttention)
        XCTAssertTrue(r.isRelevant)
    }

    func testContextAlreadyOnProfileNeedsNothing() {
        let r = report(current: "colima")
        XCTAssertTrue(r.currentContextTargetsProfile)
        XCTAssertFalse(r.needsContextSwitch)
        XCTAssertFalse(r.needsAttention)
    }

    func testOtherProfilePrefersConventionalContextName() {
        let contexts = [
            DockerContextInfo(name: "a-custom", endpoint: "unix://\(socket)"),
            DockerContextInfo(name: "colima-dev", endpoint: "unix://\(socket)"),
        ]
        XCTAssertEqual(report(profile: "dev", contexts: contexts).colimaContext?.name, "colima-dev")
        XCTAssertEqual(report(profile: "dev", contexts: [contexts[0]]).colimaContext?.name, "a-custom",
                       "any context on the profile socket works when Colima's own is missing")
    }

    func testDefaultContextFollowsVarRunDockerSock() {
        XCTAssertTrue(report(current: nil, defaultSocket: socket).currentContextTargetsProfile)
        let viaOrb = report(current: "default", defaultSocket: orbSocket)
        XCTAssertEqual(viaOrb.currentContext.name, "default")
        XCTAssertEqual(viaOrb.currentContextOwner, .orbStack)
        XCTAssertEqual(viaOrb.defaultSocketOwner, .orbStack)
        XCTAssertTrue(viaOrb.needsContextSwitch)
    }

    func testMissingColimaContextAsksToStartTheProfile() {
        let r = report(contexts: [DockerContextInfo(name: "orbstack", endpoint: "unix://\(orbSocket)")])
        XCTAssertFalse(r.needsContextSwitch)
        XCTAssertTrue(r.colimaContextMissing)
    }

    func testWithoutDockerCLIThereIsNoContextToSwitch() {
        let r = report(docker: nil)
        XCTAssertFalse(r.needsContextSwitch)
        XCTAssertFalse(r.colimaContextMissing)
    }

    func testPureColimaUserSeesNothing() {
        let r = report(current: "colima", installed: [])
        XCTAssertFalse(r.isRelevant)
        XCTAssertFalse(r.needsAttention)
        XCTAssertFalse(report(current: "default", installed: []).needsAttention,
                       "a context mismatch alone, with no other runtime, is left to Diagnostics")
    }

    func testDesktopCredentialsAndBrokenPlugins() {
        XCTAssertTrue(report(current: "colima", credsStore: "desktop").credentialsBroken)
        XCTAssertFalse(report(current: "colima", credsStore: "desktop", desktopHelper: true).credentialsBroken)
        XCTAssertTrue(report(current: "colima", credsStore: "desktop").needsAttention, "pull fails: worth opening the assistant")
        XCTAssertFalse(report(current: "colima", credsStore: "osxkeychain").usesDesktopCredentials)

        let plugins = [
            PluginLink(path: "/p/docker-compose", destination: "/Applications/Docker.app/x", destinationExists: false),
            PluginLink(path: "/p/docker-buildx", destination: "/opt/homebrew/x", destinationExists: true),
        ]
        let r = report(current: "colima", plugins: plugins)
        XCTAssertEqual(r.brokenPlugins.map(\.name), ["docker-compose"])
        XCTAssertTrue(r.needsAttention)
    }

    func testOwnerOfPaths() {
        XCTAssertEqual(OtherDockerRuntime.owner(ofPath: "/Applications/Docker.app/Contents/Resources/bin/docker"), .dockerDesktop)
        XCTAssertEqual(OtherDockerRuntime.owner(ofPath: "/Users/me/.docker/run/docker.sock"), .dockerDesktop)
        XCTAssertEqual(OtherDockerRuntime.owner(ofPath: "/Users/me/.orbstack/bin/docker"), .orbStack)
        XCTAssertNil(OtherDockerRuntime.owner(ofPath: "/Users/me/.docker/cli-plugins/docker-compose"), "only Docker Desktop's run dir")
        XCTAssertNil(OtherDockerRuntime.owner(ofPath: socket))
        XCTAssertEqual(report(docker: "/Applications/Docker.app/Contents/Resources/bin/docker").cliOwner, .dockerDesktop)
    }

    func testCommandsQuoteTheSocketPath() {
        var r = report()
        r.profileSocket = "/Users/o'neil/.colima/default/docker.sock"
        XCTAssertEqual(r.linkDefaultSocketCommand, #"sudo ln -sf '/Users/o'\''neil/.colima/default/docker.sock' /var/run/docker.sock"#)
        XCTAssertEqual(r.dockerHostExport, #"export DOCKER_HOST='unix:///Users/o'\''neil/.colima/default/docker.sock'"#)
    }

    // MARK: Config edits

    private func json(_ data: Data) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    func testSettingContextKeepsOtherKeys() throws {
        let config = Data(#"{"auths":{"ghcr.io":{}},"currentContext":"orbstack","cliPluginsExtraDirs":["/x"]}"#.utf8)
        let updated = try json(RuntimeSwitch.settingContext("colima", in: config))
        XCTAssertEqual(updated["currentContext"] as? String, "colima")
        XCTAssertNotNil(updated["auths"])
        XCTAssertEqual(updated["cliPluginsExtraDirs"] as? [String], ["/x"])

        XCTAssertNil(try json(RuntimeSwitch.settingContext("default", in: config))["currentContext"], "default removes the key")
        XCTAssertEqual(try json(RuntimeSwitch.settingContext("colima", in: nil))["currentContext"] as? String, "colima")
        XCTAssertThrowsError(try RuntimeSwitch.settingContext("colima", in: Data("[1]".utf8)))
    }

    func testReplacingDesktopCredentials() throws {
        let config = Data(#"{"credsStore":"desktop","credHelpers":{"gcr.io":"gcloud","ghcr.io":"desktop"},"auths":{}}"#.utf8)
        let parsed = RuntimeSwitch.parseConfig(config)
        XCTAssertEqual(parsed.credsStore, "desktop")
        XCTAssertEqual(parsed.desktopRegistries, ["ghcr.io"])

        let updated = try json(RuntimeSwitch.replacingDesktopCredentials(in: config))
        XCTAssertEqual(updated["credsStore"] as? String, "osxkeychain")
        XCTAssertEqual(updated["credHelpers"] as? [String: String], ["gcr.io": "gcloud", "ghcr.io": "osxkeychain"])
        XCTAssertNotNil(updated["auths"])

        let other = try json(RuntimeSwitch.replacingDesktopCredentials(in: Data(#"{"credsStore":"pass"}"#.utf8)))
        XCTAssertEqual(other["credsStore"] as? String, "pass", "only Docker Desktop's helper is replaced")
    }

    // MARK: Live switcher on a temporary docker config

    private func tempDockerConfig() throws -> URL {
        let directory = TestSupport.tempRoot.appendingPathComponent("colimax-test-docker-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory
    }

    private func addContext(_ name: String, endpoint: String, in directory: URL) throws {
        let meta = directory.appendingPathComponent("contexts/meta/\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: meta, withIntermediateDirectories: true)
        try Data(#"{"Name":"\#(name)","Endpoints":{"docker":{"Host":"\#(endpoint)"}}}"#.utf8)
            .write(to: meta.appendingPathComponent("meta.json"))
    }

    func testLiveSwitcherWritesContextWithBackupAndRejectsUnknownContexts() async throws {
        let directory = try tempDockerConfig()
        try addContext("colima", endpoint: "unix://\(socket)", in: directory)
        try addContext("orbstack", endpoint: "unix://\(orbSocket)", in: directory)
        let original = Data(#"{"currentContext":"orbstack","credsStore":"desktop"}"#.utf8)
        try original.write(to: directory.appendingPathComponent("config.json"))
        let switcher = LiveRuntimeSwitcher(configDirectory: directory)

        let before = try await XCTUnwrapAsync(await switcher.inspect(profile: "default", socketPath: socket))
        XCTAssertEqual(before.contexts.map(\.name), ["colima", "orbstack"])
        XCTAssertEqual(before.currentContextOwner, .orbStack)
        // Not `needsContextSwitch`: that also needs a docker CLI on this machine (CI runners have none).
        XCTAssertFalse(before.currentContextTargetsProfile)
        XCTAssertEqual(before.colimaContext?.name, "colima")
        XCTAssertTrue(before.usesDesktopCredentials)

        try await switcher.useContext("colima")
        let config = try json(Data(contentsOf: directory.appendingPathComponent("config.json")))
        XCTAssertEqual(config["currentContext"] as? String, "colima")
        XCTAssertEqual(config["credsStore"] as? String, "desktop", "switching the context changes nothing else")
        XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent(DockerConfigFile.backupName)), original)
        let mode = try FileManager.default.attributesOfItem(atPath: directory.appendingPathComponent("config.json").path)[.posixPermissions] as? Int
        XCTAssertEqual(mode, 0o600)
        XCTAssertEqual(DockerContextReader.current(dockerConfigDir: directory)?.endpoint, "unix://\(socket)")

        do {
            try await switcher.useContext("nope")
            XCTFail("unknown context must throw")
        } catch {
            XCTAssertTrue(error is RuntimeSwitchError)
        }
        try await switcher.useContext("default")
        XCTAssertNil(try json(Data(contentsOf: directory.appendingPathComponent("config.json")))["currentContext"])

        try await switcher.replaceDesktopCredentials()
        XCTAssertEqual(try json(Data(contentsOf: directory.appendingPathComponent("config.json")))["credsStore"] as? String, "osxkeychain")
    }

    func testLiveSwitcherMovesOnlyBrokenLinksInsideCliPlugins() async throws {
        let directory = try tempDockerConfig()
        let plugins = directory.appendingPathComponent("cli-plugins")
        let fm = FileManager.default
        try fm.createDirectory(at: plugins, withIntermediateDirectories: true)
        let real = directory.appendingPathComponent("real-buildx")
        try Data("#!/bin/sh\n".utf8).write(to: real)
        try fm.createSymbolicLink(atPath: plugins.appendingPathComponent("docker-compose").path,
                                  withDestinationPath: "/Applications/Docker.app/Contents/Resources/cli-plugins/docker-compose-colimax-test")
        try fm.createSymbolicLink(atPath: plugins.appendingPathComponent("docker-buildx").path, withDestinationPath: real.path)
        try Data().write(to: plugins.appendingPathComponent("docker-scan"))

        let links = LiveRuntimeSwitcher.pluginLinks(in: plugins)
        XCTAssertEqual(links.map(\.name), ["docker-buildx", "docker-compose"], "regular files are not links")
        XCTAssertEqual(links.filter { !$0.destinationExists }.map(\.name), ["docker-compose"])

        let switcher = LiveRuntimeSwitcher(configDirectory: directory)
        let outside = directory.appendingPathComponent("elsewhere")
        try fm.createSymbolicLink(atPath: outside.path, withDestinationPath: "/nonexistent-colimax-test")
        let moved = try await switcher.moveAside(plugins: [plugins.appendingPathComponent("docker-compose").path, outside.path,
                                                           plugins.appendingPathComponent("docker-buildx").path])
        XCTAssertEqual(moved.count, 1, "paths outside cli-plugins and links that work again are ignored")
        XCTAssertTrue(moved[0].hasSuffix("colimax-backup/cli-plugins/docker-compose"))
        XCTAssertNotNil(try? fm.destinationOfSymbolicLink(atPath: moved[0]), "the link itself is moved, not deleted")
        XCTAssertNil(try? fm.destinationOfSymbolicLink(atPath: plugins.appendingPathComponent("docker-compose").path))
        XCTAssertNotNil(try? fm.destinationOfSymbolicLink(atPath: outside.path))
        XCTAssertEqual(LiveRuntimeSwitcher.pluginLinks(in: plugins).map(\.name), ["docker-buildx"])
    }

    func testSocketTargetKeepsDanglingLinkDestination() throws {
        let directory = try tempDockerConfig()
        let link = directory.appendingPathComponent("docker.sock").path
        try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: orbSocket)
        XCTAssertEqual(LiveRuntimeSwitcher.socketTarget(link), orbSocket, "OrbStack quit: the link still says who owns it")
        XCTAssertNil(LiveRuntimeSwitcher.socketTarget(directory.appendingPathComponent("none").path))

        // A link to a socket that is itself a link (into the runtime's container) reports the first hop.
        let inner = directory.appendingPathComponent("container.sock")
        try Data().write(to: inner)
        let outer = directory.appendingPathComponent("outer.sock").path
        try FileManager.default.createSymbolicLink(atPath: outer, withDestinationPath: link)
        try FileManager.default.removeItem(atPath: link)
        try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: inner.path)
        XCTAssertEqual(LiveRuntimeSwitcher.socketTarget(outer), link)
        XCTAssertEqual(OtherDockerRuntime.owner(ofPath: "/Users/me/Library/Group Containers/HUAQ24HBR6.dev.orbstack/run/docker.sock"), .orbStack)
        XCTAssertEqual(OtherDockerRuntime.owner(ofPath: "/Users/me/Library/Containers/com.docker.docker/Data/docker.raw.sock"), .dockerDesktop)
    }

    func testBundleIdentifiersMatchHomebrewCasks() {
        // `uninstall quit:` of the Homebrew casks orbstack / docker-desktop.
        XCTAssertEqual(OtherDockerRuntime.orbStack.bundleIdentifier, "dev.kdrag0n.MacVirt")
        XCTAssertEqual(OtherDockerRuntime.dockerDesktop.quitBundleIdentifiers, ["com.docker.docker", "com.electron.dockerdesktop"])
        XCTAssertTrue(OtherDockerRuntime.dockerDesktop.resetsContextOnStart)
        XCTAssertFalse(OtherDockerRuntime.orbStack.resetsContextOnStart)
    }

    func testFindToolLooksInRuntimeUserBinDirectories() throws {
        let directory = try tempDockerConfig()
        let bin = directory.appendingPathComponent("bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let tool = bin.appendingPathComponent("colimax-test-tool")
        try Data("#!/bin/sh\n".utf8).write(to: tool)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tool.path)
        XCTAssertEqual(LiveRuntimeSwitcher.findTool("colimax-test-tool", extraDirectories: [bin.path]), tool.path,
                       "Docker Desktop's ~/.docker/bin is not on a GUI app's PATH")
        XCTAssertNil(LiveRuntimeSwitcher.findTool("colimax-test-tool", extraDirectories: []))
        XCTAssertTrue(OtherDockerRuntime.dockerDesktop.userBinDirectory.hasSuffix("/.docker/bin"))
        XCTAssertTrue(OtherDockerRuntime.orbStack.userBinDirectory.hasSuffix("/.orbstack/bin"))
    }

    // MARK: SetupModel

    @MainActor
    private func makeStore(_ switcher: FakeRuntimeSwitcher) -> AppStore {
        let services = AppServices(
            colima: FakeColima(), makeDocker: { _ in FakeDocker() },
            checkPrerequisites: { PrerequisiteReport(composeAvailable: true) },
            installPrerequisites: { _ in AsyncThrowingStream { $0.finish() } },
            watchesColimaDirectory: false,
            runtimeSwitcher: switcher
        )
        let store = AppStore(settings: AppSettings(), services: services)
        store.selectedProfileName = "default"
        addTeardownBlock { @MainActor in
            store.shutdown()
            UserDefaults.standard.removeObject(forKey: SetupModel.previousContextKey)
        }
        return store
    }

    @MainActor
    func testSetupModelSwitchesToColimaAndBack() async throws {
        UserDefaults.standard.removeObject(forKey: SetupModel.previousContextKey)
        let switcher = FakeRuntimeSwitcher.orbStack()
        let store = makeStore(switcher)
        let model = store.setupModel

        await model.checkRuntimesAtLaunch()
        XCTAssertTrue(model.runtimes?.needsContextSwitch == true)
        XCTAssertEqual(model.isPresented, !UserDefaults.standard.bool(forKey: SetupModel.hideAtLaunchKey),
                       "OrbStack owns the CLI: the assistant opens at launch")

        try await model.switchContextToColima()
        XCTAssertTrue(model.runtimes?.currentContextTargetsProfile == true)
        XCTAssertEqual(model.previousContext, "orbstack")
        XCTAssertEqual(UserDefaults.standard.string(forKey: SetupModel.previousContextKey), "orbstack")

        try await model.replaceDesktopCredentials()
        XCTAssertFalse(model.runtimes?.usesDesktopCredentials == true)
        try await model.moveBrokenPlugins()
        XCTAssertEqual(model.runtimes?.brokenPlugins, [])
        let exited = await model.quit(.orbStack)
        XCTAssertTrue(exited)
        XCTAssertEqual(model.runtimes?.runningRuntimes, [])
        XCTAssertFalse(model.runtimes?.needsAttention == true)

        try await model.switchContextBack()
        XCTAssertEqual(model.runtimes?.currentContext.name, "orbstack")
        XCTAssertNil(model.previousContext)
        XCTAssertNil(UserDefaults.standard.string(forKey: SetupModel.previousContextKey))
        XCTAssertEqual(switcher.state.current.calls,
                       ["use colima", "credentials", "move docker-compose", "quit orbStack", "use orbstack"])
        XCTAssertFalse(model.isSwitching)
    }

    @MainActor
    func testInertSwitcherNeverOpensTheAssistant() async {
        let services = AppServices(
            colima: FakeColima(), makeDocker: { _ in FakeDocker() },
            checkPrerequisites: { PrerequisiteReport(composeAvailable: true) },
            installPrerequisites: { _ in AsyncThrowingStream { $0.finish() } },
            watchesColimaDirectory: false
        )
        let store = AppStore(settings: AppSettings(), services: services)
        addTeardownBlock { @MainActor in store.shutdown() }
        await store.setupModel.checkRuntimesAtLaunch()
        XCTAssertNil(store.setupModel.runtimes)
        XCTAssertFalse(store.setupModel.isPresented)
    }
}

private func XCTUnwrapAsync<T>(_ value: @autoclosure () async throws -> T?, file: StaticString = #filePath, line: UInt = #line) async throws -> T {
    let result = try await value()
    return try XCTUnwrap(result, file: file, line: line)
}

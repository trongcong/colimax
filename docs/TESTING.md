# Testing

English · [Tiếng Việt](TESTING.vi.md)

Current results of every test layer are in [FEATURES.md](FEATURES.md#verification). This document explains how to run them and what they cover.

## Strategy

| Layer | How it is tested | Notes |
|---|---|---|
| Pure logic (parsers, validators, Diagnostics, manifests, tar headers, dump scripts) | Unit tests with fixtures | The bulk of the suite. No Colima / Docker needed |
| Processes and sockets (`Shell`, `ProcessExecution`, `DockerClient`) | Unit tests with local processes and sockets | Covers timeouts, cancellation, large output, missing sockets |
| Long-running operations (`OperationCenter.runOperation`) | Unit tests with fake streams | Success, failure, cancellation |
| Stores and screen models (`AppStore`, `RuntimeModel`, `ContainersModel`, …, `BackupScheduler` / `ResourceWatcher` hosts) | Unit tests with `FakeColima` / `FakeDocker` (`StoreTests`) | Reloads, error clearing, events, VM operations, busy keys; no VM needed. `scripts/run-tests.sh` compiles with `-D COLIMAX_UI_TESTING` for the fakes |
| Real Docker Engine API | Conditional integration tests | Run only when the flag is set and the VM responds |
| Real Colima VM / profile | Separate conditional integration tests (`COLIMAX_INTEGRATION_VM=1`) | Create a small `colimax-test-*` profile and delete it afterwards |
| Checklist logic (runtime change confirmations, Diagnostics filter, Storage selection, Setup Assistant, VM stop confirmation, notifications) | Unit tests with fakes (`ChecklistTests.swift`) | Items of the manual checklist that do not need the UI |
| UI: confirmations, forms, sheets, shortcuts, Setup Assistant states, secret masking | XCUITest against fixtures and fixture scenarios (`scripts/ui-tests.sh`, see [UI tests](#ui-tests-xcuitest)) | Needs Xcode + Accessibility permission. 31 tests, about 6.5 minutes. Runs in CI on the `xcode-27` runner as an informational job (no docker CLI there, so `testComposeDownAsksFirst` skips; results uploaded as an artifact on failure) |
| Remaining UI flows | Manual check using the checklist below | System integration, visuals, save dialogs, real VM |

## Running the tests

| Command | Scope | Notes |
|---|---|---|
| `scripts/run-tests.sh` | Unit tests | Builds with `swiftc` (target `arm64-apple-macosx14.0`) against Xcode's XCTest, with a custom runner in `Tests/Runner/main.swift`. SwiftPM not required. Integration tests skip themselves |
| `scripts/run-tests.sh --integration` | Unit + integration | Sets `COLIMAX_INTEGRATION=1`. The profile comes from `COLIMAX_PROFILE` (default `default`). Requires a running Colima VM with the docker runtime |
| `swift test` | Unit (+ integration if the environment variables are set) | Through SwiftPM, target `ColimaXTests` (`@testable import ColimaX`) |

Examples:

```bash
COLIMAX_PROFILE=dev scripts/run-tests.sh --integration
COLIMAX_INTEGRATION_VM=1 scripts/run-tests.sh --integration   # adds the VM/profile lifecycle (a few minutes)
OUT_DIR="$TMPDIR/colimax-tests" scripts/run-tests.sh   # change the build directory (default $TMPDIR/colimax-tests)
```

`scripts/run-tests.sh` excludes `ColimaXApp.swift` (`Sources/ColimaX/App/ColimaXApp.swift`, which contains `@main`) from the build and returns a non-zero exit code if the build fails or any test fails. Temporary test files live under `$TMPDIR` (`TestSupport.tempRoot`).

Some tests skip themselves when the environment does not allow them: `ComposeTests.testDiscoveryPriorityOverrideAndEnv` (cannot create `.env`), `DiagnosticsTests.testPortProbeDetectsListeningSocket` (cannot bind TCP).

## UI tests (XCUITest)

`UITests/` holds an Xcode project, `ColimaXUITests.xcodeproj`, with a single UI-testing bundle target. It does not build the app itself: `scripts/ui-tests.sh` first builds a separate bundle, `build/ColimaX-UITest.app`, compiled with `-D COLIMAX_UI_TESTING` and bundle ID `dev.colimax.ColimaX.uitest` (its own UserDefaults, so the real app's settings are untouched), then runs `xcodebuild test`. The tests launch that bundle with `COLIMAX_UI_TEST_FIXTURES=1`, so it uses `UITestFixtures` (`FakeColima` + `FakeDocker`: a running `default` profile, containers `web`, `db` (compose project `shop`) and `worker`, volume `db-data`, images `nginx:latest`, `postgres:16` and the amd64 image `legacy/app:1.0`, no vulnerability scanner); no Colima VM or Docker is needed and nothing real is deleted.

Launch environment understood by the UI-test build (`UITestApp.launch` sets it):

| Variable | Effect |
|---|---|
| `COLIMAX_UI_TEST_SCREEN` | Screen opened at launch (`Screen` raw value) |
| `COLIMAX_UI_TEST_SCENARIO` | Fixture variant (`UITestScenario`): `vm-stopped`, `slow-op` (VM operations never finish until cancelled), `no-brew`, `missing-tools`, `compose-plugin`, `no-profile`, `other-runtime` (OrbStack running and selected, Docker Desktop's credential helper and a broken plugin link left over; `FakeRuntimeSwitcher`), `elasticsearch` (adds a cluster without `path.repo`), `demo` (a realistic workload for the landing page screenshots, `DemoFixtures`) |
| `COLIMAX_UI_TEST_FOCUS` | Demo container selected on the Containers screen (`DemoFixtures.containerID`, e.g. `db`) |
| `COLIMAX_UI_TEST_DETAIL_TAB` | Tab the container details open on: `Info`, `Logs` (default), `Inspect`, `Exec` |
| `COLIMAX_UI_TEST_OPEN_FILE` | File returned by the open panel (`FilePanels.open`), e.g. a dump to restore |
| `DOCKER_CONFIG` | Docker CLI config directory written by **Configure Plugin** (a temporary directory in the test) |

Covered:

- `ColimaXUITests` (8 tests):
  - destructive confirmations, each checking that Cancel changes nothing and, where safe, that confirming does the action: deleting a container, stopping the VM with running containers, deleting a profile, deleting / pruning volumes, pruning all unused images, `docker compose down` (Cancel only: confirming would run the real compose CLI; skipped when it is not installed);
  - secret masking: `POSTGRES_PASSWORD` of the `db` container is masked until "Show Secrets" is turned on.
- `ChecklistUITests` (18 tests): ⌘1…⌘9 / Go menu / ⌘,; waiting state with the VM stopped; cancelling a long operation; quitting during an operation and without one; Runtime Settings (invalid profile name, CPU change asks to restart, arch change asks to recreate, typed confirmation to shrink the disk and the unlock resetting); Copy KEY=VALUE hidden while masked; database restore typed confirmation and preflight error; Pull button disabled for invalid references and the Arch warning; vulnerability scan without a scanner; create network form and delete / prune confirmations; compose service rebuild confirmation (Cancel only); Elasticsearch without `path.repo`; Vietnamese UI.
- `SetupUITests` (6 tests): every tool installed, no Homebrew, tools missing (exact `brew install` command, fake install, rows refresh), compose plugin not loaded (writes a temporary `DOCKER_CONFIG`), no profile (Start Colima), another runtime (G27: opens at launch, switch context / credentials / plugins / quit each ask first).

Prerequisites: Xcode (not only the Command Line Tools), and on the first run allow the test runner under System Settings → Privacy & Security → Accessibility (and Automation if asked). Run on a logged-in desktop session; the tests take control of the mouse and keyboard.

```bash
scripts/ui-tests.sh            # build the UI-test app and run every UI test
```

Release builds (`scripts/build-app.sh`) never contain the fixtures: they are compiled only with `-D COLIMAX_UI_TESTING`.

## Safe integration tests

`IntegrationTests.swift` runs against real Colima and Docker:

- Skips itself unless `COLIMAX_INTEGRATION=1` is set and the profile's `/_ping` responds.
- Resolves the endpoint the same way as the app: `colima status --json`, falling back to the default socket.
- Every resource it creates is named with the prefix `colimax-test-<id>` and carries the label `dev.colimax.test`; `tearDown` removes the containers, networks, volumes and temporary directories it created.
- Never touches the user's existing containers, volumes or networks.
- May pull these images if missing (images are kept after the tests): `busybox:latest`, `redis:7-alpine`, `mysql:8.4`, `mariadb:11`, `postgres:16-alpine`, `caddy:2-alpine`; the first run takes a few minutes to download them.
- `testComposeLifecycle` needs the docker CLI + compose plugin (skips otherwise). The project is named `colimax-test-<id>`, and `tearDown` runs `compose down`.
- `testLocalProxyRoutesByHost` needs ports 18080 / 18443 free on the Mac (skips if they are busy); the test's proxy and CA volume are named `colimax-test-*` and never touch the user's `colimax-proxy`.
- `testElasticsearchSnapshotRoundTrip` runs only when `COLIMAX_INTEGRATION_ES=1` is also set (the Elasticsearch image is about 1 GB and needs about 1 GB of RAM in the VM).
- Test containers / volumes / networks / images carry the label `dev.colimax.test=<prefix>`. Prunes in tests always filter on exactly this label (`pruneVolumes(all:label:)`, `pruneNetworks(label:)`) and never prune globally.
- `testCleanupStaleHelpersOnlyRemovesTestHelpers` calls `cleanupStaleHelpers(requiredLabel: "dev.colimax.test")`: the app's real helpers (without the test label) are not touched.
- `testPullImageReportsProgress` pulls `busybox:1.36`; the image is removed only if it was not present beforehand. `testStorageReportWithRealDiskUsage` creates a dangling image with `commit` and removes it in `tearDown`.
- `testLocalProxyFollowsTargetRestart` and `testComposeDownWithProxyRouteSucceeds` use ports 18080 / 18443 like the earlier proxy test (skip if busy); the compose test needs the docker CLI + compose plugin.
- `testTrivyScanParsesRealOutput` runs only when `trivy` is on PATH; on first use Trivy downloads its vulnerability database (needs network access; skips if the download fails).
- `VMProfileIntegrationTests` runs only when `COLIMAX_INTEGRATION_VM=1` is also set: it creates a `colimax-test-<id>` profile (1 CPU, 1 GiB RAM, 12 GiB disk), and `tearDown` deletes the profile even if the test fails midway. Other profiles are not touched.

| Test | What it checks |
|---|---|
| `testInfoAndListing` | `/info`, listing containers / images / volumes / networks, `/system/df` |
| `testContainerDetailsExecAndPlatform` | Inspect (running, restart count, OOM, sensitive env), exec with separate exit code, arm64 image architecture |
| `testNetworkConnectDisconnect` | Connect / disconnect a container to a network |
| `testVolumeBackupVerifyRestoreRoundTrip` | Backup → verify manifest → restore into another volume → read the content back; the helper has been cleaned up |
| `testRedisLogicalBackup` | Redis dump, `REDIS` header, matching manifest |
| `testDatabaseBackupFailureLeavesNoFile` | Failed dump (no `pg_dumpall`) → `dumpFailed`, no file or manifest left behind |
| `testCancelledLogStreamClosesQuickly` | Cancelling a follow log stream finishes in under 5 s |
| `testMySQLBackupRestoreRoundTrip`, `testMariaDBBackupRestoreRoundTrip`, `testPostgresBackupRestoreRoundTrip` | Create DB + table → dump (manifest matches) → drop DB → restore (G21) → data is back, no warnings, temporary file in the container removed |
| `testRedisRestoreRoundTrip` | RDB dump → `flushall` → restore (stop / replace RDB / start) → keys are back |
| `testComposeLifecycle` | validate, services, config, up, restart service, logs, down; a broken file → validate reports the error |
| `testLocalProxyRoutesByHost` | Caddy proxy (host network) routes `web.localhost` → a container in the VM, and from the Mac via 127.0.0.1; routes to nonexistent containers are skipped; the proxy does not join user networks; HTTPS generates a root CA |
| `testElasticsearchSnapshotRoundTrip` | Register a repository, create a snapshot, restore as `restored-*` and in overwrite mode, export `.tar` + manifest, delete the snapshot |
| `testSecurityAuditOnRealContainer` | Privileged container + `0.0.0.0` bind + `APP_TOKEN`: `SecurityAudit` reports privileged (critical), the port (info / warning when the VM has its own IP), and the secret variable name; the secret value appears in no result |
| `testPortHeldByHostProcessIsReported` | A real listening socket on the Mac + a stopped container declaring the same port: `PortDiagnostics` reports "process on the Mac"; releasing the port clears the warning |
| `testStorageReportWithRealDiskUsage` | Real `/system/df`: orphaned volumes are listed, mounted volumes are not; an untagged `commit` image is dangling; an exited container appears in the stopped list |
| `testVolumeAndNetworkLifecycleWithScopedPrune` | Create / remove a labeled volume; network with subnet / gateway; label-scoped volume / network prune removes only unused test resources |
| `testPullImageReportsProgress` | Pull with a progress stream, image exists after the pull; invalid references are blocked; pulling a nonexistent image reports an error |
| `testScheduledBackupRunNow` | `ScheduledBackupRunner` (the "Run Now" core): 3 volume backups with keep = 2 leave exactly the 2 newest copies, unrelated files are untouched; Redis by container name produces `.rdb` + manifest; nonexistent container → `containerNotRunning` |
| `testStatsOneShotAndMetricsHistory` | One-shot `client.stats`: memory > 0, CPU within a valid range; write / read `MetricsHistory` |
| `testCleanupStaleHelpersOnlyRemovesTestHelpers` | Removes only `created` helpers carrying the test label; regular containers and running helpers are kept |
| `testLocalProxyFollowsTargetRestart` | Target container restarts after its old IP has been taken → configuration reapplied → the proxy still routes |
| `testComposeDownWithProxyRouteSucceeds` | Proxy routes to a compose service; `compose down` succeeds, the project network is removed, the proxy keeps running; routes to the vanished container are skipped |
| `testTrivyScanParsesRealOutput` | Real Trivy scans `busybox:latest`; `parseTrivy` reads every vulnerability in the real output; `VulnerabilityScanner.scan` works |
| `VMProfileIntegrationTests.testProfileLifecycleAndDiskShrink` | `colimax-test-*` profile: start (Docker responds) → stop → shrink disk 12 → 10 GiB by deleting VM + data and recreating → delete; other profiles unchanged |

## Unit test matrix

Test files live in `Tests/ColimaXTests/`.

| File | Test class (test count) | Coverage |
|---|---|---|
| `ShellTests.swift` | `ShellTests` (14) | `Shell.run` / `Shell.stream` / `ProcessExecution`, `which`, timeout, cancellation, concurrency, large output, `ColimaLog` |
| `DockerClientTests.swift` | `DockerClientTests` (12) | Request line + percent-encoding, `dechunk`, HTTP error mapping, socket errors, safe file transfer, `MultiplexedStreamParser`, `LogDemuxer`, `LineSplitter`, `FileHasher`, label-scoped prune filters |
| `ModelTests.swift` | `ColimaModelTests` (8), `ContainerDetailsTests` (5), `ImageReferenceTests` (3) | `ColimaStatus` + socket fallback, `unixPath`, profile names, `parseConfig`, `VMUsage.parse`, `Format.date`; decoding `ContainerDetails`, sensitive `EnvVar`, health, `ImagePlatform`; `ImageReference.isValid` (PullSheet, scanner) |
| `BackupTests.swift` | `BackupTests` (16) | Manifest + verify, tar headers, pre-checked restore, database detection, dump scripts, dump validation, stale helper selection, exported log 0600 permissions even when overwriting |
| `DiagnosticsTests.swift` | `DiagnosticsTests` (10), `StorageReportTests` (2) | Runtime checks, drift, resources / virtualization, socket permissions, security audit, port conflicts, `PortProbe`, Docker context, image architecture; `StorageReport` |
| `ComposeAndStoreTests.swift` | `ComposeTests` (7), `OperationTests` (4), `StoreDerivedTests` (1) | `ComposeDiscovery`, service / project names, array arguments; `OperationCenter.runOperation` (success / failure / cancellation), `Screen.shortcutOrder`; `ComposeModel.projects` from labels |
| `RestoreTests.swift` | `RestoreTests` (9) | `TarWriter` (checksum, size, unsafe names), Redis config, psql warning filtering, restore scripts, preflight (match / wrong engine / truncated dump) |
| `ScheduleTests.swift` | `ScheduleTests` (7) | Due / retry after failure, file names, validity, Codable, retention leaves unrelated files alone, retention with manifests sharing a timestamp |
| `AlertTests.swift` | `AlertTests` (5) | Sustained threshold breaches, no spamming, hysteresis, memory requires a limit, disk, `MetricsHistory` append / load / prune |
| `ScannerTests.swift` | `ScannerTests` (7) | Parsing Trivy JSON and SARIF, sorting / deduplication, unique IDs, reference validation, CVSS scores |
| `ElasticsearchTests.swift` | `ElasticsearchTests` (7) | Image detection, snapshot names, parsing responses / `path.repo` / snapshots, restore body, errors |
| `TopologyTests.swift` | `TopologyTests` (3) | Network graph, both `depends_on` forms, layers, cycles |
| `ProxyTests.swift` | `ProxyTests` (6) | Route validation, URLs, Caddyfile, upstream selection, `TarReader` |
| `LocalizationTests.swift` | `LocalizationTests` (8) | vi / en string files parse, format specifiers match, ports display as `3307` (not `3.307`) both in code and in every vi string containing a port, language mapping |
| `IntegrationTests.swift` | `IntegrationTests` (25) | See the section above |
| `VMProfileIntegrationTests.swift` | `VMProfileIntegrationTests` (1) | See the section above (requires `COLIMAX_INTEGRATION_VM=1`) |
| `SetupTests.swift` | `SetupTests` (11) | Setup Assistant: missing formulae, compose plugin detection, `brew install` argument allowlist, docker `config.json` merge / backup / 0600 |
| `RuntimeSwitchTests.swift` | `RuntimeSwitchTests` (19) | Switching from OrbStack / Docker Desktop (G27): context / credentials / plugin / `/var/run/docker.sock` report logic, `config.json` edits keep other keys, live switcher on a temporary `DOCKER_CONFIG` (backup, 0600, unknown context rejected, only dangling links inside `cli-plugins` moved, never deleted), `SetupModel` switch / switch back with a fake |
| `ChecklistTests.swift` | `ChecklistLogicTests` (3), `ChecklistStoreTests` (11) | Manual checklist items moved to unit tests: runtime change plan (restart / recreate / typed shrink), Diagnostics filter and order, Storage removes only ticked unused volumes, Setup Assistant at launch / install / cancel, VM stop / restart confirmation only with running containers, compose project added without starting, notifications (container exit, VM, failed schedule, resource alert once) |
| `StoreTests.swift` | `StoreTests` (25) | `AppStore` + per-screen models + `OperationCenter` against `FakeColima` / `FakeDocker`: connect and reload, one failing endpoint, error clearing, events, VM / profile operations, busy keys, log bound, host protocols, UI-test fixtures |
| `TransferFakeTests.swift` | `TransferFakeTests` (10) | Services against `FakeDocker`: volume backup / restore round-trip through helpers, tampered file rejected before Docker, failed download keeps the old file, stale helper cleanup, database dump / failure / restore staging, scheduled backups, proxy Caddyfile before start |
| `TestSupport.swift` | — | Temporary directory under `$TMPDIR` |

Total: 206 tests (180 unit, 26 integration). `scripts/check-strings.sh` checks the string files, leftover Vietnamese strings in code, and missing keys.

## Case categories covered

| Category | Representative tests |
|---|---|
| Happy path | `testRunHappyPath`, `testStreamLines`, `OperationTests.testSuccess`, `testManifestRoundTripAndVerify`, `ContainerDetailsTests.testDecode`, `testParseConfigFixture` |
| Errors | `testNonZeroExit`, `testStreamFailureCarriesMessage`, `testHTTPErrorMapping`, `testFailureSetsError`, `testCorruptManifestAndFutureFormat`, `testMissingFile`, `testDumpValidation` |
| Invalid input | `testWhichRejectsPaths`, `testProfileNameValidation`, `testServiceNameValidation`, `testInvalidServiceRejected`, `testProjectNames`, `testUnixPathParsing`, `testTarValidation`, `testRequestLineAndEscaping` |
| Timeout | `testTimeoutTerminatesProcess` |
| Cancellation | `testCancellationTerminatesProcess`, `testCancelledBeforeStartDoesNotHang`, `testStreamConsumerCancellationStopsProcess`, `testCancellationMarksCancelledNotSucceeded`, integration `testCancelledLogStreamClosesQuickly` |
| Runtime missing | `testNotFound`, `testSocketFallbackWhenStatusMissing`, `DiagnosticsTests.testNoProfile`, `testDatabaseBackupRefusesStoppedContainer` |
| Unusable socket | `testSocketUnavailable`, `testNotASocket`, `testSocketPathTooLong` |
| Permissions | `testSocketPermissionChecks` |
| Empty | `testParseConfigEmpty`, `testDiscoveryEmptyDirectory`, `StorageReportTests.testEmpty`, `testMinimalJSONDecodes`, `testNoManifest` |
| Concurrency | `testConcurrentRuns`, `testLargeOutputDoesNotDeadlock` |
| Data safety and security | `testRestoreVerifiesBeforeTouchingDocker`, `testTamperedFileIsRejected`, `testTruncatedFileIsRejected`, `testFailedDownloadKeepsExistingFileAndLeavesNoPartial`, `testMissingFileFailsBeforeRunning`, `testArgumentsAreNotInterpretedByShell`, `testArgumentsAreArrays`, `testDumpScriptsAreConstantAndKeepSecretsInContainer`, `testSecurityAuditFindingsAndNoSecretLeak`, integration `testDatabaseBackupFailureLeavesNoFile` |

## Not covered automatically

- The UI flows left unchecked in the manual checklist below.
- Real Docker Scout (only the SARIF parser is tested, with fixtures).
- The `BackupScheduler` and `ResourceWatcher` timers themselves (a single run / tick, including notifications, is tested).
- Delivery of notifications by macOS (the app's calls are tested through `AppServices.notify`).

## Manual pre-release checklist

The manual UI pass has been done for 1.0.0. The `[ ]` boxes below are a template for the next release and are not ticked per item.

Run against the `build/ColimaX.app` build, on an Apple Silicon Mac, with at least one Colima profile using the docker runtime. Use dedicated test resources; never operate on real data.

Most of the checklist has moved to automated tests. How to read the items:

- `[x] ~~item~~ → test`: replaced by an automated test that has passed (unit tests run with `scripts/run-tests.sh`; integration tests with `scripts/run-tests.sh --integration`, VM items additionally with `COLIMAX_INTEGRATION_VM=1`).
- UI tests (`scripts/ui-tests.sh`, XCUITest against fixtures) are listed as `UI test…`. A new UI test is listed as `→ UI: test (not run yet)` until it has passed once on a real machine; check such an item by hand meanwhile.
- `[ ] item`: still manual: system integration (menu bar, Dock, Notification Center, login items, keychain, Terminal, browser), visuals (charts, graphs, themes), save dialogs, and anything that needs a real VM.

### Launch and navigation

- [ ] The app opens the main window and the menu bar icon; the icon changes when the VM is running / stopped.
- [x] ~~⌘1…⌘9 open Dashboard, Monitoring, Diagnostics, Containers, Compose, Images, Volumes, Networks, Storage in order; the **Go** menu includes Runtime Settings; ⌘, opens Settings~~ → UI `ChecklistUITests.testShortcutsOpenScreensInSidebarOrder`
- [ ] ⌘R refreshes.
- [x] ~~When the VM is stopped, Docker screens show a waiting state instead of an error~~ → UI `testDockerScreensWaitWhileVMIsStopped`

### Setup Assistant (G26)

Install / configure logic: `SetupTests`. The sheet states are UI tests in `SetupUITests` driven by fixture scenarios; nothing is installed for real.

- [x] ~~Turning off "Show this assistant at launch…" stops the automatic sheet; with every tool installed it does not open by itself~~ → `ChecklistStoreTests.testTurningOffShowAtLaunchKeepsTheAssistantClosed`, `testSetupAssistantStaysClosedWhenAllToolsAreInstalled`; ~~install streams the log, re-checks and refreshes profiles; Cancel installs nothing~~ → `testSetupInstallStreamsLogThenRechecksAndRefreshesProfiles`, `testCancellingSetupInstallMarksCancelledAndInstallsNothing`.
- [x] ~~All tools installed: app menu **Setup Assistant…** shows four green rows and "All tools are installed."~~ → UI `SetupUITests.testAllToolsInstalledShowsGreenRowsAndDoesNotOpenAtLaunch`
- [x] ~~No Homebrew: the sheet opens at launch, shows the official install command with **Copy** and the brew.sh link, and offers no install button~~ → UI `testNoHomebrewShowsTheInstallCommandAndNoInstallButton`
- [x] ~~Homebrew present, tools missing: **Install with Homebrew** asks for confirmation showing the exact `brew install …` command; the log streams in the sheet; afterwards the rows refresh~~ → UI `testMissingToolsInstallAsksWithTheExactCommandThenRefreshes`
- [x] ~~Compose plugin installed but not loaded: **Configure Plugin** asks for confirmation, updates the docker CLI `config.json` (other keys kept, `config.json.colimax-backup` written)~~ → UI `testConfigurePluginUpdatesTheDockerConfigAndKeepsOtherKeys`
- [x] ~~No Colima profile yet: **Start Colima** starts profile `default` and the log streams in the sheet~~ → UI `testNoProfileStartColimaStartsTheDefaultProfile`
- [ ] On a clean Mac (or a fresh macOS VM): a real `brew install colima docker docker-compose` from the assistant, then `docker compose version` works after **Configure Plugin**.

### Switching from OrbStack / Docker Desktop (G27)

Report logic and config edits: `RuntimeSwitchTests`. Sheet flow: UI `SetupUITests.testOtherRuntimeOpensAtLaunchAndEveryChangeAsksFirst` (passes locally).

- [ ] With OrbStack installed and running (context `orbstack`) and a running Colima profile: the assistant opens at launch; **Switch to Colima** then `docker context show` prints `colima` and `docker ps` lists Colima's containers; **Switch Back** restores `orbstack`.
- [ ] **Quit OrbStack** quits it; reopening OrbStack does / does not switch the context back (record which, then adjust the hint text).
- [ ] With Docker Desktop removed but `credsStore: desktop` left in `~/.docker/config.json`: the credentials row is red; **Use macOS Keychain** (installing `docker-credential-helper` first if needed), then `docker pull` of a public image works.
- [ ] A dangling `~/.docker/cli-plugins/docker-compose` link left by Docker Desktop: **Move Aside**, then **Configure Plugin** if offered, then `docker compose version` works.
- [ ] The `sudo ln -sf …` command copied from the `/var/run/docker.sock` row works in Terminal, and Testcontainers / an IDE then reaches Colima.

### Runtime (Dashboard, Runtime Settings, menu bar)

- [x] ~~Start / stop VM, recreate the VM with a smaller disk, delete a profile~~ → `VMProfileIntegrationTests.testProfileLifecycleAndDiskShrink`; ~~invalid profile name~~ → `testProfileNameValidation`; ~~Stop / Restart with containers running asks for confirmation (shows the count); with no running containers it acts immediately~~ → `ChecklistStoreTests.testStopAndRestartAskOnlyWhileContainersRun`, `testStopWithoutRunningContainersActsImmediately`, UI `testStopVMWithRunningContainersAsksFirst`; ~~deleting a profile asks for confirmation~~ → UI `testDeleteProfileAsksFirst`.
- [ ] Start / Stop / Restart buttons in the toolbar, Dashboard and menu bar; sidebar status updates without a manual refresh.
- [x] ~~Quit (⌘Q) during a long operation asks first and cancels it; with no operation it quits at once~~ → UI `testQuitDuringALongOperationAsksFirst`, `testQuitWithoutOperationQuitsAtOnce`
- [ ] Quitting from the menu bar and the Dock, and the VM and containers keep running after quitting.
- [ ] Dashboard keeps refreshing (about every 15 s) while visible and stops sampling while the window is minimized.
- [ ] Dashboard shows CPU / RAM / disk inside the VM and Docker info.
- [x] ~~Changing CPU / RAM while the VM is running asks to confirm a restart. Changing arch / runtime / VM type asks to confirm recreating the VM, with an option to delete data~~ → `ChecklistLogicTests.testRuntimeChangePlanPicksTheRightConfirmation`, UI `testCPUChangeOnRunningVMAsksToRestart`, `testArchChangeAsksToRecreateWithDataOption`
- [x] ~~An invalid or existing profile name is blocked in the form~~ → UI `testInvalidProfileNameIsBlocked`
- [x] ~~Cancelling a long operation (for example starting the VM) asks for confirmation, and the state changes to "Cancelled"~~ → UI `testCancellingALongOperationAsksAndMarksItCancelled`; the cancellation itself: `StoreTests.testCancelOperationMarksCancelled`

### Containers

- [x] ~~Exported log file has 0600 permissions, even when overwriting~~ → `BackupTests.testLogExportPermissionsAfterOverwrite`; ~~database backup creates file + manifest, stopped container is refused~~ → `test{MySQL,MariaDB,Postgres}BackupRestoreRoundTrip`, `testRedisLogicalBackup`, `testDatabaseBackupRefusesStoppedContainer`; ~~secret-like variables are masked and only shown when "Show Secrets" is enabled~~ → UI `testDatabasePasswordIsMaskedUntilRevealed`; ~~removing a container asks for confirmation~~ → UI `testRemoveContainerCancelKeepsContainer`, `testRemoveContainerConfirmRemovesIt`.
- [ ] List, filter, start / stop / restart / pause / unpause; sidebar badge with the number of running containers.
- [ ] Info tab: health, restart count, OOMKilled, exit code, limits, mounts, IP.
- [x] ~~"Copy KEY=VALUE" is unavailable while a sensitive variable is masked~~ → UI `testCopyKeyValueIsUnavailableWhileTheSecretIsMasked`
- [ ] Logs tab: streaming; the export button opens a save dialog.
- [ ] Exec tab runs commands; "Open Terminal" opens a shell in the correct container.
- [ ] The database backup menu opens a save dialog and shows progress.

### Compose

- [x] ~~Projects derived from labels~~ → `StoreDerivedTests.testComposeProjectsFromLabels`; ~~detection of compose file, override, `.env`~~ → `ComposeTests`; ~~up / restart / logs / down / validate / config~~ → `testComposeLifecycle`; ~~adding a project from a folder does not start it~~ → `ChecklistStoreTests.testAddingAComposeProjectFromAFolderDoesNotStartIt`; ~~`down` asks for confirmation~~ → UI `testComposeDownAsksFirst`.
- [ ] The project list renders correctly; the folder picker adds the project.
- [ ] up / down / start / stop / restart / pull buttons.
- [x] ~~Rebuilding a service asks for confirmation~~ → UI `testRebuildServiceAsksFirst`
- [ ] Validate sheet, merged config, logs per project and per service.

### Images, Volumes, Networks

- [x] ~~Pull with progress, invalid reference blocked~~ → `testPullImageReportsProgress`, `ImageReferenceTests`; ~~create / remove / prune volumes, create network with subnet / gateway, prune networks~~ → `testVolumeAndNetworkLifecycleWithScopedPrune`; ~~connect / disconnect~~ → `testNetworkConnectDisconnect`; ~~volume backup / verify / restore, tampered file rejected before touching Docker~~ → `testVolumeBackupVerifyRestoreRoundTrip`, `testTamperedFileIsRejected`, `testRestoreVerifiesBeforeTouchingDocker`; ~~pruning all images asks for confirmation~~ → UI `testPruneAllImagesAsksFirst`; ~~deleting / pruning volumes asks for confirmation~~ → UI `testDeleteAndPruneVolumesAsk`.
- [x] ~~Pull sheet: the Pull button is disabled for an invalid reference; progress appears in the panel at the bottom of the window; the Arch column warns about non-arm64 images~~ → UI `testPullIsDisabledForInvalidReferencesAndArchColumnWarns`
- [ ] Removing an image asks for confirmation.
- [ ] Volumes: create dialog; "Verify Backup" shows the result; restoring a tampered file shows an error.
- [x] ~~Networks: create network form (subnet / gateway validation); remove / prune ask for confirmation~~ → UI `testCreateNetworkFormAndDeleteAndPruneAskFirst`
- [ ] Connect / disconnect from the UI.

### Diagnostics, Monitoring, Storage

- [x] ~~Privileged container / `0.0.0.0` bind reported without exposing secret values~~ → `testSecurityAuditOnRealContainer`; ~~port held by a host process reported~~ → `testPortHeldByHostProcessIsReported`; ~~per-container CPU / RAM stats~~ → `testStatsOneShotAndMetricsHistory`; ~~unused volumes, dangling images, stopped containers~~ → `testStorageReportWithRealDiskUsage`; ~~filter by group, hide OK items~~ → `ChecklistLogicTests.testDiagnosticsGroupFilterHideOKAndOrder`; ~~only ticked volumes are removed~~ → `testStorageCleanupRemovesOnlyTickedUnusedVolumes`.
- [ ] Diagnostics completes, ⇧⌘R reruns it.
- [ ] Monitoring shows a continuously updating CPU / RAM / Net / Block I/O table.
- [ ] Storage shows the groups and build cache; every cleanup action asks for confirmation.

### Advanced backup, tools (P2 / P3)

- [x] ~~Database restore blocks wrong-engine / truncated dumps~~ → `RestoreTests` (preflight), integration round-trips; ~~backup schedule "Run Now" creates file + manifest, retention keeps exactly N copies and deletes no other files~~ → `testScheduledBackupRunNow`; ~~retry after 15 minutes on failure~~ → `ScheduleTests.testDueLogicAndRetryAfterFailure`; ~~a failing schedule (VM stopped) records its error and notifies~~ → `ChecklistStoreTests.testScheduledBackupFailureShowsErrorAndNotifies`; ~~write / read history, alert once until recovery, exactly one notification~~ → `AlertTests`, `testStatsOneShotAndMetricsHistory`, `testResourceAlertNotifiesOnceUntilRecovery`; ~~real Trivy produces a CVE table~~ → `testTrivyScanParsesRealOutput`; ~~target container still reachable after restart, `compose down` of the target project has no network error~~ → `testLocalProxyFollowsTargetRestart`, `testComposeDownWithProxyRouteSucceeds`; ~~Elasticsearch create / restore (copy and overwrite) / delete / export~~ → `testElasticsearchSnapshotRoundTrip` (`COLIMAX_INTEGRATION_ES=1`).
- [x] ~~Database restore: confirmation requires typing the exact container name; preflight errors appear before the prompt~~ → UI `testDatabaseRestoreRequiresTheTypedContainerName`, `testDatabaseRestorePreflightErrorAppearsBeforeThePrompt`
- [ ] Backups: form to create volume / database schedules, "Run Now" button, last run / last error shown.
- [ ] Monitoring → History & Alerts: charts have data after a few minutes.
- [x] ~~Images → Scan: without a scanner, installation instructions are shown~~ → UI `testScanWithoutScannerShowsInstallInstructions`
- [ ] With Trivy, the CVE table can be filtered by severity and "Fix available".
- [x] ~~Elasticsearch container without `path.repo`: Snapshots… shows guidance~~ → UI `testSnapshotsWithoutPathRepoShowGuidance`
- [ ] Topology: network ↔ container graph, hover highlighting; Compose dependencies by layer.
- [ ] Local Domains: Start Proxy, add a domain, open the link in a browser; Trust / Remove Trust CA (admin permission dialog).

### Preferences and system

- [x] ~~Ports display as `3307`, not `3.307`~~ → `LocalizationTests.testIdentifierNumbersAreNotGrouped`, `testVietnamesePortStringsRenderPlainDigits`; ~~shrinking the disk by recreating the VM~~ → `VMProfileIntegrationTests`; ~~cleanup of leftover `dev.colimax.helper` helpers without touching other containers~~ → `testCleanupStaleHelpersOnlyRemovesTestHelpers`, `BackupTests.testStaleHelperSelection`; ~~notifications are sent when the VM finishes starting, a container exits with a non-zero code, a backup schedule fails, a resource threshold is exceeded (and not when turned off)~~ → `ChecklistStoreTests.testVMStartNotifiesWhenEnabled`, `testContainerExitNotifiesOnlyForUnexpectedNonZeroExits`, `testScheduledBackupFailureShowsErrorAndNotifies`, `testResourceAlertNotifiesOnceUntilRecovery`.
- [x] ~~Language: the UI renders in Vietnamese with `-AppleLanguages (vi)`~~ → UI `testVietnameseUIIsTranslated`
- [ ] The English / Tiếng Việt / System picker and Restart Now relaunching in the chosen language.
- [x] ~~Runtime Settings: enable "Unlock a smaller disk for this change", choose a smaller disk → confirmation by typing the profile name; the switch turns off again after leaving the screen~~ → UI `testShrinkingTheDiskNeedsTheTypedProfileNameAndUnlockResets`
- [ ] Light / Dark / System theme applies immediately; hide / show the Dock icon.
- [ ] Launch at login can be turned on / off (`.app` build).
- [ ] macOS shows the notifications (Notification Center, with the app icon).
- [ ] Quit the app during a volume backup and reopen it: the helper is cleaned up after about 10 minutes (when the app runs its automatic cleanup).

## Troubleshooting

**Notification icon is blank on a development machine.** Notification Center remembers the app path it saw when the bundle ID first asked for notification permission. If that was an old build that has since been deleted (or moved), notifications show the generic placeholder even though Dock and Finder show the icon. Users installing a release for the first time are not affected. The same build under a fresh bundle ID (`BUNDLE_ID=dev.colimax.ColimaX.icontest scripts/build-app.sh`) shows the icon. To reset the stale record (needs Full Disk Access for Terminal; back up first):

```bash
DB="$HOME/Library/Group Containers/group.com.apple.usernoted/db2/db"
[ -f "$DB" ] || DB="$(getconf DARWIN_USER_DIR)com.apple.notificationcenter/db2/db"
cp "$DB" ~/Desktop/usernoted-db-backup
sqlite3 "$DB" "select app_id, identifier from app where identifier like 'dev.colimax%';"
sqlite3 "$DB" "delete from app where identifier = 'dev.colimax.ColimaX';"
killall usernoted NotificationCenter
```

Then open `/Applications/ColimaX.app` and allow notifications again. Also unregister stray copies with the same bundle ID: `lsregister -dump | grep -E "path:.*ColimaX.*\.app"`, then `lsregister -u <path>` (the tool lives in `/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/`).

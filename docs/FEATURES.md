English · [Tiếng Việt](FEATURES.vi.md)

# ColimaX — Feature status (single source of truth)

> **All agents (Claude Code, Codex, Cursor…) and developers: read this file before starting work. Update it as soon as a status changes.**
> Do not implement a feature that is already `Implemented` / `Verified` / `In Progress` without reading the existing code first. If you want to redo it, record the reason in the Notes column.

## Status legend

| Status | Meaning | Required conditions |
|---|---|---|
| `Planned` | Agreed to be built, no code yet | Has an ID + priority |
| `In Progress` | Someone is working on it | Record **who/which agent**. Before taking over an item that looks abandoned, check the code and the git history |
| `Implemented` | Code is in the source tree, builds cleanly, has unit tests (where testable) | Build with 0 warnings + tests PASS |
| `Verified` | Ran end-to-end against a real Colima/Docker (integration test or manual run) | Record how it was verified (test name / command) |
| `Verified (service layer)` | The service layer ran for real through integration tests; the UI has not been checked end-to-end | Same as `Verified`; state clearly what has not been checked |
| `Blocked` | Cannot proceed | Record the reason + what is needed to unblock |

Rules:
- `FEATURES.md` (English) is the source of truth. [FEATURES.vi.md](FEATURES.vi.md) is a Vietnamese translation and must be updated in the same change.
- Each feature has exactly **one** row. When the status changes, edit the row in place; do not add a new row.
- The table describes the current state only. Do not record when something was done; that history lives in git and in [CHANGELOG.md](../CHANGELOG.md).
- The **Code** column lists the main files/types so other agents can find them and avoid writing duplicates.
- Priority: `Core` is the product's foundational functionality; P0–P3 follow [AUDIT.md](AUDIT.md) (`G…`: gap ID, `R…`: risk ID).
- The **Release** column records the first version that contains the feature; `—` if not yet in a release.
- `Implemented` items without an integration test in their Notes have not been run end-to-end. How to run each kind of test: [TESTING.md](TESTING.md).

## Runtime

| ID | Feature | Priority | Status | Release | Code | Notes |
|---|---|---|---|---|---|---|
| C1 | Dashboard: VM status, CPU/RAM/Disk inside the VM, Docker info, disk usage | Core | Implemented | 1.0.0 | `DashboardView`, `ColimaService.vmUsage`, `VMUsage` | Samples every 15 s while visible, paused when the window is minimized / hidden / covered (`WindowVisibility`). The three cards use a non-lazy 3 / 2 + 1 / 1-column layout (`overviewCards`); an adaptive `LazyVGrid` hung the main thread in an endless layout pass while the Docker card showed a spinner. Unit: ColimaModelTests.testVMUsageParse |
| C7 | Runtime: start/stop/restart, create/delete profiles, change CPU/RAM/Disk/arch/runtime/VM type/mounts/Rosetta/k3s/nested virtualization | Core | Verified (service layer) | 1.0.0 | `RuntimeSettingsView`, `ColimaService`, `RuntimeConfig`, `RuntimeModel.applyRuntimeConfig` | Shrinking the disk = delete VM + data, then recreate (separate toggle, confirmed by typing the profile name). Integration: VMProfileIntegrationTests (`COLIMAX_INTEGRATION_VM=1`). Unit: ColimaModelTests (profile name, parseConfig) |
| C11 | Realtime updates: Docker `/events` + kqueue on `_lima` + 30 s fallback polling | Core | Implemented | 1.0.0 | `AppStore.connectDocker/reload`, `DirectoryWatcher` | |
| G2 | Resolve the Docker endpoint from `colima status --json` (`docker_socket`), fall back to the default socket (R5) | P0 | Verified | 1.0.0 | `ColimaStatus`, `ColimaService.status/resolveDockerSocket`, `AppStore.resolveEndpoint` | Integration: endpoint resolution + ping in IntegrationTests setUp. Unit: ColimaModelTests |

## Containers

| ID | Feature | Priority | Status | Release | Code | Notes |
|---|---|---|---|---|---|---|
| C2 | Containers: list, start/stop/restart/pause/rm, log streaming, inspect, exec, open in Terminal | Core | Implemented | 1.0.0 | `ContainersView`, `LogsPane`, `DockerAPI.swift`, `TerminalLauncher` | Listing + API: integration testInfoAndListing |
| G6 | Container details: restart count, OOMKilled, exit code, health, resource limits, env (secrets masked), mounts, IP | P1 | Verified (service layer) | 1.0.0 | `ContainerDetails`, `EnvVar`, `ContainerDetailsPane`, health icon in the Status column | Integration: testContainerDetailsExecAndPlatform (decode, exec). Unit: ContainerDetailsTests |
| G7 | Export container logs to a file | P1 | Implemented | 1.0.0 | `LogsPane.export`, `LogExport`, `AtomicFile` | Log file permissions 0600. Unit: BackupTests.testLogExportPermissionsAfterOverwrite |

## Compose

| ID | Feature | Priority | Status | Release | Code | Notes |
|---|---|---|---|---|---|---|
| C6 | Compose: detection via labels, up/down/start/stop/restart/pull | Core | Implemented | 1.0.0 | `ComposeView`, `ComposeModel`, `ComposeService`, `ComposeProject` | Unit: StoreDerivedTests.testComposeProjectsFromLabels, StoreTests |
| G15 | Compose: detect files in a directory + `.env`, validate, view config, logs, restart/rebuild individual services | P1 | Verified (service layer) | 1.0.0 | `ComposeDiscovery`, `ComposeService.ServiceCommand/logs/config/validate`, `ComposeLogsSheet` | Does not start a project automatically when files are detected. Integration: testComposeLifecycle (validate, services, config, up, restart service, logs, down, invalid file). Unit: ComposeTests |

## Images

| ID | Feature | Priority | Status | Release | Code | Notes |
|---|---|---|---|---|---|---|
| C3 | Images: list, pull (with progress), rm, prune, inspect | Core | Verified (service layer) | 1.0.0 | `ImagesView`, `ImagesModel` | Integration: testInfoAndListing, testPullImageReportsProgress. Unit: ImageReferenceTests |
| G11 | Apple Silicon: image architecture, amd64 emulation warning | P1 | Verified (service layer) | 1.0.0 | `ImagePlatform`, `HostPlatform`, `ImageArchDiagnostics`, Arch column (`ImagesView`) | Integration: testContainerDetailsExecAndPlatform (image platform arm64). Unit: DiagnosticsTests.testImageArchWarnings |
| G24 | Image vulnerability scanning (Trivy / Docker Scout) | P3 | Verified (service layer) | 1.0.0 | `ScannerTool`, `VulnerabilityScanner` (VulnerabilityScanner.swift), `VulnerabilityScanSheet`, Scan button (ImagesView) | Only uses Trivy / Docker Scout if already installed; never installs them. Parses Trivy JSON and SARIF. Integration: testTrivyScanParsesRealOutput (skipped if trivy is not installed). Unit: ScannerTests (fixtures) |

## Volumes & Backup

| ID | Feature | Priority | Status | Release | Code | Notes |
|---|---|---|---|---|---|---|
| C4 | Volumes: list, create, rm, prune, inspect, tar backup/restore | Core | Verified (service layer) | 1.0.0 | `VolumesView`, `VolumesModel`, `VolumeBackup` (BackupService.swift) | Integration: testInfoAndListing, testVolumeAndNetworkLifecycleWithScopedPrune, testCleanupStaleHelpersOnlyRemovesTestHelpers |
| G3 | Safe backups: write to a temp file + rename, never swallow write errors (R4) | P0 | Verified | 1.0.0 | `DockerClient.receiveToFile`, `AtomicFile` | Integration: testVolumeBackupVerifyRestoreRoundTrip (atomic download). Unit: DockerClientTests.testFailedDownloadKeepsExistingFileAndLeavesNoPartial |
| G8 | Backup manifest + SHA-256 + verification before restore | P1 | Verified | 1.0.0 | `BackupManifest`, `BackupVerifier`, `TarInspector`, `VolumeBackup` | Integration: testVolumeBackupVerifyRestoreRoundTrip (backup → verify manifest → restore). Unit: BackupTests |
| G9 | Logical database backups: MySQL/MariaDB, PostgreSQL, Redis/Valkey | P1 | Verified (service layer) | 1.0.0 | `DatabaseEngine`, `DatabaseBackup`, `DockerClient.execToFile` | PostgreSQL uses `pg_dumpall --clean --if-exists` so the dump can be restored. Integration: test{MySQL,MariaDB,Postgres}BackupRestoreRoundTrip (MySQL 8.4 / MariaDB 11 / PostgreSQL 16), Redis. Unit: BackupTests |
| G19 | Backup schedules + retention | P2 | Verified (service layer) | 1.0.0 | `BackupSchedule`, `BackupRetention`, `ScheduledBackupRunner` (BackupSchedule.swift), `BackupScheduler`, `BackupsView` | In-app timer (checks every minute), catches up on missed runs when the app opens, retries after 15 minutes on failure. Retention only deletes files matching the name pattern + a manifest matching the source. Database containers are matched by name. Integration: testScheduledBackupRunNow (`ScheduledBackupRunner`). Unit: ScheduleTests |
| G21 | Database dump restore | P2 | Verified (service layer) | 1.0.0 | `DatabaseRestore`, `TarWriter`, `DockerClient.uploadAsTar`, `Confirm.typed`, "Restore …" menu (ContainersView) | Verifies the manifest + dump type + dump completeness before touching Docker; confirmed by typing the container name. SQL: copies the file into the container's /tmp via the archive API, the database client reads it, then the file is deleted. Redis: stop → replace RDB → start (refused when AOF is enabled). Integration: MySQL 8.4 / MariaDB 11 / PostgreSQL 16 / Redis round-trips. Unit: RestoreTests |
| G25 | Elasticsearch snapshots | P3 | Verified (service layer) | 1.0.0 | `ElasticsearchSnapshot`, `ElasticsearchSnapshotSheet`, "Snapshots…" menu (ContainersView) | Elasticsearch / OpenSearch. REST via curl inside the container, parameters passed as argv. Requires `path.repo`. Create / list / delete / restore (defaults to `restored-*`; overwriting requires typing the name) / export the repository as `.tar` + manifest. Integration: testElasticsearchSnapshotRoundTrip (`COLIMAX_INTEGRATION_ES=1`, Elasticsearch 8.15.3). Unit: ElasticsearchTests |

## Networks

| ID | Feature | Priority | Status | Release | Code | Notes |
|---|---|---|---|---|---|---|
| C5 | Networks: list, create, rm, prune, inspect | Core | Verified (service layer) | 1.0.0 | `NetworksView`, `NetworksModel` | Integration: testInfoAndListing, testVolumeAndNetworkLifecycleWithScopedPrune |
| G14 | Connect / disconnect containers to/from networks | P1 | Verified | 1.0.0 | `DockerClient.connect/disconnect` (DockerAPI.swift), `NetworkMembersSheet` | Integration: testNetworkConnectDisconnect |
| G22 | Network topology, compose dependency graph | P3 | Implemented | 1.0.0 | `NetworkTopology`, `ComposeDependencyGraph` (Topology.swift), `TopologyView`, `ComposeService.dependencyGraph` | Read-only. Network ↔ container graph (hover to highlight), layered depends_on graph, cycle reporting. Unit: TopologyTests |
| G23 | Local domains, reverse proxy (Caddy/Traefik), local HTTPS | P3 | Verified (service layer) | 1.0.0 | `LocalProxy`, `ProxyRoute`, `ProxySettings`, `TarReader` (LocalProxy.swift), `ProxyStore` (`store.proxy`), `LocalDomainsView` | Caddy `caddy:2-alpine`, `network_mode: host` inside the VM, binds to 127.0.0.1 only, upstream = container IP (does not join the user's networks). `*.localhost`, no DNS changes. HTTPS via `local_certs`; trusting the CA is an opt-in button (`security add-trusted-cert`, login keychain). Caddy admin via unix socket + reload retry. Integration: testLocalProxyRoutesByHost (inside the VM + from the Mac via 127.0.0.1, root CA), testLocalProxyFollowsTargetRestart, testComposeDownWithProxyRouteSucceeds. Not checked end-to-end: trusting the CA. Unit: ProxyTests |

## Monitoring & Storage

| ID | Feature | Priority | Status | Release | Code | Notes |
|---|---|---|---|---|---|---|
| C8 | Monitoring: per-container CPU/RAM/Net/Block I/O (streaming) | Core | Verified (service layer) | 1.0.0 | `MonitoringView`, `MonitorStore` | 90-sample history kept in memory. Integration: testStatsOneShotAndMetricsHistory |
| G13 | Storage: orphaned volumes, unused images, build cache, cleanup with confirmation | P1 | Verified (service layer) | 1.0.0 | `StorageReport`, `StorageView`, `StorageModel`, `DockerClient.pruneBuildCache/pruneStoppedContainers` | Integration: testStorageReportWithRealDiskUsage. Unit: StorageReportTests |
| G20 | Resource threshold alerts, persisted history | P2 | Verified (service layer) | 1.0.0 | `ResourceAlerts.swift` (`AlertEvaluator`, `MetricsHistory`), `ResourceWatcher` (`store.resources`), `MetricsHistorySheet` (MonitoringView), Preferences | Background sampling every minute (`/stats?stream=0`), 3 days of JSONL stored in Application Support, alerts on container CPU (% of the VM) / RAM (% of its limit) sustained for N minutes + VM disk, 90% hysteresis. Integration: testStatsOneShotAndMetricsHistory. Unit: AlertTests |

## Diagnostics & Security

| ID | Feature | Priority | Status | Release | Code | Notes |
|---|---|---|---|---|---|---|
| G10 | Diagnostics: CLIs, endpoint ping, Docker context, config drift, VZ/virtiofs/Rosetta, resource suggestions | P1 | Implemented | 1.0.0 | `RuntimeDiagnostics`, `DockerContextReader`, `SocketPermissions`, `DiagnosticsModel`, `DiagnosticsView` | Unit: DiagnosticsTests |
| G12 | Security audit: privileged, dangerous capabilities, docker.sock mounts, host namespaces, binding to 0.0.0.0, secrets in env, socket permissions | P1 | Verified (service layer) | 1.0.0 | `SecurityAudit` | Read-only. Integration: testSecurityAuditOnRealContainer. Unit: DiagnosticsTests.testSecurityAuditFindingsAndNoSecretLeak |
| G16 | Port conflict detection | P1 | Verified (service layer) | 1.0.0 | `PortDiagnostics`, `PortProbe` | Integration: testPortHeldByHostProcessIsReported. Unit: DiagnosticsTests.testPortConflicts, testPortProbeDetectsListeningSocket |

## App / UX

| ID | Feature | Priority | Status | Release | Code | Notes |
|---|---|---|---|---|---|---|
| C9 | Preferences: Light/Dark/System theme, Dock icon, login item, auto-start VM, notifications | Core | Implemented | 1.0.0 | `PreferencesView`, `AppSettings`, `LaunchAtLogin`, `Notifier` | Login item and notifications require the `.app` bundle |
| C10 | Menu bar: status, profile picker, start/stop/restart, quick container actions | Core | Implemented | 1.0.0 | `MenuContentView`, `MenuBarIcon` | Stop / Restart asks for confirmation when containers are running (`VMControl`, also toolbar + Dashboard). Icon: CX monogram template glyph; dot = running, ring = operation in progress, faded = stopped |
| G4 | Cancel long-running operations + "Cancelled" state; a process killed by a signal is not treated as success (R6) | P0 | Implemented | 1.0.0 | `OperationCenter.launch/cancelOperation/runOperation`, `OperationPanel`, `AppDelegate.applicationShouldTerminate` | Quitting while an operation runs asks first and cancels it (⌘Q / menu bar / Dock / Restart Now); quitting never stops the VM or containers. Unit: OperationTests |
| G17 | Keyboard shortcuts ⌘1…⌘9 to switch screens | P1 | Implemented | 1.0.0 | `Screen.shortcutOrder` (MainWindow.swift), "Go" menu (ColimaXApp.swift) | Unit: OperationTests.testShortcutOrderHasNineUniqueScreens |
| G18 | Localization (English + Vietnamese) | P2 | Implemented | 1.0.0 | `Resources/{en,vi}.lproj/Localizable.strings`, `AppLanguage` + picker (AppSettings / PreferencesView), `Format.digits`, `scripts/check-strings.sh`, `scripts/build-app.sh` (copies .lproj, `CFBundleLocalizations`) | String literals in code are English (keys); the vi translation has about 700 keys. Defaults to the system language, selectable in Preferences (`AppleLanguages`, requires a restart). Ports / exit codes are displayed without thousands separators (`Format.digits`). Unit: LocalizationTests |
| G26 | Onboarding: check Homebrew / colima / docker CLI / compose plugin, install via `brew install` with confirmation, configure the compose plugin, start the first profile | P1 | Implemented | 1.0.0 | `PrerequisiteReport`, `Prerequisites` (Features/Setup/Prerequisites.swift), `SetupSheet` (Features/Setup/SetupView.swift), `SetupModel.check/install`, "Setup Assistant…" menu | Opens automatically when tools are missing (can be turned off). Does not install Homebrew (needs sudo + downloading a script): shows the command + a Copy button. `brew install` only accepts colima / docker / docker-compose / docker-credential-helper, runs `Process` with an argument array, with log + cancel in the sheet. Compose plugin: adds `cliPluginsExtraDirs` to `~/.docker/config.json` (or `$DOCKER_CONFIG`), keeps other keys, backs up to `config.json.colimax-backup`, writes with 0600. UI: SetupUITests (fake installer). Not run on a clean machine. Unit: SetupTests |
| G27 | Switch from OrbStack / Docker Desktop: detect the other runtime, point the docker CLI context at the selected Colima profile (with undo), replace Docker Desktop's credential helper, move aside broken CLI plugin links, quit the other app, explain `/var/run/docker.sock` | P1 | Implemented | 1.0.0 | `RuntimeSwitchReport`, `RuntimeSwitching` / `LiveRuntimeSwitcher`, `RuntimeSwitch`, `DockerConfigFile` (Features/Setup/RuntimeSwitch.swift), `RuntimeSwitchSection` (Features/Setup/RuntimeSwitchView.swift), `SetupModel.checkRuntimes/switchContextToColima/switchContextBack/replaceDesktopCredentials/moveBrokenPlugins/quit`, `DockerContextReader.all` | Section of the Setup Assistant; opens it at launch when OrbStack / Docker Desktop is installed or still owns the CLI and the CLI does not work with Colima yet (same "show at launch" toggle). Every change asks first. Context: writes `currentContext` in `config.json` (no docker CLI call), only to a context that exists on the profile socket (Colima's `colima` / `colima-<profile>`), keeps other keys, backs up to `config.json.colimax-backup`, 0600; the old context is kept for **Switch Back**. Credentials: `desktop` → `osxkeychain` in `credsStore` / `credHelpers` (can install `docker-credential-helper` via brew). Plugins: dangling links in `cli-plugins` are moved to `colimax-backup/cli-plugins`, never deleted. Quit: `NSRunningApplication.terminate` (warns that its containers stop; its data is kept). `/var/run/docker.sock` (needs sudo, cleared at reboot): only shows `sudo ln -sf …` and `export DOCKER_HOST=…` with Copy. Images and volumes are not moved. Detection uses the bundle IDs `dev.kdrag0n.MacVirt` / `com.docker.docker` (checked against the Homebrew casks' `uninstall quit:`; Quit also stops `com.electron.dockerdesktop`) and path markers (`/.orbstack/`, `/.docker/run/`, app bundles, their containers; `/var/run/docker.sock` is judged by its first link hop). Tools are also looked up in `~/.orbstack/bin` / `~/.docker/bin` (Docker Desktop's default CLI location, not on a GUI app's PATH). A `docker-credential-osxkeychain` shipped by OrbStack / Docker Desktop does not count, since it goes away with the app. Docker Desktop documents that it resets the context to `desktop-linux` on start; OrbStack does not document it, so the hint says "may". Not in vendor docs, so unconfirmed: Docker Desktop writing `credsStore: desktop` and leaving links in `~/.docker/cli-plugins` (both handled generically). Not run against a real OrbStack / Docker Desktop install. UI: SetupUITests.testOtherRuntimeOpensAtLaunchAndEveryChangeAsksFirst (passes locally via `scripts/ui-tests.sh`). Unit: RuntimeSwitchTests |

## Engineering / Quality

| ID | Feature | Priority | Status | Release | Code | Notes |
|---|---|---|---|---|---|---|
| G1 | Blocking I/O kept off the cooperative pool; timeout + cancellation for processes & sockets (R1–R3) | P0 | Implemented | 1.0.0 | `BlockingIO`, `ProcessExecution` (Shell.swift), `SocketHandle`, `DockerClient.connection` | Integration: testCancelledLogStreamClosesQuickly. Unit: ShellTests (timeout, cancel, concurrent, large output) |
| G5 | Performance: incremental-append log viewer, cached formatters, `which` resolved via PATH (R7–R9) | P0 | Implemented | 1.0.0 | `CodeTextView` (append), `Format` (cache), `Shell.which` (PATH) | Unit: ShellTests.testWhichRejectsPaths |
| T1 | XCTest test target (unit + conditional integration) | Core | Implemented | 1.0.0 | `Tests/ColimaXTests`, `Tests/Runner/main.swift`, `scripts/run-tests.sh`, testTarget `ColimaXTests` in `Package.swift` | Integration tests are gated by `COLIMAX_INTEGRATION=1` (set by `--integration`); Elasticsearch and VM tests need `COLIMAX_INTEGRATION_ES=1` / `COLIMAX_INTEGRATION_VM=1` |
| T2 | GitHub Actions CI: build with 0 warnings (`WARNINGS_AS_ERRORS=1`) + unit tests + packaging | Core | Implemented | 1.0.0 | `.github/workflows/ci.yml`, `scripts/dev-build.sh` | Not yet run on GitHub (no repository yet) |
| T3 | Release pipeline: Developer ID signing (timestamped), notarize + staple app & DMG, SHA-256, build provenance attestation, draft GitHub Release; ad-hoc mode without a Developer ID | Core | Implemented | 1.0.0 | `scripts/release.sh`, `scripts/notarize.sh`, `scripts/make-dmg.sh`, `.github/workflows/release.yml`, [RELEASE.md](RELEASE.md) | `build-app.sh` + `make-dmg.sh` run for real (ad-hoc signature). Workflow: without the `SIGN_IDENTITY` secret it builds an ad-hoc DMG (`build-app.sh` + `make-dmg.sh`) and appends install / verification notes to the release; with it, `release.sh` signs and notarizes. Both attest the DMG (`actions/attest@v4`, verify with `gh attestation verify … -R trongcong/colimax`). Neither mode has run on GitHub yet; Developer ID signing / notarization not run (no certificate). DMG: `diskutil image` (APFS, UDZO) on macOS 26+, `hdiutil` (HFS+, UDZO) before; `DMG_TOOL` overrides. diskutil path run for real on macOS 27 |
| T4 | App icon (`Resources/AppIcon.icns`, `CFBundleIconFile`) | Core | Implemented | 1.0.0 | `scripts/make-icon.swift`, `scripts/make-icon.sh`, `scripts/build-app.sh` | Drawn programmatically with CoreGraphics, CX monogram (also the menu bar glyph `MenuBarIcon` and the glyph in `site/`); can be replaced with a designer-made icon |
| T5 | Issue / PR templates, private vulnerability reporting channel | Core | Implemented | 1.0.0 | `.github/ISSUE_TEMPLATE/*`, `.github/PULL_REQUEST_TEMPLATE.md`, `SECURITY.md` | Private vulnerability reporting is enabled when the GitHub repository is created |
| T6 | Service protocols + in-memory fakes: `DockerEngine`, `ColimaControlling`, injected via `AppServices` | Core | Implemented | 1.0.0 | `DockerEngine` (Core/Docker), `ColimaControlling` + `LiveColima` (Core/Colima), `AppServices` (App), `FakeDocker` / `FakeColima` (Testing/Fakes.swift, `-D COLIMAX_UI_TESTING`) | Stores and every service, file / archive transfers included (backup, restore, proxy, Elasticsearch), run without a VM. Unit: StoreTests, TransferFakeTests |
| T7 | `AppStore` split: `OperationCenter` + per-screen models | Core | Implemented | 1.0.0 | `OperationCenter`, `RuntimeModel`, `SetupModel`, `ContainersModel`, `ComposeModel`, `ImagesModel`, `VolumesModel`, `NetworksModel`, `StorageModel`; `DockerContext` / `ProfileContext` | `AppStore` keeps profiles, Docker data, connection / events and navigation. How to add a screen: [ARCHITECTURE.md](ARCHITECTURE.md) section 8. Unit: StoreTests, OperationTests |
| T8 | Narrow host protocols instead of `weak store: AppStore` | Core | Implemented | 1.0.0 | `BackupSchedulerHost`, `ResourceWatcherHost`, `ProxyHost` (AppServices.swift) | `BackupScheduler`, `ResourceWatcher`, `ProxyStore` do not know `AppStore`. Unit: StoreTests (fake hosts) |
| T9 | UI tests (XCUITest): destructive confirmations, secret masking | Core | Verified | 1.0.0 | `UITests/ColimaXUITests.xcodeproj`, `UITests/ColimaXUITests/*`, `scripts/ui-tests.sh`, `UITestFixtures` | Drives `build/ColimaX-UITest.app` (`-D COLIMAX_UI_TESTING`, bundle ID `dev.colimax.ColimaX.uitest`) with `COLIMAX_UI_TEST_FIXTURES=1`: remove container (Cancel keeps it / confirm removes only it), stop VM with running containers asks first, delete profile, delete / prune volumes, prune all images, compose down (Cancel only) ask first, `POSTGRES_PASSWORD` masked until Show Secrets. Verified: `scripts/ui-tests.sh` on the dev machine. CI job `ui-tests` not yet run on GitHub (continue-on-error) |
| T10 | Manual checklist moved to automated tests: unit tests for the logic, XCUITest with fixture scenarios for the UI wiring | Core | Verified | 1.0.0 | `Tests/ColimaXTests/ChecklistTests.swift`, `UITests/ColimaXUITests/{ChecklistUITests,SetupUITests}.swift`, `UITestScenario` / `FakePrerequisites` (Testing/Fakes.swift), `AppServices.notify` / `scannerTools`, `RuntimeChange`, `DiagnosticItem.visible`, `StorageReport.unusedVolumeNames`, `VMControl` confirmer, `FilePanels.open` (`COLIMAX_UI_TEST_OPEN_FILE`) | Verified: `scripts/ui-tests.sh` on the dev machine (ChecklistUITests, SetupUITests); automated items are marked in [TESTING.md](TESTING.md). Still manual: menu bar, Dock, notification delivery, login item, CA trust, Terminal / browser, charts / topology, save dialogs, real `brew install` on a clean Mac |
| T11 | Landing page on GitHub Pages (English + Vietnamese), ready for the `colimax.dev` custom domain | Core | Implemented | 1.0.0 | `site/index.html`, `site/vi/index.html`, `site/style.css`, `site/copy.js`, `site/img/`, `.github/workflows/pages.yml`, `scripts/site-screenshots.sh`, `DemoFixtures` (Testing/DemoFixtures.swift) | Static HTML, no build step, no external requests (system fonts). Hero reproduces the menu bar menu (`MenuContentView`). Screenshots come from the `demo` fixture scenario (made-up projects, moving charts), taken with `scripts/site-screenshots.sh`. Unit: StoreTests.testDemoFixturesHaveMovingStatsAndRealisticData. Checked locally at desktop and phone widths. Deployed by the Pages workflow to `https://trongcong.github.io/colimax/`; custom domain steps in [RELEASE.md](RELEASE.md) section 2.5. Screenshot gallery (`site/gallery.js`): thumbnails, previous / next, arrow keys, swipe; no autoplay; without JavaScript the static layout stays. |
| T12 | One-line install from GitHub Releases | Core | Implemented | 1.0.0 | `scripts/install.sh`, README "Installation" | `curl -fsSL …/scripts/install.sh \| sh`: newest release (pre-releases included) or `COLIMAX_VERSION`, checks macOS 14+ / arm64, downloads the DMG + `.sha256` with curl (not quarantined, so no Open Anyway step), checks SHA-256, when `gh` is installed and signed in runs `gh attestation verify` pinned to `release.yml` and the tag (`--signer-workflow`, `--source-ref` when supported) and stops on failure unless `COLIMAX_ALLOW_UNVERIFIED=1` (SHA-256 alone only catches broken downloads: it comes from the same release), copies the app into `COLIMAX_APP_DIR` (default `/Applications`) via a temporary copy then swap; refuses while ColimaX runs; no sudo. Run for real: 1.0.0-beta.1 into a temporary folder (`COLIMAX_ALLOW_UNVERIFIED=1`), SHA-256 OK, no `com.apple.quarantine` on the app |

## Verification

State of the current code. When a run changes this, edit the line; do not append history.

| Check | Command | Result |
|---|---|---|
| Build | `WARNINGS_AS_ERRORS=1 scripts/dev-build.sh` | 0 warnings |
| Unit tests | `scripts/run-tests.sh` | All pass; integration tests skip without a VM |
| Integration tests | `COLIMAX_INTEGRATION_ES=1 COLIMAX_INTEGRATION_VM=1 scripts/run-tests.sh --integration` (Colima profile `default` running) | All pass, 0 skipped; no `dev.colimax.test` containers, volumes or networks left behind |
| UI tests | `scripts/ui-tests.sh` (needs Xcode + Accessibility permission) | All pass (`ColimaXUITests`, `ChecklistUITests`, `SetupUITests`) |
| Translations | `scripts/check-strings.sh` | OK |
| Packaging | `scripts/build-app.sh && scripts/make-dmg.sh` | Release build, valid ad-hoc signature, DMG + SHA-256 |
| Manual UI pass | Checklist in [TESTING.md](TESTING.md) | Done for 1.0.0; items now covered by UI tests are marked there |
| Not yet run | A green CI run on GitHub, Developer ID signing + notarization, Setup Assistant on a clean Mac | — |

# ColimaX Architecture

English · [Tiếng Việt](ARCHITECTURE.vi.md)

This document describes the architecture of version 1.0.0. Feature status is tracked in [FEATURES.md](FEATURES.md). The engineering review is in [AUDIT.md](AUDIT.md).

## 1. Layers

```
ColimaXApp (@main)
 ├─ Window "main"  → MainWindow (NavigationSplitView, 14 screens)
 ├─ MenuBarExtra   → MenuContentView
 └─ Settings       → PreferencesView
        │  @Environment
        ▼
Views (SwiftUI)                       DiagnosticsModel (dedicated view model for the Diagnostics screen)
        │
        ▼
Stores — @MainActor @Observable
 ├─ AppStore      profiles, Docker data, events / reloads, navigation (composition root)
 │   ├─ operations  OperationCenter: long operation + log, cancel, busy keys, errors, flash
 │   ├─ runtimeModel / setupModel                         (ProfileContext)
 │   ├─ containersModel / composeModel / imagesModel /
 │   │  volumesModel / networksModel / storageModel         (DockerContext)
 │   ├─ scheduler  BackupScheduler: backup schedules (60 s timer)       (BackupSchedulerHost)
 │   ├─ resources  ResourceWatcher: 60 s background sampling, alerts    (ResourceWatcherHost)
 │   └─ proxy      ProxyStore: *.localhost routes, Caddy container      (ProxyHost)
 ├─ AppSettings   UserDefaults (theme, Dock icon, VM auto-start, notifications)
 └─ MonitorStore  per-container stats stream
        │
        ▼
Service protocols (AppServices: .live / fakes)
 ├─ ColimaControlling   LiveColima → ColimaService            (FakeColima)
 └─ DockerEngine        DockerClient                          (FakeDocker)
        │
        ▼
Services — static enums / Sendable structs, no UI state
 ├─ Shell / ProcessExecution   Process + argument array, timeout, cancellation
 ├─ ColimaService              colima list/status/start/stop/delete, colima.yaml, vmUsage
 ├─ DockerClient (+ DockerAPI) HTTP/1.0 over a unix socket: buffered, streaming, file transfer
 ├─ ContainerDetails           container inspect model, EnvVar, ImagePlatform, HostPlatform
 ├─ BackupService              AtomicFile, BackupManifest, BackupVerifier, TarInspector,
 │                             VolumeBackup, DatabaseEngine, DatabaseBackup
 ├─ Diagnostics                RuntimeDiagnostics, ImageArchDiagnostics, SecurityAudit,
 │                             PortDiagnostics, PortProbe, DockerContextReader, StorageReport
 ├─ DatabaseRestore            restore a dump into a container, TarWriter
 ├─ BackupSchedule             schedules + BackupRetention (pure)
 ├─ ResourceAlerts             AlertEvaluator, MetricsHistory (JSONL)
 ├─ VulnerabilityScanner       Trivy / Docker Scout (CLI installed by the user)
 ├─ ElasticsearchSnapshot      snapshot API via curl inside the container
 ├─ Topology                   NetworkTopology, ComposeDependencyGraph
 ├─ LocalProxy                 Caddyfile, proxy container, root CA, TarReader
 ├─ ComposeService             docker compose CLI, ComposeDiscovery
 └─ SystemIntegration          Notifier, LaunchAtLogin, TerminalLauncher, DirectoryWatcher
        │
        ▼
Colima CLI (Process)       Docker Engine API (unix socket, HTTP/1.0)       docker CLI (Compose, Terminal)
```

Dependency rule: View → Store (or screen model) → Service. Services do not import SwiftUI and know nothing about Stores. Pure logic (parsers, validators, check functions) lives in Services so it can be tested directly against fixtures.

Stores never reach Colima or Docker directly: they go through `AppServices` (`colima: any ColimaControlling`, `makeDocker: (socketPath) -> any DockerEngine`, prerequisite check / install, `notify` for user notifications, `scannerTools` for installed vulnerability scanners). `AppServices.live` wires the real CLI and socket; `AppServices.forLaunch()` returns the UI-test fixtures instead when the app is built with `-D COLIMAX_UI_TESTING` and launched with `COLIMAX_UI_TEST_FIXTURES=1`. Every service takes `any DockerEngine`, file and archive transfers included (volume / database backup and restore, scheduled backups, the local proxy, Elasticsearch export), so all of them run against `FakeDocker` in unit tests (`TransferFakeTests`); integration tests still cover the real Docker behavior.

### Source layout

The diagram above groups types by role. On disk, `Sources/ColimaX` is organized by feature; each folder can contain types from more than one layer.

| Folder | Contents | Layer role |
|---|---|---|
| `App/` | `ColimaXApp`, `MainWindow`, `MenuContentView`, `PreferencesView`, `AppStore`, `AppSettings`, `OperationCenter`, `AppServices` (+ `DockerContext`, `ProfileContext`, `…Host` protocols) | Composition root and global state: app entry point, windows and scenes, the shared stores, service injection |
| `Core/` | `Shell`, `BlockingIO`, `Hashing`, `Utilities`, `SystemIntegration` | Infrastructure services shared by all features: process execution, blocking I/O, hashing, formatting, macOS integration |
| `Core/Docker/` | `DockerEngine` (protocol), `DockerClient`, `DockerAPI`, `DockerModels`, `ContainerDetails` | Docker Engine API client and its models |
| `Core/Colima/` | `ColimaControlling` (protocol), `LiveColima`, `ColimaService` | Colima CLI client and models |
| `Testing/` | `Fakes.swift`: `FakeColima`, `FakeDocker`, `FakePrerequisites`, `UITestFixtures`, `UITestScenario` | In-memory fakes, compiled only with `-D COLIMAX_UI_TESTING` (unit tests, UI-test app); never in release builds |
| `UI/` | `Components.swift` | Shared SwiftUI components (`CodeTextView`, `OperationPanel`, …) |
| `Features/<Name>/` | One folder per feature: Dashboard, Runtime, Containers, Compose, Images, Volumes, Networks, Backup, Monitoring, Diagnostics, LocalDomains, Setup | The feature's views, its screen model (`RuntimeModel`, `ContainersModel`, `ComposeModel`, `ImagesModel`, `VolumesModel`, `NetworksModel`, `StorageModel`, `SetupModel`), plus its feature-specific store (e.g. `BackupScheduler`, `MonitorStore`, `ResourceWatcher`, `ProxyStore`) and services (e.g. `BackupService`, `ComposeService`, `LocalProxy`, `Topology`) |

The dependency rule still applies within and across folders: a feature's views depend on stores, stores depend on services, and services (in `Core/` or a feature folder) never depend on stores or SwiftUI. Features use `Core/` and `UI/`; `App/` wires the features together.

## 2. Concurrency

| Mechanism | Where | Notes |
|---|---|---|
| `@MainActor` | All UI state (`AppStore`, `OperationCenter`, screen models, `AppSettings`, `MonitorStore`, `DiagnosticsModel`) | No races on UI state |
| `BlockingIO.run` (`Sources/ColimaX/Core/BlockingIO.swift`) | Socket `recv` / `send`, SHA-256 hashing (`FileHasher`), port probes | Runs on a dedicated concurrent `DispatchQueue`, not `Task.detached`. The cooperative pool has only about one thread per core; a few long-blocking `recv` calls are enough to stall every other async task. `onCancel` unblocks the waiting thread |
| `ProcessExecution` (`Sources/ColimaX/Core/Shell.swift`) | `Shell.run` | Reads stdout / stderr on GCD threads and waits for exit via `terminationHandler`. Default timeout 120 s; colima calls use 15–30 s. Cancelling the Task calls `terminate()`. Error results: `CancellationError` or `ShellError.timedOut` |
| `Shell.stream` | colima start / stop / delete, docker compose | Streams line by line. If the consumer cancels, the process is terminated. A process that exits due to a signal is treated as a failure |
| `SocketHandle` (`Sources/ColimaX/Core/Docker/DockerClient.swift`) | Every Docker request | Cancelling the Task calls `shutdown(fd, SHUT_RDWR)` so a pending `recv` returns immediately instead of waiting for `SO_RCVTIMEO` |
| `AtomicFile` (`Sources/ColimaX/Features/Backup/BackupService.swift`) | Backup manifests, log export | `open(O_CREAT \| O_EXCL, 0600)` on a temporary file in the same directory, `synchronize()`, then `rename(2)` |
| Long-running operations | `OperationCenter.launch` / `cancelOperation` / `runOperation` | One `operationTask` at a time; a Cancel button (with confirmation) in `OperationPanel`; the `OperationState.Status.cancelled` state is distinct from success / failure |

### Real-time updates

- Docker: `GET /events` (container, image, volume, network). Each event marks which data type needs reloading; events are coalesced for 300 ms and then reloaded once. Each type reloads independently, so one failing endpoint does not block the others (`AppStore.reload`).
- If the events stream drops: wait 3 s, run `refreshProfiles`, and reconnect if the VM is still running.
- Colima has no event API: `DirectoryWatcher` (kqueue via `DispatchSource`) watches `~/.colima/_lima` and each instance directory; changes are debounced for 600 ms and then `colima list` runs. Polling `colima list` every 30 s is only a fallback.
- Resource metrics are sampled only while the screen is open: Dashboard every 15 s, paused while the window is minimized, hidden or covered (`colima ssh` reading `/proc`, `df`), Monitoring via the `/stats` stream.

## 3. Docker endpoint

1. When a profile switches to running, `AppStore.connectDocker` calls `resolveEndpoint()`, i.e. `colima status --profile <p> --json`.
2. `ColimaStatus.dockerSocketPath` takes the `docker_socket` field and strips the `unix://` prefix; `ColimaStatus.unixPath` accepts only absolute paths.
3. `ColimaService.resolveDockerSocket` uses that value; if `colima status` fails or returns no socket, it falls back to the convention `$COLIMA_HOME/<profile>/docker.sock` (default `~/.colima`).
4. All clients (`AppStore.docker`, Compose, Terminal, Diagnostics) share `AppStore.socketPath`. Compose and Terminal receive it via `DOCKER_HOST=unix://…`, so they do not depend on the CLI's Docker context. The terminal `docker` CLI does; the Setup Assistant can point its context at the selected profile (G27, `Features/Setup/RuntimeSwitch.swift`).
5. Diagnostics reads `~/.docker/config.json` and `contexts/meta/*/meta.json` (`DockerContextReader`) to report when the CLI's context points elsewhere. This is informational only; nothing is modified.

`DockerClient` uses HTTP/1.0: the daemon does not chunk responses and closes the connection itself, so streams only need to be read until EOF. A fallback `dechunk` is still present. Path segments and query values are always percent-encoded (`DockerClient.escape`).

## 4. Backup pipeline

### Volume (`VolumeBackup`)

```
createHelper: busybox:latest, label dev.colimax.helper, bind <volume>:/volume[:ro], not started
  → GET /containers/{id}/archive?path=/volume
  → receiveToFile: temporary file ".<name>.partial-xxxxxxxx" (0600) in the same directory
                   write chunk by chunk + incremental SHA-256, synchronize()
                   success → replaceItemAt(.usingNewMetadataOnly) or moveItem to the destination
                   failure → delete the temporary file; the existing destination file is untouched
  → remove helper
  → write <file>.manifest.json via AtomicFile
```

Manifest (`BackupManifest`, `format = 1`): `kind` (volume / mysql / mariadb / postgres / redis), `source`, `image`, `createdAt`, `fileName`, `size`, `sha256`, `tool` (`ColimaX <version>`).

Restore runs in order, and every check runs before any Docker call:

1. `BackupVerifier.verify`: if a manifest exists, compare size and SHA-256; reject a corrupt manifest or one whose `format` is newer than the app. Restore is still allowed without a manifest, but the UI states clearly that the file could not be verified.
2. The manifest (if present) must have `kind == volume`.
3. `TarInspector.validateVolumeArchive`: the first tar header must be the `volume/` directory (ustar).
4. Create the volume if missing → writable helper → `PUT /containers/{id}/archive?path=/` → remove helper.

Helpers left behind when the app is killed mid-operation (label `dev.colimax.helper`, state `created`, older than 10 minutes) are removed by `VolumeBackup.cleanupStaleHelpers` on every Docker connection.

### Database (`DatabaseBackup`)

- `DatabaseEngine.detect` identifies the engine from the image repository name: MySQL / Percona, MariaDB, PostgreSQL (postgis, timescaledb), Redis / Valkey / KeyDB.
- The container must be running (`BackupError.containerNotRunning`).
- `POST /containers/{id}/exec` with `sh -c <DatabaseEngine.script>`; the script is a constant.
- `DockerClient.execToFile` demultiplexes the stream: stdout is written to the file (same temporary file + SHA-256 mechanism), stderr is kept in memory up to 16 KB for error reporting.
- Checks: exit code 0, non-empty file, completion marker (`Dump completed` for MySQL / MariaDB, `PostgreSQL database cluster dump complete`, the `REDIS` header for RDB). On failure the file is deleted and an error is reported.
- The manifest is written as for volumes. PostgreSQL uses `pg_dumpall --clean --if-exists` so the dump can be restored into an existing cluster.

### Database restore (`DatabaseRestore`, G21)

1. `preflight` (does not touch Docker): `BackupVerifier.verify`; the manifest (if present) must be from the same engine family (MySQL ↔ MariaDB count as one family); `engine.validate` on the head / tail of the file to reject truncated dumps.
2. The UI asks for confirmation by **typing the container name** (`Confirm.typed`).
3. MySQL / MariaDB / PostgreSQL: `DockerClient.uploadAsTar` wraps the file as a single-entry tar **on the fly** (no temporary tar file) and does `PUT /archive` to `/tmp/colimax-restore.dump`; then execs a constant script (`mysql` / `mariadb` / `psql -f`) whose `trap` deletes the file. Non-blocking psql errors are returned as warnings ("role already exists" is ignored).
4. Redis / Valkey: read `dir`, `dbfilename`, `appendonly` via `CONFIG GET`; refuse when AOF is enabled; stop the container → upload the RDB into `dir` → start (the container is restarted even if the upload fails).

### Backup schedules (`BackupScheduler`, G19)

- Schedules are stored in `UserDefaults` (`backupSchedules`). An in-app timer checks every 60 s and runs due schedules for the running profile sequentially. On failure, the schedule retries after `min(interval, 15 minutes)`.
- Database schedules select the container by **name** (Compose recreating a container changes its ID).
- File names follow `<source>-YYYYMMDD-HHMMSS.<ext>` (UTC). `BackupRetention` only considers files that match the name pattern **and** have a manifest matching the source and kind.

## 5. Background monitoring and alerts (G20)

- `ResourceWatcher` (enabled under Preferences → Background monitoring) calls `GET /containers/{id}/stats?stream=0` every 60 s for running containers (up to 6 in parallel).
- CPU is normalized to a percentage of the whole VM (`cpuPercent / online_cpus`); memory as a percentage of the limit.
- Samples are appended as JSONL to `~/Library/Application Support/ColimaX/metrics/<profile>.jsonl` via `BlockingIO`; pruning to 3 days runs hourly.
- `AlertEvaluator` (pure): alerts when N consecutive samples exceed the threshold, and only once until the value drops below 90% of the threshold. VM disk is measured every 10 minutes via `colima ssh`.

## 6. Local domain proxy (G23)

```
Mac: https://web.localhost:443 ──(Colima port forward 127.0.0.1)──▶ VM 127.0.0.1:443
   ▶ container colimax-proxy (caddy:2-alpine, network_mode: host)
   ▶ reverse_proxy <container IP on its network>:<port>
```

- The Caddyfile is generated from validated routes: `default_bind 127.0.0.1`, `http_port` / `https_port`, `local_certs` (or `auto_https off`). It is written with `uploadAsTar`, followed by `caddy reload`.
- When a target container restarts (`start` event), the configuration is re-applied after 2 s because its IP may have changed.
- The root CA is read from `/data/caddy/pki/authorities/local/root.crt` (volume `colimax-proxy-data`) through the archive API (`TarReader`).

## 7. Diagnostics

`DiagnosticsModel.run` (`Sources/ColimaX/Features/Diagnostics/DiagnosticsView.swift`) gathers all I/O once (`colima status`, `/_ping`, socket `lstat`, Docker context, `colima.yaml`, host CPU / memory, container and image inspect, port probes) into a snapshot. The checks are pure functions that take the snapshot and return `[DiagnosticItem]`:

| Function | Input | Checks |
|---|---|---|
| `RuntimeDiagnostics.check` | `RuntimeSnapshot` | CLI, endpoint, ping, socket permissions, Docker context, configuration drift, resources, VZ / virtiofs / Rosetta, VM disk, app running under Rosetta |
| `ImageArchDiagnostics.check` | images, platforms, containers, Rosetta, VM arch | Images / containers that are not arm64 |
| `SecurityAudit.check` | `[ContainerDetails]`, whether the VM has its own IP | privileged, dangerous capabilities, `docker.sock` mounts, host network / pid / ipc, `unconfined`, ports bound to `0.0.0.0`, env variable names that look like secrets |
| `PortDiagnostics.check` | `[ContainerDetails]`, `isInUse` closure | Duplicate declared ports, ports of stopped containers that are already taken |
| `StorageReport.analyze` | `/system/df`, containers | Data for the Storage screen |

This split allows unit testing with fixtures, without a real Docker. None of these functions modify configuration.

## 8. Testing seams and adding a feature

Every store can run without a VM. The seams:

| Seam | Real implementation | Fake (`Sources/ColimaX/Testing/Fakes.swift`, `-D COLIMAX_UI_TESTING` only) |
|---|---|---|
| `ColimaControlling` | `LiveColima` → `ColimaService` (colima CLI) | `FakeColima`: in-memory profiles, records calls, can fail lifecycle streams |
| `DockerEngine` | `DockerClient` (unix socket) | `FakeDocker`: in-memory containers / images / volumes / networks / inspect details, records mutating calls, emits `/events`, per-endpoint failures; helper containers with volume binds, volume archives, uploads, scripted exec output (`execHandler`), atomic file downloads with SHA-256 |
| `AppServices` | `.live` | `UITestFixtures.services()` (UI-test app), or built by hand in unit tests |
| `DockerContext` / `ProfileContext` | `AppStore` | Any small class; screen models only see these protocols |
| `BackupSchedulerHost` / `ResourceWatcherHost` / `ProxyHost` | `AppStore` | Any small class; the background stores hold a `weak` reference to the protocol, not to `AppStore` |

Unit tests (`Tests/ColimaXTests/StoreTests.swift`) build `AppStore(settings:services:)` with `FakeColima` / `FakeDocker` and check reloads, error clearing, event coalescing, VM operations, busy keys and the screen models. `scripts/run-tests.sh` compiles with `-D COLIMAX_UI_TESTING` so the fakes are available. UI tests (`UITests/`, run by `scripts/ui-tests.sh`) drive a separate app bundle, `build/ColimaX-UITest.app` (bundle ID `dev.colimax.ColimaX.uitest`, so its UserDefaults never touch the real app's), launched with `COLIMAX_UI_TEST_FIXTURES=1` and optionally a fixture scenario (`COLIMAX_UI_TEST_SCENARIO`, see `UITestScenario`); see [TESTING.md](TESTING.md).

### Adding a feature screen

1. Put the pure logic (parsing, validation, request building) in a service under `Features/<Name>/` or `Core/`, with unit tests against fixtures.
2. If the screen needs a new Docker or Colima call, add it to `DockerEngine` / `ColimaControlling`, implement it in `DockerClient` / `LiveColima`, and in `FakeDocker` / `FakeColima`.
3. Add a `@MainActor` screen model `Features/<Name>/<Name>Model.swift` that takes `unowned let context: any DockerContext` (or `ProfileContext`). Run actions through `context.operations` (`perform(key)` for short actions, `launch` + `runOperation` for long ones) so busy state, errors, cancellation and the operation log work the same everywhere. Make it `@Observable` only if it owns state.
4. If the model needs more from the app, extend the narrowest context protocol (and `AppStore`'s conformance) rather than passing `AppStore`.
5. Expose it as a `lazy var <name>Model` on `AppStore`; the view reads `store.<name>Model`.
6. Destructive actions confirm in the view (`Confirm.destructive` / `Confirm.typed`) before calling the model. Give the important controls an `accessibilityIdentifier` and add a UI test against the fixtures when the flow is destructive or shows secrets.
7. Add a unit test with the fakes, update `docs/FEATURES.md` (+ `.vi.md`) and add UI strings to `Resources/vi.lproj`.

## 9. Design decisions

### ADR-1: App Sandbox is not enabled

- **Context:** the app must run `colima`, `limactl` and `docker` installed via Homebrew, and connect to unix sockets in `~/.colima`.
- **Decision:** do not enable App Sandbox; enable Hardened Runtime with no entitlements.
- **Consequences:** the app cannot be distributed through the Mac App Store and runs with the logged-in user's privileges. This is mitigated by input validation, no shell string concatenation, and confirmation of destructive operations (see [SECURITY.md](../SECURITY.md)).

### ADR-2: Custom HTTP/1.0 client over a unix socket

- **Context:** Foundation's `URLSession` does not support unix sockets; using the docker CLI for every operation is slow and depends on the Docker context.
- **Decision:** `DockerClient` is written directly on BSD sockets, using HTTP/1.0 (read until EOF), percent-encoding paths and queries, with `SocketHandle` for cancellation.
- **Consequences:** most features do not need the docker CLI; multiplexed streams (`MultiplexedStreamParser`, `LogDemuxer`) and HTTP errors must be handled in-house. Compose still uses the docker CLI because Compose logic lives in the CLI.

### ADR-3: No external dependencies

- **Decision:** use only Apple frameworks (SwiftUI, Charts, AppKit, Foundation, Observation, CryptoKit, ServiceManagement, UserNotifications).
- **Consequences:** reproducible builds and a small supply-chain surface; in exchange, the HTTP client, a minimal YAML parser for `colima.yaml`, and tar header handling are written in-house.

### ADR-4: Diagnostics are pure, read-only functions

- **Decision:** separate I/O collection (`DiagnosticsModel`) from checks (pure functions in `Diagnostics.swift`); never modify configuration automatically.
- **Consequences:** testable with fixtures; the user stays in control of any change.

### ADR-5: The local domain proxy uses host networking inside the VM

- **Context:** the proxy needs to reach containers on multiple bridge networks. Joining the proxy to a project's network makes `docker compose down` fail with "network has active endpoints".
- **Decision:** the Caddy container uses `network_mode: host` inside the VM, binds only `127.0.0.1`, and uses container IPs as upstreams; DNS is not modified (`*.localhost` is used).
- **Consequences:** user networks are not touched; the configuration must be re-applied when a container IP changes (wired to the `start` event); the proxy's ports may collide with ports published by other containers in the VM.

### ADR-6: External tools are used only when already installed

- **Decision:** CVE scanning uses `trivy` / `docker scout` already present on the machine; the app does not download or install anything.
- **Consequences:** ADR-3 (no dependencies) is preserved; output depends on the tool version, so the parser decodes leniently.

## 10. Technical debt and limitations

| Issue | Impact | Direction |
|---|---|---|
| The socket is resolved only on connect | An endpoint change at runtime requires reconnecting | Already reconnects when the events stream drops |
| Localization (G18) is implemented: code literals are English keys, translations live in `Resources/{en,vi}.lproj/Localizable.strings`, accessed via `String(localized:)` | New strings must be added to both `.lproj` files; untranslated keys fall back to English | `scripts/check-strings.sh` checks key coverage; `LocalizationTests` |
| UI tests (XCUITest) cover destructive confirmations and secret masking against fixtures only, and need Xcode + Accessibility permission to run | Not run in CI yet; other flows are still checked manually | `scripts/ui-tests.sh` before each release; checklist in [TESTING.md](TESTING.md) |
| Integration tests (database backup / restore, Compose, proxy, Elasticsearch, VM lifecycle) need a real Colima VM | Real-machine coverage depends on someone running them; CI runs unit tests only | Re-run `COLIMAX_INTEGRATION_ES=1 COLIMAX_INTEGRATION_VM=1 scripts/run-tests.sh --integration` and the manual checklist in [TESTING.md](TESTING.md) before each release |

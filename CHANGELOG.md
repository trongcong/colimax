# Changelog

English · [Tiếng Việt](CHANGELOG.vi.md)

All notable changes to ColimaX are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html). `G…` / `R…` IDs refer to [docs/AUDIT.md](docs/AUDIT.md).

## [Unreleased]

## [1.0.0-beta.1] - 2026-11-22

First pre-release of **1.0.0**. Ad-hoc signed, not notarized by Apple (see [docs/RELEASE.md](docs/RELEASE.md) §3.6). The final 1.0.0 entry will repeat this list plus any fixes made during the beta.

### Added

#### Setup

- Setup Assistant: checks Homebrew, `colima`, the `docker` CLI and the compose plugin; installs missing tools with `brew install` after confirmation (log and cancel in the sheet); configures `cliPluginsExtraDirs` for a Homebrew compose plugin with a backup of the docker config; starts the first Colima profile. Opens automatically when tools are missing (can be turned off) and from the app menu.

#### Runtime

- VM status and start / stop / restart; profile selection from the toolbar and the menu bar.
- Create / delete profiles; configure CPU, RAM, disk, architecture, container runtime, VM type (vz / qemu / krunkit), mount type (virtiofs / sshfs / 9p), Rosetta, Kubernetes (k3s) and nested virtualization; warns in advance and asks for confirmation when the VM must be recreated.
- Dashboard: actual CPU / RAM / disk usage inside the VM, Docker info, storage usage.
- Docker endpoint resolved from `colima status --json` (`docker_socket`), falling back to the profile's default socket (G2).
- Real-time updates via Docker `/events` and kqueue watching of the Colima directory, with a 30 s fallback poll (C11).

#### Containers

- Filterable list; start / stop / restart / pause / unpause / remove; health icon.
- Container details: restart count, restart policy, OOMKilled, exit code, health and latest probe, memory / CPU / PIDs limits, networks / IPs, mounts, environment variables with sensitive values masked (G6).
- Streaming logs and export to file (G7); inspect JSON; exec; open a shell in Terminal.

#### Compose

- Project discovery via labels; add a project from a folder with its compose file, override and `.env`, without starting it automatically.
- up / down / start / stop / restart / pull; logs; validate; view the merged config; restart and rebuild individual services (G15).

#### Images, Volumes, Networks

- Images: pull with per-layer progress, remove, prune, inspect, architecture column and warning for non-arm64 images (G11).
- Volumes: create, remove, prune, inspect.
- Networks: create (driver, subnet, gateway, internal), remove, prune, inspect, connect / disconnect containers (G14).

#### Backup

- Volume backup to `.tar` with a `<file>.manifest.json` manifest (size, SHA-256); "Verify Backup"; restore verifies the manifest and tar structure before writing (G8).
- Logical database backup through the Docker exec API: MySQL / MariaDB, PostgreSQL, Redis / Valkey / KeyDB; checks the exit code and the dump completion marker (G9).

#### Diagnostics & Security

- Diagnostics screen: colima / docker CLI, endpoint, `/_ping`, Docker context, configuration drift, VZ / virtiofs / Rosetta, resource suggestions, VM disk usage (G10).
- Read-only security audit: privileged mode, dangerous capabilities, `docker.sock` mounts, host network / pid / ipc, `unconfined`, ports bound to `0.0.0.0`, secret-like variable names, socket permissions (G12).
- Detection of duplicate ports and ports held by a process on the host (G16).

#### Monitoring & Storage

- Per-container CPU / RAM / network / block I/O monitoring (C8).
- Storage screen: unused volumes, dangling / unused images, stopped containers, build cache; cleanup with confirmation (G13).

#### Advanced backup

- Restore a database dump into a running container: MySQL / MariaDB / PostgreSQL through the database's own client, Redis / Valkey by replacing the RDB file; checks the manifest, dump type and dump completeness before touching Docker; confirmation by typing the container name (G21).
- PostgreSQL backups use `pg_dumpall --clean --if-exists` so they can be restored into an existing cluster.
- Scheduled backups for volumes and databases, keeping the N most recent copies (only deletes files created by the schedule with a matching manifest), catch-up runs when the app opens, notification on failure; Backups screen (G19).

#### Monitoring

- Background resource sampling every minute, 3-day history, alerts when container CPU / RAM or VM disk stays above a threshold; History & Alerts sheet; configured in Preferences (G20).

#### Tools

- Image vulnerability scanning with an installed Trivy or Docker Scout (G24).
- Elasticsearch / OpenSearch snapshots: create, list, delete, restore (copy or overwrite), export the repository (G25).
- Topology screen: network ↔ container graph and Compose `depends_on` (G22).
- Local Domains screen: Caddy reverse proxy for `*.localhost`, HTTPS via an internal CA, optional CA trust button (G23).

#### App

- Main window with a four-group sidebar (Overview / Docker / Tools / Settings), menu bar icon, Settings window.
- Keyboard shortcuts ⌘1…⌘9 in sidebar order, "Go" menu (G17); ⌘R refreshes; ⇧⌘R reruns Diagnostics.
- Preferences: Light / Dark / System theme, Dock icon, launch at login, auto-start VM, notifications.
- Cancellation of long-running operations with a distinct "Cancelled" state (G4).

#### Engineering

- Blocking I/O (sockets, file hashing, port probes) runs on dedicated GCD queues instead of the cooperative thread pool; timeouts and cancellation for processes and Docker requests (G1).
- Backup files are written to a temporary file in the same directory and then renamed; write errors are reported and no partial file is left behind (G3).
- Incremental append in the log viewer; shared formatters; `Shell.which` searches `PATH` (G5).
- Each kind of Docker data reloads independently; the Exec transcript has a size limit; leftover backup helper containers are cleaned up automatically.
- XCTest suite: unit tests and conditional integration tests; `scripts/run-tests.sh`, `scripts/dev-build.sh`, `scripts/build-app.sh` (T1).

### Security

- No App Sandbox; Hardened Runtime with no entitlements.
- All host commands run with argument arrays, never through a shell; profile / volume / network / compose project / service / image names are validated; Docker API paths and queries are percent-encoded.
- Backup files, manifests and exported logs are created with 0600 permissions.
- Database credentials are used only inside the container and passed through environment variables (`MYSQL_PWD`, `REDISCLI_AUTH`), never through argv or the app.
- Secrets in environment variables are masked in the UI; the security audit lists variable names only, never values.
- Destructive operations require a confirmation dialog.

# Security

English · [Tiếng Việt](SECURITY.vi.md)

This document describes the security model, the measures implemented in the 1.0.0 code, and known limitations. The measures are covered by unit tests. Volume backup / restore, atomic file transfer and database dump / restore (MySQL, MariaDB, PostgreSQL, Redis) are covered by integration tests against a real Colima VM; confirmation dialogs and secret masking are covered by UI tests (see [docs/TESTING.md](docs/TESTING.md)).

## Model and threat model

ColimaX runs with the privileges of the logged-in user and controls the Colima CLI and the Docker Engine over a Unix socket. Anyone who can control the Docker socket has root-equivalent access inside the VM; ColimaX does not extend that access, but it cannot narrow it either.

| Threat | Mitigation |
|---|---|
| Shell injection on the host via profile, service or container names, or paths | `Process` with argument arrays, never `/bin/sh`; names validated with regular expressions; `colima start` arguments taken from a fixed list |
| Path / query injection in Docker API requests | Every path segment and query value is percent-encoded |
| Secret exposure through the UI, audit results, logs or files | Values masked in the UI; the audit records variable names only; database credentials used only inside the container; files written with 0600 |
| Data loss or corruption during backup / restore | Write to a temporary file, then rename; SHA-256 manifest; verification before restore |
| Destructive actions triggered by mistake | Confirmation dialogs |
| Code injection into the running app | Hardened Runtime, no relaxing entitlements |

Out of scope: protection against malware already running as the same user, security inside the user's containers or images, and the security of Colima / Docker themselves.

## Sandbox, Hardened Runtime, permissions

- **App Sandbox is not enabled.** The app must run `colima` / `limactl` / `docker` installed via Homebrew and connect to sockets in `~/.colima`; the sandbox only allows this through temporary-exception entitlements (see ADR-1 in [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md)).
- **Hardened Runtime is enabled** (`codesign --options runtime` in `scripts/build-app.sh`) with **no entitlements**: no `disable-library-validation`, no `allow-jit`, no `get-task-allow`.
- **No root required**, and no privileged helper is installed.
- Access scope: binaries on PATH (Homebrew paths first, then the process PATH), `$COLIMA_HOME` (default `~/.colima`), `~/.docker` (read-only, for Diagnostics), files the user picks through Save / Open panels, and temporary directories.

## Running commands

- Every host command runs through `Process` with an **argument array** (`Shell.run`, `Shell.stream`, `ProcessExecution`). `Shell.which` rejects names containing `/`.
- `colima start` arguments come from a fixed list or are numbers (`RuntimeConfig.startArguments`).
- The Dashboard's `colima ssh` runs a constant script that reads `/proc` and `df` (`ColimaService.vmUsage`).
- `sh -c` runs **only inside containers**:
  - Database dump scripts (`DatabaseEngine.script`) are constants and do not interpolate input (covered by unit tests).
  - The Exec tab runs commands typed by the user, in the container they selected. This is a feature, not a host injection path.
  - Database restore scripts (`DatabaseRestore.script`, `redisConfigScript`) are constants; the dump file is placed at `/tmp/colimax-restore.dump` through the archive API and removed by a `trap` when the script exits.
  - Elasticsearch snapshot requests (`ElasticsearchSnapshot.requestScript`): method / path / body are passed as **argv** (`sh -c <constant script> sh <method> <path> <body>`) and are not interpolated into the script. `curl -k` is used only for `localhost:9200` inside that same container.
- Vulnerability scanning runs a **user-installed** `trivy` / `docker scout` (the app never downloads them), with array arguments and a validated image reference (`VulnerabilityScanner.isValidReference`).
- Trusting the proxy CA runs `security add-trusted-cert -r trustRoot -p ssl -k <login keychain> <file>` only when the user clicks and confirms; macOS prompts for the password itself, and the app never sees it.
- The Open Terminal button (`TerminalLauncher`, `Sources/ColimaX/Core/SystemIntegration.swift`) creates a `.command` file with 0700 permissions in a temporary directory; the container ID must be all hex characters, and paths are single-quoted.

## Input validation and encoding

| Input | Rule | Code |
|---|---|---|
| Profile name | `^[a-zA-Z0-9][a-zA-Z0-9_-]{0,30}$` | `ColimaService.isValidProfileName` |
| Volume name | `^[a-zA-Z0-9][a-zA-Z0-9_.-]*$` | `NameSheet` (`Features/Volumes/VolumesView.swift`) |
| Network name | `^[a-zA-Z0-9][a-zA-Z0-9_.-]*$` | `CreateNetworkSheet` (`Features/Networks/NetworksView.swift`) |
| Subnet / gateway | `^[0-9a-fA-F:.]+/[0-9]{1,3}$` / `^[0-9a-fA-F:.]+$` | `CreateNetworkSheet` |
| Compose project name | `^[a-z0-9][a-z0-9_-]*$` | `ComposeProject.isValidName` |
| Compose service name | `^[a-zA-Z0-9][a-zA-Z0-9_.-]*$`, also checked when taken from labels or `config --services` | `ComposeService.isValidServiceName` |
| Image reference for pull | `^[a-zA-Z0-9][a-zA-Z0-9._/:@-]*$` | `PullSheet` (`Features/Images/ImagesView.swift`) |
| IDs / names in Docker API URLs | Percent-encode path segments and queries | `DockerClient.escape` |
| Local domain name | Each label `^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$`, joined with `.`; only validated strings reach the Caddyfile | `ProxyRoute.isValidSubdomain` |
| Elasticsearch snapshot name | `^[a-z0-9][a-z0-9._-]{0,200}$` | `ElasticsearchSnapshot.isValidName` |
| Tar entry name when copying a file into a container | Single file name `^[A-Za-z0-9][A-Za-z0-9._-]{0,99}$`, no `/`, no `..` | `TarWriter.isValidEntryName` |
| Redis directory / RDB name | `dir` must be absolute with no `..`; `dbfilename` follows the tar entry rule | `DatabaseRestore.parseRedisConfig` |
| Socket path | Only absolute paths from `colima status` are accepted; `sun_path` length is checked | `ColimaStatus.unixPath`, `DockerClient.connect` |

Paths in the Code column are relative to `Sources/ColimaX/`.

## Secrets

- Environment variables with secret-like names (containing `PASSWORD`, `PASSWD`, `SECRET`, `TOKEN`, `APIKEY`, `API_KEY`, `PRIVATE_KEY`, `ACCESS_KEY`, `CREDENTIAL`, `AUTH`, `DSN`, `CONNECTION_STRING`, or ending in `_PASS` / `_PWD` / `_KEY`; excluding `PWD`, `OLDPWD`, `*_FILE`) are **masked in the UI** with a fixed-length string (`EnvVar.isSensitive`, `EnvVar.maskedValue`). Viewing them requires enabling "Show Secrets"; the "Copy KEY=VALUE" menu item for a sensitive variable is only available once that is enabled.
- **The security audit never puts secret values in its results**; it lists variable names only (a unit test checks that values do not appear in `detail` / `recommendation`).
- **Database credentials are used only inside the container**: dump scripts read the password from the container's own environment variables or `*_PASSWORD_FILE` and pass it to the tool via `MYSQL_PWD` / `REDISCLI_AUTH` (environment variables, not argv). Passwords never pass through the app and are never logged. Dump stderr is capped at 16 KB for error reporting.

## Files written by the app

- Backup data (volume tar, database dump): `DockerClient.receiveToFile` writes to a temporary file in the same directory, **created with 0600 permissions**, and moves it to the destination name only after `synchronize()`. Overwriting an existing file uses `replaceItemAt(..., options: .usingNewMetadataOnly)` so the new file keeps 0600. On a mid-transfer error the temporary file is deleted and the existing destination file is left untouched.
- Backup manifests and exported logs are written through `AtomicFile` (`open(O_CREAT | O_EXCL, 0600)` on a temporary file + `rename(2)`), so they also have 0600 permissions.
- Restore always verifies the manifest (size + SHA-256) and the tar structure **before** calling Docker.

## Confirmation of destructive operations

The following operations show a confirmation dialog (`Confirm`) before running:

| Screen | Operation |
|---|---|
| Containers | Remove container (optionally with its anonymous volumes) |
| Images | Remove image (optionally forced), prune |
| Volumes | Remove volume, prune, restore into a volume |
| Networks | Remove network, prune, disconnect a container from a network |
| Compose | `down`, rebuild and recreate a service |
| Storage | Prune build cache, prune dangling / unused images, remove stopped containers, remove selected volumes |
| Runtime Settings | Delete profile (optionally with its data), apply a configuration that requires recreating the VM (optionally deleting data), apply a configuration while the VM is running (restart) |
| Operation bar | Cancel a running long operation |
| Containers | Restore database (**type the exact container name**), restore an Elasticsearch snapshot in overwrite mode (**type the exact container name**), delete snapshot |
| Backups | Delete a schedule (backup files are kept) |
| Local Domains | Remove the proxy container, trust the CA |

Storage only removes the volumes the user ticked; it never silently prunes everything.

## Backup schedules, resource history, proxy

- Backup schedule retention only deletes files that **match the schedule's naming pattern** (`<source>-YYYYMMDD-HHMMSS.<ext>`) **and** have a manifest matching the source and type; other files in the directory are never deleted (`BackupRetention`, covered by unit tests).
- Resource history is stored in `~/Library/Application Support/ColimaX/metrics/<profile>.jsonl` (container names and metrics only, no environment variables or secrets) and kept for 3 days.
- The local domain proxy (`colimax-proxy`) runs with `network_mode: host` **inside the VM** and binds only to `127.0.0.1`; it does not join user networks. The private key of Caddy's internal CA lives in the `colimax-proxy-data` volume: anyone who can read this volume, on a Mac that trusts the CA, can issue certificates that the Mac will accept. Trusting the CA is optional and can be undone with "Remove Trust" or in Keychain Access.

## Diagnostics and security audit

Read-only: inspects containers, runs `lstat` on sockets, reads configuration, and tries `bind()` on `127.0.0.1` to detect ports in use. It **never changes** container, socket or Colima configuration on its own; it only makes recommendations.

## Known limitations

- No App Sandbox: the app has the privileges of the logged-in user.
- Stop / Restart VM (toolbar, Dashboard, menu bar) and stopping a container do not ask for confirmation, even though they stop running containers.
- Secret detection is based on **variable names**; sensitive values stored in variables with ordinary names are not masked.
- Database dumps are plaintext and not encrypted. Users are responsible for protecting where they are stored.
- The `.command` file used to open Terminal stays in the temporary directory and is not deleted automatically.
- There is no automated test yet for file permissions after overwriting an existing backup.
- `scripts/build-app.sh` signs ad-hoc by default (internal use only). Releases must go through `scripts/release.sh`: Developer ID signing with a secure timestamp, notarization and stapling of both the app and the DMG, plus a SHA-256 checksum ([docs/RELEASE.md](docs/RELEASE.md)).
- During restore, the dump file in the container's `/tmp` has 0644 permissions (so images running as a non-root user can still read it); it is deleted as soon as the restore finishes.

## Reporting a vulnerability

Report vulnerabilities **privately** through GitHub: the repository's **Security → Report a vulnerability** tab (GitHub private vulnerability reporting). Do not open a public issue, and do not disclose details before a fix is available.

Please include: the ColimaX version, the macOS version, a description and reproduction steps, and the impact. The maintainer will acknowledge receipt within 7 days and share a plan for the fix; with the reporter's consent, the vulnerability will be credited in the release notes.

Supported versions for security fixes: the latest release.

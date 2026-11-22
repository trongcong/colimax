# Contributing to ColimaX

English · [Tiếng Việt](CONTRIBUTING.vi.md)

These rules apply to human contributors and coding agents alike. Agents should also read [AGENTS.md](AGENTS.md). All participants are expected to follow the [Code of Conduct](CODE_OF_CONDUCT.md).

## License

ColimaX is released under the MIT license ([LICENSE](LICENSE)). Every contribution submitted to this repository is licensed under MIT.

## Workflow

1. **Read [docs/FEATURES.md](docs/FEATURES.md) first.** It is the single source of truth for feature status (Planned / In Progress / Implemented / Verified / Blocked). Search its Code column and `Sources/ColimaX` to avoid duplicating existing work. A Vietnamese translation is kept in [docs/FEATURES.vi.md](docs/FEATURES.vi.md); update both in the same change.
2. **Claim the work:** change the feature's row to `In Progress (<person/agent>)`. For a new feature without an ID, add a row with a new ID and a priority.
3. **Do the work** following the code standards below. Keep changes small and in scope.
4. **Build and test** (required, see below).
5. **Update the docs:** status, Code column and Notes in `docs/FEATURES.md` (current state only, no dates); [CHANGELOG.md](CHANGELOG.md) under `[Unreleased]` (create that section at the top if it does not exist) for user-facing changes; [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md), [SECURITY.md](SECURITY.md) or [docs/TESTING.md](docs/TESTING.md) when you change the design, a security measure or how things are tested.
6. Mark a feature `Verified` only after it has actually run against Colima / Docker (integration test or by hand), and record how it was verified (test name or command).

## Code standards

- **Swift 6 strict concurrency, 0 warnings.** UI state lives on `@MainActor`; blocking I/O goes through `BlockingIO.run`. Do not use `Task.detached` to wait on sockets or pipes.
- **Never run commands by concatenating strings into a shell.** Use `Shell.run` / `Shell.stream` with an argument array. User-supplied arguments must pass a validator; Docker API paths and queries use `DockerClient.escape`.
- **Destructive actions require confirmation** via `Confirm.destructive` or `Confirm.ask`.
- **Do not create duplicate services, models or views.** Extend the existing types.
- Pure logic (parsers, validators, checks) belongs in services so it can be unit tested with fixtures. Views contain no business logic.
- Files holding user data (backups, logs, manifests) are written with `AtomicFile` or a temp-file-plus-rename, with permissions 0600.
- Never write secret values to logs, Diagnostics results or error messages.
- Do not add third-party dependencies without prior agreement (see ADR-3 in [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md)).
- User-facing strings are localized: write them in English and add the Vietnamese translation to `Resources/vi.lproj/Localizable.strings`. `scripts/check-strings.sh` must pass.

## Build and test before submitting

```bash
scripts/dev-build.sh                 # must report 0 warnings, 0 errors
scripts/run-tests.sh                 # unit tests must pass
scripts/run-tests.sh --integration   # when touching the Docker API, backups or endpoints (needs a running Colima VM)
scripts/check-strings.sh             # when adding or changing UI strings
scripts/ui-tests.sh                  # when touching confirmations or secret display (needs Xcode, see docs/TESTING.md)
```

Integration tests use the Colima profile named in `COLIMAX_PROFILE` (default `default`). CI runs `WARNINGS_AS_ERRORS=1 scripts/dev-build.sh`, which fails on any warning.

UI changes: run `scripts/build-app.sh`, open `build/ColimaX.app` and go through the relevant items of the manual checklist in [docs/TESTING.md](docs/TESTING.md).

New tests go in `Tests/ColimaXTests`. Integration tests must only create resources with the `colimax-test-` prefix and the `dev.colimax.test` label, clean up in `tearDown`, and never touch the user's existing resources.

## Commit conventions

Follow [Conventional Commits](https://www.conventionalcommits.org/en/v1.0.0/):

```
<type>(<scope>): <short description>
```

| Type | Use for |
|---|---|
| `feat` | New feature |
| `fix` | Bug fix |
| `perf` | Performance improvement |
| `refactor` | Restructuring without behavior change |
| `test` | Adding or changing tests |
| `docs` | Documentation only |
| `build` | Build scripts, `Package.swift` |
| `chore` | Anything else that does not affect running code |

Suggested scopes: `runtime`, `containers`, `compose`, `images`, `volumes`, `backup`, `networks`, `diagnostics`, `storage`, `monitoring`, `ui`, `docs`. Put the feature ID in the commit body when there is one (for example `Refs: G19`).

## Pull requests

Fill in the pull request template: what changed and why, the related feature ID from `docs/FEATURES.md`, and the checklist (build, tests, UI check, confirmations, no shell string concatenation, docs updated). Report security vulnerabilities privately as described in [SECURITY.md](SECURITY.md), not in a public issue or pull request.

## Project layout

```
Sources/ColimaX/
├── App/                  # @main app, scenes, command menus, AppStore, OperationCenter, AppServices, AppSettings, Preferences
├── Core/                 # Shell, BlockingIO, Hashing, Utilities, SystemIntegration
│   ├── Colima/           # ColimaControlling, LiveColima, ColimaService
│   └── Docker/           # DockerEngine, DockerClient, DockerAPI, DockerModels, ContainerDetails
├── Testing/              # FakeColima, FakeDocker, UITestFixtures (-D COLIMAX_UI_TESTING only)
├── UI/                   # Shared SwiftUI components
└── Features/<Feature>/   # Views, screen model, services and stores of each feature
Tests/ColimaXTests/       # Unit and integration tests
Tests/Runner/             # Runner for scripts/run-tests.sh
UITests/                  # XCUITest project (scripts/ui-tests.sh)
scripts/                  # Build, test, localization and release scripts
docs/                     # Project documentation (see docs/README.md)
```

New code goes in the folder of the feature it belongs to. Code shared by several features goes in `Core/` (non-UI) or `UI/` (views).

## Adding a feature

Follow the recipe in [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md#adding-a-feature-screen): pure logic in a service, new Docker / Colima calls added to `DockerEngine` / `ColimaControlling` and their fakes, a screen model that depends on `DockerContext` or `ProfileContext` (not on `AppStore`) and runs actions through `OperationCenter`, a unit test with the fakes, and a UI test when the flow is destructive or shows secrets. Mark the feature `In Progress` in [docs/FEATURES.md](docs/FEATURES.md) first.

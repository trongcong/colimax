English · [Tiếng Việt](AGENTS.vi.md)

# Instructions for agents (Codex, Cursor, Claude Code…)

1. **Read `docs/FEATURES.md` first.** It is written in English and is the single source of truth for feature status (Planned / In Progress / Implemented / Verified / Blocked). `docs/FEATURES.vi.md` is only a translation.
2. Before starting a feature: change its row to `In Progress (<agent>)`. When done, update the status, the Code column, the Release column and the Notes. Docs describe the current state only: do not record dates or a log of who did what when (git and `CHANGELOG.md` hold the history).
3. `Verified` may only be recorded after running for real against Colima/Docker (integration tests via `scripts/run-tests.sh --integration` or a manual run), together with how it was verified (test name or command).
4. Do not create duplicate services/models/views. Search the Code column of `docs/FEATURES.md` and `Sources/ColimaX` first.
5. Put new files in the right place under `Sources/ColimaX`:
   - `App/`: entry point, main window, menu bar, Preferences, global state (`AppStore`, `AppSettings`).
   - `Core/`: shared infrastructure (`Shell`, `BlockingIO`, system integration); `Core/Docker/` Docker Engine API client + models; `Core/Colima/` Colima CLI.
   - `Features/<Name>/`: the views + store + services specific to one screen / feature.
   - `UI/`: shared SwiftUI components.
   - `Testing/`: in-memory fakes and UI-test fixtures, compiled only with `-D COLIMAX_UI_TESTING`.
   Folders are only for organization; the dependency rule is still View → Store → Service (see `docs/ARCHITECTURE.md`).
6. Build & test: `scripts/dev-build.sh` (0 warnings), `scripts/run-tests.sh` (unit), `scripts/run-tests.sh --integration` (requires a running Colima VM, profile selected via `COLIMAX_PROFILE`), `scripts/check-strings.sh` (translations), `scripts/build-app.sh` (packages `build/ColimaX.app`).
7. Constraints: Swift 6 strict concurrency, 0 warnings; never run commands through a shell by concatenating input into a string; destructive operations must require confirmation; integration tests may only create `colimax-test-*` resources labeled `dev.colimax.test` and must clean up after themselves; UI strings are written in English in code and translated in `Resources/vi.lproj`.
8. Language: all documentation is written in English as the primary version, with a Vietnamese companion `<name>.vi.md` next to it (e.g. `README.vi.md`, `docs/FEATURES.vi.md`, `AGENTS.vi.md`); when you change an English doc, update its `.vi.md` companion in the same change. Code comments and script messages are in English. UI strings use English keys in code and are translated in `Resources/vi.lproj`.

The product, module, target and executable are all named `ColimaX`. Details: `CONTRIBUTING.md` (workflow, commits), `docs/ARCHITECTURE.md` (architecture), `docs/AUDIT.md` (risks and priorities), `docs/README.md` (documentation index).

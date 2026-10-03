# Contributing

## Setup

1. macOS 14+ and Xcode 26+ (select it with `sudo xcode-select -s /Applications/Xcode.app` if `xcodebuild -version` fails).
2. `git clone https://github.com/RoshanMatrubai/mindmap.git && cd mindmap`
3. `make test`

Builds are ad-hoc signed, so no Apple account is needed. To sign with your free Personal Team instead, copy `Config/Local.xcconfig.example` to `Config/Local.xcconfig` (gitignored) and fill in `DEVELOPMENT_TEAM`. It's optional: data protection doesn't depend on it.

## Commands

| Command | Does |
|---|---|
| `make run` | Debug build, (re)opens "mindmap dev" (separate bundle ID and data). `ARGS="-fixture sample"` loads the sample map |
| `make stop` / `make screenshot` / `make logs` | Quit the dev app / capture its window to `build/screenshot.png` / show its recent log |
| `make test` | Package tests plus a Debug app build |
| `make lint` / `make format` | Check / fix formatting with `swift format` |
| `make preview` | Renders the sample map to `build/preview.png` |
| `make build` | Debug build (`CONFIG=Release` for Release) |
| `make install` | Release build copied to `/Applications/mindmap.app` |
| `make check-isolation` | Checks that your terminal can't read `~/Documents` (or `FOLDER=<path>`) and has no Full Disk Access. For you, not for agents |
| `make clean` | Deletes `build/` |

Everything builds into `build/`. Use `make run` while developing; the dev copy keeps its maps inside its own container and never asks for your maps folder unless you launch it with `ARGS="-use-folder-picker YES"`.

## Before a pull request

- `make test` and `make lint` pass. CI runs both plus a Release build and fails if the build leaves the git tree dirty.
- For visual changes, check `make preview` and attach a screenshot.
- Don't hand-edit `project.pbxproj`; new files in `App/` are picked up automatically and settings go in `Config/*.xcconfig`.
- No third-party dependencies. Product specs are in `docs/`; record setup or architecture decisions in `docs/decisions/`.

## Branches and commits

- Branches: `feat/<short-name>`, `fix/<short-name>`.
- Commits: [Conventional Commits](https://www.conventionalcommits.org/) (`feat: …`, `fix: …`, `docs: …`, `chore: …`, `test: …`, `refactor: …`).

## Using AI coding agents safely

Agents read `AGENTS.md`. They never commit or push; they end with a suggested commit message for you to review.

Your maps live in the folder you pick the first time you open mindmap. Pick one inside Documents (the default suggestion is `~/Documents/mindmap`): macOS doesn't let terminal programs (Claude Code, Codex, any shell) read Documents, Desktop, Downloads or iCloud Drive unless you allow it. That's the real protection. The app also refuses a folder inside or around a git repository, so maps can't be committed by accident.

It stops working if:

- you click **Allow** when macOS asks whether your terminal may access files in Documents (or another protected folder). Always click **Don't Allow**; undo an Allow in System Settings > Privacy & Security > Files & Folders.
- your terminal app has **Full Disk Access**. Never grant it.
- you pick a folder macOS doesn't protect (anything outside the folders above).

Settings and caches stay in the app's container, which we continue to treat as readable by terminal programs, so nothing sensitive is stored there. Container protection without Full Disk Access remains untested; the corrected experiment record is in `docs/decisions/0002-data-protection.md`. Signing is not the guard for real maps.

Run `make check-isolation` yourself to confirm: it prints PROTECTED or EXPOSED and never prints file contents.

**Claude Code.** Start it from the repo root. `.claude/settings.json` denies reading the release container, its Application Scripts folder, `~/Library/Calendars`, Documents, Desktop, Downloads and iCloud Drive, for Claude's file tools and (best effort, by matching the command text) shell commands. The Bash sandbox is off so agents can run, screenshot and debug the dev app. Don't approve commands that read those folders.

**Codex.** Run with `codex --sandbox danger-full-access --ask-for-approval never`. The guard for real maps is macOS Files & Folders protection on Documents: answer **Don't Allow** if macOS asks for access, and never give the terminal Full Disk Access. Contributors who prefer Codex's sandbox can use `codex --sandbox workspace-write`; builds still work there. That sandbox limits writes to the repo, but the Files & Folders protection above is what keeps your maps away from terminal programs.

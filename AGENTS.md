# AGENTS.md

Rules for every coding agent working in this repo. Read this first; details live in `docs/`.

## Commands

| Command | Does |
|---|---|
| `make test` | Package tests (`swift test`) plus a Debug app build |
| `make lint` | `swift format lint --strict` (`make format` fixes it) |
| `make build` | Debug build (`make build CONFIG=Release` for Release) |
| `make preview` | Renders the sample fixture to `build/preview.png` |
| `make icon` | Regenerates the app icons (`App/Shared/AppIcon.icon`, `App/Shared/Debug/AppIcon-dev.icon`) from `scripts/make-icon.swift` |
| `make run` | Quits and relaunches "mindmap dev" (`ARGS="-fixture sample"` passes launch arguments) |
| `make stop` | Quits "mindmap dev" |
| `make screenshot` | Captures only the "mindmap dev" window to `build/screenshot.png` |
| `make logs` | Last 2 minutes of the dev app's `os.Logger` output |
| `make clean` | Deletes `build/` |
| `make ipad-build` | iPad app build for the iOS Simulator (`CONFIG=Release` for Release); no signing needed |
| `make ipad-run` | Boots the simulator (`SIM="<name>"`, default "iPad Pro 12.9 M1" if it exists, else "iPad Pro 13-inch (M5)"), installs and launches "mindmap dev" (`ARGS="-fixture sample"`) |
| `make ipad-stop` | Quits "mindmap dev" in the booted simulator |
| `make ipad-screenshot` | Captures the booted simulator's screen to `build/ipad-screenshot.png` |
| `make ipad-install` | For the user only: Release build on a connected iPad (`DEVICE="<name>"`); agents never run it |
| `make ipad-logs` | Last 2 minutes of the dev app's `os.Logger` output in the simulator (`LAST=15m` for longer) |

All build output goes to `build/` (gitignored). Requires Xcode 26+.

## Definition of done

- `make test` and `make lint` pass.
- For any visual change: run `make preview` and look at `build/preview.png` yourself.
- `git status` shows only files you meant to change.
- End with a suggested commit message (Conventional Commits). **Never commit or push.**

## Debugging the app

1. `make run ARGS="-fixture sample"` (fills the editor from `App/Shared/Debug/sample.mindmap`, a copy of the test fixture).
2. `make screenshot`, then look at `build/screenshot.png` yourself.
3. `make logs`. Log with the shared `log` (`App/Shared/Log.swift`); use `.notice` or higher, `log show` hides `.info`/`.debug`.
4. `make stop` when done.

DEBUG-only code goes in `App/Shared/Debug/` or `App/Mac/Debug/` inside `#if DEBUG`; Release excludes those folders.

The iPad app: `make ipad-run ARGS="-fixture sample"` → `make ipad-screenshot` (look at `build/ipad-screenshot.png`) → `make ipad-logs` → `make ipad-stop`. The simulator keeps the app's data in its own sandbox, apart from the Mac and from the user's real data. `ARGS="-fixture sample -editor-smoke YES"` runs the touch smoke harness (`App/iPad/Debug/TouchSmoke.swift`; PASS/FAIL lines, then `touch smoke complete: N checks, F failures`); `-select-node garden`, `-show-menu garden` and `-select-node garden -rename-node YES` stage screenshots; `-layout wide|narrow`, `-pane text|map`, `-orientation landscape|portrait` and `-focus-editor YES` set the layout.

## The data rule

User data never lives in the repo, and agents never touch the real user's data. Real maps live in a folder the user picks (default `~/Documents/mindmap`), which macOS keeps away from terminal programs; the app refuses folders in or around a git work tree. Settings live in the container (`~/Library/Containers/io.github.roshanmatrubai.mindmap`). Debug ("mindmap dev", bundle ID `…mindmap.dev`) has its own container and keeps its maps inside it unless launched with `-use-folder-picker YES`. The iPad simulator has its own sandboxed storage, so the iPad dev app never touches the user's real data either. Tests use `Packages/MindmapKit/Tests/Fixtures/` or temp directories. See `docs/decisions/0002-data-protection.md`.

## Never

- Never read, list or open `~/Library/Containers/io.github.roshanmatrubai.mindmap`, `~/Library/Application Scripts/io.github.roshanmatrubai.mindmap`, or the user's Calendar or Reminders data (`~/Library/Calendars`, `~/Library/Group Containers/group.com.apple.reminders`, EventKit on the user's account).
- Never read, list or search `~/Documents`, `~/Desktop`, `~/Downloads` or `~/Library/Mobile Documents` (iCloud Drive). If a command triggers a macOS "would like to access files" prompt, stop and tell the user; they will click Don't Allow.
- Never run disk-wide or home-wide searches (find /, find ~, grep -r ~, mdfind without -onlyin). Scope every search to the repo, the build folder, or a specific system path like /Applications/Xcode.app.
- Never touch the release container: no command may mention `~/Library/Containers/io.github.roshanmatrubai.mindmap` (the `.dev` one is fine).
- Never launch the Release build (`make install`, `make ipad-install`, `/Applications/mindmap.app`), on the Mac, in a simulator or on a device.
- Never run `make check-isolation`; it's for the user.
- Never capture any window but the dev app's (`make screenshot`, or `make ipad-screenshot` for the simulator; no full-screen or other-app captures).
- Never hand-edit `mindmap.xcodeproj/project.pbxproj` unless the task explicitly requires it. New files in `App/Shared`, `App/Mac` and `App/iPad` are picked up automatically; build settings go in `Config/*.xcconfig`.
- Never add dependencies: Apple frameworks only, including dev tooling.
- Never commit, push, or change git history.

## Shortcuts

Every user-facing shortcut is a menu item and is listed in the README's keyboard shortcuts table. Check docs/roadmap.md for planned shortcuts before adding new ones.

## Priorities

1. Smoothness (120 Hz pan/zoom/settle at 500 nodes; typing never stutters).
2. Power efficiency (zero CPU/GPU when idle).
3. Runs like a normal app.

Energy rules: no `Timer` except the one at local midnight; no polling; nothing animating or running a display link when idle. Details in `docs/design.md` and `docs/architecture.md`.

## Where things are

- `docs/syntax.md`: the text format. `docs/design.md`: visuals, interaction, force layout, settings, fonts, rejected ideas.
- `docs/architecture.md`: repo layout (Mac and iPad targets, what is shared) and recommended architecture. `docs/roadmap.md`: build order.
- `docs/reminders.md`: Reminders sync. `docs/decisions/`: why things are set up the way they are.
- `docs/prototype/mindmap-v6.html`: the browser prototype. It wins on visual details; the docs win on syntax, settings, architecture.
- Swift 6 language mode, macOS 14 and iPadOS 17 deployment targets, Swift Testing (`import Testing`), no snapshot tests.

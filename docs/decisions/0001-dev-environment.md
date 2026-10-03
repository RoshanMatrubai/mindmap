# 0001: Development environment

Status: accepted, 2026-10-03. Rows marked **Superseded** were replaced by [0002](0002-data-protection.md).

## Decisions

| Topic | Decision | Reason |
|---|---|---|
| App name | mindmap (display name "mindmap"; dev copy "mindmap dev") | Short, lowercase like the product's look; the dev copy is visibly different in the Dock and Finder |
| Bundle IDs | Release `io.github.roshanmatrubai.mindmap`, Debug `io.github.roshanmatrubai.mindmap.dev` | Reverse-DNS of a domain the owner controls (GitHub Pages); a separate Debug ID means a separate container |
| Data location | **Superseded by 0002** (maps in a user-picked folder; container holds settings). App Sandbox on; all user data in the app's container. Debug uses the `.dev` ID, so it can never open real data | Keeps data out of the repo and away from dev and agent runs, using macOS's own isolation |
| Project | Checked-in `.xcodeproj` with file-system synchronized folders, plus a local Swift package for logic. Settings in `.xcconfig`. No XcodeGen, Tuist or Homebrew | Adding files doesn't touch `project.pbxproj`, so few merge conflicts and no extra tools to install |
| Platform | macOS 14 minimum, Swift 6 language mode, Apple frameworks only, no third-party dependencies (including dev tooling) | macOS 14 has `CADisplayLink` on macOS; Swift 6 gives data-race checking; no dependencies keeps one-command builds |
| Signing | **Superseded by 0002** (team signing optional, no profile needed). Ad-hoc (`CODE_SIGN_IDENTITY = -`) by default; optional gitignored `Config/Local.xcconfig` for `DEVELOPMENT_TEAM` | Strangers can build without an Apple account; developers can opt into their own team |
| Map files | Plain text, extension `.mindmap` | Portable and diffable; a distinct extension lets `.gitignore` block stray maps |
| License | MIT, copyright 2026 Roshan Matrubai | Simple and permissive |
| Formatting | `swift format` (ships with the toolchain), not SwiftLint | No extra install, consistent with "no dependencies" |
| Tests | Swift Testing in the package; no snapshot tests | Modern, ships with Xcode; snapshots are brittle across GPUs and fonts. Visual checks use `make preview` |
| Commits | Agents never commit or push; they suggest a commit message | The human reviews every change before it enters history |

## Choices made during setup

| Topic | Choice | Reason |
|---|---|---|
| Xcode minimum | 26.0 | Matches the README and the Xcode on CI's `macos-26` runner (the only version CI verifies). Synchronized folders (`objectVersion = 77`) and Swift 6 would technically allow Xcode 16 |
| CI runner | `macos-26` (newest generally available GitHub macOS runner as of 2026-10; the `xcode-27` image is still in preview) | Matches the Xcode minimum |
| Claude Code sandbox | **Superseded by 0002** (sandbox off; `permissions.deny` rules only). Sandbox on with `denyRead` + `permissions.deny` for the release container, its Application Scripts folder and `~/Library/Calendars`. No `excludedCommands`: every `make` target except `run` works inside the sandbox, so the read block applies to the whole toolchain. `sandbox.filesystem.allowWrite` adds only `/private/var/folders/*/*/T/**/*` and `/private/var/folders/*/*/C/**/*` (the per-user temp and cache dirs, `getconf DARWIN_USER_TEMP_DIR` / `DARWIN_USER_CACHE_DIR`), `~/Library/Caches/org.swift.swiftpm` and `~/Library/org.swift.swiftpm` | Verified 2026-10-03 with Xcode 27.0, from the sandbox's own `Operation not permitted` errors. T: xcrun's `xcrun_db` cache and Foundation's atomic writes (SwiftPM's build manifest) stage through it, and nothing redirects them (`$TMPDIR` doesn't). C: the clang/Swift module cache. The SwiftPM dirs only remove warnings. The paths differ per machine, hence the wildcards. On macOS a wildcard entry matches only the exact path, so the subtree needs `/**/*` (a trailing `/**` is stripped). Write access only; reads were never restricted there. Remaining harmless log noise: CoreSimulator (no mach access, not needed for a macOS target) and `~/Library/Caches/com.apple.dt.xcodebuild` |
| Nested sandboxes | Still in place but only needed inside an agent sandbox, which 0002 turned off. `swift … --disable-sandbox` and `xcodebuild -IDEPackageSupportDisableManifestSandbox=YES` in the Makefile; `OTHER_SWIFT_FLAGS = -disable-sandbox` in `Base.xcconfig` | SwiftPM, xcodebuild (package resolution) and swiftc (macro plugin server, used by SwiftUI's `@State`) each run a helper under `sandbox-exec`, which fails with `sandbox_apply: Operation not permitted` inside another sandbox. The only code they'd sandbox is our own `Package.swift` and Apple's macros (no dependencies), so nothing untrusted runs |
| `make run` and agents | **Superseded by 0002** (agents run the debug loop). Agents ask the user to run it | The Claude Code sandbox blocks `open` (Launch Services). The dev app has its own data, so this is a convenience limit, not a safety one |
| Entitlements | **Superseded by 0002** (adds user-selected read-write and app-scope bookmarks). `Config/mindmap.entitlements` with only `com.apple.security.app-sandbox` | Calendar entitlement comes with roadmap step 5 |
| Preview tool | `mindmap-preview` draws with Core Graphics + Core Text + ImageIO, no window | Runs headless in CI and in agent shells |

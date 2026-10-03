# 0002: Data protection

Status: accepted, 2026-10-03. Supersedes the data-location, signing and Claude Code sandbox parts of [0001](0001-dev-environment.md).

## Decision

| Topic | Decision |
|---|---|
| Guard for real data | macOS Files & Folders protection. Maps live in a folder the user picks on first launch (`NSOpenPanel`, starts in `~/Documents`; default `~/Documents/mindmap`). Terminal programs (Claude Code, Codex, any shell) can't read Documents, Desktop, Downloads or iCloud Drive unless the user allows it |
| Access | App-scoped security-scoped bookmark in the container's UserDefaults. Entitlements: App Sandbox, `files.user-selected.read-write`, `files.bookmarks.app-scope`. A stale bookmark that still resolves and grants access is renewed quietly (fresh bookmark data from the resolved URL). One that fails to resolve or grants no access is logged and the picker is shown again. File > Change Maps Folder… re-picks |
| Data rule in the app | The picker refuses a folder inside, or containing, a git work tree, and says why. The saved folder is re-checked at launch |
| What goes where | Maps folder: maps, and anything sensitive later steps store (e.g. calendar event mappings). Container: settings and caches only |
| Debug | Maps go in `Application Support/maps` inside the dev container: no picker, no prompts, so the agent debug loop runs unattended. `-use-folder-picker YES` behaves like Release |
| Claude Code | Bash sandbox off (it blocked launching, seeing and debugging the app). `.claude/settings.json` keeps `permissions.deny` Read rules and best-effort Bash rules for the release container, Calendars, Documents, Desktop, Downloads and iCloud Drive. Agents never run `make check-isolation` |
| Signing | Not required. Ad-hoc stays the default; `Config/Local.xcconfig` (gitignored) optionally signs with a free Personal Team, no provisioning profile needed |
| Placeholder | Until roadmap step 1 the editor autosaves (300 ms after typing stops) to `untitled.mindmap` in the maps folder and loads it on launch. Step 1 decides naming and multiple maps |

## Why not container protection

### Correction, 2026-10-03

Terminal had Full Disk Access during experiments 5a and 5b below. The original Full Disk Access probe was wrong on macOS 27. Their shell-read results therefore do not show that container protection fails. Container protection remains untested without Full Disk Access. The Documents decision stands: continue treating the container as readable and keep nothing sensitive there. The historical account below records the original interpretation, superseded by this correction.

The first plan relied on macOS 14+ walling off a sandboxed app's container from other processes, which needs a stable (team) signature. Tested 2026-10-03 on macOS 27.0.1 with the dev app, Terminal without Full Disk Access:

| Experiment | Result |
|---|---|
| 5b, ad-hoc | A rebuilt app (new CDHash) still read its own marker file. The shell read the container freely, no prompt. The container's owner is recorded with `validationCategory: none`, so nothing is validated |
| 5a, team-signed, container first created by an ad-hoc build | The team owner is added next to the ad-hoc one; the shell still reads it. A container first created by an ad-hoc build may stay unprotected |
| 5a, team-signed, fresh container | Owner `validationCategory: development`, team only. Rebuilt app still read its marker. **The shell still read the container freely, no prompt** |

So the container is open to any terminal program however the app is signed. macOS does guard it against a different app identity: an ad-hoc build launching into the team-owned container was stopped by a macOS dialog until the user clicked Allow.

## Bookmarks across rebuilds

Tested with the dev app and `-use-folder-picker YES`, a test folder on the Desktop, then a real code change, rebuild and relaunch, checked through the app's own log:

| Signing | Result |
|---|---|
| Team | Resolved after rebuild; autosave wrote and the next launch read the map back |
| Ad-hoc (bookmark made by an ad-hoc build) | Resolved after two ad-hoc rebuilds; autosave wrote and read back |
| Team bookmark, then an ad-hoc build | Blocked by the container dialog above; after Allow, the bookmark resolved |

Signing is therefore not needed for protection or for keeping the maps folder. It is still mildly useful: macOS ties the container to one identity (other identities need the user's OK), and later permission grants keyed to the signature (e.g. Calendar in step 5) are likely to survive rebuilds (untested). Switching an existing install between ad-hoc and team signing can show that dialog once (it did in two of three switches here).

## Limits

- An allowed prompt: if the user ever clicks Allow on "Terminal would like to access files in your Documents folder", every program run from that terminal can read the maps. Undo it in System Settings > Privacy & Security > Files & Folders.
- Full Disk Access for the terminal app exposes everything.
- A user picking an unprotected folder (anything outside Documents, Desktop, Downloads, iCloud Drive and removable or network volumes) gets no protection. The picker only suggests Documents.
- Settings and caches in the container are readable by terminal programs; nothing sensitive may go there.
- `make check-isolation` (run by the user, never by agents) reports PROTECTED or EXPOSED for `~/Documents` or `FOLDER=<path>`, plus Full Disk Access, using only exit statuses.

## Debug loop

`make run ARGS="-fixture sample"` → `make screenshot` (only the dev window, by exact owner name; needs Screen Recording for the terminal) → `make logs` (`os.Logger`, subsystem = bundle ID) → `make stop`. DEBUG-only code lives in `App/Debug/`, excluded from Release with `EXCLUDED_SOURCE_FILE_NAMES`; `App/Debug/sample.mindmap` is a copy of the test fixture, kept in sync by a test.

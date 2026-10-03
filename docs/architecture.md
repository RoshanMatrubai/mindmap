# Architecture

## Repo layout

```
App/                        SwiftUI app target "mindmap" (file-system synchronized folder:
                            new files here join the target without editing project.pbxproj)
Config/                     Build settings (.xcconfig), entitlements. Local.xcconfig is yours, gitignored
mindmap.xcodeproj/          Checked-in project. Holds structure only; settings live in Config/
Packages/MindmapKit/        Local Swift package with all logic
  Sources/MindmapCore/      Pure Swift, no AppKit: model, parser, dates, urgency, simulation
  Sources/MindmapGraph/     AppKit / Core Animation graph rendering
  Sources/mindmap-preview/  CLI: renders a map to PNG (make preview)
  Tests/MindmapCoreTests/   Swift Testing tests
  Tests/Fixtures/           Made-up sample maps (the only .mindmap files allowed in git)
docs/                       Product and design docs, decision log, prototype
build/                      All build output (gitignored)
```

Put logic in `MindmapCore` whenever it doesn't need AppKit, so it is testable with `swift test`. The app target should stay thin: windows, scenes, and glue.

## Data

Hard requirement: no user data ever lives in the repository folder. Using the app never changes a tracked file, so `git status` stays clean after any amount of use, and a CLI agent working in the repo has no access to the data of the person using the app. Development and test runs never read or write the real user's data either.

App Sandbox is on. Maps, and anything sensitive later steps store (e.g. calendar event mappings), live in the maps folder the user picks on first launch (default `~/Documents/mindmap`), reached through an app-scoped security-scoped bookmark. Settings and caches live in the app's container. Why: [decisions/0002-data-protection.md](decisions/0002-data-protection.md).

| Build | Bundle ID | Container |
|---|---|---|
| Release ("mindmap") | `io.github.roshanmatrubai.mindmap` | `~/Library/Containers/io.github.roshanmatrubai.mindmap` |
| Debug ("mindmap dev") | `io.github.roshanmatrubai.mindmap.dev` | `~/Library/Containers/io.github.roshanmatrubai.mindmap.dev` |

Debug builds refuse to launch if their bundle ID doesn't end in `.dev` (`App/MindmapApp.swift`). By default they keep maps in `Application Support/maps` inside their own container (no picker); `-use-folder-picker YES` makes them behave like Release. Tests use fixtures and temp directories, never a container.

## Recommended architecture

A recommendation, not a requirement. Agents may push back if they justify it against the priorities in [design.md](design.md).

| Layer | Choice | Why |
|---|---|---|
| App shell | SwiftUI `App` with a `WindowGroup` and `Settings` scene, macOS 14+ | Native settings window for free |
| Editor | `NSTextView` (TextKit 2) in `NSViewRepresentable` | SwiftUI `TextEditor` can't do Notes-style Enter/Tab handling or line highlighting well |
| Graph rendering | AppKit `NSView` with a Core Animation layer tree: one container layer, one `CAShapeLayer` each for tree edges, cross links and highlighted edges, and a small layer per node with a pre-rasterized label | Pan and zoom become one `sublayerTransform` change, handled by the compositor with almost no CPU. This is the path to 120 Hz |
| Zoom sharpness | Re-rasterize labels at the new scale when a pinch ends; accept slight softness during it | Re-rendering text every frame is what kills smoothness |
| Edge width | Set `lineWidth = 1 / zoom` on edge layers each frame (a property write, not a path rebuild) | Keeps lines 1 px on screen |
| Simulation | Swift structs in contiguous arrays, off the main thread, publishing positions once per frame through `CADisplayLink` (macOS 14) only while alpha > 0.003 | The display link exists only during the settle |
| Parsing | Debounced 300 ms after typing stops, off the main thread | Typing never waits on layout |
| Storage | One plain text file per map in the user's maps folder (outside the repo), autosaved | Portable and diffable |

Fallback if the layer approach fights back: SwiftUI `Canvas` in a `TimelineView` that pauses when frozen, with labels resolved once via `GraphicsContext.resolve` and cached. Simpler and probably fine to 1,000 nodes, but pan and zoom redraw everything each frame.

## Energy checklist

- No `Timer` anywhere except one firing at local midnight to recompute due dates.
- Pause everything when the window is occluded (`NSWindow.occlusionState`).
- Measure with Instruments (Time Profiler, Energy Log) and Activity Monitor's Energy tab. Target: 0% CPU and "Low" energy impact when idle with a 500 node map open.

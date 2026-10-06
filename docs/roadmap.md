# Roadmap (build order)

0. Development environment: project, build commands, tests, CI, agent rules, docs, placeholder window.
1. Editor with Notes-style bullets, the parser, and parser tests (indentation, metadata, links, malformed input).
2. Static graph: parse, run the simulation instantly, draw the frozen result with the layer tree. Pan and zoom. Replaces the placeholder render in `mindmap-preview`.

**3a. Motion:** animated settle and reshuffle, local relaxation on edits and drags, stable node identity, saved positions, fast map switching, mouse-wheel zoom, ⇧⌘X done toggle.

**3b. Interaction (done):** Selection, highlight, camera fit, editor↔graph sync, detail panel, add/rename/remove from the graph, arrow-key navigation, ⇧-drag for subtrees, priority shortcuts.

**4. Settings (done):** Settings window, forces panel, all fonts with a picker, `[name]` links, priority keys on ⌘1–4 and ⌘0.
**5. Reminders sync (done):** `/high` tasks become reminders in a dedicated Reminders list, due at a set time (6:30 AM by default) with an alarm, completed by `[x]`. Replaced the first Calendar version ([reminders.md](reminders.md)).
**6. Performance and energy pass (done):** measured with the 500-node fixture (`-bench YES`), fixed what the profiles showed, smoke harness made deterministic. Numbers in [design.md](design.md#performance-step-6).

## iPad

A native iPadOS app (UIKit + SwiftUI, not Mac Catalyst), iPadOS 17+, iPad only, target `mindmap-ipad`. It shares `MindmapCore`, `MindmapGraph` and `App/Shared` with the Mac app ([architecture.md](architecture.md#targets-and-shared-code)). Reminders sync stays Mac-only.

**i1. Port preparation (done):** app code split into `App/Shared`, `App/Mac` and `App/iPad`; `MindmapGraph` made platform-neutral (shared `GraphController` and layer code, thin `NSView` and `UIView` hosts, `CADisplayLink` up to 120 Hz on iPad); iPad target, `make ipad-*` commands and a CI simulator build. The iPad app shows the map title and the settled graph of the `-fixture` map, without interaction.
**i2. Touch graph:** pan, pinch zoom, tap to select, drag nodes (subtrees with a modifier or long press), naming on the graph; pause motion when the scene leaves the screen.
**i3. Editor and layout:** the outline editor (TextKit 2 `UITextView`), the store shared with the Mac (split `MapStore` from AppKit), split view and detail panel, settings.
**i4. iCloud Drive sync:** maps in the app's iCloud Drive folder on both devices; handle file coordination, conflicts and the layout sidecars.
**i5. Polish and device install:** keyboard and pointer shortcuts, multitasking sizes, energy check on a ProMotion iPad, signed install on a device with the Personal Team.

## Planned shortcuts

- Step 3b (built): Esc clears the selection; Return adds a task; Tab adds a subtask; Delete removes; double-click on empty canvas adds a group; with a node selected, arrows move the selection (↑ parent, ↓ first child, ← → siblings), and without a selection they pan; ⇧-drag moves a subtree.
- Step 4 (built): ⌘, opens settings; ⌥⌘F shows or hides the forces panel; ⌥⌘= / ⌥⌘- change the label size; ⌘1–4 and ⌘0 set or clear the priority (graph selection or editor lines); focus editor / graph moved to ⌥⌘1 / ⌥⌘2 and fit all to ⌥⌘0.

Start each step by raising its open decisions. The user should have a runnable build after step 2 and after every step from then on.

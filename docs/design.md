# Design

The window has two panes. On the left is a plain text editor where you type a to-do list as an indented bullet outline, exactly the way you would in Apple Notes. On the right, that outline is drawn live as a force-directed graph in the style of Obsidian's graph view: groups are big black nodes, tasks and subtasks are smaller gray nodes, lines connect parents to children, and dashed curves connect cross-linked tasks. Clicking a group lights its whole branch in deep purple, dims everything else to about 30%, and zooms the camera to fit that branch. The graph settles once with a short physics animation, then freezes completely. High-priority tasks also appear in the macOS Reminders app.

The working browser prototype is [`prototype/mindmap-v6.html`](prototype/mindmap-v6.html); open it in Chrome or Safari. Every visual and interaction decision below was made by looking at it, so when these docs and the prototype disagree on a visual detail, the prototype wins. When they disagree on syntax, settings or architecture, these docs win, because those changed after the prototype was built. The prototype's sample text is made up; its `*` / `**` syntax is superseded by [syntax.md](syntax.md). It contains the exact colors, the simulation code and the selection logic. Its edges once failed to render inside a chat widget sandbox but render correctly as a standalone page; that was environmental and does not apply natively.

## Priorities, in order

1. **Smoothness.** Pan, zoom, selection and the settle animation must hold 120 Hz on ProMotion MacBooks with no dropped frames at 500 nodes. Typing in the editor must never stutter, even while the graph rebuilds.
2. **Power efficiency.** Zero CPU and zero GPU work when nothing is moving. No polling timers, no display link running while frozen, nothing animated in the background.
3. **Runs like a normal app.** A real `.app` bundle anyone can build with one command and drop in /Applications. No dependencies beyond Apple frameworks.

When 1 and 2 conflict, 1 wins during interaction and 2 wins the moment interaction stops.

## Graph visuals

| Element | Spec |
|---|---|
| Canvas | `#1e1e1e` |
| Group node | radius 9, fill `#0d0d0d`, stroke `#4a4a4e` 0.6 |
| Task with children | radius 6, fill `#141416`, stroke `#4a4a4e` |
| Leaf task | radius 4, fill `#55555a` |
| Group label | 16 pt × text size, `#d1d1d6` |
| Task label | 13 pt × text size, `#6e6e73`, wrapped at about 18 characters, max 2 lines with ellipsis |
| Label halo | 3 px stroke in the canvas color behind each label, so text reads over lines |
| Tree edge | `#6e6e75` at 55% opacity, 1 px on screen at every zoom level |
| Cross link | Same color at 35%, dashed 3/4, quadratic curve bowed sideways |
| Selected node | `#4f2fc4` |
| Highlighted edges | `#6a4ff0`, 1.8 px, full opacity, drawn above everything else |
| Highlighted labels | `#f2f2f7` groups, `#d1d1d6` tasks |
| Dimmed (not selected) | Nodes 30%, edges 28%, cross links 15%. Linked nodes in other groups 80% |
| Priority colors (detail panel) | high `#c98589`, medium `#c2a26a`, low/chill `#7f9cd1` |

The full prototype settle prevents overlap within each group and between group labels. Labels from different groups may overlap during that settle; that clutter is intentional. Local edits and dragging push aside any overlapped label box, including across groups.

## Interaction

- Click a group or task: highlight it, its ancestors and its whole subtree, plus cross links touching any of them. Animate the camera to fit the highlighted set (about 380 ms, ease out cubic). Select the matching line in the editor.
- Moving the editor cursor onto a line highlights that node in the graph (the prototype only does graph to editor; add this direction).
- Click empty canvas: clear selection, animate back to fit all.
- Two-finger scroll pans, pinch zooms about the cursor, plus zoom in, zoom out and fit buttons top right.
- Detail panel along the bottom: name, path (`school › calc iii work`), and either task count, next due and high priority count (groups) or due, priority, status (tasks), plus urgency percent and linked nodes.
- Leave out the prototype's "break it down" button.

## Layout: force simulation

This is the heart of the look: a d3-force style simulation, animated when needed, then frozen. The prototype's `tick()`, `collide()` and `build()` functions are the reference implementation.

Each tick, with `alpha` decaying from 1 toward 0 by 2% per tick:

1. **Repel.** Every pair pushes apart with force `repel × alpha / distance²`, ignored beyond 250 units. **User decision:** 250 is intentional and overrides the original brief's 600; don't revert it. Group pairs get 1.4× weight. Use Barnes-Hut or a uniform grid once nodes exceed about 300; the prototype is O(n²).
2. **Springs.** Each parent and child pair pulls toward `link distance`, scaled by `link force`. As in the prototype's code, a group→task spring (prototype depth 2, our depth 1) is 1.5× that and every deeper level 1×. Cross links are springs at 12% strength and 3× distance.
3. **Center gravity.** Pulls every node toward the origin with strength `center`.
4. **Urgency force.** Each node gets an urgency score from 0 to 1: due-date closeness `(8 − daysUntilDue) / 8`, plus 0.5 for high or 0.25 for medium priority, capped at 1. Parents inherit 85% of their most urgent child.
   - **Pull in:** extra gravity `0.05 × urgency`. Urgent work collects in the middle.
   - **Push out:** extra gravity `0.05 × (1 − urgency)`. Calm work collects in the middle and urgent work drifts to the rim.
   - **Off:** no extra gravity.
5. Velocity decays 40% per tick; positions integrate.
6. **Soft collision** between label boxes (same group, plus group against group) at half strength.

Stop when alpha drops below 0.003 (about 300 ticks), run a hard collision pass, then freeze.

Starting positions:

- Fresh build or reshuffle: uniform random in a disk of radius 650 from a new seed.
- Text edit: local relaxation. Only new, moved or overlapping nodes and their collision cascade can move. Every other node keeps its exact position. This replaces the brief's warm-start reheat to alpha 0.3 at the user's request.

## Decisions for the graph (steps 2 and 3)

Step 2 (built):

- Done tasks: node and label at 40% opacity, label struck through, urgency 0.
- The implicit `loose` group is drawn like any group.
- Each map remembers its layout seed, so reopening shows the same layout. Reshuffle (⇧⌘R) picks a new seed and clears pins.
- Zoom range: from 1/10 of "fit all" out to 10× "fit all" in.
- Input. Trackpad: two-finger scroll pans, pinch zooms about the cursor. Mouse: the wheel zooms about the cursor, dragging empty canvas pans. Scroll events with a gesture or momentum phase (trackpad, Magic Mouse) pan; events with neither (any wheel, including smooth-scrolling mice with precise deltas) zoom, 12% per line or 10 points, at most 1.5× per event. Zoom in, zoom out and fit buttons top right. Camera moves from buttons and shortcuts animate about 380 ms, ease-out cubic, as Core Animation keyframes. Fit all on first show, rebuild and window resize until the user pans or zooms.
- Typing and dragging now use the step 3a rules below. Pinned nodes keep their positions unless explicitly dragged.
- Dragging a node uses a 4 px threshold and about 14 px hit radius. Its edges and cross links follow. Step 3a adds subtree springs and collision cascades.
- After a drop the node is pinned there until reshuffle. Rebuilds treat pinned nodes as fixed points.
- Layout state lives in a hidden sidecar next to the map, `.<map file name>.layout.json`. Version 2 stores the seed, pins and every node's position keyed by path key. Version 1 sidecars (seed and pins) migrate by computing the seeded layout once. The sidecar follows map renames and saves after a freeze (500 ms debounce), on map switch and on quit. Never in the settings container, because keys contain task names. The dev app's sidecars live in its own dev maps folder.

Step 3a (motion):

| Change | Motion rule |
|---|---|
| Add text | Only new nodes and nodes they overlap move. A new node spawns about one link distance from its parent at the least crowded angle. Label overlaps push nodes apart smoothly, with cascades allowed. Every node outside that affected set moves by exactly zero. |
| Delete text | Remove the deleted node's layer. A quick fade is allowed. Nothing else moves. |
| Rename | Keep the node's position. If the grown label overlaps a neighbor, run the same collision cascade. |
| Change level or move lines | Match the existing node, start at its old position and glide toward its new parent. Resolve overlaps locally. |
| Drag | The dragged node follows the cursor. With ⇧ held (step 3b), its subtree follows on springs with the normal layout constants; a plain drag moves only the node. Other nodes move only after an overlap joins them to the affected set. On release, pin the dragged node, settle and freeze. |
| Open or switch maps | Display saved positions instantly without animation. Place nodes absent from the sidecar using the add-text rule. |
| Reshuffle or new map without saved positions | Animate the full prototype settle, then freeze. Ease the camera to fit until the user pans or zooms, matching the prototype's `follow` behavior. Reshuffle clears pins. |
| Done toggle | ⇧⌘X replaces ⇧⌘U. The Outline menu owns the shortcut, including while a text view has focus. |

Node identity matches the path key first, then a rename at the same sibling position under the same parent, then an unmatched node with the same name nearest in document order. Unmatched nodes are additions or deletions.

Local relaxation runs springs and repulsion for new, moved and dragged nodes, and collisions for the whole affected free set, against fixed neighbors. A free node's overlapping neighbors join that set and can push further neighbors; nodes that join this way only collide, so they move aside rather than away. Overlaps that already existed between two nodes the change didn't move are tolerated at their starting depth (close pairs may use up the margin) but never made worse, so one change doesn't ripple through the settle's intentional cross-group clutter. Drags are bounded further, see "User decisions after the step 4 review". Fixed nodes never move. A held drag cools and only pointer motion reheats it. Local settling freezes when nothing moves, or at most 5 s after a release or edit. Neighbor searches use a uniform grid.

An NSView display link exists only while the graph is moving or a drag is active, and stops as soon as the graph freezes. Simulation ticks run off the main thread at a fixed 120 ticks per second, independent of display refresh rate. The main thread applies layer positions once per display frame with implicit Core Animation actions disabled. Occluded windows pause the simulation. Worker frames, snapshots and freeze or pin callbacks carry the document they belong to; after a map switch, results for the previous map are dropped. Labels rasterize off the main thread and cache by text, font, size, scale and style; unchanged node layers are reused.

Step 3b (built): selection and highlighting, camera fit to a selection, editor↔graph sync, the detail panel, adding, renaming and removing nodes from the graph and arrow-key selection navigation. The text stays the single source of truth: every graph edit is one text replacement through the editor (one undo step in the editor's undo stack, autosaved, re-parsed at once).

| # | Topic | Decision |
|---|---|---|
| 1 | Drag | Plain drag moves only the dragged node (crowded neighbors are still pushed aside). ⇧-drag moves the node with its whole subtree. Both pin on release |
| 2 | Detail panel | Always visible along the bottom of the graph pane (at least 84 pt, prototype styling). A short hint when nothing is selected |
| 3 | Editor cursor → graph | Moving the cursor onto a line highlights its node without moving the camera. Only graph clicks, arrow keys and linked names move the camera. A line with no node (title, blank) clears the highlight |
| 4 | Rename on the graph | Double-click a node or its label to edit the name inline: Return saves, Esc cancels, clicking elsewhere saves. Metadata (done marker, due date, priority, links) is kept and follows the name. Double-click empty canvas adds a group at that spot |
| 5 | New node being named | A new node is written to the text only when its name is committed, so Esc (or an empty name) leaves the text untouched. Its dot shows while naming |
| 6 | Done checkbox | In the detail panel for leaf tasks; toggles `[x]` in the text |
| 7 | Priority shortcuts | With a node selected: ⌥⌘1 high, ⌥⌘2 medium, ⌥⌘3 low, ⌥⌘4 chill, ⌥⌘0 clear. Writes, replaces or removes the `/tag`. **Superseded by step 4 decision 10** (⌘1–4, ⌘0) |
| 8 | "Linked to" | Clicking a linked name in the detail panel selects that node, with a camera move |
| 9 | Map switch | Clears the selection |

Other step 3b rules:

- Return adds a task after the selected node's whole branch (after a group, a new group); Tab adds its last child. The new node's dot appears by its parent at the least crowded spot (the spawn rule), the name is typed there, and the node stays at that spot (it only collides). A double-clicked group stays where it was clicked.
- Delete removes the node and its subtasks with no confirmation; ⌘Z restores the exact text. Afterwards the deleted task's parent is selected; deleting a group clears the selection.
- Esc clears the selection. With a selection and the graph focused, arrows move it (↑ parent, ↓ first child, ← → previous and next sibling, groups being siblings of each other, no wrapping); without one they pan. These plain keys, Return, Tab and Delete are menu items enabled only while the graph has focus and something is selected, so the editor keeps them. ⇧⌘X toggles the selected task when the graph has focus.
- Right-click on a node selects it (no camera move) and offers Add Task, Add Subtask, Rename, Mark Done/Not Done (tasks), Priority ▸ and Delete; on empty canvas, New Group.
- Clicking empty canvas clears the selection and animates back to fit all only when something was selected, so double-clicking empty space to add a group doesn't zoom out first.
- The detail panel shows the name and path lowercased, like the graph. The group's task count is its leaf tasks (prototype `desc()`); next due and high priority look at every open task in it, including tasks with subtasks (the prototype's leaf-only rule hid a `/high` parent task). Tasks with subtasks show the task fields; only leaves get the checkbox.
- Highlighting changes layer properties only. Node dots are plain layers (fill and border colors); labels are a canvas-colored halo raster plus a glyph raster in `#f2f2f7` whose opacity gives each label color. Highlighted nodes move to a container above the highlighted edges, and highlighted edges and cross links (`#6a4ff0`, 1.3 px at 90% for cross links, as in the prototype) get their own shape layers. Dimmed nodes don't use group opacity, which would render each one offscreen.

## iPad touch (step i2)

The iPad graph does what the Mac graph does, with the same look, motion and energy rules (120 Hz while moving, no display link when frozen, none while the scene is in the background). Graph edits use the same `OutlineEditing` functions; drags use the same bounded cascade, cooling while held and 250-unit repel cutoff.

| Touch | Does |
|---|---|
| Tap node | Select: highlight the branch, camera fits it (a Mac click) |
| Tap empty canvas | Clear the selection and fit all (only when something was selected) |
| One-finger drag on a node | Move that node only (crowded neighbors pushed); pinned on release |
| ⇧ + drag (hardware keyboard), or "Move Branch" in the long-press menu then drag | Move the node with its branch. "Move Branch" lasts for one drag |
| One-finger drag on empty canvas, two-finger pan | Pan |
| Pinch | Zoom about the pinch center, the Mac's limits (1/10 to 10× fit all) |
| Long-press node | Context menu: Add Task, Add Subtask, Rename, Mark Done/Not Done (tasks), Priority ▸, Move Branch, Delete. Selects the node without a camera move |
| Long-press empty canvas | Context menu with New Group (there) |
| Double-tap a label | Rename inline: Return or tapping away saves, Esc cancels (the Mac's rules) |
| Double-tap empty canvas | New group at that spot |
| Trackpad or mouse | Pointer hover hugs the node's dot, click = tap, trackpad two-finger scroll pans, a mouse wheel (no gesture phase) zooms about the pointer by the Mac's wheel rule, pinch zooms |

- Touch hits use a 22 pt circle around a dot (the mouse uses 14 pt), then the label box.
- A double-tap is two taps within 0.35 s and 30 pt; the second acts on what the first one hit, so the first tap's camera move can't shift the target. The first tap selects, as on the Mac.
- The context menu points at the node with an invisible anchor instead of lifting a snapshot of the graph.
- The detail panel is shared with the Mac (`App/Shared/DetailPanel.swift`); on the iPad the done checkbox is a tappable square and linked names have hover effects.

## iPad editor and layout (step i3)

| Topic | Decision |
|---|---|
| Editor | TextKit 2 `UITextView`, SF Mono at the shared editor size, the Mac's colors (dimmed bullets and done markers, dates, priorities, links), done lines struck through at 45%, dotted underlines under unresolved links. Return, Tab and ⇧Tab use `OutlineEditing`; autocorrection, smart punctuation, inline predictions and Writing Tools are off |
| Keyboard bar | Above the on-screen keyboard: Indent, Outdent, Toggle Done, Priority ▸ (High, Medium, Low, Chill, None), Insert Link (`[]` with the cursor inside, or the selection wrapped), Move Up, Move Down, Hide Keyboard. Each is the same pure function as the Mac command |
| Shortcuts | The Mac's `AppCommand` table (`App/Shared/AppCommand.swift`), same names and keys, in the iPadOS menu bar and the ⌘-hold overlay. Settings (⌘,) and the forces panel (⌥⌘F) come in step i5. Plain keys (Return, Tab, Delete, arrows, Esc) act on the graph only while it has focus, so the editor keeps them |
| Wide windows | 1100 points or wider (landscape, large Stage Manager windows): editor left, graph and detail panel right, a draggable divider (editor 20–70%, at least 300 points; graph at least 400) |
| Narrow windows | Portrait, split view, small windows: a Text / Map segmented control in the toolbar. On Map the long-press menu adds "Edit Text", which switches to Text with the node's line selected. Both views stay in the window, so the editor keeps its undo stack; the hidden graph runs no display link |
| Sync | As on the Mac: tapping a node selects its line, moving the cursor highlights its node without moving the camera, and graph edits go through the editor (one step in its undo stack) |
| Maps | The toolbar's title menu switches maps and has New Map and Change Maps Folder…; autosave and title-based file names as on the Mac. Release asks for a folder (document picker, security-scoped bookmark); the dev app keeps maps in its container unless launched with `-use-folder-picker YES` |

## iCloud Drive sync (step i4)

No CloudKit and no iCloud entitlement: both apps use a maps folder the user picks, which can live in iCloud Drive.

| Topic | Decision |
|---|---|
| Watching | `MapFolderPresenter` (`NSFilePresenter`) on the maps folder: the system calls it when a map changes, appears, moves or gains a version. No timers, no polling; bursts coalesce into one more pass |
| Reads and writes | Every repository read and write is coordinated (`NSFileCoordinator`), passing the presenter so the app isn't told about its own writes. A coordinated read of a file iCloud hasn't downloaded waits for the download |
| Reload | A change on disk while the open map has no unsaved edits reloads it in place: the parse matches nodes against the shown graph, so the selection and the camera stay |
| Conflicts | A change on disk while the open map has unsaved edits, or iCloud conflict versions (`NSFileVersion`): the open text stays the map, every other version becomes a new visible map "<title> (conflict <device> <yyyy-MM-dd HH.mm>)", conflict versions are marked resolved and removed, and the detail panel says so. Autosave checks the file before writing, so it never overwrites a version it hasn't seen. The decision and the naming are pure functions (`MapSync` in MindmapCore, unit-tested) |
| Not downloaded | Listed by file name (iPadOS `.<name>.icloud` placeholders, macOS dataless files); opening one starts the download and shows "downloading…" |
| Sidecars | Layout sidecars stay hidden dot-files next to their map, read and written with coordination; last writer wins. Apple documents no exclusion of dot-files from iCloud Drive (only the `.nosync` suffix opts out), and they sync, hidden from Files and iCloud.com |
| Reminders | Mac-only. The iPad never reads, writes, moves or deletes the reminders sidecars |

## Settings

These appear in two places, a floating forces panel inside the graph pane (toggled from the toolbar and ⌥⌘F, styled like the prototype's) and the standard Settings window (⌘,). Both edit the same values live, in both directions. Every value is app-wide and persists in the container's UserDefaults, one key each, so a launch argument such as `-labelFont Quicksand` overrides it. Nothing in them is sensitive. The layout seed and pins stay per map, in the sidecar.

| Setting | Range, default | On change |
|---|---|---|
| Label size | 0.6× to 2×, 1× (⌥⌘= / ⌥⌘- step 0.05) | Re-rasterize labels with the new boxes, then push apart only overlaps deeper than they were at the old size (the local collision, animated). No reshuffle |
| Center | 0 to 0.12, 0.04 | Auto reshuffle |
| Repel | 50 to 2000, 450 | Auto reshuffle |
| Link force | 0.05 to 1.5, 0.6 | Auto reshuffle |
| Link distance | 20 to 200, 70 | Auto reshuffle |
| Urgency | Segmented: pull in / off / push out, pull in | Auto reshuffle |
| Animate settle | On / off, on | Off means compute the layout (and local motion after edits) instantly and show the frozen result |
| Reshuffle | Button | Same as ⇧⌘R: new seed, fresh build, pins cleared |
| Font | Picker (below) | Re-measure labels, then the same local push-apart as label size |
| Editor size | 11 to 18 pt, 13 | The editor's SF Mono size (Settings window only) |
| Show forces panel | On / off, off | |
| Reminders sync | On / off, off, plus "remind at", 6:30 AM. Dedicated Reminders settings tab (see [reminders.md](reminders.md)) | Requests Reminders access the first time it is turned on (step 5) |

"Auto reshuffle" means a fresh build with a new seed about 200 ms after the slider stops moving, so dragging doesn't restart the simulation every frame. It keeps pinned nodes; only ⇧⌘R (and the reshuffle buttons) clear pins.

The forces panel layout to match is the prototype's `#forces` panel. (The brief referenced a `forces-panel.png` screenshot; it is not in the repo.)

## Decisions for settings (step 4)

| # | Topic | Decision |
|---|---|---|
| 1 | Forces panel | Floating in the graph pane, top left (40 from the top, 14 from the left), prototype styling. Hidden at first launch; a toolbar button and ⌥⌘F show and hide it; visibility persists |
| 2 | Scope | Settings are app-wide (UserDefaults in the container). Layout seed and pins stay per map in the sidecar |
| 3 | Force sliders | Auto reshuffle about 200 ms after the slider stops moving (never per frame), with a new seed, keeping pinned nodes. Only ⇧⌘R clears pins |
| 4 | Font picker | Changes graph labels (and the map title) only. The editor stays SF Mono |
| 5 | Editor text size | 11 to 18 pt, default 13, Settings window only |
| 6 | Label size keys | ⌥⌘= bigger, ⌥⌘- smaller (steps of 0.05 within 0.6 to 2×); ⌘= and ⌘- stay camera zoom |
| 7 | Settings window | Tabs: "Graph" (center, repel, link force, link distance, urgency, animate settle, reshuffle button) and "Text" (font picker, label size, editor size). Calendar comes in step 5 |
| 8 | Fonts | Every family on the list below is bundled (all 48 verified OFL) |
| 9 | Calendar toggle | Not in step 4 |
| 10 | Priority keys | ⌘1 high, ⌘2 medium, ⌘3 low, ⌘4 chill, ⌘0 clear. With the graph focused they apply to the selected node; otherwise to the editor's current or selected bullet lines. They replace ⌥⌘1–4 / ⌥⌘0 |
| 11 | Moved shortcuts | Focus editor / graph: ⌘1 / ⌘2 → ⌥⌘1 / ⌥⌘2. Fit all: ⌘0 → ⌥⌘0 |
| 12 | Link syntax | `[name]` (single brackets) is a cross link anywhere in a line; `[[name]]` keeps working. `[ ]`, `[x]`, `[X]` right after the bullet stay the done marker. Empty `[]` is ignored. Brackets in ordinary text become links (unresolved if nothing matches); accepted. See [syntax.md](syntax.md) |

User decisions after the step 4 review (they override the step 3a motion rules where they differ):

| Topic | Decision |
|---|---|
| Repel cutoff | 250 units, set by the user, overriding the brief's 600. It packs the full settle tighter, which made crowded drags cascade across the whole map; the next two rows fix that instead of the cutoff |
| Drag cascade | Bounded. A node joins a drag's moving set only within 3 × link distance of the dragged node, or at most 2 overlaps from the dragged subtree (`CascadeLimit`). Nodes outside that region never move, even if a region node ends up overlapping them more deeply than before (the 3a "never worse" rule is relaxed for them). Moving the pointer is what heats the region; while it is held still the cascade cools, so a jammed crowd doesn't creep |
| Inside the region | The user chose to keep pushed nodes close rather than push them far: inside the region labels may end up somewhat closer than they started (a full crowd has nowhere else to go), at most about two task label lines deeper. In the 500-node crowded-drag test 135 nodes move (average 19 units, at most 94) |
| Local margin | Local motion (edits, drags, label size and font changes) keeps 2 units between label boxes instead of the full settle's 6, so a settled map has room and pushes stay short |

Other step 4 rules:

- Panel, top to bottom: label size; "forces (auto reshuffle)" with the live "settling N%" / "frozen" status; center, repel, link force, link distance; the urgency segmented control; reshuffle and "animate: on/off" buttons; a compact font popup. The status updates only from simulation frames, so it costs nothing while frozen.
- A graph edit refused because the editor and the store disagree is logged and shows "couldn't apply that edit, try again" in the detail panel for 3 seconds.

## Fonts

All of these are OFL licensed except the system fonts, so they ship inside the app bundle with their license files: one upright file per family from [google/fonts](https://github.com/google/fonts) (`ofl/<family>`), the variable font where there is one, else Regular, in `App/Shared/Fonts/<Family>/` with `<Family>-OFL.txt`. Together about 17 MB. The Settings window's Text tab previews each name in its own font, grouped as below; the forces panel has a compact popup. Default: Nunito Sans.

Registration is lazy: launch registers only the selected family, off the main thread, and the layout waits for it; opening the Settings window's Text tab registers the rest in the background (about 160 ms). Registering all 48 with `ATSApplicationFontsPath` delayed the first window by about 70 ms, and registering even one font on the main thread at launch cost about 60 ms. The M PLUS Rounded 1c file names its family "Rounded Mplus 1c" (`GraphFonts.fontFamily`), and google/fonts has no license file for it, so its `OFL.txt` is the standard OFL 1.1 text with the copyright line from its METADATA.pb.

| Group | Fonts |
|---|---|
| System | SF Pro, SF Pro Rounded (`.fontDesign(.rounded)`) |
| Humanist | Nunito Sans, Mulish, Karla, Figtree, Lato, Open Sans, Source Sans 3, Cabin, Red Hat Text, Albert Sans, Atkinson Hyperlegible Next, Inclusive Sans, Reddit Sans, Gantari, Lexend, Readex Pro, Noto Sans, Fira Sans, PT Sans, Public Sans, IBM Plex Sans, Libre Franklin, Overpass, Asap, Encode Sans, Hind, Mukta, Signika, Instrument Sans, Schibsted Grotesk |
| Rounded | Nunito, Quicksand, Varela Round, M PLUS Rounded 1c, Rubik |
| Geometric | Outfit, Manrope, Poppins, Urbanist, Plus Jakarta Sans, DM Sans, Work Sans, Onest, Golos Text, Commissioner, Be Vietnam Pro, Hanken Grotesk, Kumbh Sans |

Verify each license and family name when downloading; drop any that turn out not to be OFL. Add each bundled font to [THIRD_PARTY_NOTICES.md](../THIRD_PARTY_NOTICES.md). The editor uses SF Mono by default so indentation is unambiguous.

## App icon

A paper map folded in three on the graphite canvas, with the graph drawn across it: one near-black group with gray tasks, a dashed cross link and one branch lit in the selection purple. No text.

- Format: Icon Composer `.icon` bundles, so macOS 26+ draws it natively with Liquid Glass instead of shrinking a legacy icon onto a gray plate. The graph layers get glass, the folded map stays flat. Xcode also compiles an `.icns` fallback for macOS 14 and 15.
- Release uses `App/Shared/AppIcon.icon`. Debug ("mindmap dev") uses `App/Shared/Debug/AppIcon-dev.icon`, the same icon with an orange disc in the top-right corner. Each is chosen by `ASSETCATALOG_COMPILER_APPICON_NAME` in `Config/Debug.xcconfig` and `Config/Release.xcconfig`. With the Clear or Tinted icon styles the orange turns gray, but the disc still shows.
- Both bundles are generated from code: `make icon` runs `scripts/make-icon.swift` (CoreGraphics), which writes the layer PNGs and `icon.json`. Edit the script and rerun it rather than editing the bundles by hand.

## Performance (step 6)

Measured 2026-10-05 on the ProMotion MacBook's built-in panel (120 Hz) with the 500-node fixture: `make run ARGS="-fixture large -bench YES"` (`App/Mac/Debug/Benchmark.swift`). The bench drives one input per display frame: settle after a reshuffle, 2 s of trackpad pan, 2 s of pinch, a selection every 250 ms with its camera move, a 1 s crowded ⇧-drag, then typing at about 30 characters a second in bursts, so graph rebuilds land between keystrokes. It logs late frames (a display callback more than 1.5 frames after the last), the longest frame interval and main-thread input time per phase, and marks phases with "Bench" signposts. Measure an optimized build: the dev app is `-Onone`, which made the simulation, parser and label code look 10 to 400 times slower than Release (a 500-node paste took 10 s to lay out there, 25 ms optimized). The numbers below come from Debug builds compiled with `-O` and whole-module optimization, before (HEAD at step 5) and after, one run each on the same afternoon. The Mac was busy with a video call (load average about 19), so isolated late frames in every phase, before and after, are system noise; main-thread time is the trustworthy column.

| Phase | Before | After | What changed |
|---|---|---|---|
| Keystroke (main thread, median / worst) | 5.5 / 7.9 ms | 1.8 / 3.8 ms | Title scan stops at the first line; SwiftUI no longer observes `text`; one change report per keystroke, no full-text compare |
| Typing late frames (of 480) | 19 | 12 | Same, plus local motion touches only moved layers |
| Selection longest frame | 80 ms | 22 ms | Labels rasterize in the window's color space as BGRA, so Core Animation no longer converts each new bitmap on the main thread at commit (241 ms → 19 ms of main time over 8 selections) |
| Selection late frames (of 240) | 15 | 6 | Same |
| Settle late frames, longest | 4, 31 ms | 6, 21 ms | Unchanged work (about 0.6 ms main thread per frame) |
| Pan, pinch late frames (of 240) | 0, 5 | 0, 4 | Already compositor-only |
| Crowded drag late frames (of 120), graph frame avg | 2, 0.58 ms | 3, 0.44 ms | Only moved layers are touched |
| Idle CPU, idle wakeups (10 s after freeze, panel on or off) | 0.00–0.01 %, 0/s | 0.00 %, 0/s | Nothing runs: no display link, timer or task |
| Launch CPU (first 10 s) | 0.57–0.84 s | 0.71–0.80 s | Writing Tools off saves about 7 ms |

The remaining post-launch blip, about 16 s after launch, is AppKit's window-restoration snapshot (`NSPersistentUIFileManager` compressing a window image, about 120 ms of CPU, once), not the app or Writing Tools. It is left on, since turning restoration off changes how windows reopen.

## Tried and rejected

Don't reintroduce these without asking.

- Colored boxes or pills around tasks. Color lives in text and lines only.
- A visible root node. The title is a label, not a node.
- Deterministic radial or tree layouts. Too organized; the force layout is the point.
- Tasks interleaved across groups to fake clutter. It made branches unreadable.
- Strict monochrome, mechanical styling.
- Serif fonts. The look calls for relaxed humanist sans.

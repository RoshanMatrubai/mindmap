# Design

The window has two panes. On the left is a plain text editor where you type a to-do list as an indented bullet outline, exactly the way you would in Apple Notes. On the right, that outline is drawn live as a force-directed graph in the style of Obsidian's graph view: groups are big black nodes, tasks and subtasks are smaller gray nodes, lines connect parents to children, and dashed curves connect cross-linked tasks. Clicking a group lights its whole branch in deep purple, dims everything else to about 30%, and zooms the camera to fit that branch. The graph settles once with a short physics animation, then freezes completely. High-priority tasks also appear in the macOS Calendar app.

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

1. **Repel.** Every pair pushes apart with force `repel × alpha / distance²`, ignored beyond 600 units. Group pairs get 1.4× weight. Use Barnes-Hut or a uniform grid once nodes exceed about 300; the prototype is O(n²).
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
| Drag | The dragged node follows the cursor. Its subtree follows on springs with the normal layout constants. Other nodes move only after an overlap joins them to the affected set. On release, pin the dragged node, settle and freeze. |
| Open or switch maps | Display saved positions instantly without animation. Place nodes absent from the sidecar using the add-text rule. |
| Reshuffle or new map without saved positions | Animate the full prototype settle, then freeze. Ease the camera to fit until the user pans or zooms, matching the prototype's `follow` behavior. Reshuffle clears pins. |
| Done toggle | ⇧⌘X replaces ⇧⌘U. The Outline menu owns the shortcut, including while a text view has focus. |

Node identity matches the path key first, then a rename at the same sibling position under the same parent, then an unmatched node with the same name nearest in document order. Unmatched nodes are additions or deletions.

Local relaxation runs springs and repulsion for new, moved and dragged nodes, and collisions for the whole affected free set, against fixed neighbors. A free node's overlapping neighbors join that set and can push further neighbors; nodes that join this way only collide, so they move aside rather than away. Overlaps that already existed between two nodes the change didn't move are tolerated at their starting depth (close pairs may use up the margin) but never made worse, so one change doesn't ripple through the settle's intentional cross-group clutter. Fixed nodes never move. A held drag cools and only pointer motion reheats it. Local settling freezes when nothing moves, or at most 5 s after a release or edit. Neighbor searches use a uniform grid.

An NSView display link exists only while the graph is moving or a drag is active, and stops as soon as the graph freezes. Simulation ticks run off the main thread at a fixed 120 ticks per second, independent of display refresh rate. The main thread applies layer positions once per display frame with implicit Core Animation actions disabled. Occluded windows pause the simulation. Worker frames, snapshots and freeze or pin callbacks carry the document they belong to; after a map switch, results for the previous map are dropped. Labels rasterize off the main thread and cache by text, font, size, scale and style; unchanged node layers are reused.

Step 3b (planned): selection and highlighting, camera fit to a selection, editor↔graph sync, the detail panel, adding and removing nodes from the graph and arrow-key selection navigation. Return adds a task after the selected branch; Tab adds the last child, followed by inline naming. Double-click empty canvas adds a group. Context menus expose the same actions. Delete removes the node and descendants with shared editor undo.

## Settings

These appear in two places, a floating forces panel inside the graph pane (toggled from the toolbar, styled like the prototype's) and the standard Settings window (⌘,). Both edit the same values, and every value persists in app data outside the repo.

| Setting | Range, default | On change |
|---|---|---|
| Text size | 0.6× to 2×, 1× | Resize labels, re-run collision, reheat to 0.25. Does not reshuffle |
| Center | 0 to 0.12, 0.04 | Auto reshuffle |
| Repel | 50 to 2000, 450 | Auto reshuffle |
| Link force | 0.05 to 1.5, 0.6 | Auto reshuffle |
| Link distance | 20 to 200, 70 | Auto reshuffle |
| Urgency | Segmented: pull in / off / push out, pull in | Auto reshuffle |
| Animate settle | On / off, on | Off means compute the layout instantly and show the frozen result |
| Reshuffle | Button | New seed, fresh build |
| Font | Picker (below) | Re-measure labels, re-run collision |
| Show forces panel | On / off | |
| Calendar sync | On / off, off. Further options decided with the user (see [calendar.md](calendar.md)) | Requests calendar access the first time it is turned on |

"Auto reshuffle" means a fresh build with a new seed about 200 ms after the slider stops moving, so dragging doesn't restart the simulation every frame.

The forces panel layout to match is the prototype's `#forces` panel. (The brief referenced a `forces-panel.png` screenshot; it is not in the repo.)

## Fonts

All of these are OFL licensed except the system fonts, so they can ship inside the app bundle with their license files. Prefer variable font files to keep the bundle small (roughly 10 to 15 MB total). Register them with `ATSApplicationFontsPath` in Info.plist. The picker previews each name in its own font, grouped as below. Default: Nunito Sans.

| Group | Fonts |
|---|---|
| System | SF Pro, SF Pro Rounded (`.fontDesign(.rounded)`) |
| Humanist | Nunito Sans, Mulish, Karla, Figtree, Lato, Open Sans, Source Sans 3, Cabin, Red Hat Text, Albert Sans, Atkinson Hyperlegible Next, Inclusive Sans, Reddit Sans, Gantari, Lexend, Readex Pro, Noto Sans, Fira Sans, PT Sans, Public Sans, IBM Plex Sans, Libre Franklin, Overpass, Asap, Encode Sans, Hind, Mukta, Signika, Instrument Sans, Schibsted Grotesk |
| Rounded | Nunito, Quicksand, Varela Round, M PLUS Rounded 1c, Rubik |
| Geometric | Outfit, Manrope, Poppins, Urbanist, Plus Jakarta Sans, DM Sans, Work Sans, Onest, Golos Text, Commissioner, Be Vietnam Pro, Hanken Grotesk, Kumbh Sans |

Verify each license and family name when downloading; drop any that turn out not to be OFL. Add each bundled font to [THIRD_PARTY_NOTICES.md](../THIRD_PARTY_NOTICES.md). The editor uses SF Mono by default so indentation is unambiguous.

## Tried and rejected

Don't reintroduce these without asking.

- Colored boxes or pills around tasks. Color lives in text and lines only.
- A visible root node. The title is a label, not a node.
- Deterministic radial or tree layouts. Too organized; the force layout is the point.
- Tasks interleaved across groups to fake clutter. It made branches unreadable.
- Strict monochrome, mechanical styling.
- Serif fonts. The look calls for relaxed humanist sans.

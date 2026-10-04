# Roadmap (build order)

0. Development environment: project, build commands, tests, CI, agent rules, docs, placeholder window.
1. Editor with Notes-style bullets, the parser, and parser tests (indentation, metadata, links, malformed input).
2. Static graph: parse, run the simulation instantly, draw the frozen result with the layer tree. Pan and zoom. Replaces the placeholder render in `mindmap-preview`.

**3a. Motion:** animated settle and reshuffle, local relaxation on edits and drags, stable node identity, saved positions, fast map switching, mouse-wheel zoom, ⇧⌘X done toggle.

**3b. Interaction (done):** Selection, highlight, camera fit, editor↔graph sync, detail panel, add/rename/remove from the graph, arrow-key navigation, ⇧-drag for subtrees, priority shortcuts.

4. Settings window, forces panel, fonts.
5. Calendar integration for `/high` tasks, after settling its open decisions ([calendar.md](calendar.md)).
6. Performance pass against the 500 node target, then the energy pass.

## Planned shortcuts

- Step 3b (built): Esc clears the selection; Return adds a task; Tab adds a subtask; Delete removes; double-click on empty canvas adds a group; with a node selected, arrows move the selection (↑ parent, ↓ first child, ← → siblings), and without a selection they pan; ⌥⌘1–4 and ⌥⌘0 set or clear the priority; ⇧-drag moves a subtree.
- Step 4: ⌘, opens settings; ⌥⌘F shows or hides the forces panel.

Start each step by raising its open decisions. The user should have a runnable build after step 2 and after every step from then on.

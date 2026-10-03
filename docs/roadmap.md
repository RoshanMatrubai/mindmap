# Roadmap (build order)

0. Development environment: project, build commands, tests, CI, agent rules, docs, placeholder window.
1. Editor with Notes-style bullets, the parser, and parser tests (indentation, metadata, links, malformed input).
2. Static graph: parse, run the simulation instantly, draw the frozen result with the layer tree. Pan and zoom. Replaces the placeholder render in `mindmap-preview`.
3. Animated settle, warm start on edit, selection and highlighting, camera animation, editor sync.
4. Settings window, forces panel, fonts.
5. Calendar integration for `/high` tasks, after settling its open decisions ([calendar.md](calendar.md)).
6. Performance pass against the 500 node target, then the energy pass.

## Planned shortcuts

- Step 3: Esc clears the selection; Return adds a task; Tab adds a subtask; Delete removes; double-click on empty canvas adds a group; with a node selected, arrows move the selection (↑ parent, ↓ first child, ← → siblings), and without a selection they pan.
- Step 4: ⌘, opens settings; ⌥⌘F shows or hides the forces panel.

Start each step by raising its open decisions. The user should have a runnable build after step 2 and after every step from then on.

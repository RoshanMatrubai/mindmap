# Text syntax

The editor behaves like the dashed list in Apple Notes. Map files are plain text with the extension `.mindmap`. The stored dash stays visible as typed, drawn dimmed. For paste compatibility, `* ` works like `- `, and prototype-style star prefixes are accepted (`**` is depth 2, each star adds one level). Store all text exactly as typed; lowercase is for graph labels only.

```
This week

home
- do dishes
- clean room
	- vacuum floor
	- organize desk
- take out trash /tuesday
school
- calc iii work
	- finish pset /friday /medium
	- study for test on curvature /monday /high
	- frq practice [study plan]
study plan
- flashcards
```

| Line | Meaning |
|---|---|
| First non-empty line | Map title. Shown top left of the graph, never a node |
| Line with no bullet | Group (black node) |
| `- text` | Task under the most recent group |
| `- [x] text`, `- [X] text` | Done task, struck through and dimmed in the editor |
| `- [ ] text` | Open task |
| Tab + `- text` (each tab is one level) | Subtask of the task above. Arbitrary depth |
| `/monday` through `/sunday`, `/tomorrow`, `/tmrw`, `/today` | Due date |
| `/10-04-26` | exact due date, month-day-year |
| `/high`, `/medium` (alias `/med`), `/low`, `/chill` | Priority |
| `[name]` | Cross link to any node with that name, drawn as a dashed curve. `[[name]]` works the same |

## Editor key behavior (match Notes)

- Typing `- ` at the start of a line starts a bullet. Show and store the dash as typed.
- **Enter** on a bullet line continues the list: new line with the same indent and `- `. A done line continues as a plain bullet, without its done marker.
- **Enter** on an empty bullet first outdents one level; at level zero it removes the bullet, so the next thing typed becomes a group.
- **Tab** anywhere on a bullet line indents it one level. **Shift+Tab** outdents. With a multi-line selection, apply the change to every selected bullet line.
- Normalize 2 or 4 leading spaces to tabs on paste.
- Lowercase is display only. Store exactly what was typed; render labels lowercase in the graph.

Each key action or paste is one undo step.

## Due dates

Due dates are relative to the injected current day and calendar. A weekday name means its next occurrence, counting today: `/friday` on Friday means today. `/today` means today; `/tomorrow` and its alias `/tmrw` mean the next day. Keep both the resolved day and the raw token.

## Parsing rules

Metadata words are case-insensitive and must be exact known words preceded by whitespace or the start of the line. Unknown words such as `/foo`, and text such as `and/or`, stay in the node name. Priority aliases resolve to the same priority.

The first non-empty line is always the title. Ignore blank lines and accept CRLF. A non-bullet line is a group regardless of indentation. Bullets before any explicit group belong to one implicit group named `loose`, created at the first such line. Tabs each add one indentation level. For spaces, the indentation unit is the smallest nonzero leading-space run in the file, normally 2 or 4 spaces. An indentation jump deeper than the available parent plus one is clamped to parent plus one and produces a warning. Skip lines whose name is empty after metadata and links are removed.

A link is `[name]` or `[[name]]` anywhere in a line, the name being everything inside the brackets. The one exception is `[ ]`, `[x]` or `[X]` right after the bullet, which is the done marker; the same text anywhere else links to a node named `x` (or is ignored if blank). Empty `[]`, blank names and unbalanced brackets stay in the name as text. A single-bracket name can't contain another bracket. Brackets in ordinary text, as in `chapter [3]`, become links too (unresolved when no node matches). The name matches trimmed node names case-insensitively. Prefer a target in the source node's group; otherwise use the first matching node in document order. Ignore self-links. Keep unresolved link names in the model without creating an edge.

Nodes retain their typed names, source line and character range. Their stable path keys use lowercased group/task/subtask names; duplicate paths get `#2`, `#3` suffixes in document order.

# Calendar integration

High-priority tasks also appear in the native macOS Calendar app through EventKit. No third-party services and no network.

## Settled

- Only tasks marked `/high` sync. Everything else stays in the app.
- Sync is driven by the text. Adding `/high` to a task creates its event; removing `/high`, deleting the task, or marking it done removes or completes the event; editing the task text or due date updates the event.
- Events go into a dedicated calendar the app creates (working name "Mindmap"), so they can be toggled together in Calendar and the app never touches other calendars.
- Each synced task stores its event identifier in app data (outside the repo, not in the visible text), so edits map to the right event.
- Sync runs on the same debounced parse that rebuilds the graph, off the main thread. No polling; listen for `EKEventStoreChanged` only if two-way sync is chosen.
- Calendar sync is off by default and requests calendar access the first time it is turned on (see the Settings table in [design.md](design.md)).

## Open decisions (decide with the user before building)

| Decision | Options to present |
|---|---|
| Access level | Write-only access (less intrusive, can't read events back) vs full access (needed for updates, removal and two-way sync), requested only when sync is first turned on |
| Event shape | All-day event on the due date vs a timed block, and if timed, default time and length |
| `/high` tasks with no due date | Skip, put on today, or put on the next free slot |
| Direction | One-way (app to Calendar) vs two-way (moving the event rewrites the due date in the text) |
| Calendar vs Reminders | Calendar events, Reminders (native completion), or both |
| Alerts | None, or an alert some time before |
| Subtasks of a high-priority task | Separate events, folded into the event notes, or ignored |
| Settings surface | Which of these become user settings and which are fixed |

The calendar entitlement is not in the project yet; add it in this step (see [decisions/0001-dev-environment.md](decisions/0001-dev-environment.md)).

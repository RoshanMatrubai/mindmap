# Reminders sync

Tasks marked `/high` appear as high-priority reminders in the native macOS Reminders app through EventKit, in a list the app creates. Sync is one-way, from the map to Reminders. It uses no network or third-party services. Sync is off by default. (It replaced Calendar sync, whose all-day events showed as spanning two days.)

## Hard rule for agents

Agents must never request Reminders or Calendar access, create an `EKEventStore`, run the real store, read or change real reminders, lists, calendars or events, or trigger a macOS Reminders or Calendar permission prompt. Unit tests and the native smoke harness use the in-memory `FakeReminderStore`. Debug builds use it by default. Only the owner may launch the dev app with `-real-reminders YES`; that uses a list named `mindmap dev`, never `mindmap`. Release uses `mindmap`.

All operations go through `ReminderStore`. The real store may list reminder lists to locate its own list, but every reminder fetch and mutation is restricted to that list. It never fetches reminders in other lists or looks up item identifiers globally. A same-name list is not evidence of ownership: the adapter saves the identifier of the list it created and does not adopt somebody else's list.

## Decisions

Full Reminders access (`requestFullAccessToReminders`) is requested only when the user turns sync on. The app includes `NSRemindersFullAccessUsageDescription` and the sandbox entitlement `com.apple.security.personal-information.calendars`, which covers all of EventKit, reminders included; there is no separate reminders entitlement. Launch and automatic sync check the access state without requesting it. Denial appears in the Reminders tab with a button to System Settings > Privacy & Security > Reminders.

Each reminder's title is the task name as typed, its priority is high and its notes contain the `map › group › task` path, a blank line, then its subtasks, with done ones marked. A dated task's reminder is due at the "remind at" time (default 6:30 AM, local time) on its due date, with an absolute alarm at that moment. A `/high` task without a due date gets a reminder with no date and no alarm. A selected synced task says `in reminders: <date and time>` (or `no date`, plus `, completed` when checked off); errors appear in the detail panel and settings status.

`[x]` in the map completes the reminder and removing `[x]` un-completes it. The sidecar records each task's done state at the last sync, and completion is pushed only when that state changed in the map, so a reminder checked off (or un-checked) in Reminders is left alone. Completing a reminder never changes the text. A task that is already done when it first syncs gets no reminder. Removing `/high` or deleting the task removes its reminder. Changing its name, subtasks or due date updates the existing reminder. Node identity uses the same path, sibling rename and same-name move matching as graph layout. Relative due dates are recomputed from today's date using the parser's rules, including weekdays counting today. After a weekday passes, its reminder moves to the next occurrence.

The app creates its dedicated list on first sync, in the account of the default list for new reminders. If that account refuses new lists (Google, Exchange and school accounts can) or there is no default list, it tries iCloud, then On My Mac, then any other CalDAV account, never subscribed or birthday sources, and records the chosen account next to the list identifier. The status line names that account. If no account accepts, the status line says so. EventKit errors never crash the app or stop it from launching; every error goes to the status line. If an expected reminder is missing, the next run recreates it (unless its task is done). If the owned list or its account is deleted, the next run recreates it. Edits in Reminders other than completion are overwritten on the next change.

Turning sync off presents `Remove the mindmap list and its N reminders?` (the dev list is named `mindmap dev`). Cancel preserves sync. Confirm removes the app's list and its reminders, then disables sync. Settings has a Reminders tab with the switch, the "remind at" time and a status line such as `full access · 3 reminders · in iCloud`. Changing the time resyncs every map.

## Migration from Calendar sync

Every sync first checks for `.calendar-store.json`, the Calendar version's ownership file. If it exists and Calendar access is already granted, the calendar with that stored identifier (and with it, its events) is deleted, then the file. Calendar access is never requested; without it the old calendar stays and the file is kept for a later try. The sync switch uses a new UserDefaults key, so after the update sync starts off and turning it on requests Reminders access. Old `.calendar.json` sidecars still load; their event identifiers are dropped.

## Storage and triggers

Sensitive mappings live next to each map in `.<map file name>.calendar.json` (the name is kept from the Calendar version), never in the settings container. The sidecar records node path keys, reminder identifiers, each `/high` task's last synced done state and the previous identity tree; it follows map renames like the layout sidecar. Every reminder also has `mindmap://<url-encoded map file name>/<url-encoded path key>` in its URL so changed identifiers can be recovered inside the dedicated list. List ownership lives in `.reminders-store.json` in the maps folder; it also keeps each reminder's tag, in case EventKit doesn't return a reminder's URL. Only the non-sensitive sync switch and the "remind at" time live in UserDefaults. See [0002](decisions/0002-data-protection.md).

The pure `MindmapCore` planner takes parsed maps, current reminder records, today and the remind-at time, and returns create, update and delete operations. `ReminderSync.run` removes the old calendar, ensures the list, reads it, plans and applies. The app's serial worker parses files, runs that through the store and saves sidecars off the main thread. After each debounced parse, it syncs only the open map. At launch, enable, a remind-at change and `NSCalendarDayChanged`, it syncs every map in the folder and removes reminders tagged with maps that no longer exist. There is no polling, Timer or `EKEventStoreChanged` observer.

Real EventKit execution remains owner-only. Agents verify the fake store, pure planner, app UI and compiled adapter without accessing Reminders or Calendar.

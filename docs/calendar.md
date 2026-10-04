# Calendar integration

Open tasks marked `/high` with a due date appear as all-day events in the native macOS Calendar app through EventKit. Sync is one-way, from the map to Calendar. It uses no network or third-party services, no Reminders and no alerts. Sync is off by default.

## Hard rule for agents

Agents must never request Calendar access, run the real store, read or change real events, or trigger the macOS Calendar permission prompt. Unit tests and the native smoke harness use the in-memory `FakeCalendarStore`. Debug builds use it by default. Only the owner may launch the dev app with `-real-calendar YES`; that uses a calendar named `mindmap dev`, never `mindmap`. Release uses `mindmap`.

All calendar operations go through `CalendarStore`. The real store may list calendars to locate its own calendar, but every event query and mutation is restricted to that calendar. It never enumerates events in other calendars or looks up event identifiers globally. A same-name calendar is not evidence of ownership: the adapter saves the identifier of the calendar it created and does not adopt somebody else's calendar.

## Decisions

Full Calendar access (`requestFullAccessToEvents`) is requested only when the user first turns sync on. The app includes `NSCalendarsFullAccessUsageDescription` and the sandbox entitlement `com.apple.security.personal-information.calendars`. Launch and automatic sync check the access state without requesting it. Denial appears in the Calendar tab with a button to System Settings > Privacy & Security > Calendars.

Each event's title is the task name as typed. Its notes contain the `map › group › task` path, a blank line, then its subtasks, with done ones marked. Events have no alarms. A `/high` task without a due date has no event and its detail panel says `not on calendar: no date`. A selected synced task says `on calendar: <date>`; errors appear in the detail panel and settings status.

Removing `/high`, deleting a task or marking it done removes its event. Changing its name, level or due date updates the existing event. Node identity uses the same path, sibling rename and same-name move matching as graph layout. Relative due dates are recomputed from today's date using the parser's rules, including weekdays counting today. After a weekday passes, its event moves to the next occurrence.

The app creates its dedicated calendar on first sync, in the source of the default calendar for new events. If that account refuses new calendars (Google, Exchange and school accounts can) or there is no default calendar, it tries iCloud, then On My Mac, then any other CalDAV account, never subscribed or birthday sources, and records the chosen source next to the calendar identifier. The status line names that account. If no account accepts, the status line says so; calendar errors never stop the app from launching. If an expected event is missing, the next run recreates it. If the owned calendar or its account is deleted, the next run recreates it. Calendar edits never change map text.

Turning sync off presents `Remove the mindmap calendar and its N events?` (the dev calendar is named `mindmap dev`). Cancel preserves sync. Confirm removes the app's calendar and its events, then disables sync. Settings has a Calendar tab with the switch and a status line showing access, synced event count and last error.

## Storage and triggers

Sensitive mappings live next to each map in `.<map file name>.calendar.json`, never in the settings container. The sidecar records node path keys, event identifiers and the previous identity tree; it follows map renames like the layout sidecar. Every event also has `mindmap://<url-encoded map file name>/<url-encoded path key>` in its URL so changed event identifiers can be recovered inside the dedicated calendar. Calendar ownership and event date scan bounds live in `.calendar-store.json` in the maps folder. Only the non-sensitive sync preference lives in UserDefaults. See [0002](decisions/0002-data-protection.md).

The pure `MindmapCore` planner takes parsed maps, current event records and today, and returns create, update and delete operations. The app's serial worker parses files, applies operations through the store and saves sidecars off the main thread. After each debounced parse, it syncs only the open map. At launch, enable and `NSCalendarDayChanged`, it syncs every map in the folder and removes events tagged with maps that no longer exist. There is no polling, Timer or `EKEventStoreChanged` observer.

Real EventKit execution remains owner-only. Agents verify the fake store, pure planner, app UI and compiled adapter without accessing Calendar.

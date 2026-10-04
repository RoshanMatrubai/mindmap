# Calendar sync implementation

The user supplied the final step 5 design and authorized implementation and fake-only verification. Tasks marked `/high`, open and dated become all-day events in the app's dedicated calendar. The parser's relative-date rules remain unchanged. Sensitive identity mappings, previous identity snapshots and calendar ownership metadata stay in the maps folder.

Implement the pure planner, identity sidecar, store protocol and fake first, with unit coverage for lifecycle, identity, notes, multiple maps, orphan cleanup, rollover, recovery and isolation. Build the EventKit adapter separately without running it. Scope every event query and mutation to the owned calendar, persist ownership next to maps and request access only on explicit enable.

Integrate a serial calendar coordinator with MapStore's debounced parse, launch, enable and day-change triggers. Serialize rename and folder transitions against pending sync work. Add the Calendar settings tab, removal confirmation and selected-task status. Extend the in-app smoke harness using only the fake store.

Verify package tests, Debug build, strict formatting, Release build, preview, native smoke, dev-only screenshots and idle CPU. Report any sandbox denial without bypassing it. Never commit or push.

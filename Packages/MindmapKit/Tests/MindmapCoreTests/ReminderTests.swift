import Foundation
import Testing

@testable import MindmapCore

struct ReminderTests {
  private var calendar: Calendar {
    var value = Calendar(identifier: .gregorian)
    value.timeZone = TimeZone(secondsFromGMT: 0)!
    return value
  }
  private var today: Date { calendar.date(from: DateComponents(year: 2026, month: 10, day: 4))! }
  private func map(
    _ text: String, name: String = "Test.mindmap", sidecar: ReminderSidecar = ReminderSidecar()
  ) -> ReminderMap {
    ReminderMap(
      fileName: name, model: MapParser.parse(text: text, today: today, calendar: calendar),
      sidecar: sidecar)
  }
  private func plan(
    _ maps: [ReminderMap], _ records: [ReminderRecord] = [], day: Date? = nil,
    orphans: Bool = true
  ) -> [ReminderOperation] {
    ReminderSync.plan(
      maps: maps, current: records, today: day ?? today, calendar: calendar, removeOrphans: orphans)
  }
  /// `hour`:`minute` on the day `days` after today, in the test calendar.
  private func at(_ hour: Int, _ minute: Int, days: Int) -> Date {
    calendar.date(byAdding: DateComponents(day: days, hour: hour, minute: minute), to: today)!
  }
  @Test func highTaskCreatesTitleNotesAndDueAt630WithAlarm() async throws {
    let source = map(
      "My Map\nSchool\n- Write Essay /high /tomorrow\n  - Draft\n  - [x] Read Notes\n")
    let store = FakeReminderStore(access: .fullAccess)
    try await store.ensureList()
    let records = try await store.apply(plan([source]))
    let reminder = try #require(records.first?.reminder)
    #expect(reminder.title == "Write Essay")
    #expect(reminder.due == DateComponents(year: 2026, month: 10, day: 5, hour: 6, minute: 30))
    #expect(reminder.alarm == at(6, 30, days: 1))
    #expect(reminder.completed == false)
    #expect(reminder.notes == "My Map › School › Write Essay\n\n- [ ] Draft\n- [x] Read Notes")
    #expect(reminder.url.absoluteString == "mindmap://Test.mindmap/school%2Fwrite%20essay")
    #expect(plan([source], records).isEmpty)
  }
  @Test(arguments: ["- Task /today", ""])
  func removingPriorityOrDeletingRemoves(line: String) async throws {
    let store = FakeReminderStore(access: .fullAccess)
    let records = try await store.apply(plan([map("Map\nGroup\n- Task /high /today")]))
    #expect(plan([map("Map\nGroup\n" + line)], records) == [.delete(records[0].identifier)])
  }
  @Test func undatedHighTaskGetsReminderWithoutDateOrAlarm() async throws {
    let source = map("Map\nGroup /high /today\n- Undated /high\n- Ordinary /today")
    let operations = plan([source])
    guard case .create(let reminder) = try #require(operations.first) else {
      Issue.record("expected create")
      return
    }
    #expect(operations.count == 1)
    #expect(reminder.title == "Undated")
    #expect(reminder.due == nil)
    #expect(reminder.alarm == nil)
    let store = FakeReminderStore(access: .fullAccess)
    let records = try await store.apply(operations)
    let dated = map(
      "Map\nGroup\n- Undated /high /today",
      sidecar: ReminderSync.sidecar(for: source, records: records))
    guard case .update(let update) = try #require(plan([dated], records).first) else {
      Issue.record("expected update")
      return
    }
    #expect(update.reminder.alarm == at(6, 30, days: 0))
    let undated = map("Map\nGroup\n- Undated /high")
    guard case .update(let cleared) = try #require(plan([undated], [update]).first) else {
      Issue.record("expected update")
      return
    }
    #expect(cleared.reminder.due == nil && cleared.reminder.alarm == nil)
  }
  @Test func remindAtSettingMovesDueTimeAndAlarm() async throws {
    let source = map("Map\nGroup\n- Task /high /tomorrow")
    let store = FakeReminderStore(access: .fullAccess)
    let records = try await store.apply(plan([source]))
    let operations = ReminderSync.plan(
      maps: [source], current: records, today: today, calendar: calendar, remindAt: 8 * 60 + 15)
    guard case .update(let update) = try #require(operations.first) else {
      Issue.record("expected update")
      return
    }
    #expect(update.identifier == records[0].identifier)
    #expect(update.reminder.due?.hour == 8 && update.reminder.due?.minute == 15)
    #expect(update.reminder.alarm == at(8, 15, days: 1))
    #expect(ReminderSync.defaultRemindAt == 6 * 60 + 30)
  }
  @Test func doneInMapPushesCompletionOnlyWhenItChanges() async throws {
    let open = map("Map\nGroup\n- Task /high /today")
    let store = FakeReminderStore(access: .fullAccess)
    var records = try await store.apply(plan([open]))
    let done = map(
      "Map\nGroup\n- [x] Task /high /today",
      sidecar: ReminderSync.sidecar(for: open, records: records))
    records = try await store.apply(plan([done], records))
    #expect(records.count == 1)
    #expect(records[0].reminder.completed)
    // Still done: nothing to push, even after the user un-checks it in Reminders.
    let stillDone = map(
      "Map\nGroup\n- [x] Task /high /today",
      sidecar: ReminderSync.sidecar(for: done, records: records))
    #expect(plan([stillDone], records).isEmpty)
    await store.setCompletedOutside(records[0].identifier, false)
    #expect(plan([stillDone], try await store.reminders()).isEmpty)
    // Removing [x] un-completes it.
    await store.setCompletedOutside(records[0].identifier, true)
    let reopened = map("Map\nGroup\n- Task /high /today", sidecar: stillDone.sidecar)
    records = try await store.apply(plan([reopened], try await store.reminders()))
    #expect(records[0].reminder.completed == false)
    // A task created already done gets no reminder.
    #expect(plan([map("Map\nGroup\n- [x] Other /high /today")]).isEmpty)
  }
  @Test func reminderCheckedOffInRemindersIsLeftAlone() async throws {
    let source = map("Map\nGroup\n- Task /high /today")
    let store = FakeReminderStore(access: .fullAccess)
    let records = try await store.apply(plan([source]))
    await store.setCompletedOutside(records[0].identifier, true)
    let saved = map(
      "Map\nGroup\n- Task /high /today",
      sidecar: ReminderSync.sidecar(for: source, records: records))
    #expect(plan([saved], try await store.reminders()).isEmpty)
    // Other edits update the reminder but keep it checked off.
    let renamed = map("Map\nGroup\n- Renamed /high /today", sidecar: saved.sidecar)
    let updated = try await store.apply(plan([renamed], try await store.reminders()))
    #expect(updated[0].reminder.title == "Renamed")
    #expect(updated[0].reminder.completed)
  }
  @Test func firstSyncRemovesOldCalendarThenCreatesReminders() async throws {
    let store = FakeReminderStore(access: .fullAccess, legacyCalendarEvents: 3)
    let result = try await ReminderSync.run(
      store: store, maps: [map("Map\nGroup\n- Task /high /today")], today: today,
      calendar: calendar)
    #expect(await store.legacyCalendarEvents == nil)
    #expect(result.records.count == 1)
    #expect(result.account == "On My Mac")
    let denied = FakeReminderStore(access: .denied, legacyCalendarEvents: 3)
    await #expect(throws: ReminderStoreFailure.accessUnavailable) {
      try await ReminderSync.run(store: denied, maps: [], today: today, calendar: calendar)
    }
    #expect(await denied.legacyCalendarEvents == 3)
  }
  @Test func calendarVersionSidecarStillLoads() throws {
    let json = """
      {"eventIdentifiers":{"group/task":"event-id"},"identity":{"nodes":[{"name":"Group","pathKey":"group"},{"name":"Task","parent":0,"pathKey":"group/task"}],"title":"Map"},"mapFileName":"Test.mindmap","version":1}
      """
    let sidecar = try JSONDecoder().decode(ReminderSidecar.self, from: Data(json.utf8))
    #expect(sidecar.reminderIdentifiers.isEmpty)
    #expect(sidecar.mapFileName == "Test.mindmap")
    #expect(sidecar.previousModel?.nodes.map(\.pathKey) == ["group", "group/task"])
    #expect(plan([map("Map\nGroup\n- Task /high /today", sidecar: sidecar)]).count == 1)
  }
  @Test func renameAndDueChangeKeepIdentifier() async throws {
    let old = map("Map\nGroup\n- Task /high /today")
    let store = FakeReminderStore(access: .fullAccess)
    let records = try await store.apply(plan([old]))
    let next = map(
      "Map\nGroup\n- Renamed /high /tomorrow",
      sidecar: ReminderSync.sidecar(for: old, records: records))
    let operations = plan([next], records)
    guard case .update(let updated) = try #require(operations.first) else {
      Issue.record("expected update")
      return
    }
    #expect(updated.identifier == records[0].identifier)
    #expect(updated.reminder.title == "Renamed")
    #expect(updated.reminder.alarm == at(6, 30, days: 1))
  }
  @Test func indentAndMapRenameKeepIdentifier() async throws {
    let old = map("Map\nGroup\n- Parent\n- Task /high /today")
    let store = FakeReminderStore(access: .fullAccess)
    let records = try await store.apply(plan([old]))
    let next = map(
      "New Map\nGroup\n- Parent\n  - Task /high /today", name: "Renamed.mindmap",
      sidecar: ReminderSync.sidecar(for: old, records: records))
    let operations = plan([next], records)
    guard case .update(let updated) = try #require(operations.first) else {
      Issue.record("expected update")
      return
    }
    #expect(updated.identifier == records[0].identifier)
    #expect(updated.reminder.mapFileName == "Renamed.mindmap")
    #expect(updated.reminder.pathKey == "group/parent/task")
  }
  @Test func multipleMapsAndOrphanCleanupScope() async throws {
    let a = map("A\nGroup\n- Task /high /today", name: "A.mindmap")
    let b = map("B\nGroup\n- Task /high /today", name: "B.mindmap")
    let store = FakeReminderStore(access: .fullAccess)
    let records = try await store.apply(plan([a, b]))
    #expect(records.count == 2)
    #expect(plan([a], records, orphans: false).isEmpty)
    #expect(plan([a], records).count == 1)
    #expect(plan([], records).count == 2)
  }
  @Test func weekdayRollsOverUsingParserRule() async throws {
    let source = map("Map\nGroup\n- Task /high /sunday")
    let store = FakeReminderStore(access: .fullAccess)
    let records = try await store.apply(plan([source]))
    let monday = calendar.date(byAdding: .day, value: 1, to: today)!
    let operations = plan([source], records, day: monday)
    guard case .update(let updated) = try #require(operations.first) else {
      Issue.record("expected update")
      return
    }
    #expect(updated.reminder.alarm == at(6, 30, days: 7))
  }
  @Test func changedIdentifierFoundByTagAndMissingReminderRecreated() async throws {
    let source = map("Map\nGroup\n- Task /high /today")
    let store = FakeReminderStore(access: .fullAccess)
    let records = try await store.apply(plan([source]))
    let saved = map(
      "Map\nGroup\n- Task /high /today",
      sidecar: ReminderSync.sidecar(for: source, records: records))
    let changed = ReminderRecord(identifier: "changed", reminder: records[0].reminder)
    #expect(plan([saved], [changed]).isEmpty)
    #expect(plan([saved], []).count == 1)
    try await store.removeList()
    try await store.ensureList()
    let recreated = try await store.apply(plan([saved], try await store.reminders()))
    #expect(recreated.count == 1)
    #expect(recreated[0].identifier != records[0].identifier)
  }
  @Test func fakeRemovalAndDeniedAccess() async throws {
    let denied = FakeReminderStore(access: .denied)
    #expect(try await denied.requestAccess() == false)
    let store = FakeReminderStore(access: .fullAccess)
    #expect(try await store.requestAccess())
    _ = try await store.apply(plan([map("Map\nGroup\n- Task /high /today")]))
    try await store.removeList()
    #expect(try await store.reminders().isEmpty)
    #expect(await store.listExists == false)
  }
  @Test func sidecarRoundTripAndMove() throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let oldURL = folder.appendingPathComponent("Old.mindmap")
    let newURL = folder.appendingPathComponent("New.mindmap")
    let model = map("Map\nGroup\n- Task /high /today").model
    let sidecar = ReminderSidecar(reminderIdentifiers: ["group/task": "id"], previousModel: model)
    try sidecar.save(for: oldURL)
    #expect(ReminderSidecar.load(for: oldURL)?.reminderIdentifiers == sidecar.reminderIdentifiers)
    #expect(
      ReminderSidecar.load(for: oldURL)?.previousModel?.nodes.map(\.name) == model.nodes.map(\.name)
    )
    try ReminderSidecar.move(from: oldURL, to: newURL)
    #expect(ReminderSidecar.load(for: oldURL) == nil)
    #expect(ReminderSidecar.load(for: newURL)?.reminderIdentifiers == sidecar.reminderIdentifiers)
    #expect(ReminderSidecar.url(for: newURL).lastPathComponent == ".New.mindmap.calendar.json")
  }
  @Test func reminderTagsRoundTripUnicodeAndReservedCharacters() throws {
    let mapName = "é Plan #1?.mindmap"
    let path = "school/Task #2? [x]/résumé"
    let url = Reminder.tagURL(mapFileName: mapName, pathKey: path)
    let decoded = try #require(Reminder.identity(from: url))
    #expect(decoded.mapFileName == mapName)
    #expect(decoded.pathKey == path)
    #expect(Reminder.identity(from: URL(string: "https://example.com/task")!) == nil)
    #expect(Reminder.identity(from: URL(string: "mindmap://missing")!) == nil)
  }

  @Test func subtasksAndRemindersEditsAreOverwrittenOneWay() async throws {
    let old = map("Map\nGroup\n- Task /high /today\n  - Child")
    let store = FakeReminderStore(access: .fullAccess)
    var records = try await store.apply(plan([old]))
    records[0].reminder.title = "Reminders edit"
    let next = map("Map\nGroup\n- Task /high /today\n  - [x] Child\n    - Nested")
    let operations = plan([next], records)
    guard case .update(let update) = try #require(operations.first) else {
      Issue.record("expected update")
      return
    }
    #expect(update.reminder.title == "Task")
    #expect(update.reminder.notes == "Map › Group › Task\n\n- [x] Child\n  - [ ] Nested")
  }

  @Test func duplicateTaskNamesProduceDistinctReminders() async throws {
    let source = map("Map\nGroup\n- Task /high /today\n- Task /high /today")
    let store = FakeReminderStore(access: .fullAccess)
    let records = try await store.apply(plan([source]))
    #expect(records.count == 2)
    #expect(Set(records.map(\.identifier)).count == 2)
    #expect(Set(records.map { $0.reminder.url }).count == 2)
    #expect(plan([source], records).isEmpty)
  }

  @Test func missingIdentifierAfterMapRenameFoundByPreviousTag() async throws {
    let old = map("Map\nGroup\n- Task /high /today")
    let store = FakeReminderStore(access: .fullAccess)
    let records = try await store.apply(plan([old]))
    let next = map(
      "Map\nGroup\n- Task /high /today", name: "Renamed.mindmap",
      sidecar: ReminderSync.sidecar(for: old, records: records))
    let changed = ReminderRecord(identifier: "changed", reminder: records[0].reminder)
    let operations = plan([next], [changed], orphans: false)
    guard case .update(let update) = try #require(operations.first) else {
      Issue.record("expected update")
      return
    }
    #expect(operations.count == 1)
    #expect(update.identifier == "changed")
  }

  @Test func corruptIdentityTreeCannotBeLoaded() throws {
    let json = """
      {"version":1,"eventIdentifiers":{},"identity":{"title":"Map","nodes":[{"pathKey":"task","name":"Task","parent":99}]}}
      """
    #expect(throws: DecodingError.self) {
      try JSONDecoder().decode(ReminderSidecar.self, from: Data(json.utf8))
    }
  }

  @Test func fakeRefusesDeniedAccessAndForeignIdentifiers() async throws {
    let denied = FakeReminderStore(access: .denied)
    await #expect(throws: ReminderStoreFailure.accessUnavailable) {
      try await denied.ensureList()
    }
    await #expect(throws: ReminderStoreFailure.accessUnavailable) { try await denied.reminders() }
    let reminder = Reminder(
      mapFileName: "Test.mindmap", pathKey: "task", title: "Task", notes: "")
    let store = FakeReminderStore(
      access: .fullAccess, records: [ReminderRecord(identifier: "fake-1", reminder: reminder)])
    let records = try await store.apply([.create(reminder)])
    #expect(Set(records.map(\.identifier)).count == 2)
    await #expect(throws: ReminderStoreFailure.foreignIdentifier) {
      try await store.apply([.delete("other-list-id")])
    }
    await #expect(throws: ReminderStoreFailure.foreignIdentifier) {
      try await store.apply([
        .update(ReminderRecord(identifier: "other-list-id", reminder: reminder))
      ])
    }
    #expect(try await store.reminders() == records)
  }

  @Test func duplicateReminderTagsAreCleanedUp() async throws {
    let source = map("Map\nGroup\n- Task /high /today")
    let store = FakeReminderStore(access: .fullAccess)
    let records = try await store.apply(plan([source]))
    let duplicate = ReminderRecord(identifier: "duplicate", reminder: records[0].reminder)
    #expect(plan([source], records + [duplicate]) == [.delete("duplicate")])
  }

  @Test func ancestorRenameAndMoveKeepChildIdentifier() async throws {
    let old = map("Map\nGroup\n- Parent\n  - Task /high /today\nOther")
    let store = FakeReminderStore(access: .fullAccess)
    let records = try await store.apply(plan([old]))
    let next = map(
      "Map\nRenamed Group\n- Renamed Parent\n  - Task /high /today\nOther",
      sidecar: ReminderSync.sidecar(for: old, records: records))
    let updated = try await store.apply(plan([next], records))
    #expect(updated.count == 1)
    #expect(updated[0].identifier == records[0].identifier)
    #expect(updated[0].reminder.pathKey == "renamed group/renamed parent/task")
    let moved = map(
      "Map\nRenamed Group\n- Renamed Parent\nOther\n- Task /high /today",
      sidecar: ReminderSync.sidecar(for: next, records: updated))
    let final = try await store.apply(plan([moved], updated))
    #expect(final.count == 1)
    #expect(final[0].identifier == records[0].identifier)
    #expect(final[0].reminder.pathKey == "other/task")
  }

  @Test func fakePermissionIsExplicitAndStaysInMemory() async throws {
    let store = FakeReminderStore()
    #expect(try await store.accessState() == .notDetermined)
    #expect(await store.accessRequests == 0)
    #expect(try await store.requestAccess())
    #expect(try await store.accessState() == .fullAccess)
    #expect(await store.accessRequests == 1)
  }

  @Test func staleMappingCannotAdoptAnotherMapsReminder() async throws {
    let other = map("Other\nGroup\n- Task /high /today", name: "Other.mindmap")
    let store = FakeReminderStore(access: .fullAccess)
    let records = try await store.apply(plan([other]))
    let source = map(
      "Map\nGroup\n- Task /high /today",
      sidecar: ReminderSidecar(reminderIdentifiers: ["group/task": records[0].identifier]))
    let operations = plan([source], records, orphans: false)
    #expect(operations.count == 1)
    guard case .create(let reminder) = try #require(operations.first) else {
      Issue.record("a stale mapping must create its own reminder")
      return
    }
    #expect(reminder.mapFileName == "Test.mindmap")
    let result = try await store.apply(operations)
    #expect(result.first { $0.identifier == records[0].identifier } == records[0])
  }

  private let google = ReminderSource(identifier: "google", title: "Google", kind: .calDAV)
  private let iCloud = ReminderSource(identifier: "icloud", title: "iCloud", kind: .calDAV)
  private let birthdays = ReminderSource(identifier: "bday", title: "Birthdays", kind: .readOnly)

  @Test func refusedDefaultAccountFallsBackToICloud() async throws {
    let store = FakeReminderStore(
      access: .fullAccess, defaultSource: google,
      sources: [birthdays, FakeReminderStore.onMyMac, google, iCloud], refusing: ["google"])
    #expect(try await store.ensureList() == "iCloud")
    let records = try await store.apply(plan([map("Map\nGroup\n- Task /high /today")]))
    #expect(records.count == 1)
    #expect(await store.listSource == iCloud)
  }

  @Test func noDefaultListUsesFallbackOrder() async throws {
    let store = FakeReminderStore(
      access: .fullAccess, defaultSource: nil, sources: [birthdays, FakeReminderStore.onMyMac])
    #expect(try await store.ensureList() == "On My Mac")
    #expect(
      ReminderSource.candidates(
        remembered: nil, preferred: nil,
        in: [google, birthdays, FakeReminderStore.onMyMac, iCloud]
      ).map(\.identifier)
        == ["icloud", "local", "google"])
  }

  @Test func missingStoredListIsRecreated() async throws {
    let source = map("Map\nGroup\n- Task /high /today")
    let store = FakeReminderStore(access: .fullAccess)
    let records = try await store.apply(plan([source]))
    let saved = map(
      "Map\nGroup\n- Task /high /today",
      sidecar: ReminderSync.sidecar(for: source, records: records))
    await store.deleteListOutside()
    #expect(try await store.ensureList() == "On My Mac")
    let recreated = try await store.apply(plan([saved], try await store.reminders()))
    #expect(recreated.count == 1)
    #expect(await store.listExists)
  }

  @Test func everyAccountRefusingReportsHowToFix() async throws {
    let store = FakeReminderStore(
      access: .fullAccess, defaultSource: google, sources: [google, birthdays],
      refusing: ["google"])
    await #expect(throws: ReminderSourceFailure.noWritableAccount) {
      try await store.ensureList()
    }
    await #expect(throws: ReminderSourceFailure.noWritableAccount) {
      try await store.apply(plan([map("Map\nGroup\n- Task /high /today")]))
    }
    #expect(await store.listExists == false)
    #expect(
      ReminderSourceFailure.noWritableAccount.localizedDescription
        == "couldn't create a reminders list in any account: add an iCloud or On My Mac "
        + "account, then try again")
  }

}

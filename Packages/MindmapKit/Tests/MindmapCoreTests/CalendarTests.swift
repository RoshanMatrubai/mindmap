import Foundation
import Testing

@testable import MindmapCore

struct CalendarTests {
  private var calendar: Calendar {
    var value = Calendar(identifier: .gregorian)
    value.timeZone = TimeZone(secondsFromGMT: 0)!
    return value
  }
  private var today: Date { calendar.date(from: DateComponents(year: 2026, month: 10, day: 4))! }
  private func map(
    _ text: String, name: String = "Test.mindmap", sidecar: CalendarSidecar = CalendarSidecar()
  ) -> CalendarMap {
    CalendarMap(
      fileName: name, model: MapParser.parse(text: text, today: today, calendar: calendar),
      sidecar: sidecar)
  }
  private func plan(
    _ maps: [CalendarMap], _ records: [CalendarEventRecord] = [], day: Date? = nil,
    orphans: Bool = true
  ) -> [CalendarOperation] {
    CalendarSync.plan(
      maps: maps, current: records, today: day ?? today, calendar: calendar, removeOrphans: orphans)
  }
  @Test func highTaskCreatesTypedTitleAllDayAndNotes() async throws {
    let source = map(
      "My Map\nSchool\n- Write Essay /high /tomorrow\n  - Draft\n  - [x] Read Notes\n")
    let store = FakeCalendarStore(access: .fullAccess)
    try await store.ensureCalendar()
    let records = try await store.apply(plan([source]))
    let event = try #require(records.first?.event)
    #expect(event.title == "Write Essay")
    #expect(event.date == calendar.date(byAdding: .day, value: 1, to: today))
    #expect(event.notes == "My Map › School › Write Essay\n\n- [ ] Draft\n- [x] Read Notes")
    #expect(event.url.absoluteString == "mindmap://Test.mindmap/school%2Fwrite%20essay")
    #expect(plan([source], records).isEmpty)
  }
  @Test(arguments: ["- Task /today", "- Task /high", "- [x] Task /high /today", ""])
  func removingPriorityDoneOrDeletedRemoves(line: String) async throws {
    let store = FakeCalendarStore(access: .fullAccess)
    let records = try await store.apply(plan([map("Map\nGroup\n- Task /high /today")]))
    #expect(plan([map("Map\nGroup\n" + line)], records) == [.delete(records[0].identifier)])
  }
  @Test func noDateOrGroupDoesNotCreate() {
    #expect(plan([map("Map\nGroup /high /today\n- Undated /high\n- Ordinary /today")]).isEmpty)
  }
  @Test func renameAndDueChangeKeepIdentifier() async throws {
    let old = map("Map\nGroup\n- Task /high /today")
    let store = FakeCalendarStore(access: .fullAccess)
    let records = try await store.apply(plan([old]))
    let next = map(
      "Map\nGroup\n- Renamed /high /tomorrow",
      sidecar: CalendarSync.sidecar(for: old, records: records))
    let operations = plan([next], records)
    guard case .update(let updated) = try #require(operations.first) else {
      Issue.record("expected update")
      return
    }
    #expect(updated.identifier == records[0].identifier)
    #expect(updated.event.title == "Renamed")
    #expect(updated.event.date == calendar.date(byAdding: .day, value: 1, to: today))
  }
  @Test func indentAndMapRenameKeepIdentifier() async throws {
    let old = map("Map\nGroup\n- Parent\n- Task /high /today")
    let store = FakeCalendarStore(access: .fullAccess)
    let records = try await store.apply(plan([old]))
    let next = map(
      "New Map\nGroup\n- Parent\n  - Task /high /today", name: "Renamed.mindmap",
      sidecar: CalendarSync.sidecar(for: old, records: records))
    let operations = plan([next], records)
    guard case .update(let updated) = try #require(operations.first) else {
      Issue.record("expected update")
      return
    }
    #expect(updated.identifier == records[0].identifier)
    #expect(updated.event.mapFileName == "Renamed.mindmap")
    #expect(updated.event.pathKey == "group/parent/task")
  }
  @Test func multipleMapsAndOrphanCleanupScope() async throws {
    let a = map("A\nGroup\n- Task /high /today", name: "A.mindmap")
    let b = map("B\nGroup\n- Task /high /today", name: "B.mindmap")
    let store = FakeCalendarStore(access: .fullAccess)
    let records = try await store.apply(plan([a, b]))
    #expect(records.count == 2)
    #expect(plan([a], records, orphans: false).isEmpty)
    #expect(plan([a], records).count == 1)
    #expect(plan([], records).count == 2)
  }
  @Test func weekdayRollsOverUsingParserRule() async throws {
    let source = map("Map\nGroup\n- Task /high /sunday")
    let store = FakeCalendarStore(access: .fullAccess)
    let records = try await store.apply(plan([source]))
    let monday = calendar.date(byAdding: .day, value: 1, to: today)!
    let operations = plan([source], records, day: monday)
    guard case .update(let updated) = try #require(operations.first) else {
      Issue.record("expected update")
      return
    }
    #expect(updated.event.date == calendar.date(byAdding: .day, value: 7, to: today))
  }
  @Test func changedIdentifierFoundByTagAndMissingEventRecreated() async throws {
    let source = map("Map\nGroup\n- Task /high /today")
    let store = FakeCalendarStore(access: .fullAccess)
    let records = try await store.apply(plan([source]))
    let saved = map(
      "Map\nGroup\n- Task /high /today",
      sidecar: CalendarSync.sidecar(for: source, records: records))
    let changed = CalendarEventRecord(identifier: "changed", event: records[0].event)
    #expect(plan([saved], [changed]).isEmpty)
    #expect(plan([saved], []).count == 1)
    try await store.removeCalendar()
    try await store.ensureCalendar()
    let recreated = try await store.apply(plan([saved], try await store.events()))
    #expect(recreated.count == 1)
    #expect(recreated[0].identifier != records[0].identifier)
  }
  @Test func fakeRemovalAndDeniedAccess() async throws {
    let denied = FakeCalendarStore(access: .denied)
    #expect(try await denied.requestAccess() == false)
    let store = FakeCalendarStore(access: .fullAccess)
    #expect(try await store.requestAccess())
    _ = try await store.apply(plan([map("Map\nGroup\n- Task /high /today")]))
    try await store.removeCalendar()
    #expect(try await store.events().isEmpty)
    #expect(await store.calendarExists == false)
  }
  @Test func sidecarRoundTripAndMove() throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let oldURL = folder.appendingPathComponent("Old.mindmap")
    let newURL = folder.appendingPathComponent("New.mindmap")
    let model = map("Map\nGroup\n- Task /high /today").model
    let sidecar = CalendarSidecar(eventIdentifiers: ["group/task": "id"], previousModel: model)
    try sidecar.save(for: oldURL)
    #expect(CalendarSidecar.load(for: oldURL)?.eventIdentifiers == sidecar.eventIdentifiers)
    #expect(
      CalendarSidecar.load(for: oldURL)?.previousModel?.nodes.map(\.name) == model.nodes.map(\.name)
    )
    try CalendarSidecar.move(from: oldURL, to: newURL)
    #expect(CalendarSidecar.load(for: oldURL) == nil)
    #expect(CalendarSidecar.load(for: newURL)?.eventIdentifiers == sidecar.eventIdentifiers)
    #expect(CalendarSidecar.url(for: newURL).lastPathComponent == ".New.mindmap.calendar.json")
  }
  @Test func eventTagsRoundTripUnicodeAndReservedCharacters() throws {
    let mapName = "é Plan #1?.mindmap"
    let path = "school/Task #2? [x]/résumé"
    let url = CalendarEvent.tagURL(mapFileName: mapName, pathKey: path)
    let decoded = try #require(CalendarEvent.identity(from: url))
    #expect(decoded.mapFileName == mapName)
    #expect(decoded.pathKey == path)
    #expect(CalendarEvent.identity(from: URL(string: "https://example.com/task")!) == nil)
    #expect(CalendarEvent.identity(from: URL(string: "mindmap://missing")!) == nil)
  }

  @Test func subtasksAndCalendarEditsAreOverwrittenOneWay() async throws {
    let old = map("Map\nGroup\n- Task /high /today\n  - Child")
    let store = FakeCalendarStore(access: .fullAccess)
    var records = try await store.apply(plan([old]))
    records[0].event.title = "Calendar edit"
    let next = map("Map\nGroup\n- Task /high /today\n  - [x] Child\n    - Nested")
    let operations = plan([next], records)
    guard case .update(let update) = try #require(operations.first) else {
      Issue.record("expected update")
      return
    }
    #expect(update.event.title == "Task")
    #expect(update.event.notes == "Map › Group › Task\n\n- [x] Child\n  - [ ] Nested")
  }

  @Test func duplicateTaskNamesProduceDistinctEvents() async throws {
    let source = map("Map\nGroup\n- Task /high /today\n- Task /high /today")
    let store = FakeCalendarStore(access: .fullAccess)
    let records = try await store.apply(plan([source]))
    #expect(records.count == 2)
    #expect(Set(records.map(\.identifier)).count == 2)
    #expect(Set(records.map { $0.event.url }).count == 2)
    #expect(plan([source], records).isEmpty)
  }

  @Test func missingIdentifierAfterMapRenameFoundByPreviousTag() async throws {
    let old = map("Map\nGroup\n- Task /high /today")
    let store = FakeCalendarStore(access: .fullAccess)
    let records = try await store.apply(plan([old]))
    let next = map(
      "Map\nGroup\n- Task /high /today", name: "Renamed.mindmap",
      sidecar: CalendarSync.sidecar(for: old, records: records))
    let changed = CalendarEventRecord(identifier: "changed", event: records[0].event)
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
      try JSONDecoder().decode(CalendarSidecar.self, from: Data(json.utf8))
    }
  }

  @Test func fakeRefusesDeniedAccessAndForeignIdentifiers() async throws {
    let denied = FakeCalendarStore(access: .denied)
    await #expect(throws: CalendarStoreFailure.accessUnavailable) {
      try await denied.ensureCalendar()
    }
    await #expect(throws: CalendarStoreFailure.accessUnavailable) { try await denied.events() }
    let event = CalendarEvent(
      mapFileName: "Test.mindmap", pathKey: "task", title: "Task", date: today, notes: "")
    let store = FakeCalendarStore(
      access: .fullAccess, records: [CalendarEventRecord(identifier: "fake-1", event: event)])
    let records = try await store.apply([.create(event)])
    #expect(Set(records.map(\.identifier)).count == 2)
    await #expect(throws: CalendarStoreFailure.foreignIdentifier) {
      try await store.apply([.delete("other-calendar-id")])
    }
    await #expect(throws: CalendarStoreFailure.foreignIdentifier) {
      try await store.apply([
        .update(CalendarEventRecord(identifier: "other-calendar-id", event: event))
      ])
    }
    #expect(try await store.events() == records)
  }

  @Test func duplicateEventTagsAreCleanedUp() async throws {
    let source = map("Map\nGroup\n- Task /high /today")
    let store = FakeCalendarStore(access: .fullAccess)
    let records = try await store.apply(plan([source]))
    let duplicate = CalendarEventRecord(identifier: "duplicate", event: records[0].event)
    #expect(plan([source], records + [duplicate]) == [.delete("duplicate")])
  }

  @Test func ancestorRenameAndMoveKeepChildIdentifier() async throws {
    let old = map("Map\nGroup\n- Parent\n  - Task /high /today\nOther")
    let store = FakeCalendarStore(access: .fullAccess)
    let records = try await store.apply(plan([old]))
    let next = map(
      "Map\nRenamed Group\n- Renamed Parent\n  - Task /high /today\nOther",
      sidecar: CalendarSync.sidecar(for: old, records: records))
    let updated = try await store.apply(plan([next], records))
    #expect(updated.count == 1)
    #expect(updated[0].identifier == records[0].identifier)
    #expect(updated[0].event.pathKey == "renamed group/renamed parent/task")
    let moved = map(
      "Map\nRenamed Group\n- Renamed Parent\nOther\n- Task /high /today",
      sidecar: CalendarSync.sidecar(for: next, records: updated))
    let final = try await store.apply(plan([moved], updated))
    #expect(final.count == 1)
    #expect(final[0].identifier == records[0].identifier)
    #expect(final[0].event.pathKey == "other/task")
  }

  @Test func fakePermissionIsExplicitAndStaysInMemory() async throws {
    let store = FakeCalendarStore()
    #expect(try await store.accessState() == .notDetermined)
    #expect(await store.accessRequests == 0)
    #expect(try await store.requestAccess())
    #expect(try await store.accessState() == .fullAccess)
    #expect(await store.accessRequests == 1)
  }

  @Test func staleMappingCannotAdoptAnotherMapsEvent() async throws {
    let other = map("Other\nGroup\n- Task /high /today", name: "Other.mindmap")
    let store = FakeCalendarStore(access: .fullAccess)
    let records = try await store.apply(plan([other]))
    let source = map(
      "Map\nGroup\n- Task /high /today",
      sidecar: CalendarSidecar(eventIdentifiers: ["group/task": records[0].identifier]))
    let operations = plan([source], records, orphans: false)
    #expect(operations.count == 1)
    guard case .create(let event) = try #require(operations.first) else {
      Issue.record("a stale mapping must create its own event")
      return
    }
    #expect(event.mapFileName == "Test.mindmap")
    let result = try await store.apply(operations)
    #expect(result.first { $0.identifier == records[0].identifier } == records[0])
  }

  private let google = CalendarSource(identifier: "google", title: "Google", kind: .calDAV)
  private let iCloud = CalendarSource(identifier: "icloud", title: "iCloud", kind: .calDAV)
  private let birthdays = CalendarSource(identifier: "bday", title: "Birthdays", kind: .readOnly)

  @Test func refusedDefaultAccountFallsBackToICloud() async throws {
    let store = FakeCalendarStore(
      access: .fullAccess, defaultSource: google,
      sources: [birthdays, FakeCalendarStore.onMyMac, google, iCloud], refusing: ["google"])
    #expect(try await store.ensureCalendar() == "iCloud")
    let records = try await store.apply(plan([map("Map\nGroup\n- Task /high /today")]))
    #expect(records.count == 1)
    #expect(await store.calendarSource == iCloud)
  }

  @Test func noDefaultCalendarUsesFallbackOrder() async throws {
    let store = FakeCalendarStore(
      access: .fullAccess, defaultSource: nil, sources: [birthdays, FakeCalendarStore.onMyMac])
    #expect(try await store.ensureCalendar() == "On My Mac")
    #expect(
      CalendarSource.candidates(
        remembered: nil, preferred: nil,
        in: [google, birthdays, FakeCalendarStore.onMyMac, iCloud]
      ).map(\.identifier)
        == ["icloud", "local", "google"])
  }

  @Test func missingStoredCalendarIsRecreated() async throws {
    let source = map("Map\nGroup\n- Task /high /today")
    let store = FakeCalendarStore(access: .fullAccess)
    let records = try await store.apply(plan([source]))
    let saved = map(
      "Map\nGroup\n- Task /high /today",
      sidecar: CalendarSync.sidecar(for: source, records: records))
    await store.deleteCalendarOutside()
    #expect(try await store.ensureCalendar() == "On My Mac")
    let recreated = try await store.apply(plan([saved], try await store.events()))
    #expect(recreated.count == 1)
    #expect(await store.calendarExists)
  }

  @Test func everyAccountRefusingReportsHowToFix() async throws {
    let store = FakeCalendarStore(
      access: .fullAccess, defaultSource: google, sources: [google, birthdays],
      refusing: ["google"])
    await #expect(throws: CalendarSourceFailure.noWritableAccount) {
      try await store.ensureCalendar()
    }
    await #expect(throws: CalendarSourceFailure.noWritableAccount) {
      try await store.apply(plan([map("Map\nGroup\n- Task /high /today")]))
    }
    #expect(await store.calendarExists == false)
    #expect(
      CalendarSourceFailure.noWritableAccount.localizedDescription
        == "couldn't create a calendar in any account: add an iCloud or On My Mac calendar "
        + "account, then try again")
  }

}

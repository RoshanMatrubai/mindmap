import EventKit
import Foundation
import MindmapCore

/// EventKit stays confined to this worker actor. The dev app uses FakeReminderStore unless
/// its owner explicitly launches it with -real-reminders YES. Never exercise this store in tests.
actor EventKitReminderStore: ReminderStore {
  private struct Ownership: Codable {
    var identifier: String
    /// The account the list was created in.
    var source: String?
    /// Each reminder's tag, for when EventKit doesn't hand back a reminder's url.
    var tags: [String: URL]?
  }

  /// What the Calendar version of the app wrote in `.calendar-store.json`.
  private struct LegacyCalendar: Codable {
    var identifier: String
  }

  private enum StoreError: LocalizedError {
    case accessRequired, missingIdentifier, ownershipConflict

    var errorDescription: String? {
      switch self {
      case .accessRequired: "Reminders full access is required."
      case .missingIdentifier: "Reminders did not return an account identifier."
      case .ownershipConflict: "The selected maps folder already owns a different list."
      }
    }
  }

  /// Lets the fetched reminders cross EventKit's completion handler back into this actor.
  private struct Fetched: @unchecked Sendable { var reminders: [EKReminder] }

  private static let ownershipFile = ".reminders-store.json"
  private static let legacyFile = ".calendar-store.json"
  private var folder: URL
  private let name: String
  private var eventStore: EKEventStore?
  private var ownership: Ownership?
  private var ownershipLoaded = false

  init(folder: URL, name: String) {
    self.folder = folder
    self.name = name
  }

  /// Move ownership while both folders still have security-scoped access. This only moves
  /// maps-folder metadata and neither initializes EventKit nor requests access.
  func relocate(to newFolder: URL) throws {
    guard newFolder != folder else { return }
    try loadOwnership()
    let manager = FileManager.default
    let target = newFolder.appendingPathComponent(Self.ownershipFile)
    if let ownership, manager.fileExists(atPath: target.path) {
      let other = try JSONDecoder().decode(Ownership.self, from: Data(contentsOf: target))
      if other.identifier != ownership.identifier { throw StoreError.ownershipConflict }
    }
    for file in [Self.ownershipFile, Self.legacyFile] {
      let old = folder.appendingPathComponent(file)
      let new = newFolder.appendingPathComponent(file)
      guard manager.fileExists(atPath: old.path) else { continue }
      if manager.fileExists(atPath: new.path) {
        try manager.removeItem(at: old)
      } else {
        try manager.moveItem(at: old, to: new)
      }
    }
    folder = newFolder
    ownership = nil
    ownershipLoaded = false
  }

  func accessState() -> ReminderAccessState {
    switch EKEventStore.authorizationStatus(for: .reminder) {
    case .notDetermined: .notDetermined
    case .fullAccess: .fullAccess
    case .restricted: .restricted
    default: .denied
    }
  }

  /// Called only when the user explicitly enables sync, never from launch or a parse.
  func requestAccess() async throws -> Bool {
    if accessState() == .fullAccess { return true }
    return try await withCheckedThrowingContinuation { continuation in
      store().requestFullAccessToReminders { granted, error in
        if let error {
          continuation.resume(throwing: error)
        } else {
          continuation.resume(returning: granted)
        }
      }
    }
  }

  /// Deletes the calendar the Calendar version created, found only by its stored identifier.
  /// It uses Calendar access the user already granted and never requests it.
  func removeLegacyCalendar() throws {
    let url = folder.appendingPathComponent(Self.legacyFile)
    guard FileManager.default.fileExists(atPath: url.path),
      EKEventStore.authorizationStatus(for: .event) == .fullAccess
    else { return }
    let legacy = try JSONDecoder().decode(LegacyCalendar.self, from: Data(contentsOf: url))
    if let calendar = store().calendars(for: .event).first(where: {
      $0.calendarIdentifier == legacy.identifier
    }) {
      try store().removeCalendar(calendar, commit: true)
    }
    try FileManager.default.removeItem(at: url)
  }

  @discardableResult func ensureList() throws -> String {
    try requireAccess()
    if let list = try ownedList() {
      // EKCalendar.source is implicitly unwrapped; never let it trap.
      return list.source.map(Self.source)?.title ?? name
    }
    // The stored list or its account is gone, or none was made yet: create a new one.
    let store = store()
    let candidates = ReminderSource.candidates(
      remembered: ownership?.source,
      preferred: store.defaultCalendarForNewReminders()?.source.map(Self.source),
      in: store.sources.map(Self.source))
    let (chosen, list) = try ReminderSource.create(in: candidates) { candidate in
      guard let source = store.sources.first(where: { $0.sourceIdentifier == candidate.identifier })
      else { throw StoreError.missingIdentifier }
      let list = EKCalendar(for: .reminder, eventStore: store)
      list.title = name
      list.source = source
      do {
        try store.saveCalendar(list, commit: true)
      } catch {
        // Drop the refused list so it isn't retried with the next account's commit.
        store.reset()
        throw error
      }
      return list
    }
    ownership = Ownership(identifier: list.calendarIdentifier, source: chosen.identifier)
    do {
      try saveOwnership()
    } catch {
      // Without the ownership file a later launch cannot safely find this list.
      try? store.removeCalendar(list, commit: true)
      ownership = nil
      throw error
    }
    return chosen.title
  }

  func reminders() async throws -> [ReminderRecord] {
    try requireAccess()
    guard let list = try ownedList() else { return [] }
    return await fetch(list).compactMap(record)
  }

  func apply(_ operations: [ReminderOperation]) async throws -> [ReminderRecord] {
    try ensureList()
    guard let list = try ownedList() else { return [] }
    let store = store()
    var existing: [String: EKReminder] = [:]
    for reminder in await fetch(list) where record(reminder) != nil {
      existing[reminder.calendarItemIdentifier] = reminder
    }
    var tags = ownership?.tags ?? [:]
    defer {
      ownership?.tags = tags
      try? saveOwnership()
    }
    for operation in operations {
      switch operation {
      case .create(let value):
        tags[try write(value, to: EKReminder(eventStore: store), list: list)] = value.url
      case .update(let value):
        // Only reminders fetched from the own list can be updated. A missing one is
        // recreated, without the global calendarItem(withIdentifier:) lookup.
        let reminder = existing[value.identifier] ?? EKReminder(eventStore: store)
        tags[try write(value.reminder, to: reminder, list: list)] = value.reminder.url
      case .delete(let identifier):
        if let reminder = existing[identifier] { try store.remove(reminder, commit: true) }
        tags[identifier] = nil
      }
    }
    let records = try await reminders()
    let remaining = Set(records.map(\.identifier))
    tags = tags.filter { remaining.contains($0.key) }
    return records
  }

  func removeList() throws {
    try requireAccess()
    if let list = try ownedList() {
      try store().removeCalendar(list, commit: true)
    }
    if FileManager.default.fileExists(atPath: ownershipURL.path) {
      try FileManager.default.removeItem(at: ownershipURL)
    }
    ownership = nil
  }

  private static func source(_ source: EKSource) -> ReminderSource {
    let kind: ReminderSource.Kind =
      switch source.sourceType {
      case .local: .local
      case .calDAV: .calDAV
      case .subscribed, .birthdays: .readOnly
      default: .other
      }
    return ReminderSource(
      identifier: source.sourceIdentifier,
      title: kind == .local ? "On My Mac" : source.title, kind: kind)
  }

  private var ownershipURL: URL { folder.appendingPathComponent(Self.ownershipFile) }

  private func store() -> EKEventStore {
    if let eventStore { return eventStore }
    let value = EKEventStore()
    eventStore = value
    return value
  }

  private func requireAccess() throws {
    guard accessState() == .fullAccess else { throw StoreError.accessRequired }
  }

  private func loadOwnership() throws {
    if !ownershipLoaded {
      if FileManager.default.fileExists(atPath: ownershipURL.path) {
        ownership = try JSONDecoder().decode(
          Ownership.self, from: Data(contentsOf: ownershipURL))
      }
      ownershipLoaded = true
    }
  }

  private func ownedList() throws -> EKCalendar? {
    try loadOwnership()
    guard let ownership else { return nil }
    // A name alone is never proof of ownership. Do not adopt a user's same-name list.
    return store().calendars(for: .reminder).first {
      $0.calendarIdentifier == ownership.identifier
    }
  }

  private func saveOwnership() throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    try encoder.encode(ownership).write(to: ownershipURL, options: .atomic)
  }

  /// Every reminder in the app's list, completed or not.
  private func fetch(_ list: EKCalendar) async -> [EKReminder] {
    let store = store()
    let predicate = store.predicateForReminders(in: [list])
    let fetched = await withCheckedContinuation { continuation in
      _ = store.fetchReminders(matching: predicate) {
        continuation.resume(returning: Fetched(reminders: $0 ?? []))
      }
    }
    return fetched.reminders.filter { $0.calendar?.calendarIdentifier == list.calendarIdentifier }
  }

  /// Saves the reminder and returns its identifier.
  private func write(_ value: Reminder, to reminder: EKReminder, list: EKCalendar) throws -> String
  {
    reminder.calendar = list
    reminder.title = value.title
    reminder.notes = value.notes
    reminder.url = value.url
    reminder.priority = Int(EKReminderPriority.high.rawValue)
    reminder.dueDateComponents = value.due
    reminder.alarms = value.alarm.map { [EKAlarm(absoluteDate: $0)] }
    reminder.isCompleted = value.completed
    try store().save(reminder, commit: true)
    return reminder.calendarItemIdentifier
  }

  private func record(_ reminder: EKReminder) -> ReminderRecord? {
    let identifier = reminder.calendarItemIdentifier
    guard let url = reminder.url ?? ownership?.tags?[identifier],
      let identity = Reminder.identity(from: url)
    else { return nil }
    var value = Reminder(
      mapFileName: identity.mapFileName, pathKey: identity.pathKey,
      title: reminder.title ?? "", notes: reminder.notes ?? "", due: reminder.dueDateComponents,
      alarm: reminder.alarms?.first?.absoluteDate, completed: reminder.isCompleted)
    value.url = url
    return ReminderRecord(identifier: identifier, reminder: value)
  }
}

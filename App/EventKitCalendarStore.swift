import EventKit
import Foundation
import MindmapCore

/// EventKit stays confined to this worker actor. The dev app uses FakeCalendarStore unless
/// its owner explicitly launches it with -real-calendar YES. Never exercise this store in tests.
actor EventKitCalendarStore: CalendarStore {
  private struct Ownership: Codable {
    var identifier: String
    var earliest: Date
    var latest: Date
  }

  private enum StoreError: LocalizedError {
    case accessRequired, noDefaultSource, missingIdentifier, invalidDate, ownershipConflict

    var errorDescription: String? {
      switch self {
      case .accessRequired: "Calendar full access is required."
      case .noDefaultSource: "No default calendar source is available."
      case .missingIdentifier: "Calendar did not return an event identifier."
      case .invalidDate: "The calendar event date is invalid."
      case .ownershipConflict: "The selected maps folder already owns a different calendar."
      }
    }
  }

  private var folder: URL
  private let name: String
  private var eventStore: EKEventStore?
  private var ownership: Ownership?
  private var ownershipLoaded = false

  init(folder: URL, name: String) {
    self.folder = folder
    self.name = name
  }

  /// Move ownership while both folders still have security-scoped access. This only copies
  /// maps-folder metadata and neither initializes EventKit nor requests calendar access.
  func relocate(to newFolder: URL) throws {
    guard newFolder != folder else { return }
    try loadOwnership()
    let oldURL = ownershipURL
    let target = newFolder.appendingPathComponent(".calendar-store.json")
    var movingOwnership = ownership
    if FileManager.default.fileExists(atPath: target.path) {
      let other = try JSONDecoder().decode(Ownership.self, from: Data(contentsOf: target))
      if let movingOwnership, other.identifier != movingOwnership.identifier {
        throw StoreError.ownershipConflict
      }
      if var current = movingOwnership {
        current.earliest = min(current.earliest, other.earliest)
        current.latest = max(current.latest, other.latest)
        movingOwnership = current
      } else {
        movingOwnership = other
      }
    }
    if let movingOwnership {
      let encoder = JSONEncoder()
      encoder.outputFormatting = [.sortedKeys]
      try encoder.encode(movingOwnership).write(to: target, options: .atomic)
    }
    if FileManager.default.fileExists(atPath: oldURL.path) {
      try FileManager.default.removeItem(at: oldURL)
    }
    ownership = movingOwnership
    folder = newFolder
  }

  func accessState() -> CalendarAccessState {
    switch EKEventStore.authorizationStatus(for: .event) {
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
      store().requestFullAccessToEvents { granted, error in
        if let error {
          continuation.resume(throwing: error)
        } else {
          continuation.resume(returning: granted)
        }
      }
    }
  }

  func ensureCalendar() throws {
    try requireAccess()
    if try ownedCalendar() != nil { return }
    let store = store()
    guard let source = store.defaultCalendarForNewEvents?.source else {
      throw StoreError.noDefaultSource
    }
    let calendar = EKCalendar(for: .event, eventStore: store)
    calendar.title = name
    calendar.source = source
    try store.saveCalendar(calendar, commit: true)
    let today = Calendar.current.startOfDay(for: Date())
    ownership = Ownership(identifier: calendar.calendarIdentifier, earliest: today, latest: today)
    do {
      try saveOwnership()
    } catch {
      // Without the ownership file a later launch cannot safely find this calendar.
      try? store.removeCalendar(calendar, commit: true)
      ownership = nil
      throw error
    }
  }

  func events() throws -> [CalendarEventRecord] {
    try requireAccess()
    guard let calendar = try ownedCalendar() else { return [] }
    return try scan(calendar).compactMap(record)
  }

  func apply(_ operations: [CalendarOperation]) throws -> [CalendarEventRecord] {
    try ensureCalendar()
    guard let calendar = try ownedCalendar() else { return [] }
    let store = store()
    var existing: [String: EKEvent] = [:]
    for event in try scan(calendar) {
      if let identifier = event.eventIdentifier, record(event) != nil {
        existing[identifier] = event
      }
    }
    for operation in operations {
      switch operation {
      case .create(let value):
        let event = EKEvent(eventStore: store)
        try write(value, to: event, calendar: calendar)
      case .update(let value):
        // Only events found by the own-calendar predicate can be updated. A missing event
        // is recreated, without the global event(withIdentifier:) lookup.
        let event = existing[value.identifier] ?? EKEvent(eventStore: store)
        try write(value.event, to: event, calendar: calendar)
      case .delete(let identifier):
        if let event = existing[identifier] {
          try store.remove(event, span: .thisEvent, commit: true)
        }
      }
    }
    return try events()
  }

  func removeCalendar() throws {
    try requireAccess()
    if let calendar = try ownedCalendar() {
      try store().removeCalendar(calendar, commit: true)
    }
    if FileManager.default.fileExists(atPath: ownershipURL.path) {
      try FileManager.default.removeItem(at: ownershipURL)
    }
    ownership = nil
  }

  private var ownershipURL: URL { folder.appendingPathComponent(".calendar-store.json") }

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

  private func ownedCalendar() throws -> EKCalendar? {
    try loadOwnership()
    guard let ownership else { return nil }
    // A name alone is never proof of ownership. Do not adopt a user's same-name calendar.
    return store().calendars(for: .event).first {
      $0.calendarIdentifier == ownership.identifier
    }
  }

  private func saveOwnership() throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    try encoder.encode(ownership).write(to: ownershipURL, options: .atomic)
  }

  /// Saved bounds include every day this app has written, so old and orphaned events are
  /// still discoverable. Each predicate covers less than EventKit's four-year maximum.
  private func scan(_ calendar: EKCalendar) throws -> [EKEvent] {
    guard let ownership else { return [] }
    let civil = Calendar.current
    let today = civil.startOfDay(for: Date())
    guard ownership.earliest.timeIntervalSinceReferenceDate.isFinite,
      ownership.latest.timeIntervalSinceReferenceDate.isFinite,
      let end = civil.date(byAdding: .day, value: 2, to: max(today, ownership.latest))
    else { throw StoreError.invalidDate }
    var cursor = civil.startOfDay(for: min(today, ownership.earliest))
    var result: [String: EKEvent] = [:]
    while cursor < end {
      guard let next = civil.date(byAdding: .year, value: 3, to: cursor) else {
        throw StoreError.invalidDate
      }
      let upper = min(end, next)
      let predicate = store().predicateForEvents(
        withStart: cursor, end: upper, calendars: [calendar])
      for event in store().events(matching: predicate) {
        guard event.calendar.calendarIdentifier == calendar.calendarIdentifier,
          let identifier = event.eventIdentifier
        else { continue }
        result[identifier] = event
      }
      cursor = upper
    }
    return Array(result.values)
  }

  private func write(_ value: CalendarEvent, to event: EKEvent, calendar: EKCalendar) throws {
    let civil = Calendar.current
    let start = civil.startOfDay(for: value.date)
    guard start.timeIntervalSinceReferenceDate.isFinite,
      let end = civil.date(byAdding: .day, value: 1, to: start)
    else { throw StoreError.invalidDate }
    // Record bounds before committing an event, including a crash between the two writes.
    ownership?.earliest = min(ownership?.earliest ?? start, start)
    ownership?.latest = max(ownership?.latest ?? start, start)
    try saveOwnership()
    event.calendar = calendar
    event.title = value.title
    event.notes = value.notes
    event.url = value.url
    event.isAllDay = true
    event.startDate = start
    event.endDate = end
    event.alarms = nil
    event.recurrenceRules = nil
    try store().save(event, span: .thisEvent, commit: true)
    guard event.eventIdentifier != nil else { throw StoreError.missingIdentifier }
  }

  private func record(_ event: EKEvent) -> CalendarEventRecord? {
    guard let identifier = event.eventIdentifier, let url = event.url,
      let identity = CalendarEvent.identity(from: url), let date = event.startDate
    else { return nil }
    var value = CalendarEvent(
      mapFileName: identity.mapFileName, pathKey: identity.pathKey,
      title: event.title ?? "", date: date, notes: event.notes ?? "")
    value.url = url
    return CalendarEventRecord(identifier: identifier, event: value)
  }
}

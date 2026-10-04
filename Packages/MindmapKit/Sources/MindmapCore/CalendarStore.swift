import Foundation

public enum CalendarAccessState: String, Sendable, Equatable {
  case notDetermined, fullAccess, denied, restricted
}

public enum CalendarStoreFailure: Error, Sendable, Equatable {
  case accessUnavailable
  case foreignIdentifier
}

/// This boundary exposes only the calendar created by the app. Implementations must never read
/// or mutate events in another calendar, including when looking up an event identifier.
public protocol CalendarStore: Sendable {
  func accessState() async throws -> CalendarAccessState
  func requestAccess() async throws -> Bool
  func ensureCalendar() async throws
  func events() async throws -> [CalendarEventRecord]
  /// Applies a plan and returns all event records remaining in the app's calendar.
  func apply(_ operations: [CalendarOperation]) async throws -> [CalendarEventRecord]
  func removeCalendar() async throws
}

/// In-memory store for unit tests and the default Debug app. It has no EventKit dependency and
/// cannot request macOS Calendar permission or access the user's calendars.
public actor FakeCalendarStore: CalendarStore {
  public private(set) var calendarExists = false
  public private(set) var accessRequests = 0
  public private(set) var appliedOperations: [CalendarOperation] = []
  private var access: CalendarAccessState
  private var records: [CalendarEventRecord]
  private var sequence = 0

  public init(access: CalendarAccessState = .notDetermined, records: [CalendarEventRecord] = []) {
    self.access = access
    self.records = records
    calendarExists = !records.isEmpty
  }

  public func accessState() async throws -> CalendarAccessState { access }

  public func requestAccess() async throws -> Bool {
    accessRequests += 1
    if access == .notDetermined { access = .fullAccess }
    return access == .fullAccess
  }

  private func requireAccess() throws {
    guard access == .fullAccess else { throw CalendarStoreFailure.accessUnavailable }
  }

  public func ensureCalendar() async throws {
    try requireAccess()
    calendarExists = true
  }

  public func events() async throws -> [CalendarEventRecord] {
    try requireAccess()
    return records
  }

  public func apply(_ operations: [CalendarOperation]) async throws -> [CalendarEventRecord] {
    try requireAccess()
    // Validate identifiers against this calendar before any mutation. An identifier from another
    // calendar cannot be used to reach it through this boundary.
    let owned = Set(records.map(\.identifier))
    for operation in operations {
      switch operation {
      case .create: break
      case .update(let record):
        guard owned.contains(record.identifier) else {
          throw CalendarStoreFailure.foreignIdentifier
        }
      case .delete(let identifier):
        guard owned.contains(identifier) else { throw CalendarStoreFailure.foreignIdentifier }
      }
    }
    calendarExists = true
    for operation in operations {
      switch operation {
      case .create(let event):
        repeat { sequence += 1 } while records.contains { $0.identifier == "fake-\(sequence)" }
        records.append(CalendarEventRecord(identifier: "fake-\(sequence)", event: event))
      case .update(let record):
        if let index = records.firstIndex(where: { $0.identifier == record.identifier }) {
          records[index] = record
        }
      case .delete(let identifier):
        records.removeAll { $0.identifier == identifier }
      }
    }
    appliedOperations.append(contentsOf: operations)
    return records
  }

  public func removeCalendar() async throws {
    try requireAccess()
    records.removeAll()
    calendarExists = false
  }
}

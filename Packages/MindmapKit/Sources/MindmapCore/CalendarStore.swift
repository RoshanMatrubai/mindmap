import Foundation

public enum CalendarAccessState: String, Sendable, Equatable {
  case notDetermined, fullAccess, denied, restricted
}

public enum CalendarStoreFailure: Error, Sendable, Equatable {
  case accessUnavailable
  case foreignIdentifier
}

/// A calendar account (EKSource) as the app sees it.
public struct CalendarSource: Sendable, Equatable {
  public enum Kind: Sendable { case local, calDAV, readOnly, other }

  public var identifier: String
  public var title: String
  public var kind: Kind

  public init(identifier: String, title: String, kind: Kind) {
    self.identifier = identifier
    self.title = title
    self.kind = kind
  }

  /// Accounts to try, in order: the remembered one, the default calendar's, then iCloud,
  /// On My Mac and any other CalDAV account. Subscribed and birthday accounts are never tried.
  public static func candidates(
    remembered: String?, preferred: CalendarSource?, in all: [CalendarSource]
  ) -> [CalendarSource] {
    var seen = Set<String>()
    let ordered =
      all.filter { $0.identifier == remembered } + [preferred].compactMap { $0 }
      + all.filter { $0.kind == .calDAV && $0.title == "iCloud" }
      + all.filter { $0.kind == .local } + all.filter { $0.kind == .calDAV }
    return ordered.filter { $0.kind != .readOnly && seen.insert($0.identifier).inserted }
  }

  /// Returns the first candidate in which `create` succeeds, with what it created. Accounts
  /// such as Google, Exchange or school ones may refuse new calendars; the next is tried instead.
  public static func create<Created>(
    in candidates: [CalendarSource], _ create: (CalendarSource) throws -> Created
  ) throws -> (source: CalendarSource, created: Created) {
    for source in candidates {
      do {
        return (source, try create(source))
      } catch {
        continue
      }
    }
    throw CalendarSourceFailure.noWritableAccount
  }
}

public enum CalendarSourceFailure: LocalizedError, Sendable, Equatable {
  case noWritableAccount

  public var errorDescription: String? {
    "couldn't create a calendar in any account: add an iCloud or On My Mac calendar account, "
      + "then try again"
  }
}

/// This boundary exposes only the calendar created by the app. Implementations must never read
/// or mutate events in another calendar, including when looking up an event identifier.
public protocol CalendarStore: Sendable {
  func accessState() async throws -> CalendarAccessState
  func requestAccess() async throws -> Bool
  /// Creates the app's calendar if it is missing and returns its account's name.
  @discardableResult func ensureCalendar() async throws -> String
  func events() async throws -> [CalendarEventRecord]
  /// Applies a plan and returns all event records remaining in the app's calendar.
  func apply(_ operations: [CalendarOperation]) async throws -> [CalendarEventRecord]
  func removeCalendar() async throws
}

/// In-memory store for unit tests and the default Debug app. It has no EventKit dependency and
/// cannot request macOS Calendar permission or access the user's calendars.
public actor FakeCalendarStore: CalendarStore {
  public static let onMyMac = CalendarSource(identifier: "local", title: "On My Mac", kind: .local)
  public var calendarExists: Bool { calendarSource != nil }
  public private(set) var calendarSource: CalendarSource?
  public private(set) var accessRequests = 0
  public private(set) var appliedOperations: [CalendarOperation] = []
  private var access: CalendarAccessState
  private var records: [CalendarEventRecord]
  private var sequence = 0
  private let defaultSource: CalendarSource?
  private let sources: [CalendarSource]
  private let refusing: Set<String>

  /// `defaultSource` is the account of the default calendar for new events (nil when there is
  /// none). Accounts listed in `refusing` reject new calendars like Google or Exchange can.
  public init(
    access: CalendarAccessState = .notDetermined, records: [CalendarEventRecord] = [],
    defaultSource: CalendarSource? = onMyMac, sources: [CalendarSource] = [onMyMac],
    refusing: Set<String> = []
  ) {
    self.access = access
    self.records = records
    self.defaultSource = defaultSource
    self.sources = sources
    self.refusing = refusing
    calendarSource = records.isEmpty ? nil : defaultSource
  }

  /// Simulates the user deleting the app's calendar in Calendar.
  public func deleteCalendarOutside() {
    calendarSource = nil
    records.removeAll()
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

  @discardableResult public func ensureCalendar() throws -> String {
    try requireAccess()
    if let calendarSource { return calendarSource.title }
    let candidates = CalendarSource.candidates(
      remembered: nil, preferred: defaultSource, in: sources)
    let source = try CalendarSource.create(in: candidates) { source in
      if refusing.contains(source.identifier) { throw CalendarStoreFailure.accessUnavailable }
    }.source
    calendarSource = source
    return source.title
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
    try ensureCalendar()
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
    calendarSource = nil
  }
}

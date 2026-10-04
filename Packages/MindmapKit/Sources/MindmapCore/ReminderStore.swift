import Foundation

public enum ReminderAccessState: String, Sendable, Equatable {
  case notDetermined, fullAccess, denied, restricted
}

public enum ReminderStoreFailure: Error, Sendable, Equatable {
  case accessUnavailable
  case foreignIdentifier
}

/// An EventKit account (EKSource) as the app sees it.
public struct ReminderSource: Sendable, Equatable {
  public enum Kind: Sendable { case local, calDAV, readOnly, other }

  public var identifier: String
  public var title: String
  public var kind: Kind

  public init(identifier: String, title: String, kind: Kind) {
    self.identifier = identifier
    self.title = title
    self.kind = kind
  }

  /// Accounts to try, in order: the remembered one, the default list's, then iCloud,
  /// On My Mac and any other CalDAV account. Subscribed and birthday accounts are never tried.
  public static func candidates(
    remembered: String?, preferred: ReminderSource?, in all: [ReminderSource]
  ) -> [ReminderSource] {
    var seen = Set<String>()
    let ordered =
      all.filter { $0.identifier == remembered } + [preferred].compactMap { $0 }
      + all.filter { $0.kind == .calDAV && $0.title == "iCloud" }
      + all.filter { $0.kind == .local } + all.filter { $0.kind == .calDAV }
    return ordered.filter { $0.kind != .readOnly && seen.insert($0.identifier).inserted }
  }

  /// Returns the first candidate in which `create` succeeds, with what it created. Accounts
  /// such as Google, Exchange or school ones may refuse new lists; the next is tried instead.
  public static func create<Created>(
    in candidates: [ReminderSource], _ create: (ReminderSource) throws -> Created
  ) throws -> (source: ReminderSource, created: Created) {
    for source in candidates {
      do {
        return (source, try create(source))
      } catch {
        continue
      }
    }
    throw ReminderSourceFailure.noWritableAccount
  }
}

public enum ReminderSourceFailure: LocalizedError, Sendable, Equatable {
  case noWritableAccount

  public var errorDescription: String? {
    "couldn't create a reminders list in any account: add an iCloud or On My Mac account, "
      + "then try again"
  }
}

/// This boundary exposes only the list created by the app. Implementations must never read
/// or mutate reminders in another list, including when looking up a reminder identifier.
public protocol ReminderStore: Sendable {
  func accessState() async throws -> ReminderAccessState
  func requestAccess() async throws -> Bool
  /// Deletes the calendar and events the Calendar version of the app created, if it still
  /// exists. Never requests Calendar access.
  func removeLegacyCalendar() async throws
  /// Creates the app's list if it is missing and returns its account's name.
  @discardableResult func ensureList() async throws -> String
  func reminders() async throws -> [ReminderRecord]
  /// Applies a plan and returns all reminder records remaining in the app's list.
  func apply(_ operations: [ReminderOperation]) async throws -> [ReminderRecord]
  func removeList() async throws
}

/// In-memory store for unit tests and the default Debug app. It has no EventKit dependency and
/// cannot request macOS Reminders permission or access the user's reminders.
public actor FakeReminderStore: ReminderStore {
  public static let onMyMac = ReminderSource(identifier: "local", title: "On My Mac", kind: .local)
  public var listExists: Bool { listSource != nil }
  public private(set) var listSource: ReminderSource?
  /// Events in the old Calendar version's calendar; nil once it is gone.
  public private(set) var legacyCalendarEvents: Int?
  public private(set) var accessRequests = 0
  public private(set) var appliedOperations: [ReminderOperation] = []
  private var access: ReminderAccessState
  private var records: [ReminderRecord]
  private var sequence = 0
  private let defaultSource: ReminderSource?
  private let sources: [ReminderSource]
  private let refusing: Set<String>

  /// `defaultSource` is the account of the default list for new reminders (nil when there is
  /// none). Accounts listed in `refusing` reject new lists like Google or Exchange can.
  public init(
    access: ReminderAccessState = .notDetermined, records: [ReminderRecord] = [],
    defaultSource: ReminderSource? = onMyMac, sources: [ReminderSource] = [onMyMac],
    refusing: Set<String> = [], legacyCalendarEvents: Int? = nil
  ) {
    self.access = access
    self.records = records
    self.defaultSource = defaultSource
    self.sources = sources
    self.refusing = refusing
    self.legacyCalendarEvents = legacyCalendarEvents
    listSource = records.isEmpty ? nil : defaultSource
  }

  /// Simulates the user deleting the app's list in Reminders.
  public func deleteListOutside() {
    listSource = nil
    records.removeAll()
  }

  /// Simulates the user checking off (or un-checking) a reminder in Reminders.
  public func setCompletedOutside(_ identifier: String, _ completed: Bool) {
    if let index = records.firstIndex(where: { $0.identifier == identifier }) {
      records[index].reminder.completed = completed
    }
  }

  public func accessState() async throws -> ReminderAccessState { access }

  public func requestAccess() async throws -> Bool {
    accessRequests += 1
    if access == .notDetermined { access = .fullAccess }
    return access == .fullAccess
  }

  private func requireAccess() throws {
    guard access == .fullAccess else { throw ReminderStoreFailure.accessUnavailable }
  }

  public func removeLegacyCalendar() throws {
    try requireAccess()
    legacyCalendarEvents = nil
  }

  @discardableResult public func ensureList() throws -> String {
    try requireAccess()
    if let listSource { return listSource.title }
    let candidates = ReminderSource.candidates(
      remembered: nil, preferred: defaultSource, in: sources)
    let source = try ReminderSource.create(in: candidates) { source in
      if refusing.contains(source.identifier) { throw ReminderStoreFailure.accessUnavailable }
    }.source
    listSource = source
    return source.title
  }

  public func reminders() async throws -> [ReminderRecord] {
    try requireAccess()
    return records
  }

  public func apply(_ operations: [ReminderOperation]) async throws -> [ReminderRecord] {
    try requireAccess()
    // Validate identifiers against this list before any mutation. An identifier from another
    // list cannot be used to reach it through this boundary.
    let owned = Set(records.map(\.identifier))
    for operation in operations {
      switch operation {
      case .create: break
      case .update(let record):
        guard owned.contains(record.identifier) else {
          throw ReminderStoreFailure.foreignIdentifier
        }
      case .delete(let identifier):
        guard owned.contains(identifier) else { throw ReminderStoreFailure.foreignIdentifier }
      }
    }
    try ensureList()
    for operation in operations {
      switch operation {
      case .create(let reminder):
        repeat { sequence += 1 } while records.contains { $0.identifier == "fake-\(sequence)" }
        records.append(ReminderRecord(identifier: "fake-\(sequence)", reminder: reminder))
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

  public func removeList() async throws {
    try requireAccess()
    records.removeAll()
    listSource = nil
  }
}

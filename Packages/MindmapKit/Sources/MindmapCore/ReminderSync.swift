import Foundation

/// A high-priority reminder belonging to one task in one map.
public struct Reminder: Sendable, Equatable {
  public var mapFileName: String
  public var pathKey: String
  public var title: String
  public var notes: String
  /// Year, month, day, hour and minute in local time; nil for an undated task.
  public var due: DateComponents?
  /// An absolute alarm at the due time; nil without a due date.
  public var alarm: Date?
  public var completed: Bool
  public var url: URL

  public init(
    mapFileName: String, pathKey: String, title: String, notes: String,
    due: DateComponents? = nil, alarm: Date? = nil, completed: Bool = false
  ) {
    self.mapFileName = mapFileName
    self.pathKey = pathKey
    self.title = title
    self.notes = notes
    self.due = due.map(Self.normalized)
    self.alarm = alarm
    self.completed = completed
    url = Self.tagURL(mapFileName: mapFileName, pathKey: pathKey)
  }

  /// Only the fields the app writes, so components read back from EventKit compare equal.
  public static func normalized(_ value: DateComponents) -> DateComponents {
    DateComponents(
      year: value.year, month: value.month, day: value.day, hour: value.hour,
      minute: value.minute)
  }

  public static func tagURL(mapFileName: String, pathKey: String) -> URL {
    let allowed = CharacterSet(
      charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")
    let map = mapFileName.addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
    let path = pathKey.addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
    // Only unreserved ASCII remains, so this always parses. The fallback has no identity.
    return URL(string: "mindmap://\(map)/\(path)") ?? URL(filePath: "/")
  }

  public static func identity(from url: URL) -> (mapFileName: String, pathKey: String)? {
    guard url.scheme == "mindmap" else { return nil }
    let raw = url.absoluteString
    guard raw.hasPrefix("mindmap://") else { return nil }
    let parts = raw.dropFirst("mindmap://".count).split(
      separator: "/", maxSplits: 1, omittingEmptySubsequences: false)
    guard parts.count == 2,
      let map = String(parts[0]).removingPercentEncoding, !map.isEmpty,
      let path = String(parts[1]).removingPercentEncoding, !path.isEmpty
    else { return nil }
    return (map, path)
  }
}

public struct ReminderRecord: Sendable, Equatable {
  public var identifier: String
  public var reminder: Reminder

  public init(identifier: String, reminder: Reminder) {
    self.identifier = identifier
    self.reminder = reminder
  }
}

public enum ReminderOperation: Sendable, Equatable {
  case create(Reminder)
  case update(ReminderRecord)
  case delete(String)
}

public struct ReminderMap: Sendable, Equatable {
  public var fileName: String
  public var model: MapModel
  public var sidecar: ReminderSidecar

  public init(fileName: String, model: MapModel, sidecar: ReminderSidecar = ReminderSidecar()) {
    self.fileName = fileName
    self.model = model
    self.sidecar = sidecar
  }
}

/// Pure one-way reconciliation. The caller reads only its dedicated list, then applies the
/// returned operations through ReminderStore away from the main thread.
public enum ReminderSync {
  /// Minutes after midnight: 6:30 AM.
  public static let defaultRemindAt = 6 * 60 + 30

  /// One sync run: removes the Calendar version's calendar, makes sure the list exists, then
  /// reconciles. Returns the list's records and the name of the account holding it.
  public static func run(
    store: any ReminderStore, maps: [ReminderMap], today: Date, calendar: Calendar,
    remindAt: Int = defaultRemindAt, removeOrphans: Bool = true
  ) async throws -> (records: [ReminderRecord], account: String) {
    try await store.removeLegacyCalendar()
    let account = try await store.ensureList()
    let operations = plan(
      maps: maps, current: try await store.reminders(), today: today, calendar: calendar,
      remindAt: remindAt, removeOrphans: removeOrphans)
    return (try await store.apply(operations), account)
  }

  public static func plan(
    maps: [ReminderMap], current: [ReminderRecord], today: Date, calendar: Calendar,
    remindAt: Int = defaultRemindAt, removeOrphans: Bool = true
  ) -> [ReminderOperation] {
    var operations: [ReminderOperation] = []
    var kept = Set<String>()
    var scopes = Set(maps.map(\.fileName))
    var dueDays: [String: Date?] = [:]
    for map in maps {
      if let oldName = map.sidecar.mapFileName { scopes.insert(oldName) }
      let previous = map.sidecar.previousModel
      let matched = previous.map { NodeIdentity.match(old: $0, new: map.model) }
      for index in map.model.nodes.indices {
        let node = map.model.nodes[index]
        guard node.depth > 0, node.priority == .high else { continue }
        var alarm: Date?
        if let token = node.due?.rawToken.lowercased() {
          if dueDays[token] == nil {
            // Use the parser itself so weekday and relative-date behavior cannot drift.
            let parsed = MapParser.parse(
              text: "date\n- task \(token)", today: today, calendar: calendar)
            dueDays[token] = .some(parsed.nodes.last?.due?.day)
          }
          alarm = dueDays[token].flatMap { $0 }.flatMap {
            calendar.date(
              bySettingHour: remindAt / 60, minute: remindAt % 60, second: 0, of: $0)
          }
        }
        var desired = reminder(map: map, index: index, alarm: alarm, calendar: calendar)
        let oldIndex = matched?.newToOld[index]
        let oldKey = oldIndex.flatMap { previous?.nodes[$0].pathKey }
        let identifier =
          map.sidecar.reminderIdentifiers[node.pathKey]
          ?? oldKey.flatMap { map.sidecar.reminderIdentifiers[$0] }
        let oldMap = map.sidecar.mapFileName ?? map.fileName
        let existing =
          current.first {
            !kept.contains($0.identifier) && identifier != nil && $0.identifier == identifier
              && ($0.reminder.mapFileName == map.fileName || $0.reminder.mapFileName == oldMap)
              && ($0.reminder.pathKey == node.pathKey || $0.reminder.pathKey == oldKey)
          } ?? current.first {
            !kept.contains($0.identifier) && $0.reminder.mapFileName == map.fileName
              && $0.reminder.pathKey == node.pathKey
          }
          ?? current.first {
            !kept.contains($0.identifier) && oldKey != nil && $0.reminder.mapFileName == oldMap
              && $0.reminder.pathKey == oldKey
          }
        let lastDone = map.sidecar.done[node.pathKey] ?? oldKey.flatMap { map.sidecar.done[$0] }
        if let existing {
          kept.insert(existing.identifier)
          // Push completion only when the task's done state changed since the last sync, so a
          // reminder checked off in Reminders is never un-checked.
          desired.completed =
            lastDone != nil && lastDone != node.done ? node.done : existing.reminder.completed
          if existing.reminder != desired {
            operations.append(
              .update(ReminderRecord(identifier: existing.identifier, reminder: desired)))
          }
        } else if !node.done {
          operations.append(.create(desired))
        }
      }
    }
    for record in current where !kept.contains(record.identifier) {
      if removeOrphans || scopes.contains(record.reminder.mapFileName) {
        operations.append(.delete(record.identifier))
      }
    }
    return operations
  }

  public static func sidecar(for map: ReminderMap, records: [ReminderRecord]) -> ReminderSidecar {
    var identifiers: [String: String] = [:]
    for record in records where record.reminder.mapFileName == map.fileName {
      identifiers[record.reminder.pathKey] = record.identifier
    }
    var done: [String: Bool] = [:]
    for node in map.model.nodes where node.depth > 0 && node.priority == .high {
      done[node.pathKey] = node.done
    }
    return ReminderSidecar(
      reminderIdentifiers: identifiers, done: done, previousModel: map.model,
      mapFileName: map.fileName)
  }

  private static func reminder(map: ReminderMap, index: Int, alarm: Date?, calendar: Calendar)
    -> Reminder
  {
    let node = map.model.nodes[index]
    var ancestors = [node.name]
    var parent = node.parent
    while let current = parent {
      ancestors.append(map.model.nodes[current].name)
      parent = map.model.nodes[current].parent
    }
    let path = ([map.model.title] + ancestors.reversed()).joined(separator: " › ")
    var subtasks: [String] = []
    func appendChildren(_ index: Int, depth: Int) {
      for child in map.model.nodes[index].children {
        let task = map.model.nodes[child]
        subtasks.append(
          String(repeating: "  ", count: depth) + "- [\(task.done ? "x" : " ")] " + task.name)
        appendChildren(child, depth: depth + 1)
      }
    }
    appendChildren(index, depth: 0)
    return Reminder(
      mapFileName: map.fileName, pathKey: node.pathKey, title: node.name,
      notes: path + "\n\n" + subtasks.joined(separator: "\n"),
      due: alarm.map { calendar.dateComponents([.year, .month, .day, .hour, .minute], from: $0) },
      alarm: alarm, completed: node.done)
  }
}

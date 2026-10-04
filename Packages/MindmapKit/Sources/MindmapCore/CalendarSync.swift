import Foundation

/// An all-day, alert-free event belonging to one task in one map.
public struct CalendarEvent: Sendable, Equatable {
  public var mapFileName: String
  public var pathKey: String
  public var title: String
  public var date: Date
  public var notes: String
  public var url: URL

  public init(mapFileName: String, pathKey: String, title: String, date: Date, notes: String) {
    self.mapFileName = mapFileName
    self.pathKey = pathKey
    self.title = title
    self.date = date
    self.notes = notes
    url = Self.tagURL(mapFileName: mapFileName, pathKey: pathKey)
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

public struct CalendarEventRecord: Sendable, Equatable {
  public var identifier: String
  public var event: CalendarEvent

  public init(identifier: String, event: CalendarEvent) {
    self.identifier = identifier
    self.event = event
  }
}

public enum CalendarOperation: Sendable, Equatable {
  case create(CalendarEvent)
  case update(CalendarEventRecord)
  case delete(String)
}

public struct CalendarMap: Sendable, Equatable {
  public var fileName: String
  public var model: MapModel
  public var sidecar: CalendarSidecar

  public init(fileName: String, model: MapModel, sidecar: CalendarSidecar = CalendarSidecar()) {
    self.fileName = fileName
    self.model = model
    self.sidecar = sidecar
  }
}

/// Pure one-way reconciliation. The caller reads only its dedicated calendar, then applies the
/// returned operations through CalendarStore away from the main thread.
public enum CalendarSync {
  public static func plan(
    maps: [CalendarMap], current: [CalendarEventRecord], today: Date, calendar: Calendar,
    removeOrphans: Bool = true
  ) -> [CalendarOperation] {
    var operations: [CalendarOperation] = []
    var kept = Set<String>()
    var scopes = Set(maps.map(\.fileName))
    var dueDates: [String: Date] = [:]
    for map in maps {
      if let oldName = map.sidecar.mapFileName { scopes.insert(oldName) }
      let previous = map.sidecar.previousModel
      let matched = previous.map { NodeIdentity.match(old: $0, new: map.model) }
      for index in map.model.nodes.indices {
        let node = map.model.nodes[index]
        guard node.depth > 0, node.priority == .high, !node.done, let due = node.due else {
          continue
        }
        let token = due.rawToken.lowercased()
        if dueDates[token] == nil {
          // Use the parser itself so weekday and relative-date behavior cannot drift.
          let parsed = MapParser.parse(
            text: "date\n- task \(token)", today: today, calendar: calendar)
          dueDates[token] = parsed.nodes.last?.due?.day
        }
        guard let date = dueDates[token] else { continue }
        let desired = event(map: map, index: index, date: date)
        let oldIndex = matched?.newToOld[index]
        let oldKey = oldIndex.flatMap { previous?.nodes[$0].pathKey }
        let identifier =
          map.sidecar.eventIdentifiers[node.pathKey]
          ?? oldKey.flatMap { map.sidecar.eventIdentifiers[$0] }
        let oldMap = map.sidecar.mapFileName ?? map.fileName
        let existing =
          current.first {
            !kept.contains($0.identifier) && identifier != nil && $0.identifier == identifier
              && ($0.event.mapFileName == map.fileName || $0.event.mapFileName == oldMap)
              && ($0.event.pathKey == node.pathKey || $0.event.pathKey == oldKey)
          } ?? current.first {
            !kept.contains($0.identifier) && $0.event.mapFileName == map.fileName
              && $0.event.pathKey == node.pathKey
          }
          ?? current.first {
            !kept.contains($0.identifier) && oldKey != nil && $0.event.mapFileName == oldMap
              && $0.event.pathKey == oldKey
          }
        if let existing {
          kept.insert(existing.identifier)
          if existing.event != desired {
            operations.append(
              .update(CalendarEventRecord(identifier: existing.identifier, event: desired)))
          }
        } else {
          operations.append(.create(desired))
        }
      }
    }
    for record in current where !kept.contains(record.identifier) {
      if removeOrphans || scopes.contains(record.event.mapFileName) {
        operations.append(.delete(record.identifier))
      }
    }
    return operations
  }

  public static func sidecar(for map: CalendarMap, records: [CalendarEventRecord])
    -> CalendarSidecar
  {
    var identifiers: [String: String] = [:]
    for record in records where record.event.mapFileName == map.fileName {
      identifiers[record.event.pathKey] = record.identifier
    }
    return CalendarSidecar(
      eventIdentifiers: identifiers, previousModel: map.model, mapFileName: map.fileName)
  }

  private static func event(map: CalendarMap, index: Int, date: Date) -> CalendarEvent {
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
    return CalendarEvent(
      mapFileName: map.fileName, pathKey: node.pathKey, title: node.name,
      date: date, notes: path + "\n\n" + subtasks.joined(separator: "\n"))
  }
}

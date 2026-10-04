import Foundation

/// Stateless outline parsing. All dates are resolved using the caller's clock and calendar.
public enum MapParser {
  private static let dueWords = [
    "today": 0, "tomorrow": 1, "tmrw": 1,
    "sunday": 7, "monday": 8, "tuesday": 9, "wednesday": 10,
    "thursday": 11, "friday": 12, "saturday": 13,
  ]
  private static let priorityWords: [String: MapPriority] = [
    "high": .high, "medium": .medium, "med": .medium, "low": .low, "chill": .chill,
  ]

  public static func parse(text: String, today: Date, calendar: Calendar) -> MapModel {
    let lines = sourceLines(text)
    let spaceUnit =
      lines.compactMap { line -> Int? in
        let count = line.text.utf16.prefix(while: { $0 == 32 }).count
        return count == 0 ? nil : count
      }.min() ?? 2
    let startOfToday = calendar.startOfDay(for: today)
    let weekday = calendar.component(.weekday, from: today)
    // Resolve each token once per document, rather than calling Calendar for every task.
    var dueDays: [String: Date] = [:]
    for (word, value) in dueWords {
      let offset = value < 7 ? value : (value - 6 - weekday + 7) % 7
      dueDays[word] = calendar.date(byAdding: .day, value: offset, to: startOfToday)
    }
    var model = MapModel(title: "", nodes: [], resolvedLinks: [], unresolvedLinks: [], warnings: [])
    var hasTitle = false
    var group: Int?
    var looseGroup: Int?
    var ancestors: [Int] = []
    var pathCounts: [String: Int] = [:]
    var usedPaths = Set<String>()
    var groupForNode: [Int] = []
    var pending: [(source: Int, name: String, range: NSRange)] = []

    func pathKey(name: String, parent: Int?) -> String {
      let prefix = parent.map { model.nodes[$0].pathKey + "/" } ?? ""
      let base = prefix + name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
      var count = (pathCounts[base] ?? 0) + 1
      var key = count == 1 ? base : base + "#\(count)"
      while usedPaths.contains(key) {
        count += 1
        key = base + "#\(count)"
      }
      pathCounts[base] = count
      usedPaths.insert(key)
      return key
    }

    for line in lines {
      let trimmed = line.text.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !trimmed.isEmpty else { continue }
      if !hasTitle {
        model.title = trimmed
        hasTitle = true
        continue
      }
      let parts = lineParts(line.text)
      let tokens = scanTokens(line.text, parts: parts)
      let content = line.text as NSString
      var removals = tokens.map(\.range)
      if parts.contentStart > 0 {
        removals.append(NSRange(location: 0, length: parts.contentStart))
      }
      removals.sort { $0.location < $1.location }
      var name = ""
      var position = 0
      for range in removals {
        if range.location > position {
          name += content.substring(
            with: NSRange(location: position, length: range.location - position))
        }
        position = max(position, NSMaxRange(range))
      }
      if position < content.length { name += content.substring(from: position) }
      name = name.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !name.isEmpty else { continue }

      let isBullet = parts.bulletRange != nil
      if isBullet, group == nil {
        if let existing = looseGroup {
          group = existing
        } else {
          let id = model.nodes.count
          model.nodes.append(
            MapNode(
              id: id, pathKey: pathKey(name: "loose", parent: nil), name: "loose", depth: 0,
              parent: nil, children: [], done: false, due: nil, priority: nil, linkNames: [],
              sourceLineIndex: line.index, sourceRange: NSRange(location: line.offset, length: 0)))
          groupForNode.append(id)
          looseGroup = id
          group = id
        }
        ancestors = [group!]
      }
      var depth = 0
      var parent: Int?
      if isBullet {
        let indent = parts.tabs + parts.spaces / spaceUnit
        let desired = indent + parts.starDepth
        depth = min(desired, ancestors.count)
        if depth < desired {
          model.warnings.append(
            ParseWarning(
              sourceLineIndex: line.index, message: "Indent depth \(desired) clamped to \(depth)."))
        }
        parent = ancestors[depth - 1]
      }
      var due: DueDate?
      var priority: MapPriority?
      var links: [String] = []
      let id = model.nodes.count
      for token in tokens {
        let raw = content.substring(with: token.range)
        switch token.kind {
        case .due:
          if let day = dueDays[String(raw.dropFirst()).lowercased()] {
            due = DueDate(day: day, rawToken: raw)
          }
        case .priority(let value): priority = value
        case .link:
          let linkName = Self.linkName(raw)
          links.append(linkName)
          pending.append(
            (
              id, linkName,
              NSRange(location: line.offset + token.range.location, length: token.range.length)
            ))
        case .bullet, .doneMarker: break
        }
      }
      model.nodes.append(
        MapNode(
          id: id, pathKey: pathKey(name: name, parent: parent), name: name, depth: depth,
          parent: parent, children: [], done: parts.done, due: due, priority: priority,
          linkNames: links, sourceLineIndex: line.index,
          sourceRange: NSRange(location: line.offset, length: content.length)))
      if let parent { model.nodes[parent].children.append(id) }
      if isBullet {
        groupForNode.append(group!)
        ancestors = Array(ancestors.prefix(depth))
        ancestors.append(id)
      } else {
        group = id
        groupForNode.append(id)
        ancestors = [id]
      }
    }
    var byName: [String: [Int]] = [:]
    for node in model.nodes {
      byName[node.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(), default: []]
        .append(node.id)
    }
    for link in pending {
      let key = link.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
      guard let matches = byName[key] else {
        model.unresolvedLinks.append(
          UnresolvedLink(source: link.source, name: link.name, sourceRange: link.range))
        continue
      }
      let candidates = matches.filter { $0 != link.source }
      if let target = candidates.first(where: { groupForNode[$0] == groupForNode[link.source] })
        ?? candidates.first
      {
        model.resolvedLinks.append(
          ResolvedLink(source: link.source, target: target, name: link.name))
      }
    }
    return model
  }

  public static func metadataTokens(in line: String) -> [MetadataToken] {
    scanTokens(line, parts: lineParts(line))
  }

  public static func isDone(line: String) -> Bool { lineParts(line).done }

  private struct LineParts {
    var tabs = 0
    var spaces = 0
    var starDepth = 1
    var contentStart = 0
    var bulletRange: NSRange?
    var markerRange: NSRange?
    var done = false
  }

  private static func whitespace(_ unit: UInt16) -> Bool {
    unit == 32 || unit == 9 || unit == 13 || unit == 10
  }

  private static func lineParts(_ line: String) -> LineParts {
    let units = Array(line.utf16)
    var result = LineParts()
    var index = 0
    while index < units.count, units[index] == 32 || units[index] == 9 {
      if units[index] == 9 { result.tabs += 1 } else { result.spaces += 1 }
      index += 1
    }
    result.contentStart = index
    let start = index
    guard index < units.count else { return result }
    if units[index] == 45 {
      index += 1
    } else if units[index] == 42 {
      while index < units.count, units[index] == 42 { index += 1 }
      result.starDepth = index - start
    } else {
      return result
    }
    guard index == units.count || whitespace(units[index]) else { return result }
    result.bulletRange = NSRange(location: start, length: index - start)
    while index < units.count, whitespace(units[index]) { index += 1 }
    result.contentStart = index
    if index + 2 < units.count, units[index] == 91, units[index + 2] == 93,
      [UInt16(32), 88, 120].contains(units[index + 1]),
      index + 3 == units.count || whitespace(units[index + 3])
    {
      result.markerRange = NSRange(location: index, length: 3)
      result.done = units[index + 1] != 32
    }
    return result
  }

  private static func scanTokens(_ line: String, parts: LineParts) -> [MetadataToken] {
    let units = Array(line.utf16)
    let source = line as NSString
    var result: [MetadataToken] = []
    if let range = parts.bulletRange { result.append(MetadataToken(kind: .bullet, range: range)) }
    if let range = parts.markerRange {
      result.append(MetadataToken(kind: .doneMarker, range: range))
    }
    // The done marker is `[ ]`, `[x]` or `[X]` right after the bullet, never a link.
    var index = parts.markerRange.map(NSMaxRange) ?? parts.contentStart
    while index < units.count {
      if units[index] == 91, let end = linkEnd(units, from: index) {
        result.append(
          MetadataToken(kind: .link, range: NSRange(location: index, length: end - index)))
        index = end
        continue
      }
      if units[index] == 47, index == 0 || whitespace(units[index - 1]) {
        var end = index + 1
        while end < units.count, !whitespace(units[end]) { end += 1 }
        let word = source.substring(with: NSRange(location: index + 1, length: end - index - 1))
          .lowercased()
        let kind: MetadataKind?
        if let priority = priorityWords[word] {
          kind = .priority(priority)
        } else if dueWords[word] != nil {
          kind = .due
        } else {
          kind = nil
        }
        if let kind {
          result.append(
            MetadataToken(kind: kind, range: NSRange(location: index, length: end - index)))
        }
        index = end
      } else {
        index += 1
      }
    }
    return result
  }

  /// The end (exclusive) of a `[[name]]` or `[name]` link starting at `start`, or nil. The name
  /// must not be blank, and a single-bracket name can't contain another bracket.
  private static func linkEnd(_ units: [UInt16], from start: Int) -> Int? {
    func named(_ range: Range<Int>) -> Bool { range.contains { !whitespace(units[$0]) } }
    if start + 1 < units.count, units[start + 1] == 91 {
      var end = start + 2
      while end + 1 < units.count, !(units[end] == 93 && units[end + 1] == 93) { end += 1 }
      return end + 1 < units.count && named(start + 2..<end) ? end + 2 : nil
    }
    var end = start + 1
    while end < units.count, units[end] != 93, units[end] != 91 { end += 1 }
    return end < units.count && units[end] == 93 && named(start + 1..<end) ? end + 1 : nil
  }

  private static func linkName(_ token: String) -> String {
    let brackets = token.hasPrefix("[[") ? 2 : 1
    return String(token.dropFirst(brackets).dropLast(brackets))
  }

  private struct SourceLine {
    var text: String
    var index: Int
    var offset: Int
  }

  private static func sourceLines(_ text: String) -> [SourceLine] {
    let units = Array(text.utf16)
    var lines: [SourceLine] = []
    var start = 0
    var index = 0
    while index <= units.count {
      if index == units.count || units[index] == 10 || units[index] == 13 {
        lines.append(
          SourceLine(
            text: String(decoding: units[start..<index], as: UTF16.self), index: lines.count,
            offset: start))
        if index < units.count, units[index] == 13, index + 1 < units.count, units[index + 1] == 10
        {
          index += 1
        }
        start = index + 1
      }
      index += 1
    }
    return lines
  }
}

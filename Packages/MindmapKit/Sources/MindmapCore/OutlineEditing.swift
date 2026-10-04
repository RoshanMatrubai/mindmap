import Foundation

public enum EditingKey: Sendable {
  case enter, tab, backtab
}

public struct TextChange: Equatable, Sendable {
  public let range: NSRange
  public let replacement: String
  public let selection: NSRange
}

public enum OutlineEditing {
  /// All ranges use UTF16 offsets, matching the native text editor's selection.
  public static func change(text: String, selection: NSRange, key: EditingKey) -> TextChange? {
    let source = text as NSString
    guard selection.location >= 0, selection.length >= 0,
      selection.location <= source.length, selection.length <= source.length - selection.location
    else { return nil }
    let lines = paragraphs(source)
    let unit = spaceUnit(lines: lines, source: source)
    guard let selected = selectedLines(lines, selection: selection, source: source) else {
      return nil
    }
    let first = selected.lowerBound

    if key == .enter {
      let line = lines[first]
      guard let bullet = bullet(in: line, source: source) else { return nil }
      var payload = source.substring(
        with: NSRange(
          location: bullet.contentStart, length: NSMaxRange(line.range) - bullet.contentStart)
      )
      .trimmingCharacters(in: .whitespaces)
      if payload.hasPrefix("[x]") || payload.hasPrefix("[X]") || payload.hasPrefix("[ ]") {
        payload = String(payload.dropFirst(3)).trimmingCharacters(in: .whitespaces)
      }
      if payload.isEmpty {
        if let removal = outdent(bullet: bullet, source: source, unit: unit) {
          let replacement = source.substring(with: line.range) as NSString
          let relative = NSRange(
            location: removal.location - line.range.location, length: removal.length)
          let result = replacement.replacingCharacters(in: relative, with: "")
          return TextChange(
            range: line.range, replacement: result,
            selection: NSRange(
              location: line.range.location + (result as NSString).length, length: 0))
        }
        return TextChange(
          range: line.range, replacement: "",
          selection: NSRange(location: line.range.location, length: 0))
      }
      let indent = source.substring(
        with: NSRange(
          location: line.range.location, length: bullet.markerStart - line.range.location))
      let newline = line.newline.isEmpty ? (text.contains("\r\n") ? "\r\n" : "\n") : line.newline
      let replacement =
        newline + indent + String(repeating: "\t", count: max(0, bullet.stars - 1)) + "- "
      return TextChange(
        range: selection, replacement: replacement,
        selection: NSRange(
          location: selection.location + (replacement as NSString).length, length: 0))
    }

    let last = selected.upperBound
    var edits: [NSRange] = []
    for line in lines[first...max(first, last)] {
      guard let bullet = bullet(in: line, source: source) else { continue }
      if key == .tab {
        edits.append(NSRange(location: line.range.location, length: 0))
      } else if let removal = outdent(bullet: bullet, source: source, unit: unit) {
        edits.append(removal)
      }
    }
    guard !edits.isEmpty else { return nil }
    let changedRange = NSRange(
      location: lines[first].range.location,
      length: NSMaxRange(lines[max(first, last)].range) - lines[first].range.location)
    let replacement = NSMutableString(string: source.substring(with: changedRange))
    for edit in edits.reversed() {
      replacement.replaceCharacters(
        in: NSRange(
          location: edit.location - changedRange.location,
          length: edit.length), with: key == .tab ? "\t" : "")
    }
    func adjusted(_ offset: Int) -> Int {
      var result = offset
      for edit in edits where edit.location <= offset {
        result += key == .tab ? 1 : -min(edit.length, offset - edit.location)
      }
      return result
    }
    let start = adjusted(selection.location)
    return TextChange(
      range: changedRange, replacement: replacement as String,
      selection: NSRange(location: start, length: adjusted(NSMaxRange(selection)) - start))
  }

  /// Normalize only leading space indentation; names, tabs and line endings are preserved.
  public static func normalizedPaste(_ text: String) -> String {
    let source = text as NSString
    let lines = paragraphs(source)
    let runs = lines.map { leadingSpaces(in: $0, source: source) }.filter { $0 > 0 }
    guard let unit = runs.min(), unit == 2 || unit == 4 else { return text }
    let result = NSMutableString(string: text)
    for line in lines.reversed() {
      let spaces = leadingSpaces(in: line, source: source)
      guard spaces >= unit else { continue }
      result.replaceCharacters(
        in: NSRange(location: line.range.location, length: spaces),
        with: String(repeating: "\t", count: spaces / unit)
          + String(repeating: " ", count: spaces % unit))
    }
    return result as String
  }

  /// ⇧⌘U, as in Notes: if any selected bullet is not done, mark them all done (`[x]`);
  /// otherwise remove the markers. An open `[ ]` becomes `[x]`.
  public static func toggleDone(text: String, selection: NSRange) -> TextChange? {
    let source = text as NSString
    let lines = paragraphs(source)
    guard let selected = selectedLines(lines, selection: selection, source: source) else {
      return nil
    }
    let bullets = lines[selected].compactMap { bullet(in: $0, source: source) }
    guard !bullets.isEmpty else { return nil }
    func marker(_ b: Bullet) -> (range: NSRange, done: Bool)? {
      let end = NSMaxRange(lines.first { $0.range.location == b.lineStart }!.range)
      guard b.contentStart + 3 <= end else { return nil }
      let token = source.substring(with: NSRange(location: b.contentStart, length: 3))
      guard ["[x]", "[X]", "[ ]"].contains(token) else { return nil }
      let after = b.contentStart + 3
      guard after == end || [9, 32].contains(source.character(at: after)) else { return nil }
      return (NSRange(location: b.contentStart, length: 3), token != "[ ]")
    }
    let allDone = bullets.allSatisfy { marker($0)?.done == true }
    var edits: [(range: NSRange, text: String)] = []
    for b in bullets {
      let current = marker(b)
      if allDone, let current {
        let end = NSMaxRange(lines.first { $0.range.location == b.lineStart }!.range)
        let space = NSMaxRange(current.range) < end ? 1 : 0
        edits.append((NSRange(location: current.range.location, length: 3 + space), ""))
      } else if !allDone, let current, !current.done {
        edits.append((current.range, "[x]"))
      } else if !allDone, current == nil {
        edits.append((NSRange(location: b.contentStart, length: 0), "[x] "))
      }
    }
    return apply(edits, in: lines[selected], source: source, selection: selection)
  }

  /// ⌃⌘↑ / ⌃⌘↓: swaps the current bullet line and its subtasks with the sibling block above or
  /// below. Only siblings under the same parent; `nil` at either end.
  public static func moveBlock(text: String, selection: NSRange, up: Bool) -> TextChange? {
    let source = text as NSString
    let lines = paragraphs(source)
    let unit = spaceUnit(lines: lines, source: source)
    guard let selected = selectedLines(lines, selection: selection, source: source) else {
      return nil
    }
    func level(_ i: Int) -> Int? {
      guard i >= 0, i < lines.count, let b = bullet(in: lines[i], source: source) else {
        return nil
      }
      var tabs = 0
      var spaces = 0
      for offset in b.lineStart..<b.markerStart {
        if source.character(at: offset) == 9 { tabs += 1 } else { spaces += 1 }
      }
      return tabs + spaces / unit + max(0, b.stars - 1)
    }
    func blockEnd(_ i: Int) -> Int {
      var end = i + 1
      while let l = level(end), l > level(i)! { end += 1 }
      return end
    }
    let start = selected.lowerBound
    guard let own = level(start) else { return nil }
    let first: Range<Int>
    let second: Range<Int>
    if up {
      var k = start - 1
      while let l = level(k), l > own { k -= 1 }
      guard level(k) == own else { return nil }
      first = k..<start
      second = start..<blockEnd(start)
    } else {
      let end = blockEnd(start)
      guard level(end) == own else { return nil }
      first = start..<end
      second = end..<blockEnd(end)
    }
    let newline = lines[first.lowerBound].newline
    let region = NSRange(
      location: lines[first.lowerBound].range.location,
      length: NSMaxRange(lines[second.upperBound - 1].range)
        - lines[first.lowerBound].range.location
    )
    func joined(_ block: Range<Int>) -> String {
      lines[block].map { source.substring(with: $0.range) }.joined(separator: newline)
    }
    let replacement = joined(second) + newline + joined(first)
    let shift =
      up
      ? region.location - lines[second.lowerBound].range.location
      : region.location + (joined(second) as NSString).length + (newline as NSString).length
        - lines[first.lowerBound].range.location
    return TextChange(
      range: region, replacement: replacement,
      selection: NSRange(location: selection.location + shift, length: selection.length))
  }

  /// The first and last paragraph touched by `selection`. A selection ending at the start of a
  /// line doesn't include that line.
  private static func selectedLines(_ lines: [Paragraph], selection: NSRange, source: NSString)
    -> ClosedRange<Int>?
  {
    guard selection.location >= 0, selection.length >= 0,
      selection.location <= source.length, selection.length <= source.length - selection.location,
      let first = lines.firstIndex(where: {
        selection.location >= $0.range.location && selection.location < $0.end
          || selection.location == source.length && $0.end == source.length && $0.newline.isEmpty
      })
    else { return nil }
    let selectedEnd = selection.length == 0 ? selection.location : NSMaxRange(selection) - 1
    let last = lines.lastIndex(where: { $0.range.location <= selectedEnd }) ?? first
    return first...max(first, last)
  }

  /// Applies non-overlapping edits inside the selected lines as one change, keeping the selection
  /// on the same text.
  private static func apply(
    _ edits: [(range: NSRange, text: String)], in lines: ArraySlice<Paragraph>, source: NSString,
    selection: NSRange
  ) -> TextChange? {
    guard !edits.isEmpty, let firstLine = lines.first, let lastLine = lines.last else { return nil }
    let changed = NSRange(
      location: firstLine.range.location,
      length: NSMaxRange(lastLine.range) - firstLine.range.location)
    let replacement = NSMutableString(string: source.substring(with: changed))
    for edit in edits.sorted(by: { $0.range.location > $1.range.location }) {
      replacement.replaceCharacters(
        in: NSRange(location: edit.range.location - changed.location, length: edit.range.length),
        with: edit.text)
    }
    func adjusted(_ offset: Int) -> Int {
      var result = offset
      for edit in edits where edit.range.location < offset {
        let removed = min(edit.range.length, offset - edit.range.location)
        result += (edit.text as NSString).length - removed
      }
      return result
    }
    let start = adjusted(selection.location)
    return TextChange(
      range: changed, replacement: replacement as String,
      selection: NSRange(location: start, length: adjusted(NSMaxRange(selection)) - start))
  }

  private struct Paragraph {
    let range: NSRange
    let newline: String
    var end: Int { NSMaxRange(range) + (newline as NSString).length }
  }

  private struct Bullet {
    let lineStart: Int
    let markerStart: Int
    let contentStart: Int
    let stars: Int
  }

  private static func paragraphs(_ source: NSString) -> [Paragraph] {
    var result: [Paragraph] = []
    var start = 0
    var cursor = 0
    while cursor < source.length {
      let character = source.character(at: cursor)
      if character == 10 || character == 13 {
        let count =
          character == 13 && cursor + 1 < source.length
            && source.character(at: cursor + 1) == 10 ? 2 : 1
        result.append(
          Paragraph(
            range: NSRange(location: start, length: cursor - start),
            newline: source.substring(with: NSRange(location: cursor, length: count))))
        cursor += count
        start = cursor
      } else {
        cursor += 1
      }
    }
    result.append(
      Paragraph(range: NSRange(location: start, length: source.length - start), newline: ""))
    return result
  }

  private static func bullet(in line: Paragraph, source: NSString) -> Bullet? {
    let end = NSMaxRange(line.range)
    var cursor = line.range.location
    while cursor < end && (source.character(at: cursor) == 9 || source.character(at: cursor) == 32)
    {
      cursor += 1
    }
    guard cursor < end else { return nil }
    let marker = cursor
    var stars = 0
    if source.character(at: cursor) == 45 {
      cursor += 1
    } else if source.character(at: cursor) == 42 {
      while cursor < end && source.character(at: cursor) == 42 {
        stars += 1
        cursor += 1
      }
    } else {
      return nil
    }
    guard cursor == end || source.character(at: cursor) == 32 || source.character(at: cursor) == 9
    else { return nil }
    while cursor < end && (source.character(at: cursor) == 32 || source.character(at: cursor) == 9)
    {
      cursor += 1
    }
    return Bullet(
      lineStart: line.range.location, markerStart: marker, contentStart: cursor, stars: stars)
  }

  private static func outdent(bullet: Bullet, source: NSString, unit: Int) -> NSRange? {
    if bullet.markerStart > bullet.lineStart {
      if source.character(at: bullet.lineStart) == 9 {
        return NSRange(location: bullet.lineStart, length: 1)
      }
      var spaces = 0
      while bullet.lineStart + spaces < bullet.markerStart
        && source.character(at: bullet.lineStart + spaces) == 32
      {
        spaces += 1
      }
      return NSRange(location: bullet.lineStart, length: min(unit, spaces))
    }
    return bullet.stars > 1 ? NSRange(location: bullet.markerStart, length: 1) : nil
  }

  private static func leadingSpaces(in line: Paragraph, source: NSString) -> Int {
    var count = 0
    while count < line.range.length && source.character(at: line.range.location + count) == 32 {
      count += 1
    }
    return count
  }

  private static func spaceUnit(lines: [Paragraph], source: NSString) -> Int {
    let minimum = lines.map { leadingSpaces(in: $0, source: source) }.filter { $0 > 0 }.min() ?? 2
    return minimum == 4 ? 4 : 2
  }
}

/// Edits made from the graph. `model` must be the parse of `text`; node ranges come from it.
/// Each result is one replacement, so it is one undo step in the editor. The selection lands on
/// the line the graph should select next.
extension OutlineEditing {
  /// Return on the graph: a new line after `node`'s whole branch at the same level. After a group
  /// that is a new group.
  public static func insertSibling(text: String, model: MapModel, after node: Int, name: String)
    -> TextChange?
  {
    guard model.nodes.indices.contains(node), let name = cleaned(name) else { return nil }
    let n = model.nodes[node]
    let prefix =
      n.depth == 0
      ? "" : (dashIndent(text, n) ?? String(repeating: "\t", count: n.depth - 1)) + "- "
    return insertLine(text, at: branchEnd(model, node), prefix + name)
  }

  /// Tab on the graph: a new last child of `node`.
  public static func appendChild(text: String, model: MapModel, to node: Int, name: String)
    -> TextChange?
  {
    guard model.nodes.indices.contains(node), let name = cleaned(name) else { return nil }
    let n = model.nodes[node]
    let indent: String
    if let first = n.children.first, let own = dashIndent(text, model.nodes[first]) {
      indent = own
    } else if n.depth == 0 {
      indent = ""
    } else {
      indent = (dashIndent(text, n) ?? String(repeating: "\t", count: n.depth - 1)) + "\t"
    }
    return insertLine(text, at: branchEnd(model, node), indent + "- " + name)
  }

  /// Double-click on empty canvas: a new group at the end of the map.
  public static func appendGroup(text: String, name: String) -> TextChange? {
    guard let name = cleaned(name) else { return nil }
    let source = text as NSString
    let newline = text.contains("\r\n") ? "\r\n" : "\n"
    // The first non-empty line is the title, never a group.
    let hasTitle = !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    let last = source.length == 0 ? 10 : source.character(at: source.length - 1)
    let open = last == 10 || last == 13
    let lead = (open ? "" : newline) + (hasTitle ? "" : "untitled map" + newline)
    let start = source.length + (lead as NSString).length
    return TextChange(
      range: NSRange(location: source.length, length: 0), replacement: lead + name + newline,
      selection: NSRange(location: start, length: (name as NSString).length))
  }

  /// Replaces only the name, keeping indentation, bullet, done marker, due date, priority and
  /// links (which follow the name, in their original order).
  public static func rename(text: String, model: MapModel, node: Int, to name: String)
    -> TextChange?
  {
    guard model.nodes.indices.contains(node), let name = cleaned(name) else { return nil }
    let n = model.nodes[node]
    if n.sourceRange.length == 0 {
      // The implicit `loose` group becomes a real group line above its first bullet.
      return insertLine(text, before: n.sourceRange.location, name)
    }
    let line = (text as NSString).substring(with: n.sourceRange)
    let ns = line as NSString
    let tokens = MapParser.metadataTokens(in: line)
    var prefixEnd = 0
    while prefixEnd < ns.length, [9, 32].contains(ns.character(at: prefixEnd)) { prefixEnd += 1 }
    for token in tokens {
      switch token.kind {
      case .bullet, .doneMarker:
        prefixEnd = max(prefixEnd, NSMaxRange(token.range))
        while prefixEnd < ns.length, [9, 32].contains(ns.character(at: prefixEnd)) {
          prefixEnd += 1
        }
      default: break
      }
    }
    let kept = tokens.filter {
      switch $0.kind {
      case .due, .priority, .link: true
      case .bullet, .doneMarker: false
      }
    }.map { " " + ns.substring(with: $0.range) }
    let replacement = ns.substring(to: prefixEnd) + name + kept.joined()
    return TextChange(
      range: n.sourceRange, replacement: replacement,
      selection: NSRange(location: n.sourceRange.location, length: (replacement as NSString).length)
    )
  }

  /// Delete on the graph: the node's line and its whole branch, with one line ending.
  public static func deleteBranch(text: String, model: MapModel, node: Int) -> TextChange? {
    guard model.nodes.indices.contains(node) else { return nil }
    let source = text as NSString
    let start = model.nodes[node].sourceRange.location
    var end = branchEnd(model, node)
    var location = start
    if end < source.length {
      end += lineBreakLength(source, at: end)
    } else if start > 0 {
      // The last line has no ending of its own: take the one before it.
      location =
        start
        - (start >= 2 && source.substring(with: NSRange(location: start - 2, length: 2)) == "\r\n"
          ? 2 : 1)
    }
    let parent = model.nodes[node].parent.map { model.nodes[$0].sourceRange }
    return TextChange(
      range: NSRange(location: location, length: end - location), replacement: "",
      selection: parent ?? NSRange(location: location, length: 0))
  }

  /// ⌥⌘1–4 and ⌥⌘0: writes, replaces or removes the node's `/priority` word.
  public static func setPriority(
    text: String, model: MapModel, node: Int, _ priority: MapPriority?
  ) -> TextChange? {
    guard model.nodes.indices.contains(node), model.nodes[node].sourceRange.length > 0 else {
      return nil
    }
    let range = model.nodes[node].sourceRange
    let line = (text as NSString).substring(with: range)
    let ns = line as NSString
    let found = MapParser.metadataTokens(in: line).filter {
      if case .priority = $0.kind { return true }
      return false
    }.map(\.range)
    var result = line
    // Later tokens first, so earlier ranges stay valid. The first one is replaced in place.
    for (i, token) in found.enumerated().reversed() {
      if i == 0, let priority {
        result = (result as NSString).replacingCharacters(in: token, with: "/" + priority.rawValue)
      } else {
        let space = token.location > 0 && [9, 32].contains(ns.character(at: token.location - 1))
        result = (result as NSString).replacingCharacters(
          in: NSRange(
            location: token.location - (space ? 1 : 0), length: token.length + (space ? 1 : 0)),
          with: "")
      }
    }
    if found.isEmpty, let priority { result += " /" + priority.rawValue }
    guard result != line else { return nil }
    return TextChange(
      range: range, replacement: result,
      selection: NSRange(location: range.location, length: (result as NSString).length))
  }

  private static func cleaned(_ name: String) -> String? {
    let line = name.components(separatedBy: .newlines).joined(separator: " ")
      .trimmingCharacters(in: .whitespaces)
    return line.isEmpty ? nil : line
  }

  /// End of the last line in `node`'s branch, before its line ending.
  private static func branchEnd(_ model: MapModel, _ node: Int) -> Int {
    var end = NSMaxRange(model.nodes[node].sourceRange)
    var pending = model.nodes[node].children
    while let n = pending.popLast() {
      end = max(end, NSMaxRange(model.nodes[n].sourceRange))
      pending.append(contentsOf: model.nodes[n].children)
    }
    return end
  }

  /// The leading whitespace of a `- ` bullet line; nil for star bullets and groups.
  private static func dashIndent(_ text: String, _ node: MapNode) -> String? {
    let line = (text as NSString).substring(with: node.sourceRange)
    let indent = line.prefix { $0 == "\t" || $0 == " " }
    return line.dropFirst(indent.count).hasPrefix("-") ? String(indent) : nil
  }

  private static func lineBreakLength(_ source: NSString, at offset: Int) -> Int {
    guard offset < source.length else { return 0 }
    let c = source.character(at: offset)
    if c == 13 {
      return offset + 1 < source.length && source.character(at: offset + 1) == 10 ? 2 : 1
    }
    return c == 10 ? 1 : 0
  }

  /// Inserts `line` as a new line after the end of the line holding `offset`.
  private static func insertLine(_ text: String, at offset: Int, _ line: String) -> TextChange {
    let newline = text.contains("\r\n") ? "\r\n" : "\n"
    let start = offset + (newline as NSString).length
    return TextChange(
      range: NSRange(location: offset, length: 0), replacement: newline + line,
      selection: NSRange(location: start, length: (line as NSString).length))
  }

  /// Inserts `line` as a new line starting at `offset`, the start of an existing line.
  private static func insertLine(_ text: String, before offset: Int, _ line: String) -> TextChange {
    let newline = text.contains("\r\n") ? "\r\n" : "\n"
    return TextChange(
      range: NSRange(location: offset, length: 0), replacement: line + newline,
      selection: NSRange(location: offset, length: (line as NSString).length))
  }
}

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
    guard
      let first = lines.firstIndex(where: {
        selection.location >= $0.range.location && selection.location < $0.end
          || selection.location == source.length && $0.end == source.length && $0.newline.isEmpty
      })
    else { return nil }

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

    let selectedEnd = selection.length == 0 ? selection.location : NSMaxRange(selection) - 1
    let last = lines.lastIndex(where: { $0.range.location <= selectedEnd }) ?? first
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

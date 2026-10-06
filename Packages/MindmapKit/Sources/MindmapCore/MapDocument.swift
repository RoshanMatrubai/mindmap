import Foundation

/// The text of one map. Placeholder until the parser lands (roadmap step 1).
public struct MapDocument: Sendable, Equatable {
  public var text: String

  public init(text: String) {
    self.text = text
  }

  /// The map title: the first non-empty line, trimmed. `nil` when the text is blank.
  public var title: String? { Self.title(of: text) }

  /// Runs on every keystroke, so it reads only up to the title line, never the whole text.
  public static func title(of text: String) -> String? {
    var rest = text[...]
    while !rest.isEmpty {
      let end = rest.firstIndex(where: \.isNewline) ?? rest.endIndex
      let trimmed = rest[..<end].trimmingCharacters(in: .whitespaces)
      if !trimmed.isEmpty { return trimmed }
      rest = rest[end...].dropFirst()
    }
    return nil
  }
}

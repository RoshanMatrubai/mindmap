import Foundation

/// The text of one map. Placeholder until the parser lands (roadmap step 1).
public struct MapDocument: Sendable, Equatable {
  public var text: String

  public init(text: String) {
    self.text = text
  }

  /// The map title: the first non-empty line, trimmed. `nil` when the text is blank.
  public var title: String? { Self.title(of: text) }

  public static func title(of text: String) -> String? {
    for line in text.split(whereSeparator: \.isNewline) {
      let trimmed = line.trimmingCharacters(in: .whitespaces)
      if !trimmed.isEmpty { return trimmed }
    }
    return nil
  }
}

import Foundation

public enum MapPriority: String, Sendable, Equatable {
  case high, medium, low, chill
}

public struct DueDate: Sendable, Equatable {
  public var day: Date
  public var rawToken: String
}

public struct MapNode: Identifiable, Sendable, Equatable {
  public var id: Int
  public var pathKey: String
  public var name: String
  public var depth: Int
  public var parent: Int?
  public var children: [Int]
  public var done: Bool
  public var due: DueDate?
  public var priority: MapPriority?
  public var linkNames: [String]
  public var sourceLineIndex: Int
  /// UTF-16 range in the original document, excluding its line ending.
  public var sourceRange: NSRange
}

public struct ResolvedLink: Sendable, Equatable {
  public var source: Int
  public var target: Int
  public var name: String
}

public struct UnresolvedLink: Sendable, Equatable {
  public var source: Int
  public var name: String
  /// UTF-16 range of the complete `[name]` or `[[name]]` token in the original document.
  public var sourceRange: NSRange
}

public struct ParseWarning: Sendable, Equatable {
  public var sourceLineIndex: Int
  public var message: String
}

public struct MapModel: Sendable, Equatable {
  public var title: String
  public var nodes: [MapNode]
  public var resolvedLinks: [ResolvedLink]
  public var unresolvedLinks: [UnresolvedLink]
  public var warnings: [ParseWarning]

  public var groupCount: Int { nodes.lazy.filter { $0.depth == 0 }.count }
  public var nodeCount: Int { nodes.count }
  public var linkCount: Int { resolvedLinks.count }

  public var statsText: String {
    var text = "\(groupCount) groups · \(nodeCount) nodes · \(linkCount) links"
    if !unresolvedLinks.isEmpty { text += " · \(unresolvedLinks.count) unresolved" }
    if !warnings.isEmpty { text += " · \(warnings.count) warnings" }
    return text
  }
}

public enum MetadataKind: Sendable, Equatable {
  case bullet
  case doneMarker
  case due
  case priority(MapPriority)
  case link
}

public struct MetadataToken: Sendable, Equatable {
  public var kind: MetadataKind
  /// UTF-16 range within the supplied line.
  public var range: NSRange
}

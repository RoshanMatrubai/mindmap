import Foundation

/// Reminder mappings and identity memory contain task names. This sidecar lives beside its map,
/// never in UserDefaults or the settings container. It keeps the `.calendar.json` name of the
/// Calendar version; version 1 files from it load with their event identifiers dropped.
public struct ReminderSidecar: Codable, Sendable, Equatable {
  public var version = 2
  public var reminderIdentifiers: [String: String]
  /// Each high task's done state at the last sync, so completion is pushed only on change.
  public var done: [String: Bool]
  public var mapFileName: String?
  private var identity: IdentityModel?

  public var previousModel: MapModel? {
    get { identity?.model }
    set { identity = newValue.map(IdentityModel.init) }
  }

  public init(
    reminderIdentifiers: [String: String] = [:], done: [String: Bool] = [:],
    previousModel: MapModel? = nil, mapFileName: String? = nil
  ) {
    self.reminderIdentifiers = reminderIdentifiers
    self.done = done
    self.mapFileName = mapFileName
    identity = previousModel.map(IdentityModel.init)
  }

  private enum CodingKeys: String, CodingKey {
    case version, reminderIdentifiers, done, mapFileName, identity
  }

  public init(from decoder: Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    let version = try values.decode(Int.self, forKey: .version)
    guard version == 1 || version == 2 else {
      throw DecodingError.dataCorruptedError(
        forKey: .version, in: values, debugDescription: "Unsupported reminder sidecar version")
    }
    // Version 1 held Calendar event identifiers, which never match a reminder.
    reminderIdentifiers =
      try values.decodeIfPresent([String: String].self, forKey: .reminderIdentifiers) ?? [:]
    done = try values.decodeIfPresent([String: Bool].self, forKey: .done) ?? [:]
    mapFileName = try values.decodeIfPresent(String.self, forKey: .mapFileName)
    identity = try values.decodeIfPresent(IdentityModel.self, forKey: .identity)
    if let nodes = identity?.nodes {
      guard Set(nodes.map(\.pathKey)).count == nodes.count,
        nodes.enumerated().allSatisfy({ index, node in
          node.parent.map { $0 >= 0 && $0 < index } ?? true
        })
      else {
        throw DecodingError.dataCorruptedError(
          forKey: .identity, in: values, debugDescription: "Invalid reminder identity tree")
      }
    }
  }

  public static func url(for map: URL) -> URL {
    map.deletingLastPathComponent().appendingPathComponent(
      "." + map.lastPathComponent + ".calendar.json")
  }

  public static func load(for map: URL) -> ReminderSidecar? {
    guard let data = try? Data(contentsOf: url(for: map)) else { return nil }
    return try? JSONDecoder().decode(Self.self, from: data)
  }

  public func save(for map: URL) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    try encoder.encode(self).write(to: Self.url(for: map), options: .atomic)
  }

  public static func move(from old: URL, to new: URL) throws {
    let source = url(for: old)
    let target = url(for: new)
    guard source != target, FileManager.default.fileExists(atPath: source.path) else { return }
    if FileManager.default.fileExists(atPath: target.path) {
      try FileManager.default.removeItem(at: target)
    }
    try FileManager.default.moveItem(at: source, to: target)
  }

  public static func remove(for map: URL) throws {
    let path = url(for: map)
    if FileManager.default.fileExists(atPath: path.path) {
      try FileManager.default.removeItem(at: path)
    }
  }

  private struct IdentityModel: Codable, Sendable, Equatable {
    struct Node: Codable, Sendable, Equatable {
      var pathKey: String
      var name: String
      var parent: Int?
    }
    var title: String
    var nodes: [Node]

    init(_ model: MapModel) {
      title = model.title
      nodes = model.nodes.map { Node(pathKey: $0.pathKey, name: $0.name, parent: $0.parent) }
    }

    var model: MapModel {
      var restored: [MapNode] = []
      for (index, node) in nodes.enumerated() {
        let depth = node.parent.map { restored[$0].depth + 1 } ?? 0
        restored.append(
          MapNode(
            id: index, pathKey: node.pathKey, name: node.name, depth: depth,
            parent: node.parent, children: [], done: false, due: nil, priority: nil,
            linkNames: [], sourceLineIndex: index, sourceRange: NSRange(location: 0, length: 0)))
        if let parent = node.parent { restored[parent].children.append(index) }
      }
      return MapModel(
        title: title, nodes: restored, resolvedLinks: [], unresolvedLinks: [], warnings: [])
    }
  }
}

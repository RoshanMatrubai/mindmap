import Foundation

/// Per-map layout memory, stored next to the map as `.<map file name>.layout.json`. It holds node
/// names (pin keys), so it lives in the maps folder, never in the container.
public struct LayoutSidecar: Codable, Sendable, Equatable {
  public var seed: Int
  /// Dropped node positions keyed by node path key.
  public var pins: [String: LayoutPoint]

  public init(seed: Int, pins: [String: LayoutPoint] = [:]) {
    self.seed = seed
    self.pins = pins
  }

  public static func randomSeed() -> Int { Int.random(in: 1..<2_147_483_647) }

  public static func url(for map: URL) -> URL {
    map.deletingLastPathComponent().appendingPathComponent(
      "." + map.lastPathComponent + ".layout.json")
  }

  /// `nil` when the map has no sidecar yet or it can't be read.
  public static func load(for map: URL) -> LayoutSidecar? {
    guard let data = try? Data(contentsOf: url(for: map)) else { return nil }
    return try? JSONDecoder().decode(LayoutSidecar.self, from: data)
  }

  public func save(for map: URL) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    try encoder.encode(self).write(to: Self.url(for: map), options: .atomic)
  }

  /// Follows a map rename. A leftover sidecar at the target belongs to no map and is replaced.
  public static func move(from old: URL, to new: URL) throws {
    let source = url(for: old)
    let target = url(for: new)
    guard source != target, FileManager.default.fileExists(atPath: source.path) else { return }
    try? FileManager.default.removeItem(at: target)
    try FileManager.default.moveItem(at: source, to: target)
  }
}

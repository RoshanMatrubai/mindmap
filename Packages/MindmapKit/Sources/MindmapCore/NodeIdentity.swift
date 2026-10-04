import Foundation

/// Preserves document identity across path changes without putting identifiers in the text.
public enum NodeIdentity {
  public struct Result: Sendable, Equatable {
    public var newToOld: [Int: Int]
    public var new: Set<Int>
    public var deleted: Set<Int>
    public var renamed: Set<Int>
    public var moved: Set<Int>
  }

  public static func match(old: MapModel, new: MapModel) -> Result {
    var pairs: [Int: Int] = [:]
    var unused = Set(old.nodes.indices)
    let paths = Dictionary(
      uniqueKeysWithValues: old.nodes.enumerated().map { ($0.element.pathKey, $0.offset) })
    for (i, node) in new.nodes.enumerated() {
      if let previous = paths[node.pathKey] {
        pairs[i] = previous
        unused.remove(previous)
      }
    }
    func sameParent(_ previous: Int?, _ current: Int?) -> Bool {
      if previous == nil && current == nil { return true }
      guard let previous, let current else { return false }
      return pairs[current] == previous
    }
    func slot(_ i: Int, in model: MapModel) -> Int {
      let siblings =
        model.nodes[i].parent.map { model.nodes[$0].children }
        ?? model.nodes.indices.filter { model.nodes[$0].parent == nil }
      return siblings.firstIndex(of: i) ?? 0
    }
    var renamed = Set<Int>()
    // Parents precede children. A renamed parent's descendants can therefore match by parent
    // identity even though their full path changed too.
    for i in new.nodes.indices where pairs[i] == nil {
      let node = new.nodes[i]
      let candidates = unused.sorted().filter {
        sameParent(old.nodes[$0].parent, node.parent) && slot($0, in: old) == slot(i, in: new)
      }
      guard let previous = candidates.first else { continue }
      let oldName = old.nodes[previous].name
      if oldName != node.name {
        // A name still present elsewhere is a move, not a replacement of this sibling.
        let oldNameSurvives = new.nodes.indices.contains {
          pairs[$0] == nil && $0 != i && new.nodes[$0].name == oldName
        }
        let newNameExisted = unused.contains {
          $0 != previous && old.nodes[$0].name == node.name
        }
        if oldNameSurvives || newNameExisted { continue }
        renamed.insert(i)
      }
      pairs[i] = previous
      unused.remove(previous)
    }
    // Same-name moves use the nearest unmatched node in document order, including duplicates.
    for i in new.nodes.indices where pairs[i] == nil {
      let candidates = unused.filter { old.nodes[$0].name == new.nodes[i].name }
      guard
        let previous = candidates.min(by: {
          abs($0 - i) == abs($1 - i) ? $0 < $1 : abs($0 - i) < abs($1 - i)
        })
      else { continue }
      pairs[i] = previous
      unused.remove(previous)
    }
    var moved = Set<Int>()
    for (i, previous) in pairs {
      if !sameParent(old.nodes[previous].parent, new.nodes[i].parent) { moved.insert(i) }
    }
    return Result(
      newToOld: pairs, new: Set(new.nodes.indices).subtracting(pairs.keys), deleted: unused,
      renamed: renamed, moved: moved)
  }
}

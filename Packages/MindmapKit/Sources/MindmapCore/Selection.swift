import Foundation

public enum SelectionMove: Sendable, CaseIterable {
  case parent, firstChild, previousSibling, nextSibling
}

/// What the detail panel shows for the selected node (prototype `select()`).
public struct NodeDetail: Equatable, Sendable {
  public enum Kind: Equatable, Sendable {
    /// `tasks` counts leaf descendants, as the prototype's `desc()` does. Next due and high
    /// priority look at every open task in the group, including ones with subtasks.
    case group(tasks: Int, nextDue: String?, highPriority: Int)
    case task(due: String?, priority: MapPriority?, done: Bool, leaf: Bool)
  }

  public struct Linked: Equatable, Sendable {
    public var index: Int
    public var name: String
  }

  public var index: Int
  public var name: String
  /// Ancestor names, group first. Empty for a group.
  public var path: [String]
  public var kind: Kind
  public var urgencyPercent: Int
  public var linked: [Linked]
}

public enum Selection {
  /// The node, its ancestors and its whole subtree, plus the other ends of cross links touching
  /// any of them (`linked`, document order, never in `nodes`).
  public static func highlight(_ model: MapModel, of index: Int) -> (nodes: Set<Int>, linked: [Int])
  {
    guard model.nodes.indices.contains(index) else { return ([], []) }
    var nodes = Set<Int>()
    var up: Int? = index
    while let a = up {
      nodes.insert(a)
      up = model.nodes[a].parent
    }
    var pending = [index]
    while let n = pending.popLast() {
      nodes.insert(n)
      pending.append(contentsOf: model.nodes[n].children)
    }
    var linked = Set<Int>()
    for link in model.resolvedLinks where nodes.contains(link.source) || nodes.contains(link.target)
    {
      let other = nodes.contains(link.source) ? link.target : link.source
      if !nodes.contains(other) { linked.insert(other) }
    }
    return (nodes, linked.sorted())
  }

  /// ↑ parent, ↓ first child, ← → previous and next sibling (groups are siblings of each other).
  /// Nil at the ends; nothing wraps.
  public static func neighbor(_ model: MapModel, of index: Int, _ move: SelectionMove) -> Int? {
    guard model.nodes.indices.contains(index) else { return nil }
    let node = model.nodes[index]
    switch move {
    case .parent: return node.parent
    case .firstChild: return node.children.first
    case .previousSibling, .nextSibling:
      let siblings =
        node.parent.map { model.nodes[$0].children }
        ?? model.nodes.filter { $0.depth == 0 }.map(\.id)
      guard let i = siblings.firstIndex(of: index) else { return nil }
      let j = i + (move == .nextSibling ? 1 : -1)
      return siblings.indices.contains(j) ? siblings[j] : nil
    }
  }

  public static func detail(_ model: MapModel, urgency: [Double], of index: Int) -> NodeDetail? {
    guard model.nodes.indices.contains(index) else { return nil }
    let node = model.nodes[index]
    var path: [String] = []
    var up = node.parent
    while let a = up {
      path.insert(model.nodes[a].name, at: 0)
      up = model.nodes[a].parent
    }
    func token(_ due: DueDate?) -> String? {
      due.map { String($0.rawToken.dropFirst()).lowercased() }
    }
    let kind: NodeDetail.Kind
    if node.depth == 0 {
      var tasks: [MapNode] = []
      var pending = node.children
      while !pending.isEmpty {
        let n = model.nodes[pending.removeFirst()]
        tasks.append(n)
        pending.append(contentsOf: n.children)
      }
      let leaves = tasks.filter { $0.children.isEmpty }
      let open = tasks.filter { !$0.done }
      let next = open.filter { $0.due != nil }.min { $0.due!.day < $1.due!.day }
      kind = .group(
        tasks: leaves.count, nextDue: token(next?.due),
        highPriority: open.filter { $0.priority == .high }.count)
    } else {
      kind = .task(
        due: token(node.due), priority: node.priority, done: node.done,
        leaf: node.children.isEmpty)
    }
    let linked = highlight(model, of: index).linked.map {
      NodeDetail.Linked(index: $0, name: model.nodes[$0].name)
    }
    let u = urgency.indices.contains(index) ? urgency[index] : 0
    return NodeDetail(
      index: index, name: node.name, path: path, kind: kind,
      urgencyPercent: Int((u * 100).rounded()), linked: linked)
  }

  /// The node whose line holds a UTF-16 location (cursor at the line's end included). The
  /// implicit `loose` group shares its first bullet's start, so the bullet wins.
  public static func node(_ model: MapModel, atLocation location: Int) -> Int? {
    model.nodes.last {
      $0.sourceRange.location <= location && location <= NSMaxRange($0.sourceRange)
    }?.id
  }
}

import Foundation

/// A fixed 120 Hz simulation. Local edits keep every node outside the overlap cascade fixed.
/// The value is Sendable so an actor can tick it without touching the view or layer tree.
public struct LayoutSimulation: Sendable {
  private var state: Simulation
  private var model: MapModel
  private var seed: Int
  private var ticks = 0
  private var remainder = 0.0
  private var springNodes = Set<Int>()
  private var dragSubtree = Set<Int>()
  private var dragged: Int?
  /// Local ticks since the last release or edit. Settling stops after 5 s whatever wobbles.
  private var settleTicks = 0
  /// Overlap depth of pairs (`i * count + j`, i < j) that already overlapped when local motion
  /// began, neither one moving. The full settle allows cross-group overlaps and packs groups at
  /// the margin; a cascade that resolved those would ripple through the whole map.
  private var existing: [Int: Double] = [:]
  public private(set) var isFullLayout: Bool
  public private(set) var isFrozen = false
  public private(set) var affected = Set<Int>()
  public private(set) var pins: [String: LayoutPoint]

  public var layout: GraphLayout {
    GraphLayout(
      model: model,
      nodes: model.nodes.indices.map { i in
        GraphNode(
          x: state.x[i], y: state.y[i], radius: state.radius[i], fontSize: state.fontSize[i],
          lines: state.lines[i], halfWidth: state.hw[i], up: state.up[i], down: state.dn[i],
          urgency: state.urgency[i], group: state.group[i])
      }, seed: seed, ticks: ticks, alpha: state.alpha)
  }

  public init(
    model: MapModel, seed: Int, pins: [String: LayoutPoint] = [:], params: ForceParams = .init(),
    today: Date, calendar: Calendar, measure: ForceLayout.Measure = ForceLayout.estimate
  ) {
    self.model = model
    self.seed = seed
    self.pins = pins.filter { key, _ in model.nodes.contains { $0.pathKey == key } }
    state = Simulation(
      model: model, seed: seed, pins: self.pins, params: params, today: today,
      calendar: calendar, measure: measure)
    isFullLayout = true
    affected = Set(model.nodes.indices.filter { !state.pinned[$0] })
    if model.nodes.isEmpty { forceFreeze() }
  }

  /// `placements` puts new nodes (by index in `model`) at a point instead of spawning them by
  /// their parent. Placed nodes only collide, so they stay where the graph put them.
  public init(
    previous: GraphLayout, model: MapModel, pins: [String: LayoutPoint] = [:],
    placements: [Int: LayoutPoint] = [:], params: ForceParams = .init(), today: Date,
    calendar: Calendar, measure: ForceLayout.Measure = ForceLayout.estimate
  ) {
    self.init(
      model: model, seed: previous.seed, params: params, today: today,
      calendar: calendar, measure: measure)
    isFullLayout = false
    let identity = NodeIdentity.match(old: previous.model, new: model)
    self.pins = [:]
    for (current, old) in identity.newToOld {
      state.x[current] = previous.nodes[old].x
      state.y[current] = previous.nodes[old].y
      if !identity.moved.contains(current),
        let point = pins[previous.model.nodes[old].pathKey] ?? pins[model.nodes[current].pathKey]
      {
        self.pins[model.nodes[current].pathKey] = point
        state.x[current] = point.x
        state.y[current] = point.y
      }
    }
    state.pinned = model.nodes.map { self.pins[$0.pathKey] != nil }
    affected = identity.new.union(identity.moved)
    springNodes = affected
    for i in identity.new.sorted() {
      if let point = placements[i] {
        state.x[i] = point.x
        state.y[i] = point.y
        springNodes.remove(i)
      } else {
        spawn(i)
      }
    }
    for i in identity.renamed {
      let old = previous.nodes[identity.newToOld[i]!]
      guard state.hw[i] > old.halfWidth || state.up[i] > old.up || state.dn[i] > old.down else {
        continue
      }
      if model.nodes.indices.contains(where: { $0 != i && overlaps(i, $0) }) {
        affected.insert(i)
      }
    }
    existing = state.existingOverlaps(except: affected)
    activateOverlaps()
    affected = affected.filter { !state.pinned[$0] }
    isFrozen = affected.isEmpty
    state.alpha = isFrozen ? 0 : 1
  }

  public init(
    model: MapModel, sidecar: LayoutSidecar, params: ForceParams = .init(), today: Date,
    calendar: Calendar, measure: ForceLayout.Measure = ForceLayout.estimate
  ) {
    self.init(
      model: model, seed: sidecar.seed, pins: sidecar.pins, params: params,
      today: today, calendar: calendar, measure: measure)
    if sidecar.version == 1 {
      // The old format has no positions. Do the original seeded settle exactly once.
      while !isFrozen { advance(by: 1.0 / 120) }
      isFullLayout = false
      return
    }
    isFullLayout = false
    affected = []
    for (i, node) in model.nodes.enumerated() {
      if let point = sidecar.pins[node.pathKey] ?? sidecar.positions[node.pathKey] {
        state.x[i] = point.x
        state.y[i] = point.y
      } else {
        affected.insert(i)
      }
    }
    springNodes = affected
    for i in affected.sorted() { spawn(i) }
    existing = state.existingOverlaps(except: affected)
    // Saved nodes must be shown exactly as saved, even if their labels overlap. Only the new
    // nodes initiate a cascade when the file has changed outside the app.
    activateOverlaps()
    isFrozen = affected.isEmpty
    state.alpha = isFrozen ? 0 : 1
  }

  public mutating func advance(by seconds: Double) {
    guard !isFrozen, seconds.isFinite, seconds > 0 else { return }
    remainder += seconds
    let step = 1.0 / 120
    while remainder + 1e-12 >= step && !isFrozen {
      remainder = max(0, remainder - step)
      if isFullLayout {
        state.tick()
        ticks += 1
        if state.alpha < 0.003 {
          state.settle()
          forceFreeze()
        }
      } else {
        localTick()
      }
    }
  }

  /// A plain drag moves only `index`; with `subtree` (⇧-drag) its descendants follow on springs.
  public mutating func beginDrag(_ index: Int, subtree: Bool = true) {
    guard model.nodes.indices.contains(index) else { return }
    isFullLayout = false
    dragged = index
    dragSubtree = [index]
    var pending = subtree ? model.nodes[index].children : []
    while let child = pending.popLast() {
      dragSubtree.insert(child)
      pending.append(contentsOf: model.nodes[child].children)
    }
    springNodes = dragSubtree
    affected = dragSubtree
    existing = state.existingOverlaps(except: dragSubtree)
    state.vx = Array(repeating: 0, count: state.count)
    state.vy = state.vx
    for i in dragSubtree {
      pins.removeValue(forKey: model.nodes[i].pathKey)
      state.pinned[i] = false
      state.vx[i] = 0
      state.vy[i] = 0
    }
    state.alpha = 1
    remainder = 0
    isFrozen = false
  }

  public mutating func drag(to point: LayoutPoint) {
    guard let dragged, point.x.isFinite, point.y.isFinite else { return }
    // Only pointer motion reheats. A held drag cools, so the subtree stops pressing on a crowd.
    if state.x[dragged] != point.x || state.y[dragged] != point.y { state.alpha = 1 }
    state.x[dragged] = point.x
    state.y[dragged] = point.y
    state.vx[dragged] = 0
    state.vy[dragged] = 0
    activateOverlaps()
  }

  public mutating func endDrag() {
    guard let index = dragged else { return }
    let point = LayoutPoint(x: state.x[index], y: state.y[index])
    pins[model.nodes[index].pathKey] = point
    state.pinned[index] = true
    dragged = nil
    settleTicks = 0
    // The dropped node stays in the affected set (it moved) but is now pinned.
    if affected.allSatisfy({ state.pinned[$0] }) { forceFreeze() }
  }

  /// Freezes the current positions for persistence when a map switches or the app quits.
  public mutating func forceFreeze() {
    isFrozen = true
    state.vx = Array(repeating: 0, count: state.count)
    state.vy = state.vx
    state.alpha = min(state.alpha, 0.0029)
    remainder = 0
  }

  public func snapshotSidecar() -> LayoutSidecar { LayoutSidecar(layout: layout, pins: pins) }

  private mutating func spawn(_ i: Int) {
    let parent = model.nodes[i].parent
    let point = leastCrowded(
      around: LayoutPoint(x: parent.map { state.x[$0] } ?? 0, y: parent.map { state.y[$0] } ?? 0),
      distance: state.params.linkDistance * (model.nodes[i].depth == 1 ? 1.5 : 1),
      box: (state.hw[i], state.up[i], state.dn[i]), skipping: i)
    state.x[i] = point.x
    state.y[i] = point.y
  }

  /// Where a node added from the graph appears before it has a name: the spawn rule, around a
  /// parent (`depth` is the new node's) or, for a new group, beside the group `center` belongs to.
  public func spawnPoint(around center: Int?, depth: Int) -> LayoutPoint {
    let origin =
      center.map { LayoutPoint(x: state.x[$0], y: state.y[$0]) } ?? LayoutPoint(x: 0, y: 0)
    let distance = state.params.linkDistance * (depth == 0 ? 3 : depth == 1 ? 1.5 : 1)
    let size = depth == 0 ? 9.0 : 4
    return leastCrowded(
      around: origin, distance: distance, box: (size + 30, size + 3, size + 22), skipping: nil)
  }

  private func leastCrowded(
    around center: LayoutPoint, distance: Double, box: (hw: Double, up: Double, dn: Double),
    skipping i: Int?
  ) -> LayoutPoint {
    var best = (x: center.x + distance, y: center.y, score: Double.infinity)
    for angle in 0..<48 {
      let theta = Double(angle) * 2 * Double.pi / 48
      let x = center.x + cos(theta) * distance
      let y = center.y + sin(theta) * distance
      var score = 0.0
      for j in model.nodes.indices where j != i {
        let ox =
          min(x + box.hw, state.x[j] + state.hw[j])
          - max(x - box.hw, state.x[j] - state.hw[j]) + 6
        let oy =
          min(y + box.dn, state.y[j] + state.dn[j])
          - max(y - box.up, state.y[j] - state.up[j]) + 6
        score += max(0, ox) * max(0, oy) * 100
        let d2 = pow(x - state.x[j], 2) + pow(y - state.y[j], 2)
        score += 1 / max(1, d2)
      }
      if score < best.score { best = (x, y, score) }
    }
    return LayoutPoint(x: best.x, y: best.y)
  }

  private func overlaps(_ i: Int, _ j: Int) -> Bool {
    let ox =
      min(state.x[i] + state.hw[i], state.x[j] + state.hw[j])
      - max(state.x[i] - state.hw[i], state.x[j] - state.hw[j]) + 6
    let oy =
      min(state.y[i] + state.dn[i], state.y[j] + state.dn[j])
      - max(state.y[i] - state.up[i], state.y[j] - state.up[j]) + 6
    return ox > 0 && oy > 0
  }

  private mutating func activateOverlaps() {
    state.expandLocalOverlaps(&affected, existing: existing)
  }

  private mutating func localTick() {
    activateOverlaps()
    var free = Array(repeating: false, count: state.count)
    var spring = free
    var subtree = free
    for i in affected { free[i] = !state.pinned[i] && dragged != i }
    for i in springNodes { spring[i] = true }
    for i in dragSubtree { subtree[i] = true }
    let (x0, y0) = (state.x, state.y)
    state.localForces(
      free: free, spring: spring, subtree: subtree, onlySubtreeSprings: !dragSubtree.isEmpty)
    activateOverlaps()
    var active = Array(repeating: false, count: state.count)
    for i in affected {
      active[i] = true
      free[i] = !state.pinned[i] && dragged != i
    }
    state.localCollision(active: active, free: free, existing: existing)
    ticks += 1
    state.alpha *= 0.98
    if dragged == nil {
      // Net displacement, not requested pushes: a node wedged between fixed neighbors is pushed
      // both ways every tick without moving.
      var moved = 0.0
      for i in affected { moved = max(moved, hypot(state.x[i] - x0[i], state.y[i] - y0[i])) }
      settleTicks += 1
      if state.alpha < 0.003 && (moved < 0.02 || settleTicks >= 600) { forceFreeze() }
    }
  }
}

extension Simulation {
  /// Cells as wide as two of the largest label boxes plus the margin, so overlapping boxes are
  /// always in the same or adjacent cells.
  private var overlapGrid: Grid {
    let reach = max(2 * (hw.max() ?? 0), (up.max() ?? 0) + (dn.max() ?? 0)) + 6
    return Grid(x: x, y: y, cell: reach)
  }

  private func boxesOverlap(
    _ px: UnsafeMutablePointer<Double>, _ py: UnsafeMutablePointer<Double>, _ i: Int, _ j: Int
  ) -> (x: Double, y: Double)? {
    let ox = min(px[i] + hw[i], px[j] + hw[j]) - max(px[i] - hw[i], px[j] - hw[j]) + 6
    let oy = min(py[i] + dn[i], py[j] + dn[j]) - max(py[i] - up[i], py[j] - up[j]) + 6
    return ox > 0 && oy > 0 ? (ox, oy) : nil
  }

  /// Every pass only visits grid neighbors, so a crowded drag costs about the affected count
  /// times the local density instead of the affected count times every node.
  func existingOverlaps(except moving: Set<Int>) -> [Int: Double] {
    var pairs: [Int: Double] = [:]
    var x = x
    var y = y
    x.withUnsafeMutableBufferPointer { x in
      y.withUnsafeMutableBufferPointer { y in
        let px = x.baseAddress!
        let py = y.baseAddress!
        overlapGrid.forEachPair { i, j in
          if !moving.contains(i) && !moving.contains(j),
            let (ox, oy) = boxesOverlap(px, py, i, j)
          {
            // Close pairs may use up the 6-unit margin and touch; none may overlap more than it did.
            pairs[i * count + j] = max(min(ox, oy), 6)
          }
        }
      }
    }
    return pairs
  }

  /// How much of the overlap of `i` and `j` (with its margin) is beyond the tolerated depth.
  private func excess(
    _ px: UnsafeMutablePointer<Double>, _ py: UnsafeMutablePointer<Double>, _ i: Int, _ j: Int,
    _ existing: [Int: Double]
  ) -> (x: Double, y: Double, depth: Double)? {
    guard let (ox, oy) = boxesOverlap(px, py, i, j) else { return nil }
    let allowed = existing.isEmpty ? 0 : existing[min(i, j) * count + max(i, j)] ?? 0
    let depth = min(ox, oy) - allowed
    return depth > 1e-9 ? (ox, oy, depth) : nil
  }

  func expandLocalOverlaps(_ affected: inout Set<Int>, existing: [Int: Double]) {
    guard count > 0, !affected.isEmpty, affected.count < count else { return }
    let grid = overlapGrid
    var active = Array(repeating: false, count: count)
    var pending = affected.sorted()
    for i in pending { active[i] = true }
    var x = x
    var y = y
    x.withUnsafeMutableBufferPointer { x in
      y.withUnsafeMutableBufferPointer { y in
        let px = x.baseAddress!
        let py = y.baseAddress!
        var cursor = 0
        while cursor < pending.count {
          let i = pending[cursor]
          cursor += 1
          grid.forEachNeighbor(of: i) { j in
            if !active[j] && !pinned[j] && excess(px, py, i, j, existing) != nil {
              active[j] = true
              affected.insert(j)
              pending.append(j)
            }
          }
        }
      }
    }
  }

  mutating func localForces(
    free: [Bool], spring: [Bool], subtree: [Bool], onlySubtreeSprings: Bool
  ) {
    guard count > 0 else { return }
    let n = count
    let al = alpha
    let forceParams = params
    let edges = springs
    let groups = isGroup
    // Repulsion ignores pairs beyond `repelRange`, so cells that size find every pair that counts.
    let grid = Grid(x: x, y: y, cell: ForceParams.repelRange)
    x.withUnsafeMutableBufferPointer { x in
      y.withUnsafeMutableBufferPointer { y in
        vx.withUnsafeMutableBufferPointer { vx in
          vy.withUnsafeMutableBufferPointer { vy in
            let px = x.baseAddress!
            let py = y.baseAddress!
            let pvx = vx.baseAddress!
            let pvy = vy.baseAddress!
            // Only spring-driven nodes (new or moved, outside a dragged subtree) feel repulsion.
            // Nodes that joined through an overlap have no spring to balance it, so repulsion
            // would push them out of every crowd and cascade across the map. They only collide.
            for i in 0..<n where free[i] && spring[i] && !subtree[i] {
              grid.forEachNeighbor(of: i) { j in
                var dx = px[i] - px[j]
                var dy = py[i] - py[j]
                var d2 = dx * dx + dy * dy
                guard d2 <= ForceParams.repelRange * ForceParams.repelRange else { return }
                if d2 < 1 {
                  dx = i < j ? -0.5 : 0.5
                  dy = 0.25
                  d2 = 1
                }
                let weight = groups[i] && groups[j] ? 1.4 : 1
                let f = forceParams.repel * al * weight / d2
                pvx[i] += dx * f
                pvy[i] += dy * f
              }
            }
            for edge in edges {
              if onlySubtreeSprings && (!subtree[edge.s] || !subtree[edge.t] || edge.k != 1) {
                continue
              }
              var dx = px[edge.t] + pvx[edge.t] - px[edge.s] - pvx[edge.s]
              var dy = py[edge.t] + pvy[edge.t] - py[edge.s] - pvy[edge.s]
              let length = max(1, hypot(dx, dy))
              let f =
                (length - forceParams.linkDistance * edge.d) / length
                * al * forceParams.linkForce * edge.k
              dx *= f
              dy *= f
              if free[edge.t] && spring[edge.t] {
                pvx[edge.t] -= dx * 0.5
                pvy[edge.t] -= dy * 0.5
              }
              if free[edge.s] && spring[edge.s] {
                pvx[edge.s] += dx * 0.5
                pvy[edge.s] += dy * 0.5
              }
            }
            for i in 0..<n where free[i] {
              pvx[i] *= 0.6
              pvy[i] *= 0.6
              px[i] += pvx[i]
              py[i] += pvy[i]
            }
          }
        }
      }
    }
  }

  mutating func localCollision(active: [Bool], free: [Bool], existing: [Int: Double]) {
    guard count > 0 else { return }
    let grid = overlapGrid
    var x = x
    var y = y
    x.withUnsafeMutableBufferPointer { x in
      y.withUnsafeMutableBufferPointer { y in
        let px = x.baseAddress!
        let py = y.baseAddress!
        for i in 0..<count where active[i] {
          grid.forEachNeighbor(of: i) { j in
            guard !(active[j] && j < i), free[i] || free[j],
              let (ox, oy, depth) = excess(px, py, i, j, existing)
            else { return }
            let amount = depth * 0.25 / (free[i] && free[j] ? 2 : 1)
            if ox < oy {
              let shift = (px[j] >= px[i] ? 1.0 : -1) * amount
              if free[i] { px[i] -= shift }
              if free[j] { px[j] += shift }
            } else {
              let shift = (py[j] >= py[i] ? 1.0 : -1) * amount
              if free[i] { py[i] -= shift }
              if free[j] { py[j] += shift }
            }
          }
        }
      }
    }
    self.x = x
    self.y = y
  }
}

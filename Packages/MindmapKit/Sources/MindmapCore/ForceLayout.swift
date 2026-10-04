import Foundation

public enum UrgencyMode: Sendable, Equatable {
  case pullIn, off, pushOut
}

public struct ForceParams: Sendable, Equatable {
  public var center = 0.04
  public var repel = 450.0
  /// Pairs farther apart than this don't repel.
  public static let repelRange = 250.0
  public var linkForce = 0.6
  public var linkDistance = 70.0
  public var urgency = UrgencyMode.pullIn
  public var textSize = 1.0

  public init() {}
}

/// One drawn node, index-aligned with `MapModel.nodes`. Coordinates are world units, y down.
public struct GraphNode: Sendable, Equatable {
  public var x: Double
  public var y: Double
  public var radius: Double
  public var fontSize: Double
  public var lines: [String]
  /// Label box around (x, y), as in the prototype's sizes(): half width, above, below.
  public var halfWidth: Double
  public var up: Double
  public var down: Double
  public var urgency: Double
  public var group: Int
}

public struct GraphLayout: Sendable, Equatable {
  public var model: MapModel
  public var nodes: [GraphNode]
  public var seed: Int
  public var ticks: Int
  public var alpha: Double
}

/// Port of the prototype's build(), sizes(), urgency(), tick(), collide() and settle(), run to
/// completion with no animation. Deterministic for a given seed, pins and input.
public enum ForceLayout {
  public typealias Measure = @Sendable (_ line: String, _ fontSize: Double) -> Double

  /// The prototype's estimate: about 0.58 em per character.
  public static let estimate: Measure = { line, size in Double(line.count) * size * 0.58 }

  /// Prototype wrap(): about 18 characters per line, at most 2 lines, the second cut with "…".
  public static func wrap(_ name: String) -> [String] {
    var out: [String] = []
    var current = ""
    for word in name.split(separator: " ", omittingEmptySubsequences: false).map(String.init) {
      let joined = (current + " " + word).trimmingCharacters(in: .whitespaces)
      if joined.count > 18 && !current.isEmpty {
        out.append(current)
        current = word
      } else {
        current = joined
      }
    }
    out.append(current)
    if out.count > 2 { out = [out[0], String(out[1].prefix(16)) + "…"] }
    return out
  }

  /// (8 − daysUntilDue) / 8, plus 0.5 for high or 0.25 for medium, capped at 1. Parents get 85%
  /// of their most urgent child. Done tasks are 0.
  public static func urgency(_ model: MapModel, today: Date, calendar: Calendar) -> [Double] {
    let start = calendar.startOfDay(for: today)
    var own = model.nodes.map { node -> Double in
      if node.done { return 0 }
      var u = 0.0
      if let due = node.due {
        let days = calendar.dateComponents([.day], from: start, to: due.day).day ?? 0
        u = max(0, Double(8 - days) / 8)
      }
      if node.priority == .high { u += 0.5 } else if node.priority == .medium { u += 0.25 }
      return min(1, u)
    }
    // Children always follow their parent in document order, so a reverse pass sees them first.
    for index in model.nodes.indices.reversed() where !model.nodes[index].done {
      for child in model.nodes[index].children {
        own[index] = max(own[index], own[child] * 0.85)
      }
    }
    return own
  }

  public static func run(
    model: MapModel, seed: Int, pins: [String: LayoutPoint] = [:], params: ForceParams = .init(),
    today: Date, calendar: Calendar, measure: Measure = estimate
  ) -> GraphLayout {
    var sim = Simulation(
      model: model, seed: seed, pins: pins, params: params, today: today, calendar: calendar,
      measure: measure)
    var ticks = 0
    while sim.alpha > 0.003 {
      sim.tick()
      ticks += 1
    }
    sim.settle()
    let nodes = model.nodes.indices.map { i in
      GraphNode(
        x: sim.x[i], y: sim.y[i], radius: sim.radius[i], fontSize: sim.fontSize[i],
        lines: sim.lines[i], halfWidth: sim.hw[i], up: sim.up[i], down: sim.dn[i],
        urgency: sim.urgency[i], group: sim.group[i])
    }
    return GraphLayout(model: model, nodes: nodes, seed: seed, ticks: ticks, alpha: sim.alpha)
  }
}

public struct LayoutPoint: Codable, Sendable, Equatable {
  public var x: Double
  public var y: Double
  public init(x: Double, y: Double) {
    self.x = x
    self.y = y
  }
}

/// The prototype's 16807 LCG.
struct SeededRandom: Sendable {
  var seed: Int
  init(_ seed: Int) { self.seed = (seed % 2_147_483_647 + 2_147_483_647) % 2_147_483_647 }
  mutating func next() -> Double {
    if seed == 0 { seed = 7 }
    seed = (seed * 16807) % 2_147_483_647
    return Double(seed) / 2_147_483_647
  }
}

/// Struct-of-arrays state so the hot loops stay in contiguous memory.
struct Simulation: Sendable {
  var x: [Double], y: [Double], vx: [Double], vy: [Double]
  var radius: [Double], fontSize: [Double], hw: [Double], up: [Double], dn: [Double]
  var lines: [[String]]
  var urgency: [Double]
  var group: [Int]
  var isGroup: [Bool]
  var pinned: [Bool]
  var springs: [(s: Int, t: Int, k: Double, d: Double)] = []
  /// Collision only runs inside a group, plus group against group.
  var collisionSets: [[Int]] = []
  var params: ForceParams
  var random: SeededRandom
  var alpha = 1.0
  let count: Int

  init(
    model: MapModel, seed: Int, pins: [String: LayoutPoint], params: ForceParams, today: Date,
    calendar: Calendar, measure: ForceLayout.Measure
  ) {
    let n = model.nodes.count
    count = n
    self.params = params
    random = SeededRandom(seed)
    x = Array(repeating: 0, count: n)
    y = x
    vx = x
    vy = x
    radius = x
    fontSize = x
    hw = x
    up = x
    dn = x
    lines = Array(repeating: [], count: n)
    urgency = ForceLayout.urgency(model, today: today, calendar: calendar)
    group = Array(repeating: 0, count: n)
    isGroup = model.nodes.map { $0.depth == 0 }
    pinned = Array(repeating: false, count: n)
    var members: [Int: [Int]] = [:]
    for (i, node) in model.nodes.enumerated() {
      group[i] = node.parent.map { group[$0] } ?? i
      members[group[i], default: []].append(i)
      // sizes(): our depth 0 is the prototype's depth 1.
      let big = !node.children.isEmpty
      radius[i] = node.depth == 0 ? 9 : big ? 6 : 4
      fontSize[i] = (node.depth == 0 ? 16 : 13) * params.textSize
      lines[i] = ForceLayout.wrap(node.name.lowercased())
      let widest = lines[i].map { measure($0, fontSize[i]) }.max() ?? 0
      hw[i] = max(radius[i], widest / 2) + 4
      up[i] = radius[i] + 3
      dn[i] = radius[i] + 5 + Double(lines[i].count) * fontSize[i] * 1.2
      // Prototype springs: d = 1.5 when the child is its depth 2 (a task directly under a group,
      // our depth 1), else 1.
      if let parent = node.parent {
        springs.append((parent, i, 1, node.depth == 1 ? 1.5 : 1))
      }
    }
    for link in model.resolvedLinks { springs.append((link.source, link.target, 0.12, 3)) }
    collisionSets = members.keys.sorted().map { members[$0]! }
    collisionSets.append(isGroup.indices.filter { isGroup[$0] })
    for i in 0..<n {
      // Draw for every node so pinning one never changes where the others start.
      let angle = random.next() * 6.283
      let r = random.next().squareRoot() * 650
      if let pin = pins[model.nodes[i].pathKey] {
        x[i] = pin.x
        y[i] = pin.y
        pinned[i] = true
      } else {
        x[i] = r * cos(angle)
        y[i] = r * sin(angle)
      }
    }
  }

  mutating func tick() {
    let al = alpha
    repel(al)
    let lk = params.linkForce
    let ld = params.linkDistance
    for e in springs {
      var dx = x[e.t] + vx[e.t] - x[e.s] - vx[e.s]
      var dy = y[e.t] + vy[e.t] - y[e.s] - vy[e.s]
      var l = (dx * dx + dy * dy).squareRoot()
      if l == 0 { l = 1 }
      l = (l - ld * e.d) / l * al * lk * e.k
      dx *= l
      dy *= l
      vx[e.t] -= dx * 0.5
      vy[e.t] -= dy * 0.5
      vx[e.s] += dx * 0.5
      vy[e.s] += dy * 0.5
    }
    for i in 0..<count {
      let pull: Double
      switch params.urgency {
      case .pullIn: pull = 0.05 * urgency[i]
      case .off: pull = 0
      case .pushOut: pull = 0.05 * (1 - urgency[i])
      }
      let g = params.center + pull
      vx[i] -= x[i] * g * al
      vy[i] -= y[i] * g * al
      vx[i] *= 0.6
      vy[i] *= 0.6
      if pinned[i] {
        vx[i] = 0
        vy[i] = 0
      } else {
        x[i] += vx[i]
        y[i] += vy[i]
      }
    }
    collide(0.5)
    alpha += (0 - alpha) * 0.02
  }

  /// Pairs beyond `repelRange` are ignored, so above 300 nodes a grid of that cell size finds exactly the
  /// same pairs as the prototype's all-pairs loop. Unsafe buffers keep the hot loop free of
  /// bounds and exclusivity checks.
  private mutating func repel(_ al: Double) {
    let strength = params.repel * al
    let n = count
    guard n > 0 else { return }
    let grid = n > 300 ? Grid(x: x, y: y, cell: ForceParams.repelRange) : nil
    var rng = random
    x.withUnsafeBufferPointer { x in
      y.withUnsafeBufferPointer { y in
        isGroup.withUnsafeBufferPointer { g in
          vx.withUnsafeMutableBufferPointer { vx in
            vy.withUnsafeMutableBufferPointer { vy in
              let px = x.baseAddress!
              let py = y.baseAddress!
              let pg = g.baseAddress!
              let pvx = vx.baseAddress!
              let pvy = vy.baseAddress!
              func pair(_ i: Int, _ j: Int) {
                var dx = px[j] - px[i]
                var dy = py[j] - py[i]
                var d2 = dx * dx + dy * dy
                if d2 > ForceParams.repelRange * ForceParams.repelRange { return }
                if d2 < 1 {
                  dx = rng.next() - 0.5
                  dy = rng.next() - 0.5
                  d2 = 1
                }
                let f = strength * (pg[i] && pg[j] ? 1.4 : 1) / d2
                pvx[i] -= dx * f
                pvy[i] -= dy * f
                pvx[j] += dx * f
                pvy[j] += dy * f
              }
              if let grid {
                grid.forEachPair(pair)
              } else {
                for i in 0..<n {
                  for j in (i + 1)..<max(i + 1, n) { pair(i, j) }
                }
              }
            }
          }
        }
      }
    }
    random = rng
  }

  /// Label boxes push apart along the axis of least overlap. Pinned nodes stay put.
  mutating func collide(_ k: Double) {
    guard count > 0 else { return }
    let sets = collisionSets
    x.withUnsafeMutableBufferPointer { x in
      y.withUnsafeMutableBufferPointer { y in
        hw.withUnsafeBufferPointer { hw in
          up.withUnsafeBufferPointer { up in
            dn.withUnsafeBufferPointer { dn in
              pinned.withUnsafeBufferPointer { pinned in
                let px = x.baseAddress!
                let py = y.baseAddress!
                let phw = hw.baseAddress!
                let pup = up.baseAddress!
                let pdn = dn.baseAddress!
                let ppinned = pinned.baseAddress!
                for set in sets {
                  set.withUnsafeBufferPointer { set in
                    guard !set.isEmpty else { return }
                    let pset = set.baseAddress!
                    var a = 0
                    while a < set.count {
                      let i = pset[a]
                      var b = a + 1
                      while b < set.count {
                        let j = pset[b]
                        b += 1
                        if ppinned[i] && ppinned[j] { continue }
                        let ox =
                          min(px[i] + phw[i], px[j] + phw[j])
                          - max(px[i] - phw[i], px[j] - phw[j]) + 6
                        let oy =
                          min(py[i] + pdn[i], py[j] + pdn[j])
                          - max(py[i] - pup[i], py[j] - pup[j]) + 6
                        guard ox > 0, oy > 0 else { continue }
                        let wi = ppinned[i] ? 0.0 : ppinned[j] ? 2 : 1
                        let wj = ppinned[j] ? 0.0 : ppinned[i] ? 2 : 1
                        if ox < oy {
                          let shift = (px[j] >= px[i] ? 1.0 : -1) * ox * k / 2
                          px[i] -= shift * wi
                          px[j] += shift * wj
                        } else {
                          let shift = (py[j] >= py[i] ? 1.0 : -1) * oy * k / 2
                          py[i] -= shift * wi
                          py[j] += shift * wj
                        }
                      }
                      a += 1
                    }
                  }
                }
              }
            }
          }
        }
      }
    }
  }

  /// The hard collision pass after the simulation stops.
  mutating func settle() {
    for _ in 0..<120 { collide(1) }
  }
}

/// Nodes bucketed into square cells (a counting sort), for neighbor-only repulsion.
struct Grid {
  private var order: [Int]
  private var start: [Int]
  private var home: [Int]
  private let columns: Int
  private let rows: Int

  init(x: [Double], y: [Double], cell: Double) {
    let minX = x.min() ?? 0
    let minY = y.min() ?? 0
    // Larger cells still hold every neighbor. This caps the cell count when one node is far away.
    let area = ((x.max() ?? 0) - minX) * ((y.max() ?? 0) - minY)
    let cell = max(cell, (area / Double(max(64, 4 * x.count))).squareRoot(), 1)
    let cx = x.map { Int(($0 - minX) / cell) }
    let cy = y.map { Int(($0 - minY) / cell) }
    let columns = (cx.max() ?? 0) + 1
    self.columns = columns
    rows = (cy.max() ?? 0) + 1
    home = zip(cx, cy).map { $0.1 * columns + $0.0 }
    start = Array(repeating: 0, count: columns * rows + 1)
    for h in home { start[h + 1] += 1 }
    for c in 0..<(columns * rows) { start[c + 1] += start[c] }
    order = Array(repeating: 0, count: home.count)
    var fill = start
    for (i, h) in home.enumerated() {
      order[fill[h]] = i
      fill[h] += 1
    }
  }

  /// Calls `body(j)` for every other node in the same or adjacent cells as `i`.
  func forEachNeighbor(of i: Int, _ body: (Int) -> Void) {
    let column = home[i] % columns
    let row = home[i] / columns
    for r in max(0, row - 1)...min(rows - 1, row + 1) {
      for c in max(0, column - 1)...min(columns - 1, column + 1) {
        let cell = r * columns + c
        for k in start[cell]..<start[cell + 1] where order[k] != i { body(order[k]) }
      }
    }
  }

  /// Calls `body(i, j)` once for every pair (i < j) in the same or adjacent cells.
  func forEachPair(_ body: (Int, Int) -> Void) {
    guard !home.isEmpty else { return }
    home.withUnsafeBufferPointer { home in
      start.withUnsafeBufferPointer { start in
        order.withUnsafeBufferPointer { order in
          let phome = home.baseAddress!
          let pstart = start.baseAddress!
          let porder = order.baseAddress!
          var i = 0
          while i < home.count {
            let column = phome[i] % columns
            let row = phome[i] / columns
            var r = max(0, row - 1)
            let lastRow = min(rows - 1, row + 1)
            while r <= lastRow {
              var c = max(0, column - 1)
              let lastColumn = min(columns - 1, column + 1)
              while c <= lastColumn {
                let cell = r * columns + c
                var k = pstart[cell]
                let end = pstart[cell + 1]
                while k < end {
                  let j = porder[k]
                  if j > i { body(i, j) }
                  k += 1
                }
                c += 1
              }
              r += 1
            }
            i += 1
          }
        }
      }
    }
  }
}

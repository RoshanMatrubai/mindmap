import Foundation
import MindmapCore
import Testing

private let motionDay = Date(timeIntervalSince1970: 1_790_985_600)
private var motionCalendar: Calendar {
  var calendar = Calendar(identifier: .gregorian)
  calendar.timeZone = TimeZone(secondsFromGMT: 0)!
  return calendar
}
private func motionModel(_ text: String) -> MapModel {
  MapParser.parse(text: text, today: motionDay, calendar: motionCalendar)
}
private func motionLayout(_ text: String, points: [LayoutPoint]) -> GraphLayout {
  var layout = ForceLayout.run(
    model: motionModel(text), seed: 42, today: motionDay, calendar: motionCalendar)
  for i in points.indices {
    layout.nodes[i].x = points[i].x
    layout.nodes[i].y = points[i].y
  }
  return layout
}
private func finish(_ simulation: inout LayoutSimulation) {
  for _ in 0..<1200 where !simulation.isFrozen { simulation.advance(by: 1.0 / 120) }
}
private func point(_ layout: GraphLayout, _ i: Int) -> LayoutPoint {
  LayoutPoint(x: layout.nodes[i].x, y: layout.nodes[i].y)
}
private func overlap(_ a: GraphNode, _ b: GraphNode) -> Bool {
  min(a.x + a.halfWidth, b.x + b.halfWidth) > max(a.x - a.halfWidth, b.x - b.halfWidth)
    && min(a.y + a.down, b.y + b.down) > max(a.y - a.up, b.y - b.up)
}

@Test func identityMatchesPathsRenamesMovesAndDeletions() {
  let old = motionModel("t\ng\n- alpha\n- beta\n- gone\nh\n- child")
  let new = motionModel("t\ng\n- renamed\n\t- beta\n- fresh\nh\n- child")
  let identity = NodeIdentity.match(old: old, new: new)
  #expect(identity.newToOld[0] == 0)
  #expect(identity.newToOld[1] == 1)
  #expect(identity.renamed.contains(1))
  #expect(identity.newToOld[2] == 2)
  #expect(identity.moved.contains(2))
  #expect(identity.new == [3])
  #expect(identity.deleted == [3])
  let addition = NodeIdentity.match(old: old, new: motionModel("t\ng\n- alpha\nh\n- child\n- new"))
  #expect(addition.new == [4])
  #expect(addition.deleted == [2, 3])
}

@Test func renamedParentPreservesDescendantIdentity() {
  let result = NodeIdentity.match(
    old: motionModel("t\ng\n- parent\n\t- child"),
    new: motionModel("t\ng\n- changed\n\t- child"))
  #expect(result.newToOld == [0: 0, 1: 1, 2: 2])
  #expect(result.renamed == [1])
  #expect(result.moved.isEmpty)
}

@Test func insertionLeavesUnaffectedNodesExactlyFixed() {
  let old = motionLayout(
    "t\ng\n- existing\nh\n- distant",
    points: [
      .init(x: 0, y: 0), .init(x: 100, y: 0), .init(x: 1000, y: 0), .init(x: 1100, y: 0),
    ])
  var sim = LayoutSimulation(
    previous: old, model: motionModel("t\ng\n- existing\n- new\nh\n- distant"),
    today: motionDay, calendar: motionCalendar)
  #expect(point(sim.layout, 0) == point(old, 0))
  #expect(point(sim.layout, 1) == point(old, 1))
  finish(&sim)
  #expect(sim.isFrozen)
  for (new, previous) in NodeIdentity.match(old: old.model, new: sim.layout.model).newToOld {
    if !sim.affected.contains(new) { #expect(point(sim.layout, new) == point(old, previous)) }
  }
  #expect(point(sim.layout, 3) == point(old, 2))
  #expect(point(sim.layout, 4) == point(old, 3))
}

@Test func deletionAndShortRenameDontMoveAnything() {
  let old = motionLayout(
    "t\ng\n- long name\n- remove",
    points: [
      .init(x: 0, y: 0), .init(x: 100, y: 0), .init(x: 200, y: 0),
    ])
  let sim = LayoutSimulation(
    previous: old, model: motionModel("t\ng\n- short"), today: motionDay,
    calendar: motionCalendar)
  #expect(sim.isFrozen)
  #expect(point(sim.layout, 1) == point(old, 1))
}

@Test func grownLabelPushesNeighborsWithCascadeButNeverPins() {
  var params = ForceParams()
  params.repel = 0
  let old = motionLayout(
    "t\ng\n- a\n- b\n- c\n- far",
    points: [
      .init(x: 0, y: -200), .init(x: 0, y: 0), .init(x: 70, y: 0),
      .init(x: 92, y: 0), .init(x: 1000, y: 0),
    ])
  var sim = LayoutSimulation(
    previous: old, model: motionModel("t\ng\n- a much longer name\n- b\n- c\n- far"),
    pins: ["g": point(old, 0), "g/a": point(old, 1)], params: params, today: motionDay,
    calendar: motionCalendar)
  #expect(point(sim.layout, 1) == point(old, 1))
  #expect(!sim.affected.contains(3))
  finish(&sim)
  #expect(sim.isFrozen)
  #expect(point(sim.layout, 1) == point(old, 1))
  #expect(sim.affected.contains(2))
  #expect(sim.affected.contains(3))
  #expect(point(sim.layout, 0) == point(old, 0))
  #expect(point(sim.layout, 4) == point(old, 4))
  #expect(!overlap(sim.layout.nodes[1], sim.layout.nodes[2]))
  #expect(!overlap(sim.layout.nodes[2], sim.layout.nodes[3]))
}

@Test func indentStartsAtPreviousPositionThenGlides() {
  let old = motionLayout(
    "t\ng\n- a\n- b",
    points: [
      .init(x: 0, y: -300), .init(x: 100, y: 0), .init(x: -100, y: 0),
    ])
  var sim = LayoutSimulation(
    previous: old, model: motionModel("t\ng\n- a\n\t- b"), today: motionDay,
    calendar: motionCalendar)
  #expect(point(sim.layout, 2) == point(old, 2))
  sim.advance(by: 0.1)
  #expect(point(sim.layout, 2) != point(old, 2))
  #expect(point(sim.layout, 0) == point(old, 0))
}

@Test func dragSpringsSubtreeAndPinsOnReleaseWithoutMovingOthers() {
  let old = motionLayout(
    "t\ng\n- a\n\t- child\nh\n- far",
    points: [
      .init(x: 0, y: -100), .init(x: 0, y: 0), .init(x: 70, y: 0),
      .init(x: 1000, y: 0), .init(x: 1100, y: 0),
    ])
  var sim = LayoutSimulation(
    previous: old, model: old.model, today: motionDay, calendar: motionCalendar)
  sim.beginDrag(1)
  sim.drag(to: .init(x: 200, y: 100))
  sim.advance(by: 0.25)
  #expect(point(sim.layout, 1) == .init(x: 200, y: 100))
  #expect(point(sim.layout, 2).x > 70)
  #expect(point(sim.layout, 3) == point(old, 3))
  #expect(point(sim.layout, 4) == point(old, 4))
  sim.endDrag()
  finish(&sim)
  #expect(sim.isFrozen)
  #expect(sim.pins["g/a"] == .init(x: 200, y: 100))
  #expect(sim.snapshotSidecar().pins == sim.pins)
}

@Test func plainDragMovesOnlyTheNodeAndPinsIt() {
  let old = motionLayout(
    "t\ng\n- a\n\t- child\nh\n- far",
    points: [
      .init(x: 0, y: -100), .init(x: 0, y: 0), .init(x: 70, y: 0),
      .init(x: 1000, y: 0), .init(x: 1100, y: 0),
    ])
  var sim = LayoutSimulation(
    previous: old, model: old.model, today: motionDay, calendar: motionCalendar)
  sim.beginDrag(1, subtree: false)
  sim.drag(to: .init(x: -200, y: 100))
  sim.advance(by: 0.25)
  #expect(point(sim.layout, 1) == .init(x: -200, y: 100))
  for i in [0, 2, 3, 4] { #expect(point(sim.layout, i) == point(old, i)) }
  sim.endDrag()
  finish(&sim)
  #expect(sim.isFrozen)
  #expect(sim.pins == ["g/a": .init(x: -200, y: 100)])
}

@Test func placedNewNodeStartsAtItsPointAndOnlyCollides() {
  let old = motionLayout(
    "t\ng\n- a\nh\n- far",
    points: [.init(x: 0, y: 0), .init(x: 100, y: 0), .init(x: 1000, y: 0), .init(x: 1100, y: 0)])
  let model = motionModel("t\ng\n- a\nh\n- far\nnew")
  var sim = LayoutSimulation(
    previous: old, model: model, placements: [4: .init(x: 500, y: 500)], today: motionDay,
    calendar: motionCalendar)
  #expect(point(sim.layout, 4) == .init(x: 500, y: 500))
  finish(&sim)
  #expect(point(sim.layout, 4) == .init(x: 500, y: 500))
  for i in 0..<4 { #expect(point(sim.layout, i) == point(old, i)) }
  let spawned = sim.spawnPoint(around: 0, depth: 1)
  #expect(abs(hypot(spawned.x, spawned.y) - 105) < 1e-9)
}

@Test func fixedTickRateMatchesAcrossDisplayRefreshRates() {
  let model = motionModel("t\ng\n- a\n- b")
  var sixty = LayoutSimulation(model: model, seed: 42, today: motionDay, calendar: motionCalendar)
  var oneTwenty = sixty
  for _ in 0..<60 { sixty.advance(by: 1.0 / 60) }
  for _ in 0..<120 { oneTwenty.advance(by: 1.0 / 120) }
  #expect(sixty.layout == oneTwenty.layout)
  finish(&sixty)
  #expect(sixty.isFrozen)
  #expect(sixty.layout.alpha < 0.003)
}

@Test func savedPositionsRestoreInstantlyAndUnknownNodesRelaxLocally() throws {
  let old = motionLayout(
    "t\ng\n- a\nh",
    points: [
      .init(x: 0, y: 0), .init(x: 100, y: 0), .init(x: 1000, y: 0),
    ])
  let sidecar = LayoutSidecar(layout: old, pins: ["g/a": point(old, 1)])
  #expect(sidecar.version == 2)
  #expect(
    try JSONDecoder().decode(LayoutSidecar.self, from: JSONEncoder().encode(sidecar)) == sidecar)
  let restored = LayoutSimulation(
    model: old.model, sidecar: sidecar, today: motionDay, calendar: motionCalendar)
  #expect(restored.isFrozen)
  #expect(restored.layout.nodes == old.nodes)
  var edited = LayoutSimulation(
    model: motionModel("t\ng\n- a\n- new\nh"), sidecar: sidecar, today: motionDay,
    calendar: motionCalendar)
  #expect(point(edited.layout, 1) == point(old, 1))
  finish(&edited)
  #expect(point(edited.layout, 3) == point(old, 2))
}

@Test func versionOneMigratesThroughSeededLayoutOnce() throws {
  let data = Data(#"{"seed":42,"pins":{"g/a":{"x":123,"y":456}}}"#.utf8)
  let legacy = try JSONDecoder().decode(LayoutSidecar.self, from: data)
  #expect(legacy.version == 1)
  let model = motionModel("t\ng\n- a\n- b")
  let sim = LayoutSimulation(
    model: model, sidecar: legacy, today: motionDay, calendar: motionCalendar)
  let expected = ForceLayout.run(
    model: model, seed: 42, pins: legacy.pins, today: motionDay, calendar: motionCalendar)
  #expect(sim.isFrozen)
  #expect(sim.layout.nodes == expected.nodes)
  #expect(sim.snapshotSidecar().version == 2)
  #expect(sim.snapshotSidecar().positions.count == model.nodeCount)
}

@Test func draggingAfterFullSettleDoesNotReactivateRemoteNodes() {
  var params = ForceParams()
  params.center = 0
  params.urgency = .off
  var sim = LayoutSimulation(
    model: motionModel("t\ng\n- a\n\t- child\nh\n- far"), seed: 42, params: params,
    today: motionDay, calendar: motionCalendar)
  finish(&sim)
  let old = sim.layout
  #expect(!overlap(old.nodes[1], old.nodes[4]))
  sim.beginDrag(1)
  sim.drag(to: .init(x: old.nodes[1].x + 5, y: old.nodes[1].y))
  sim.advance(by: 0.1)
  #expect(point(sim.layout, 4) == point(old, 4))
}

@Test func duplicateNameMoveUsesNearestUnmatchedDocumentNode() {
  let identity = NodeIdentity.match(
    old: motionModel("t\ng\n- same\nh\n- same\ni"),
    new: motionModel("t\ng\nh\ni\n- same"))
  #expect(identity.newToOld[3] == 3)
  #expect(identity.moved == [3])
  #expect(identity.deleted == [1])
}

// MARK: Immobility over the sample fixture

private let motionSample = motionLayout(
  try! String(contentsOf: fixtureURL, encoding: .utf8), points: [])

private enum Edit: CaseIterable { case add, delete, rename, indent }

/// One edit applied to every third line of the sample text (all lines is slow in Debug).
private func edited(_ edit: Edit) -> [String] {
  let lines = try! String(contentsOf: fixtureURL, encoding: .utf8).components(separatedBy: "\n")
  return stride(from: 1, to: lines.count, by: 3).compactMap { i -> String? in
    let line = lines[i]
    guard !line.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
    var copy = lines
    let indent = String(line.prefix { $0 == "\t" })
    let bullet = line.dropFirst(indent.count).hasPrefix("- ")
    switch edit {
    case .add: copy.insert(indent + (bullet ? "- " : "\t- ") + "added task", at: i + 1)
    case .delete: copy.remove(at: i)
    case .rename:
      // Insert before trailing metadata so the edit stays a rename of the visible name.
      copy[i] =
        indent + (bullet ? "- " : "") + "renamed "
        + line.dropFirst(indent.count + (bullet ? 2 : 0))
    case .indent:
      guard bullet else { return nil }
      copy[i] = "\t" + line
    }
    return copy.joined(separator: "\n")
  }
}

@Test(arguments: Edit.allCases)
private func everyEditLeavesNodesOutsideTheAffectedSetExactlyStill(_ edit: Edit) {
  let old = motionSample
  let texts = edited(edit)
  #expect(texts.count > 30)
  for text in texts {
    var sim = LayoutSimulation(
      previous: old, model: motionModel(text), today: motionDay, calendar: motionCalendar)
    let identity = NodeIdentity.match(old: old.model, new: sim.layout.model)
    if edit == .delete && identity.moved.isEmpty {
      #expect(sim.isFrozen, "a deletion with no reparenting starts frozen")
    }
    finish(&sim)
    #expect(sim.isFrozen)
    var still = 0
    for (new, previous) in identity.newToOld where !sim.affected.contains(new) {
      still += 1
      #expect(point(sim.layout, new) == point(old, previous))
    }
    if identity.moved.isEmpty {
      #expect(still > old.nodes.count / 2, "an edit that reparents nothing stays local")
    }
  }
}

/// Raw label box overlap depth (no margin); 0 when apart.
private func depth(_ a: GraphNode, _ b: GraphNode) -> Double {
  max(
    0,
    min(
      min(a.x + a.halfWidth, b.x + b.halfWidth) - max(a.x - a.halfWidth, b.x - b.halfWidth),
      min(a.y + a.down, b.y + b.down) - max(a.y - a.up, b.y - b.up)))
}

/// Sweeps a subtree through the densest part of the 500-node map. The grid must find every
/// neighbor the old all-pairs loops found, pushed nodes must not drift or spread across the
/// map, the drag must freeze, and nodes outside the cascade must stay exactly still.
@Test func crowdedDragStaysBoundedAndFreezes() throws {
  let text = try String(
    contentsOf: fixtureURL.deletingLastPathComponent().appendingPathComponent("large.mindmap"),
    encoding: .utf8)
  let old = ForceLayout.run(
    model: motionModel(text), seed: 7, today: motionDay, calendar: motionCalendar)
  #expect(old.nodes.count == 500)
  var sim = LayoutSimulation(
    previous: old, model: old.model, today: motionDay, calendar: motionCalendar)
  let dragged = try #require(old.model.nodes.firstIndex { $0.children.count >= 2 })
  var subtree: Set = [dragged]
  var pending = old.model.nodes[dragged].children
  while let child = pending.popLast() {
    subtree.insert(child)
    pending += old.model.nodes[child].children
  }
  let start = point(old, dragged)
  sim.beginDrag(dragged)
  for step in 1...60 {
    let t = Double(step) / 60
    sim.drag(to: .init(x: start.x * (1 - t), y: start.y * (1 - t)))
    sim.advance(by: 1.0 / 120)
  }
  // Holding still cools the drag, so the subtree stops pressing on the crowd.
  for _ in 0..<480 { sim.advance(by: 1.0 / 120) }
  let held = sim.layout
  for _ in 0..<480 { sim.advance(by: 1.0 / 120) }
  for i in held.nodes.indices {
    #expect(
      hypot(sim.layout.nodes[i].x - held.nodes[i].x, sim.layout.nodes[i].y - held.nodes[i].y) < 20)
  }
  sim.endDrag()
  for _ in 0..<600 where !sim.isFrozen { sim.advance(by: 1.0 / 120) }
  #expect(sim.isFrozen, "release freezes within 5 s")
  let layout = sim.layout
  let pushed = sim.affected.subtracting(subtree)
  #expect(pushed.count > 10, "the drag reached a crowd")
  #expect(pushed.count < 400, "the cascade never takes over the map")
  let drift = pushed.map {
    hypot(layout.nodes[$0].x - old.nodes[$0].x, layout.nodes[$0].y - old.nodes[$0].y)
  }
  #expect(drift.reduce(0, +) / Double(drift.count) < 60, "pushed nodes move aside, not away")
  for i in sim.affected where sim.pins[old.model.nodes[i].pathKey] == nil {
    for j in layout.nodes.indices where j != i {
      let before =
        subtree.contains(i) || subtree.contains(j) ? 0 : depth(old.nodes[i], old.nodes[j])
      #expect(depth(layout.nodes[i], layout.nodes[j]) <= before + 6, "\(i) overlaps \(j) by \(depth(layout.nodes[i], layout.nodes[j])), before \(before)")
    }
  }
  #expect(sim.affected.contains(dragged))
  for i in layout.nodes.indices where !sim.affected.contains(i) {
    #expect(point(layout, i) == point(old, i))
  }
}

import CoreGraphics
import Foundation
import MindmapCore
import Testing

private var utc: Calendar {
  var calendar = Calendar(identifier: .gregorian)
  calendar.timeZone = TimeZone(secondsFromGMT: 0)!
  return calendar
}

/// A Friday.
private let friday = utc.date(from: DateComponents(year: 2026, month: 10, day: 2, hour: 15))!

private func model(_ text: String) -> MapModel {
  MapParser.parse(text: text, today: friday, calendar: utc)
}

private func layout(_ text: String, seed: Int = 42, pins: [String: LayoutPoint] = [:])
  -> GraphLayout
{
  ForceLayout.run(model: model(text), seed: seed, pins: pins, today: friday, calendar: utc)
}

private let sample = try! String(contentsOf: fixtureURL, encoding: .utf8)

@Test func sameSeedGivesSamePositions() {
  let a = layout(sample)
  let b = layout(sample)
  #expect(a.nodes == b.nodes)
  #expect(layout(sample, seed: 43).nodes != a.nodes)
}

@Test func simulationConverges() {
  let result = layout(sample)
  #expect(result.alpha < 0.003)
  #expect(result.ticks > 250 && result.ticks < 320)
  #expect(result.nodes.allSatisfy { $0.x.isFinite && $0.y.isFinite })
}

@Test func sameGroupLabelsDontOverlapAfterHardPass() {
  let groups = model(sample).nodes
  for seed in [1, 42, 99_991] {
    let nodes = layout(sample, seed: seed).nodes
    for i in nodes.indices {
      for j in nodes.indices where j > i {
        let a = nodes[i]
        let b = nodes[j]
        guard a.group == b.group || (groups[i].depth == 0 && groups[j].depth == 0) else {
          continue
        }
        let ox =
          min(a.x + a.halfWidth, b.x + b.halfWidth) - max(a.x - a.halfWidth, b.x - b.halfWidth)
        let oy = min(a.y + a.down, b.y + b.down) - max(a.y - a.up, b.y - b.up)
        #expect(ox <= 0 || oy <= 0, "seed \(seed): \(a.lines) overlaps \(b.lines)")
      }
    }
  }
}

@Test func pinnedNodesStayAcrossRebuilds() {
  let pins = [
    "garden/plant herbs": LayoutPoint(x: 400, y: -300), "kitchen": LayoutPoint(x: 0, y: 0),
  ]
  let first = layout(sample, pins: pins)
  let edited = layout(sample + "\nnew group\n- new task\n", pins: pins)
  for result in [first, edited] {
    for (key, point) in pins {
      let index = result.model.nodes.firstIndex { $0.pathKey == key }!
      #expect(result.nodes[index].x == point.x && result.nodes[index].y == point.y)
    }
  }
}

@Test func largeLayoutConverges() throws {
  let url = fixtureURL.deletingLastPathComponent().appendingPathComponent("large.mindmap")
  let text = try String(contentsOf: url, encoding: .utf8)
  let result = layout(text)
  #expect(result.nodes.count == 500)
  #expect(result.alpha < 0.003)
}

@Test func urgencyScores() {
  let m = model(
    "t\ng\n- today /today\n- tomorrow high /tomorrow /high\n- monday medium /monday /med\n"
      + "- plain\n- parent\n\t- child /today /high\n- [x] done /today /high\n\t- open child /today")
  let u = ForceLayout.urgency(m, today: friday, calendar: utc)
  let byName = Dictionary(uniqueKeysWithValues: zip(m.nodes.map(\.name), u))
  #expect(byName["today"] == 1)
  #expect(byName["tomorrow high"] == 1)  // 7/8 + 0.5, capped
  #expect(byName["monday medium"] == 5.0 / 8 + 0.25)  // Friday → Monday is 3 days
  #expect(byName["plain"] == 0)
  #expect(byName["child"] == 1)
  #expect(byName["parent"] == 0.85)
  #expect(byName["done"] == 0)
  #expect(byName["open child"] == 1)
  #expect(byName["g"] == 0.85)
}

@Test func wrapsLabelsLikeThePrototype() {
  #expect(ForceLayout.wrap("short") == ["short"])
  #expect(ForceLayout.wrap("finish the mystery novel") == ["finish the mystery", "novel"])
  #expect(
    ForceLayout.wrap("one two three four five six seven eight nine ten")
      == ["one two three four", "five six seven…"])
}

@Test func sidecarSaveLoadAndRename() throws {
  let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
  try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: folder) }
  let map = folder.appending(path: "week.mindmap")
  #expect(LayoutSidecar.url(for: map).lastPathComponent == ".week.mindmap.layout.json")
  #expect(LayoutSidecar.load(for: map) == nil)
  let state = LayoutSidecar(seed: 1234, pins: ["home/dishes": LayoutPoint(x: 1.5, y: -2)])
  try state.save(for: map)
  #expect(LayoutSidecar.load(for: map) == state)
  let renamed = folder.appending(path: "month.mindmap")
  try LayoutSidecar(seed: 9).save(for: renamed)  // stale leftover is replaced
  try LayoutSidecar.move(from: map, to: renamed)
  #expect(LayoutSidecar.load(for: map) == nil)
  #expect(LayoutSidecar.load(for: renamed) == state)
  #expect(try MapFiles.list(in: folder).isEmpty)  // hidden, never listed as a map
}

@Test func zoomClampsToTenthOfFitAndTenTimesIn() {
  let fit = Camera.fit(
    CGRect(x: -500, y: -300, width: 1000, height: 600), in: CGSize(width: 800, height: 600))
  #expect(abs(fit.zoom - 800.0 / 1060) < 1e-9)
  let limits = Camera.limits(fitZoom: fit.zoom)
  let center = CGPoint(x: 400, y: 300)
  #expect(fit.zoomed(by: 1000, about: center, limits: limits).zoom == fit.zoom * 10)
  #expect(fit.zoomed(by: 0.0001, about: center, limits: limits).zoom == fit.zoom / 10)
  let anchor = CGPoint(x: 123, y: 456)
  let zoomed = fit.zoomed(by: 2, about: anchor, limits: limits)
  let before = fit.toWorld(anchor)
  let after = zoomed.toWorld(anchor)
  #expect(abs(before.x - after.x) < 1e-9 && abs(before.y - after.y) < 1e-9)
}

@Test func fitNeverNarrowerThan380Units() {
  let fit = Camera.fit(
    CGRect(x: 0, y: 0, width: 10, height: 10), in: CGSize(width: 760, height: 760))
  #expect(abs(fit.zoom - 2) < 1e-9)
}

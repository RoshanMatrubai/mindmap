import AppKit
import Foundation
import MindmapCore
import Testing

@testable import MindmapGraph

private func simulation(_ text: String) -> LayoutSimulation {
  var calendar = Calendar(identifier: .gregorian)
  calendar.timeZone = TimeZone(secondsFromGMT: 0)!
  let day = Date(timeIntervalSince1970: 1_790_985_600)
  return LayoutSimulation(
    model: MapParser.parse(text: text, today: day, calendar: calendar), seed: 42, today: day,
    calendar: calendar)
}

/// A frame, snapshot or freeze from the previous map must never reach the next one.
@MainActor
@Test func resultsFromThePreviousMapAreDropped() async {
  let view = GraphView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
  var freezes: [UUID] = []
  view.onFreeze = { document, _, _ in freezes.append(document) }
  let (a, b) = (UUID(), UUID())
  let first = simulation("first\ng\n- a\n- b")
  view.show(first, title: "first", refit: true, document: a)
  let stale = await SimulationWorker(first, document: a).frame(seconds: 10, drag: nil)
  #expect(stale.simulation.isFrozen)

  let second = simulation("second\nh\n- c")
  view.show(second, title: "second", refit: true, document: b)
  #expect(!view.controller.apply(stale, seconds: 10, drag: nil, generation: 0))
  #expect(
    !view.controller.apply(stale, seconds: 10, drag: nil, generation: view.controller.generation))
  #expect(view.scene.layout?.model == second.layout.model)
  #expect(view.displayedSimulation?.layout.model == second.layout.model)
  #expect(freezes.isEmpty)
  #expect(await view.simulationSnapshot(for: a) == nil)
  #expect(await view.stopAndSnapshot(for: a) == nil)
  #expect(await view.simulationSnapshot(for: b)?.layout.model == second.layout.model)
}

@Test func wheelZoomIsProportionalAndClamped() {
  #expect(GraphView.wheelZoom(1, precise: false) == 1.12)
  #expect(GraphView.wheelZoom(10, precise: true) == 1.12)
  #expect(GraphView.wheelZoom(-10, precise: true) == 1 / 1.12)
  #expect(abs(GraphView.wheelZoom(2.5, precise: true) - pow(1.12, 0.25)) < 1e-12)
  #expect(GraphView.wheelZoom(500, precise: true) == GraphView.wheelZoom(3.5, precise: false))
  #expect(GraphView.wheelZoom(500, precise: true) < 1.5)
}

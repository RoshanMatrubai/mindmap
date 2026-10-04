import Foundation
import MindmapCore

struct GraphDrag: Sendable, Equatable {
  var index: Int
  var point: LayoutPoint
  var active: Bool
  /// ⇧-drag: the subtree follows.
  var subtree = false
}

struct SimulationFrame: Sendable {
  var document: UUID
  var simulation: LayoutSimulation
  var layout: GraphLayout
}

/// This actor is the only writer of simulation state. AppKit never runs a physics tick.
actor SimulationWorker {
  /// Every frame names the map it belongs to.
  let document: UUID
  private var simulation: LayoutSimulation
  private var dragged: Int?
  private var appliedDrag: GraphDrag?

  init(_ simulation: LayoutSimulation, document: UUID) {
    self.simulation = simulation
    self.document = document
  }

  func frame(seconds: Double, drag: GraphDrag?) -> SimulationFrame {
    apply(drag)
    simulation.advance(by: seconds)
    return SimulationFrame(document: document, simulation: simulation, layout: simulation.layout)
  }

  func snapshot(drag: GraphDrag?) -> LayoutSimulation {
    apply(drag)
    return simulation
  }

  private func apply(_ drag: GraphDrag?) {
    guard let drag, drag != appliedDrag else { return }
    appliedDrag = drag
    if dragged != drag.index {
      simulation.beginDrag(drag.index, subtree: drag.subtree)
      dragged = drag.index
    }
    simulation.drag(to: drag.point)
    if !drag.active {
      simulation.endDrag()
      dragged = nil
    }
  }
}

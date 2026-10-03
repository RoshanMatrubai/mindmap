import MindmapGraph
import SwiftUI

struct GraphPane: NSViewRepresentable {
  @Bindable var store: MapStore

  func makeNSView(context: Context) -> GraphView {
    let view = GraphView(frame: NSRect(x: 0, y: 0, width: 600, height: 600))
    view.onPin = { key, point in store.pin(key, at: point) }
    store.graphView = view
    return view
  }

  /// Redraws only when the store has a new layout, not on every SwiftUI update, so a dragged
  /// node isn't snapped back.
  func updateNSView(_ view: GraphView, context: Context) {
    guard let graph = store.graph, graph.generation != context.coordinator.generation else {
      return
    }
    context.coordinator.generation = graph.generation
    let title = graph.layout.model.title
    view.show(
      graph.layout, title: (title.isEmpty ? "untitled map" : title).lowercased(), refit: graph.refit
    )
    #if DEBUG
      DebugLaunch.zoomOnce(view)
    #endif
  }

  func makeCoordinator() -> Coordinator { Coordinator() }

  final class Coordinator {
    var generation = 0
  }
}

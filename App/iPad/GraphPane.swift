import MindmapGraph
import SwiftUI

/// Hosts the touch graph and wires it to the shared store, as the Mac's GraphPane does.
struct GraphPane: UIViewRepresentable {
  @Bindable var store: PadMapStore
  /// False while a narrow window shows the text: the graph pauses its motion.
  var visible = true
  /// A narrow window: the long-press menu offers "Edit Text".
  var offersEditText = false

  func makeUIView(context: Context) -> GraphView {
    let view = GraphView(frame: CGRect(x: 0, y: 0, width: 600, height: 600))
    view.onPin = { document, key, point in store.pin(document: document, key, at: point) }
    view.onFreeze = { document, layout, pins in
      store.graphFrozen(document: document, layout, pins: pins)
    }
    view.onSelect = { index in store.graphSelected(index) }
    view.onEdit = { edit in store.applyGraphEdit(edit) }
    view.onFocus = { focused in store.graphFocused = focused }
    view.onSettle = { alpha in store.settleChanged(alpha) }
    view.onMessage = { message in store.showNotice(message) }
    view.onEditText = { index in store.editText(index) }
    view.scene.labelFamily = store.preferences.labelFont
    store.graphView = view
    return view
  }

  /// Redraws only when the store has a new layout, not on every SwiftUI update, so a dragged
  /// node isn't snapped back.
  func updateUIView(_ view: GraphView, context: Context) {
    view.isOnScreen = visible
    // ⌘Z with the graph focused undoes in the editor's stack, where graph edits go.
    view.externalUndoManager = store.editorView?.undoManager
    view.offersEditText = offersEditText
    guard let graph = store.graph, graph.generation != context.coordinator.generation else {
      return
    }
    context.coordinator.generation = graph.generation
    view.onFirstFrame = { _ in store.graphShown(document: graph.documentID) }
    if view.scene.labelFamily != graph.family { view.scene.labelFamily = graph.family }
    let title = graph.layout.model.title
    view.show(
      graph.simulation, title: (title.isEmpty ? "untitled map" : title).lowercased(),
      refit: graph.refit, reuseNodes: graph.reuseNodes, document: graph.documentID
    )
    // Not during this SwiftUI update: the store's observed state changes.
    Task { @MainActor in store.graphDidUpdate() }
    #if DEBUG
      DebugLaunch.stageOnce(view, store)
    #endif
  }

  func makeCoordinator() -> Coordinator { Coordinator() }

  final class Coordinator {
    var generation = 0
  }
}

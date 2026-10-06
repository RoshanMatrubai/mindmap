import MindmapGraph
import SwiftUI

/// The graph fills the window, with the detail panel along the bottom (as in the Mac's graph
/// pane). The canvas color runs under the status bar and the home indicator.
struct ContentView: View {
  @Bindable var store: MapStore

  var body: some View {
    VStack(spacing: 0) {
      GraphPane(store: store)
      DetailPanel(store: store)
    }
    .background(Color(cgColor: GraphStyle.canvas).ignoresSafeArea())
    .preferredColorScheme(.dark)
    .onAppear {
      // Debug builds already use their container; Release has no picker until step i4.
      if store.folder == nil && !store.isSwitching { store.useAppFolder() }
      #if DEBUG
        DebugLaunch.logLaunch("window")
        TouchSmoke.runIfRequested(store)
      #endif
    }
    .alert(
      "map file",
      isPresented: Binding(
        get: { store.errorMessage != nil }, set: { if !$0 { store.errorMessage = nil } })
    ) {
      Button("OK") { store.errorMessage = nil }
    } message: {
      Text(store.errorMessage ?? "")
    }
  }
}

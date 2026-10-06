import SwiftUI

/// The iPad app, roadmap step i2: the touch graph and its detail panel over the shared store.
/// The outline editor comes in step i3; until then graph edits change the store's text directly,
/// with the store's undo manager. Maps live in the app's own container (no folder picker yet).
@main
struct MindmapApp: App {
  @State private var store: MapStore
  @Environment(\.scenePhase) private var scenePhase

  init() {
    #if DEBUG
      DebugLaunch.requireDevBundleID()
    #endif
    log.notice("launch \(Bundle.main.bundleIdentifier ?? "<none>", privacy: .public)")
    _store = State(initialValue: MapStore())
  }

  var body: some Scene {
    WindowGroup {
      ContentView(store: store)
    }
    .onChange(of: scenePhase) { _, phase in
      switch phase {
      // Picks up changes made while away (the Mac activation rule).
      case .active: store.activated()
      // Saved before the system may end the app; nothing keeps running in the background.
      case .background: Task { await store.saveNow() }
      default: break
      }
    }
  }
}

import SwiftUI

@main
struct MindmapApp: App {
  @NSApplicationDelegateAdaptor(AppLifecycle.self) private var lifecycle
  @State private var store: MapStore

  init() {
    #if DEBUG
      DebugLaunch.configure()
      // Data rule: Debug builds must use the .dev bundle ID, so they get their own sandbox
      // container and settings, and can never pick up the real app's maps folder. See docs/decisions/0001-dev-environment.md.
      let id = Bundle.main.bundleIdentifier ?? "<none>"
      guard id.hasSuffix(".dev") else {
        fatalError(
          "Debug build has bundle ID \(id); it must end in .dev to keep real data out of reach.")
      }
    #endif
    log.notice("launch \(Bundle.main.bundleIdentifier ?? "<none>", privacy: .public)")
    let store = MapStore()
    _store = State(initialValue: store)
    AppLifecycle.store = store
  }

  var body: some Scene {
    WindowGroup {
      ContentView(store: store)
    }
    .commands {
      CommandGroup(replacing: .newItem) {
        Button("New Map") { store.newMap() }
          .keyboardShortcut("n", modifiers: .command)
          .disabled(store.folder == nil || store.isSwitching)
        Button("Change Maps Folder…") { store.chooseFolder() }
      }
    }
    Settings {
      // Settings window arrives in roadmap step 4.
      EmptyView()
    }
  }
}

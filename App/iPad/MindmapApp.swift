import SwiftUI

/// The iPad app: the outline editor and the touch graph over the shared store, side by side in
/// wide windows. Menus and shortcuts come from the Mac's `AppCommand` table.
@main
struct MindmapApp: App {
  @State private var store: PadMapStore
  @Environment(\.scenePhase) private var scenePhase

  init() {
    #if DEBUG
      DebugLaunch.requireDevBundleID()
    #endif
    log.notice("launch \(Bundle.main.bundleIdentifier ?? "<none>", privacy: .public)")
    _store = State(initialValue: PadMapStore())
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
    .commands {
      CommandGroup(replacing: .newItem) {
        AppCommand.newMap.button(store)
        Button("Change Maps Folder…") { store.chooseFolder() }
        Divider()
        AppCommand.nextMap.button(store)
        AppCommand.previousMap.button(store)
      }
      CommandMenu("Outline") {
        AppCommand.toggleDone.button(store)
        Divider()
        AppCommand.indent.button(store)
        AppCommand.outdent.button(store)
        Divider()
        AppCommand.moveUp.button(store)
        AppCommand.moveDown.button(store)
        Divider()
        AppCommand.addTask.button(store)
        AppCommand.addSubtask.button(store)
        AppCommand.deleteNode.button(store)
        Menu("Priority") {
          AppCommand.priorityHigh.button(store)
          AppCommand.priorityMedium.button(store)
          AppCommand.priorityLow.button(store)
          AppCommand.priorityChill.button(store)
          Divider()
          AppCommand.priorityNone.button(store)
        }
      }
      CommandGroup(after: .toolbar) {
        AppCommand.zoomIn.button(store)
        AppCommand.zoomOut.button(store)
        AppCommand.fitAll.button(store)
        AppCommand.reshuffle.button(store)
        Divider()
        AppCommand.biggerLabels.button(store)
        AppCommand.smallerLabels.button(store)
        Divider()
        AppCommand.focusEditor.button(store)
        AppCommand.focusGraph.button(store)
        Divider()
        AppCommand.clearSelection.button(store)
        AppCommand.selectParent.button(store)
        AppCommand.selectFirstChild.button(store)
        AppCommand.selectPreviousSibling.button(store)
        AppCommand.selectNextSibling.button(store)
      }
    }
  }
}

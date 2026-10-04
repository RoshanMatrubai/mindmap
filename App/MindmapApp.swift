import AppKit
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
    .defaultSize(width: 1400, height: 900)
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
        AppCommand.focusEditor.button(store)
        AppCommand.focusGraph.button(store)
        Divider()
        AppCommand.clearSelection.button(store)
        AppCommand.selectParent.button(store)
        AppCommand.selectFirstChild.button(store)
        AppCommand.selectPreviousSibling.button(store)
        AppCommand.selectNextSibling.button(store)
        Divider()
      }
    }
    Settings {
      // Settings window arrives in roadmap step 4.
      EmptyView()
    }
  }
}

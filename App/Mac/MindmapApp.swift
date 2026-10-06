import AppKit
import SwiftUI

@main
struct MindmapApp: App {
  @NSApplicationDelegateAdaptor(AppLifecycle.self) private var lifecycle
  @State private var store: MapStore

  init() {
    #if DEBUG
      DebugLaunch.configure()
      DebugLaunch.requireDevBundleID()
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
      CommandGroup(replacing: .appSettings) {
        AppCommand.settings.button(store)
      }
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
        AppCommand.toggleForcesPanel.button(store)
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
        Divider()
      }
    }
    Settings {
      SettingsView(store: store)
    }
  }
}

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

  /// Editor commands go to whichever outline editor has focus.
  private func send(_ action: Selector) {
    NSApp.sendAction(action, to: nil, from: nil)
  }

  var body: some Scene {
    WindowGroup {
      ContentView(store: store)
    }
    .defaultSize(width: 1400, height: 900)
    .commands {
      CommandGroup(replacing: .newItem) {
        Button("New Map") { store.newMap() }
          .keyboardShortcut("n", modifiers: .command)
          .disabled(store.folder == nil || store.isSwitching)
        Button("Change Maps Folder…") { store.chooseFolder() }
        Divider()
        Button("Next Map") { store.switchMap(by: 1) }
          .keyboardShortcut("]", modifiers: [.command, .shift])
          .disabled(store.maps.count < 2 || store.isSwitching)
        Button("Previous Map") { store.switchMap(by: -1) }
          .keyboardShortcut("[", modifiers: [.command, .shift])
          .disabled(store.maps.count < 2 || store.isSwitching)
      }
      CommandMenu("Outline") {
        Button("Toggle Done") { send(#selector(OutlineTextView.toggleDone(_:))) }
          .keyboardShortcut("u", modifiers: [.command, .shift])
        Divider()
        Button("Indent") { send(#selector(OutlineTextView.indentLines(_:))) }
          .keyboardShortcut("]", modifiers: .command)
        Button("Outdent") { send(#selector(OutlineTextView.outdentLines(_:))) }
          .keyboardShortcut("[", modifiers: .command)
        Divider()
        Button("Move Up") { send(#selector(OutlineTextView.moveLineUp(_:))) }
          .keyboardShortcut(.upArrow, modifiers: [.control, .command])
        Button("Move Down") { send(#selector(OutlineTextView.moveLineDown(_:))) }
          .keyboardShortcut(.downArrow, modifiers: [.control, .command])
      }
      CommandGroup(after: .toolbar) {
        Button("Zoom In") { store.graphView?.zoomIn() }
          .keyboardShortcut("=", modifiers: .command)
        Button("Zoom Out") { store.graphView?.zoomOut() }
          .keyboardShortcut("-", modifiers: .command)
        Button("Fit All") { store.graphView?.fitAll() }
          .keyboardShortcut("0", modifiers: .command)
        Button("Reshuffle") { store.reshuffle() }
          .keyboardShortcut("r", modifiers: [.command, .shift])
          .disabled(store.currentURL == nil)
        Divider()
        Button("Focus Editor") { store.focusEditor() }
          .keyboardShortcut("1", modifiers: .command)
        Button("Focus Graph") { store.focusGraph() }
          .keyboardShortcut("2", modifiers: .command)
        Divider()
      }
    }
    Settings {
      // Settings window arrives in roadmap step 4.
      EmptyView()
    }
  }
}

#if DEBUG
  import MindmapCore
  import MindmapGraph
  import UIKit

  /// Roadmap step i5: the settings sheet, the forces popover, their shortcuts, live values and
  /// "animate settle".
  extension TouchSmoke {
    static func settingsChecks(_ store: PadMapStore, _ view: GraphView) async {
      guard await frozen(store, view) else { return }
      check(
        AppCommand.iPad.contains(.settings) && AppCommand.iPad.contains(.toggleForcesPanel),
        "the iPad menus have Settings (⌘,) and Forces Panel (⌥⌘F)")
      AppCommand.settings.perform(store)
      await wait("⌘, opens the settings sheet") {
        store.layout.showingSettings && DebugControls.settingsVisible
          && DebugControls.sliders["settings Repel"] != nil
      }
      let repel = store.preferences.forces.repel
      DebugControls.sliders["settings Repel"]?.wrappedValue = repel + 100
      check(
        store.preferences.forces.repel == repel + 100, "a Graph slider changes the setting live")
      store.layout.settingsTab = .text
      await wait("the Text tab shows the sizes") {
        DebugControls.sliders["settings Label size"] != nil
          && DebugControls.sliders["settings Editor size"] != nil
      }
      DebugControls.sliders["settings Editor size"]?.wrappedValue = 15
      await pause(300)
      check(
        store.preferences.editorFontSize == 15
          && store.editorView?.fontSize == 15, "Editor size applies to the editor")
      store.layout.showingSettings = false
      store.layout.settingsTab = .graph
      await wait("the settings sheet closes") { !DebugControls.settingsVisible }
      AppCommand.toggleForcesPanel.perform(store)
      await wait("⌥⌘F opens the forces popover") {
        DebugControls.panelVisible && DebugControls.sliders["panel repel"] != nil
      }
      DebugControls.sliders["panel link distance"]?.wrappedValue = 90
      check(store.preferences.forces.linkDistance == 90, "the popover's sliders apply live")
      AppCommand.toggleForcesPanel.perform(store)
      await wait("⌥⌘F closes it") { !DebugControls.panelVisible }
      await pause(600)
      guard await frozen(store, view) else { return }
      // Animate settle off: a reshuffle shows the frozen result at once, no display link.
      store.preferences.animateSettle = false
      let generation = store.graph?.generation ?? 0
      store.reshuffle()
      await wait("reshuffle with animate settle off") {
        (store.graph?.generation ?? 0) > generation && view.scene.layout?.model == store.model
          && store.parsedText == store.text
      }
      check(
        view.displayedSimulation?.isFrozen == true && !view.isAnimating
          && GraphView.debugLiveDisplayLinks == 0, "animate settle off shows the frozen layout")
      store.preferences.animateSettle = true
      await frozen(store, view)
    }
  }
#endif

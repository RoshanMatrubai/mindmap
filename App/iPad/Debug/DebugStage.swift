#if DEBUG
  import MindmapGraph
  import UIKit

  /// The iPad app's DEBUG-only launch arguments for screenshots (CI and the agent debug loop).
  /// Once the first graph has settled:
  /// - `-select-node "garden"` selects that node like a tap (branch lit, camera fitted);
  /// - with `-rename-node YES` its inline name field then opens, mid-rename;
  /// - `-show-menu "garden"` opens the long-press menu on that node.
  /// Each logs `debug stage ready: …` when the state is on screen.
  extension DebugLaunch {
    @MainActor static func stageOnce(_ view: GraphView, _ store: MapStore) {
      let defaults = UserDefaults.standard
      let select = defaults.string(forKey: "select-node")
      let menu = defaults.string(forKey: "show-menu")
      guard select != nil || menu != nil, !staged else { return }
      staged = true
      Task {
        // The settle, then the camera fit.
        let deadline = ContinuousClock.now.advanced(by: .seconds(20))
        while view.displayedSimulation?.isFrozen != true || view.scene.debugCameraAnimating,
          ContinuousClock.now < deadline
        {
          try? await Task.sleep(for: .milliseconds(50))
        }
        try? await Task.sleep(for: .milliseconds(500))
        guard let model = view.scene.layout?.model else { return }
        if let name = select {
          guard let index = model.nodes.firstIndex(where: { $0.name == name }) else {
            return log.error("select-node \(name, privacy: .public) not found")
          }
          view.select(index, camera: true)
          store.graphSelected(index)
          try? await Task.sleep(for: .milliseconds(700))
          if defaults.bool(forKey: "rename-node") {
            view.beginRename(index)
            try? await Task.sleep(for: .milliseconds(700))
            log.notice("debug stage ready: rename \(name, privacy: .public)")
          } else {
            log.notice("debug stage ready: select \(name, privacy: .public)")
          }
        }
        if let name = menu {
          guard let index = model.nodes.firstIndex(where: { $0.name == name }),
            let n = view.scene.layout?.nodes[index]
          else { return log.error("show-menu \(name, privacy: .public) not found") }
          let point = view.scene.camera.toScreen(CGPoint(x: n.x, y: n.y))
          let shown = view.debugPresentMenu(at: point)
          try? await Task.sleep(for: .milliseconds(900))
          log.notice(
            "debug stage ready: menu \(name, privacy: .public) presented=\(shown, privacy: .public)"
          )
        }
      }
    }
    @MainActor private static var staged = false
  }
#endif

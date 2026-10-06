#if DEBUG
  import AppKit
  import MindmapGraph

  /// The Mac app's DEBUG-only launch arguments for the agent debug loop (AGENTS.md). Excluded
  /// from Release builds. The fixture and bundle ID guard are in App/Shared/Debug/DebugBuild.swift.
  extension DebugLaunch {
    /// Fixtures and native smoke checks start with fresh window state, including after a crash.
    static var realReminders: Bool {
      let args = CommandLine.arguments
      return args.indices.contains { index in
        args[index] == "-real-reminders" && index + 1 < args.count && args[index + 1] == "YES"
      }
    }

    static func configure() {
      precondition(
        !realReminders || !UserDefaults.standard.bool(forKey: "editor-smoke"),
        "The smoke harness must never run with real Reminders access.")
      if UserDefaults.standard.string(forKey: "fixture") != nil
        || UserDefaults.standard.bool(forKey: "editor-smoke")
      {
        UserDefaults.standard.register(defaults: ["ApplePersistenceIgnoreState": true])
      }
    }

    /// `-window-size 1400x900` sets the window's content size, for screenshots.
    @MainActor static func applyWindowSize() {
      guard let value = UserDefaults.standard.string(forKey: "window-size") else { return }
      let parts = value.split(separator: "x").compactMap { Double($0) }
      guard parts.count == 2 else { return }
      DispatchQueue.main.async {
        NSApp.windows.first?.setContentSize(NSSize(width: parts[0], height: parts[1]))
        NSApp.windows.first?.center()
      }
    }

    /// `-graph-zoom 3` zooms (animated) once the first graph is shown, to check label sharpness.
    @MainActor static func zoomOnce(_ view: GraphView) {
      let factor = UserDefaults.standard.double(forKey: "graph-zoom")
      guard factor > 0, !zoomed else { return }
      zoomed = true
      DispatchQueue.main.async { view.zoom(by: factor) }
    }
    @MainActor private static var zoomed = false

    /// `-select-node "garden"` selects that node once the first graph is shown, like a click;
    /// `-rename-node YES` then opens its inline name field. For screenshots.
    @MainActor static func selectOnce(_ view: GraphView, _ store: MacMapStore) {
      guard let name = UserDefaults.standard.string(forKey: "select-node"), !selected else {
        return
      }
      selected = true
      Task {
        try? await Task.sleep(for: .seconds(1))
        guard let index = view.scene.layout?.model.nodes.firstIndex(where: { $0.name == name })
        else { return log.error("select-node \(name, privacy: .public) not found") }
        view.select(index, camera: true)
        store.graphSelected(index)
        if UserDefaults.standard.bool(forKey: "rename-node") {
          try? await Task.sleep(for: .milliseconds(500))
          view.beginRename(index)
        }
      }
    }
    @MainActor private static var selected = false

    /// `-reshuffle-after 3` reshuffles once, that many seconds after launch, to capture the settle.
    @MainActor static func reshuffleOnce(_ store: MacMapStore) {
      let seconds = UserDefaults.standard.double(forKey: "reshuffle-after")
      guard seconds > 0, !reshuffled else { return }
      reshuffled = true
      Task {
        try? await Task.sleep(for: .seconds(seconds))
        store.reshuffle()
      }
    }
    @MainActor private static var reshuffled = false

    /// `-open-settings Text` opens the Settings window on that tab ("Graph", "Text" or "Reminders") once the
    /// first graph is shown. For screenshots.
    static var settingsTab: String? { UserDefaults.standard.string(forKey: "open-settings") }

    @MainActor static func openSettingsOnce(_ store: MacMapStore) {
      guard settingsTab != nil, !settingsOpened else { return }
      settingsOpened = true
      Task {
        try? await Task.sleep(for: .seconds(1))
        store.openSettings?()
      }
    }
    @MainActor private static var settingsOpened = false
  }
#endif

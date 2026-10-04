#if DEBUG
  import AppKit
  import MindmapGraph

  /// DEBUG-only launch arguments for the agent debug loop (AGENTS.md). Excluded from Release builds.
  enum DebugLaunch {
    /// Fixtures and native smoke checks start with fresh window state, including after a crash.
    static func configure() {
      if UserDefaults.standard.string(forKey: "fixture") != nil
        || UserDefaults.standard.bool(forKey: "editor-smoke")
      {
        UserDefaults.standard.register(defaults: ["ApplePersistenceIgnoreState": true])
      }
    }

    /// `-fixture <name>` (read via UserDefaults' argument domain) fills the editor from a fixture
    /// bundled into Debug builds. App/Debug/sample.mindmap mirrors Packages/MindmapKit/Tests/Fixtures.
    static var fixtureText: String? {
      guard let name = UserDefaults.standard.string(forKey: "fixture") else { return nil }
      guard let url = Bundle.main.url(forResource: name, withExtension: "mindmap"),
        let text = try? String(contentsOf: url, encoding: .utf8)
      else {
        log.error("fixture \(name, privacy: .public) not found")
        return nil
      }
      return text
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

    /// `-reshuffle-after 3` reshuffles once, that many seconds after launch, to capture the settle.
    @MainActor static func reshuffleOnce(_ store: MapStore) {
      let seconds = UserDefaults.standard.double(forKey: "reshuffle-after")
      guard seconds > 0, !reshuffled else { return }
      reshuffled = true
      Task {
        try? await Task.sleep(for: .seconds(seconds))
        store.reshuffle()
      }
    }
    @MainActor private static var reshuffled = false

    /// Without `-use-folder-picker YES`, maps go in a folder inside the dev container: no picker,
    /// no prompts, so the agent debug loop runs unattended. With it, Debug behaves like Release.
    static var containerMapsFolder: URL? {
      guard !UserDefaults.standard.bool(forKey: "use-folder-picker") else { return nil }
      let url = URL.applicationSupportDirectory.appending(path: "maps")
      try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
      return url
    }
  }
#endif

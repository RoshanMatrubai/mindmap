#if DEBUG
  import AppKit
  import MindmapGraph

  /// DEBUG-only launch arguments for the agent debug loop (AGENTS.md). Excluded from Release builds.
  enum DebugLaunch {
    /// Fixtures and native smoke checks start with fresh window state, including after a crash.
    static var realCalendar: Bool {
      let args = CommandLine.arguments
      return args.indices.contains { index in
        args[index] == "-real-calendar" && index + 1 < args.count && args[index + 1] == "YES"
      }
    }

    static func configure() {
      precondition(
        !realCalendar || !UserDefaults.standard.bool(forKey: "editor-smoke"),
        "The smoke harness must never run with real Calendar access.")
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

    /// `-select-node "garden"` selects that node once the first graph is shown, like a click;
    /// `-rename-node YES` then opens its inline name field. For screenshots.
    @MainActor static func selectOnce(_ view: GraphView, _ store: MapStore) {
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

    /// `-open-settings Text` opens the Settings window on that tab ("Graph", "Text" or "Calendar") once the
    /// first graph is shown. For screenshots.
    static var settingsTab: String? { UserDefaults.standard.string(forKey: "open-settings") }

    @MainActor static func openSettingsOnce(_ store: MapStore) {
      guard settingsTab != nil, !settingsOpened else { return }
      settingsOpened = true
      Task {
        try? await Task.sleep(for: .seconds(1))
        store.openSettings?()
      }
    }
    @MainActor private static var settingsOpened = false

    /// Logs milliseconds since the process started, once per stage (launch-time measurements).
    @MainActor static func logLaunch(_ stage: String) {
      guard !launchStages.contains(stage) else { return }
      launchStages.insert(stage)
      var info = kinfo_proc()
      var size = MemoryLayout<kinfo_proc>.stride
      var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
      guard sysctl(&mib, 4, &info, &size, nil, 0) == 0 else { return }
      let start = info.kp_proc.p_starttime
      let started = Double(start.tv_sec) + Double(start.tv_usec) / 1e6
      let ms = (Date().timeIntervalSince1970 - started) * 1000
      log.notice("launch \(stage, privacy: .public) ms=\(ms, privacy: .public)")
    }
    @MainActor private static var launchStages = Set<String>()

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

#if DEBUG
  import Foundation

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

#if DEBUG
  import Foundation

  /// DEBUG-only launch support shared by the Mac and iPad apps. Excluded from Release builds.
  /// The Mac app adds its own launch arguments in App/Mac/Debug/DebugLaunch.swift.
  enum DebugLaunch {
    /// Data rule: Debug builds must use the .dev bundle ID, so they get their own sandbox
    /// container and settings, and can never pick up the real app's data. See
    /// docs/decisions/0001-dev-environment.md.
    static func requireDevBundleID() {
      let id = Bundle.main.bundleIdentifier ?? "<none>"
      guard id.hasSuffix(".dev") else {
        fatalError(
          "Debug build has bundle ID \(id); it must end in .dev to keep real data out of reach.")
      }
    }

    /// `-fixture <name>` (read via UserDefaults' argument domain) fills the map from a fixture
    /// bundled into Debug builds. App/Shared/Debug/sample.mindmap mirrors
    /// Packages/MindmapKit/Tests/Fixtures.
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

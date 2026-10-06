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
  }
#endif

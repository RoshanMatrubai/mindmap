import MindmapCore
import MindmapGraph
import SwiftUI

/// The iPad app, roadmap step i1: the map title and its settled graph, no interaction yet.
/// Debug builds show the `-fixture` map; files and editing come in later steps.
@main
struct MindmapApp: App {
  init() {
    #if DEBUG
      DebugLaunch.requireDevBundleID()
    #endif
    log.notice("launch \(Bundle.main.bundleIdentifier ?? "<none>", privacy: .public)")
  }

  var body: some Scene {
    WindowGroup {
      // Inside the safe area, so the title clears the status bar; the canvas color fills behind.
      GraphPane(text: Self.text)
        .background(Color(cgColor: GraphStyle.canvas).ignoresSafeArea())
        .preferredColorScheme(.dark)
    }
  }

  private static var text: String {
    #if DEBUG
      if let fixture = DebugLaunch.fixtureText { return fixture }
    #endif
    return "untitled map\n"
  }
}

/// Parses and lays out off the main thread (as on the Mac), then lets the view settle it.
struct GraphPane: UIViewRepresentable {
  let text: String

  func makeUIView(context: Context) -> GraphView {
    let view = GraphView(frame: CGRect(x: 0, y: 0, width: 600, height: 600))
    let text = text
    let preferences = Preferences(defaults: .standard)
    view.scene.labelFamily = preferences.labelFont
    Task {
      let simulation = await Task.detached(priority: .userInitiated) {
        GraphFonts.register(preferences.labelFont)
        let today = Date()
        let model = MapParser.parse(text: text, today: today, calendar: .current)
        return LayoutSimulation(
          model: model, seed: LayoutSidecar.randomSeed(), params: preferences.forces,
          today: today, calendar: .current,
          measure: GraphStyle.measure(family: preferences.labelFont))
      }.value
      let title = simulation.layout.model.title
      view.show(
        simulation, title: (title.isEmpty ? "untitled map" : title).lowercased(), refit: true,
        document: UUID())
    }
    return view
  }

  func updateUIView(_ view: GraphView, context: Context) {}
}

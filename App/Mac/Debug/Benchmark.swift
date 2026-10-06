#if DEBUG
  import AppKit
  import MindmapGraph
  import os

  /// `-bench YES -fixture large`: scripted settle, pan, pinch, selection, crowded drag and typing
  /// on the 500-node map, one input per display frame. Each phase is a signpost interval
  /// ("Bench"), so Instruments can attribute it, and logs its late frames (a display callback
  /// more than 1.5 frames after the previous one) and main-thread input time. Excluded from
  /// Release builds.
  @MainActor
  enum Benchmark {
    static func runIfRequested(_ store: MapStore) {
      guard UserDefaults.standard.bool(forKey: "bench") else { return }
      Task { await run(store) }
    }

    private static let signposts = OSLog(
      subsystem: Bundle.main.bundleIdentifier!, category: "motion")

    private static func run(_ store: MapStore) async {
      guard
        await until({
          !store.isSwitching && store.graphView?.scene.layout?.model.nodeCount == 500
            && store.parsedText == store.text
        }), let view = store.graphView, let editor = store.editorView as? OutlineTextView,
        let window = view.window
      else { return log.error("bench: 500-node map not shown") }
      // The target is a ProMotion panel: run on the fastest screen, in front (occluded windows
      // pause the simulation).
      if let screen = NSScreen.screens.max(by: {
        $0.maximumFramesPerSecond < $1.maximumFramesPerSecond
      }) {
        window.setFrameOrigin(
          CGPoint(
            x: screen.visibleFrame.midX - window.frame.width / 2,
            y: screen.visibleFrame.midY - window.frame.height / 2))
        _ = await until { window.screen == screen }
      }
      NSApp.activate()
      window.orderFrontRegardless()
      guard await until({ frozen(view) }) else { return log.error("bench: map never froze") }
      log.notice(
        "bench start fps=\(view.window?.screen?.maximumFramesPerSecond ?? 0, privacy: .public)")
      try? await Task.sleep(for: .seconds(1))

      store.reshuffle()
      _ = await until { view.isAnimating }
      await phase("settle", view: view, frames: 1200, stop: { frozen(view) }, { _ in })

      view.fitAll()
      _ = await until { !view.scene.debugCameraAnimating }
      let center = CGPoint(x: view.bounds.midX, y: view.bounds.midY)
      await phase("pan", view: view, frames: 240) { frame in
        let dx: Int32 = frame % 120 < 60 ? 6 : -6
        if let event = trackpadScroll(dx: dx, dy: dx / 2) { view.scrollWheel(with: event) }
      }
      await phase("pinch", view: view, frames: 240) { frame in
        view.debugMagnify(by: frame % 120 < 60 ? 0.02 : -0.02, about: center)
      }
      _ = await until { frozen(view) }

      view.fitAll()
      _ = await until { !view.scene.debugCameraAnimating }
      let model = view.scene.layout!.model
      let groups = model.nodes.indices.filter { model.nodes[$0].depth == 0 }
      await phase("selection", view: view, frames: 240) { frame in
        guard frame % 30 == 0 else { return }
        let index: Int? = frame % 60 == 0 ? groups[(frame / 60) % groups.count] : nil
        view.select(index, camera: true)
        store.graphSelected(index)
      }
      _ = await until { !view.scene.debugCameraAnimating }

      view.fitAll()
      _ = await until { !view.scene.debugCameraAnimating }
      if let layout = view.scene.layout,
        let index = layout.model.nodes.firstIndex(where: { $0.children.count >= 2 })
      {
        let start = view.scene.camera.toScreen(
          CGPoint(x: layout.nodes[index].x, y: layout.nodes[index].y))
        view.mouseDown(with: mouse(.leftMouseDown, start, view))
        await phase("crowded drag", view: view, frames: 120) { frame in
          let t = Double(frame + 1) / 120
          let p = CGPoint(
            x: start.x + (center.x - start.x) * t, y: start.y + (center.y - start.y) * t)
          view.mouseDragged(with: mouse(.leftMouseDragged, p, view))
        }
        view.mouseUp(with: mouse(.leftMouseUp, center, view))
        await phase("drag release", view: view, frames: 1200, stop: { frozen(view) }, { _ in })
      }

      // About 30 characters a second in bursts, pausing past the 300 ms parse debounce so graph
      // rebuilds land between keystrokes.
      store.focusEditor()
      let end = (editor.string as NSString).range(
        of: "\n", options: [], range: NSRange(location: 20, length: 200))
      editor.setSelectedRange(NSRange(location: end.location, length: 0))
      var keystrokes: [Double] = []
      await phase("typing", view: view, frames: 8 * 60) { frame in
        guard frame % 60 < 20, frame % 4 == 0 else { return }
        let started = ContinuousClock.now
        editor.insertText(frame % 60 == 16 ? " " : "x", replacementRange: editor.selectedRange())
        keystrokes.append(milliseconds(started.duration(to: .now)))
      }
      keystrokes.sort()
      log.notice(
        "bench typing keystrokes=\(keystrokes.count, privacy: .public) median-ms=\(keystrokes[keystrokes.count / 2], privacy: .public) worst-ms=\(keystrokes.last ?? 0, privacy: .public)"
      )
      editor.undoManager?.undo()
      _ = await until { frozen(view) && store.parsedText == store.text }
      log.notice("bench complete")
    }

    private static func frozen(_ view: GraphView) -> Bool {
      !view.isAnimating && view.displayedSimulation?.isFrozen == true
    }

    /// The harness's bounded wait: checks every frame or so, at most 20 s.
    private static func until(_ predicate: () -> Bool) async -> Bool {
      let deadline = ContinuousClock.now.advanced(by: .seconds(20))
      while !predicate(), ContinuousClock.now < deadline {
        try? await Task.sleep(for: .milliseconds(10))
      }
      return predicate()
    }

    /// Calls `body` once per display frame for `frames` frames (or until `stop`), then logs.
    private static func phase(
      _ name: StaticString, view: GraphView, frames: Int, stop: (() -> Bool)? = nil,
      _ body: @escaping (Int) -> Void
    ) async {
      view.debugResetFrameMetrics()
      let id = OSSignpostID(log: signposts)
      os_signpost(.begin, log: signposts, name: "Bench", signpostID: id, "%{public}s", "\(name)")
      let driver = FrameDriver(frames: frames, stop: stop, body: body)
      await withCheckedContinuation { continuation in
        driver.finished = { continuation.resume() }
        driver.start(on: view)
      }
      os_signpost(.end, log: signposts, name: "Bench", signpostID: id)
      let input = driver.inputMilliseconds.sorted()
      let graph = view.debugFrameMetrics
      log.notice(
        "bench phase=\(name, privacy: .public) visible=\(view.window?.occlusionState.contains(.visible) == true, privacy: .public) frames=\(driver.intervals.count, privacy: .public) late=\(driver.late, privacy: .public) longest-interval-ms=\(driver.intervals.max() ?? 0, privacy: .public) input-median-ms=\(input.isEmpty ? 0 : input[input.count / 2], privacy: .public) input-worst-ms=\(input.last ?? 0, privacy: .public) graph-frame-average-ms=\(graph.averageMilliseconds, privacy: .public) graph-frame-worst-ms=\(graph.worstMilliseconds, privacy: .public)"
      )
    }

    private static func trackpadScroll(dx: Int32, dy: Int32) -> NSEvent? {
      guard
        let cg = CGEvent(
          scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2, wheel1: dy, wheel2: dx,
          wheel3: 0)
      else { return nil }
      cg.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
      cg.setIntegerValueField(.scrollWheelEventScrollPhase, value: 2)
      return NSEvent(cgEvent: cg)
    }

    private static func mouse(_ type: NSEvent.EventType, _ point: CGPoint, _ view: GraphView)
      -> NSEvent
    {
      NSEvent.mouseEvent(
        with: type,
        location: view.convert(CGPoint(x: point.x, y: view.bounds.height - point.y), to: nil),
        modifierFlags: .shift, timestamp: ProcessInfo.processInfo.systemUptime,
        windowNumber: view.window?.windowNumber ?? 0, context: nil, eventNumber: 0, clickCount: 1,
        pressure: 1)!
    }

    nonisolated static func milliseconds(_ duration: Duration) -> Double {
      Double(duration.components.seconds) * 1000 + Double(duration.components.attoseconds) / 1e15
    }
  }

  /// A display link that exists only while a benchmark phase runs.
  @MainActor
  private final class FrameDriver: NSObject {
    let frames: Int
    let stop: (() -> Bool)?
    let body: (Int) -> Void
    var finished: (() -> Void)?
    private(set) var intervals: [Double] = []
    private(set) var late = 0
    private(set) var inputMilliseconds: [Double] = []
    private var link: CADisplayLink?
    private var last: CFTimeInterval?
    private var count = 0

    init(frames: Int, stop: (() -> Bool)?, body: @escaping (Int) -> Void) {
      self.frames = frames
      self.stop = stop
      self.body = body
    }

    func start(on view: NSView) {
      link = view.displayLink(target: self, selector: #selector(frame))
      link?.add(to: .main, forMode: .common)
    }

    @objc private func frame(_ link: CADisplayLink) {
      if let last {
        let interval = (link.timestamp - last) * 1000
        intervals.append(interval)
        if interval > (link.targetTimestamp - link.timestamp) * 1000 * 1.5 { late += 1 }
      }
      last = link.timestamp
      if count >= frames || stop?() == true {
        link.invalidate()
        self.link = nil
        finished?()
        return
      }
      let started = ContinuousClock.now
      body(count)
      inputMilliseconds.append(Benchmark.milliseconds(started.duration(to: .now)))
      count += 1
    }
  }
#endif

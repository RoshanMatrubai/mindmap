import AppKit
import MindmapCore
import QuartzCore
import os

/// The graph pane. Trackpad: two-finger scroll pans, pinch zooms about the cursor. Mouse: the
/// wheel zooms about the cursor, dragging empty canvas pans. Dragging a node moves and pins it.
/// The display link exists only during simulation or an active drag.
public final class GraphView: NSView {
  public let scene = GraphScene()
  /// A node was dropped: the shown document, its path key and new world position.
  public var onPin: ((UUID, String, LayoutPoint) -> Void)?
  /// Until the user pans or zooms, the camera fits everything (first show, rebuilds, resizes).
  private var following = true
  private var press: (point: CGPoint, camera: Camera, node: Int?, grab: CGPoint)?
  private var moved = false
  private var rasterTask: Task<Void, Never>?
  public var onFreeze: ((UUID, GraphLayout, [String: LayoutPoint]) -> Void)?
  /// The map whose simulation is shown. Worker frames, snapshots and callbacks carry it, so a
  /// result that arrives after a map switch is dropped.
  public private(set) var document: UUID?
  public var onFirstFrame: ((Int) -> Void)?
  public private(set) var displayedSimulation: LayoutSimulation?
  public var isAnimating: Bool { motionLink != nil }
  public var affectedIndices: Set<Int> { displayedSimulation?.affected ?? [] }
  private var worker: SimulationWorker?
  private var motionLink: CADisplayLink?
  private var frameTask: Task<Void, Never>?
  private(set) var generation = 0
  private var lastTimestamp: Double?
  private var accumulatedTime = 0.0
  private var dragUpdate: GraphDrag?
  private var freezeReported = false
  private var firstFrameReported = false
  private var frameTotal = 0.0
  private var frameWorst = 0.0
  private var frameCount = 0
  private let performance = OSLog(
    subsystem: Bundle.main.bundleIdentifier ?? "mindmap-preview", category: "motion")
  private let motionLog = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "mindmap-preview", category: "motion")

  #if DEBUG
    /// Display links created and not yet invalidated, across all graph views. 0 when frozen.
    public private(set) static var debugLiveDisplayLinks = 0
    /// Display frames delivered while nothing could move. Must stay 0.
    public private(set) static var debugIdleFrames = 0
    public private(set) var debugInitialLayout: GraphLayout?
    public var debugFrameMetrics:
      (
        averageMilliseconds: Double, worstMilliseconds: Double, frames: Int
      )
    {
      (frameCount == 0 ? 0 : frameTotal / Double(frameCount), frameWorst, frameCount)
    }
    public func debugResetFrameMetrics() {
      frameTotal = 0
      frameWorst = 0
      frameCount = 0
    }
    public func debugMagnify(by magnification: Double, about point: CGPoint) {
      move(scene.visibleCamera.zoomed(by: 1 + magnification, about: point, limits: limits))
    }
  #endif

  public override init(frame: NSRect) {
    super.init(frame: frame)
    wantsLayer = true
    layerContentsRedrawPolicy = .never
    layer?.addSublayer(scene.root)
    scene.rasterizesAsynchronously = true
    scene.onRasterReady = { [weak self] in
      guard let self, !self.firstFrameReported, let layout = self.scene.layout else { return }
      self.firstFrameReported = true
      os_signpost(.event, log: self.performance, name: "FirstFrame")
      self.onFirstFrame?(layout.nodes.count)
    }
    let buttons = [
      button("plus", "Zoom in", #selector(zoomInClicked)),
      button("minus", "Zoom out", #selector(zoomOutClicked)),
      button("arrow.up.left.and.arrow.down.right", "Fit all", #selector(fitClicked)),
    ]
    for (i, b) in buttons.enumerated() {
      // Prototype: 28 px buttons, 6 apart, 10 from the top and 12 from the right.
      b.frame = NSRect(
        x: frame.width - 12 - 28 - Double(2 - i) * 34, y: frame.height - 10 - 28, width: 28,
        height: 28)
      b.autoresizingMask = [.minXMargin, .minYMargin]
      addSubview(b)
    }
  }

  required init?(coder: NSCoder) { fatalError("not used") }

  /// Prototype `.zb` button: #232326 fill, 0.5 px #3a3a3c border, 6 px corners, #a1a1a6 icon.
  private func button(_ symbol: String, _ label: String, _ action: Selector) -> NSView {
    let image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)!
      .withSymbolConfiguration(.init(pointSize: 11, weight: .regular))!
    let b = NSButton(image: image, target: self, action: action)
    b.isBordered = false
    b.contentTintColor = NSColor(cgColor: GraphStyle.color(0xa1a1a6))
    b.toolTip = label
    b.frame = NSRect(x: 0, y: 0, width: 28, height: 28)
    b.autoresizingMask = [.width, .height]
    let box = NSView(frame: b.frame)
    box.wantsLayer = true
    box.layer?.backgroundColor = GraphStyle.color(0x232326)
    box.layer?.borderColor = GraphStyle.color(0x3a3a3c)
    box.layer?.borderWidth = 0.5
    box.layer?.cornerRadius = 6
    box.addSubview(b)
    return box
  }

  public override var acceptsFirstResponder: Bool { true }
  public override var isOpaque: Bool { true }

  /// Saved positions show immediately. Fresh layouts and local edits animate off the main thread.
  /// `refit` (new map, reshuffle) goes back to fitting everything.
  public func show(
    _ simulation: LayoutSimulation, title: String, refit: Bool, reuseNodes: Bool = true,
    document: UUID
  ) {
    stopMotion()
    self.document = document
    worker = SimulationWorker(simulation, document: document)
    displayedSimulation = simulation
    dragUpdate = nil
    press = nil
    freezeReported = false
    firstFrameReported = false
    frameTotal = 0
    frameWorst = 0
    frameCount = 0
    #if DEBUG
      debugInitialLayout = simulation.layout
    #endif
    if refit { following = true }
    scene.setTitle(title)
    scene.show(simulation.layout, reuseNodes: reuseNodes)
    if refit { scene.setCamera(fitCamera) }
    scene.refreshRaster()
    if simulation.isFrozen {
      reportFreeze(simulation)
    } else {
      resumeMotion()
    }
  }

  /// Drains queued ticks and drag input before an edit is matched against the visible map.
  /// Nil when `document` isn't shown, before or after the wait.
  public func simulationSnapshot(for document: UUID) async -> LayoutSimulation? {
    guard self.document == document, let worker else { return nil }
    let snapshot = await worker.snapshot(drag: dragUpdate)
    return self.document == document ? snapshot : nil
  }

  /// Stops frame delivery before saving or switching maps. No stale frame can repaint a new map.
  public func stopAndSnapshot(for document: UUID) async -> LayoutSimulation? {
    let worker = self.worker
    let drag = dragUpdate
    stopMotion()
    scene.cancelRaster()
    guard self.document == document, let worker else { return nil }
    let snapshot = await worker.snapshot(drag: drag)
    guard self.document == document else { return nil }
    displayedSimulation = snapshot
    return snapshot
  }

  public override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    NotificationCenter.default.removeObserver(
      self, name: NSWindow.didChangeOcclusionStateNotification, object: nil)
    if let window {
      NotificationCenter.default.addObserver(
        self, selector: #selector(occlusionChanged),
        name: NSWindow.didChangeOcclusionStateNotification, object: window)
      resumeMotion()
    } else {
      pauseMotion()
    }
  }

  @objc private func occlusionChanged(_ notification: Notification) {
    if window?.occlusionState.contains(.visible) == true { resumeMotion() } else { pauseMotion() }
  }

  private func resumeMotion() {
    guard motionLink == nil, worker != nil,
      displayedSimulation?.isFrozen == false || dragUpdate?.active == true,
      window?.occlusionState.contains(.visible) == true
    else { return }
    lastTimestamp = nil
    accumulatedTime = 0
    let link = displayLink(target: self, selector: #selector(displayFrame))
    motionLink = link
    link.add(to: .main, forMode: .common)
    #if DEBUG
      Self.debugLiveDisplayLinks += 1
    #endif
    motionLog.notice("display-link started nodes=\(self.scene.layout?.nodes.count ?? 0)")
  }

  private func pauseMotion() {
    #if DEBUG
      if motionLink != nil { Self.debugLiveDisplayLinks -= 1 }
    #endif
    motionLink?.invalidate()
    motionLink = nil
    lastTimestamp = nil
    accumulatedTime = 0
  }

  private func stopMotion() {
    generation += 1
    frameTask?.cancel()
    frameTask = nil
    pauseMotion()
  }

  @objc private func displayFrame(_ link: CADisplayLink) {
    #if DEBUG
      if frameTask == nil && dragUpdate == nil && displayedSimulation?.isFrozen != false {
        Self.debugIdleFrames += 1
      }
    #endif
    let delta =
      lastTimestamp.map { max(0, link.timestamp - $0) }
      ?? max(0, link.targetTimestamp - link.timestamp)
    lastTimestamp = link.timestamp
    accumulatedTime += delta
    guard frameTask == nil, let worker else { return }
    let seconds = accumulatedTime
    accumulatedTime = 0
    let generation = generation
    let drag = dragUpdate
    frameTask = Task { [weak self] in
      let frame = await worker.frame(seconds: seconds, drag: drag)
      guard let self, !Task.isCancelled else { return }
      self.apply(frame, seconds: seconds, drag: drag, generation: generation)
    }
  }

  /// Returns false and changes nothing for a frame from an earlier `show` or another map.
  @discardableResult
  func apply(_ frame: SimulationFrame, seconds: Double, drag: GraphDrag?, generation: Int) -> Bool {
    guard generation == self.generation, frame.document == document else { return false }
    let started = ContinuousClock.now
    os_signpost(.begin, log: performance, name: "MainFrame")
    let snapshot = frame.simulation
    frameTask = nil
    displayedSimulation = snapshot
    var layout = frame.layout
    if let current = dragUpdate, current.active, layout.nodes.indices.contains(current.index) {
      layout.nodes[current.index].x = current.point.x
      layout.nodes[current.index].y = current.point.y
    }
    scene.applyPositions(layout)
    if following && snapshot.isFullLayout {
      let old = scene.camera
      let target = fitCamera
      // Same easing as prototype follow, normalized to elapsed display time.
      let easing = 1 - pow(0.85, seconds * 60)
      scene.setCamera(
        Camera(
          zoom: old.zoom + (target.zoom - old.zoom) * easing,
          offset: CGPoint(
            x: old.offset.x + (target.offset.x - old.offset.x) * easing,
            y: old.offset.y + (target.offset.y - old.offset.y) * easing)))
    }
    os_signpost(.end, log: performance, name: "MainFrame")
    let duration = started.duration(to: .now)
    let ms =
      Double(duration.components.seconds) * 1000
      + Double(duration.components.attoseconds) / 1e15
    frameTotal += ms
    frameWorst = max(frameWorst, ms)
    frameCount += 1
    if drag?.active == false && dragUpdate == drag { dragUpdate = nil }
    if snapshot.isFrozen && dragUpdate?.active != true {
      pauseMotion()
      reportFreeze(snapshot)
    }
    return true
  }

  private func reportFreeze(_ simulation: LayoutSimulation) {
    guard !freezeReported else { return }
    freezeReported = true
    if following && simulation.isFullLayout { scene.setCamera(fitCamera) }
    scene.refreshRaster()
    let average = frameCount == 0 ? 0 : frameTotal / Double(frameCount)
    motionLog.notice(
      "display-link stopped frozen nodes=\(simulation.layout.nodes.count) frames=\(self.frameCount) main-average-ms=\(average, privacy: .public) main-worst-ms=\(self.frameWorst, privacy: .public)"
    )
    if let document { onFreeze?(document, simulation.layout, simulation.pins) }
  }

  private var fitCamera: Camera {
    Camera.fit(scene.layout?.bounds ?? .null, in: bounds.size)
  }

  public override func layout() {
    super.layout()
    let resized = scene.size != bounds.size
    scene.setSize(bounds.size)
    if resized && following && scene.layout != nil { scene.setCamera(fitCamera) }
    if resized { scheduleRaster() }
  }

  public override func viewDidChangeBackingProperties() {
    super.viewDidChangeBackingProperties()
    scene.screenScale = window?.backingScaleFactor ?? 2
  }

  public override func resetCursorRects() {
    addCursorRect(bounds, cursor: .openHand)
  }

  // MARK: Camera commands

  public func zoomIn() { zoom(by: 1 / 0.7) }
  public func zoomOut() { zoom(by: 1 / 1.4) }

  public func fitAll() {
    following = true
    scene.animateCamera(to: fitCamera) { [weak self] in self?.scheduleRaster() }
  }

  @objc private func zoomInClicked() { zoomIn() }
  @objc private func zoomOutClicked() { zoomOut() }
  @objc private func fitClicked() { fitAll() }

  /// Animated zoom about the center of the pane.
  public func zoom(by factor: Double) {
    following = false
    let center = CGPoint(x: bounds.midX, y: bounds.midY)
    let target = scene.visibleCamera.zoomed(by: factor, about: center, limits: limits)
    scene.animateCamera(to: target) { [weak self] in self?.scheduleRaster() }
  }

  private var limits: ClosedRange<Double> { Camera.limits(fitZoom: fitCamera.zoom) }

  /// Moves the camera at once (gestures). Labels re-rasterize shortly after it stops.
  private func move(_ camera: Camera) {
    following = false
    scene.setCamera(camera)
    scheduleRaster()
  }

  /// One-shot debounce, not a timer: nothing is scheduled while idle.
  private func scheduleRaster() {
    rasterTask?.cancel()
    rasterTask = Task { [weak self] in
      do { try await Task.sleep(for: .milliseconds(150)) } catch { return }
      self?.scene.refreshRaster()
    }
  }

  // MARK: Input

  /// View coordinates, y down like the scene.
  private func point(_ event: NSEvent) -> CGPoint {
    let p = convert(event.locationInWindow, from: nil)
    return CGPoint(x: p.x, y: bounds.height - p.y)
  }

  /// Trackpad (and Magic Mouse) scrolls carry a gesture or momentum phase and pan. Wheels have
  /// neither, even smooth-scrolling ones with precise deltas, and zoom about the cursor.
  public override func scrollWheel(with event: NSEvent) {
    let camera = scene.visibleCamera
    if !event.phase.isEmpty || !event.momentumPhase.isEmpty {
      move(camera.panned(by: CGPoint(x: event.scrollingDeltaX, y: event.scrollingDeltaY)))
    } else if event.scrollingDeltaY != 0 {
      move(
        camera.zoomed(
          by: Self.wheelZoom(event.scrollingDeltaY, precise: event.hasPreciseScrollingDeltas),
          about: point(event), limits: limits))
    }
  }

  /// One line (or 10 precise points) zooms 12%, proportionally, at most 1.5× per event.
  static func wheelZoom(_ delta: Double, precise: Bool) -> Double {
    let lines = max(-3.5, min(3.5, precise ? delta / 10 : delta))
    return pow(1.12, lines)
  }

  public override func magnify(with event: NSEvent) {
    move(
      scene.visibleCamera.zoomed(by: 1 + event.magnification, about: point(event), limits: limits))
  }

  public override func mouseDown(with event: NSEvent) {
    window?.makeFirstResponder(self)
    let p = point(event)
    let camera = scene.visibleCamera
    scene.setCamera(camera)
    // Prototype hit circle: about 14 px.
    let node = scene.node(at: p, radius: 14)
    var grab = CGPoint.zero
    if let node, let n = scene.layout?.nodes[node] {
      let w = camera.toWorld(p)
      grab = CGPoint(x: n.x - w.x, y: n.y - w.y)
    }
    press = (p, camera, node, grab)
    moved = false
  }

  public override func mouseDragged(with event: NSEvent) {
    guard let press else { return }
    let p = point(event)
    let delta = CGPoint(x: p.x - press.point.x, y: p.y - press.point.y)
    if !moved && abs(delta.x) + abs(delta.y) <= 4 { return }
    moved = true
    if let node = press.node {
      following = false
      let w = press.camera.toWorld(p)
      let point = LayoutPoint(x: w.x + press.grab.x, y: w.y + press.grab.y)
      dragUpdate = GraphDrag(index: node, point: point, active: true)
      freezeReported = false
      scene.moveNode(node, to: CGPoint(x: point.x, y: point.y))
      resumeMotion()
    } else {
      NSCursor.closedHand.set()
      move(press.camera.panned(by: delta))
    }
  }

  public override func mouseUp(with event: NSEvent) {
    defer {
      press = nil
      window?.invalidateCursorRects(for: self)
    }
    guard moved, let node = press?.node, let layout = scene.layout else { return }
    let n = layout.nodes[node]
    if worker != nil {
      dragUpdate = GraphDrag(index: node, point: LayoutPoint(x: n.x, y: n.y), active: false)
      resumeMotion()
    }
    if let document {
      onPin?(document, layout.model.nodes[node].pathKey, LayoutPoint(x: n.x, y: n.y))
    }
  }

  public override func keyDown(with event: NSEvent) {
    let step = 60.0
    let delta: CGPoint
    switch event.specialKey {
    case .leftArrow?: delta = CGPoint(x: step, y: 0)
    case .rightArrow?: delta = CGPoint(x: -step, y: 0)
    case .upArrow?: delta = CGPoint(x: 0, y: step)
    case .downArrow?: delta = CGPoint(x: 0, y: -step)
    default:
      super.keyDown(with: event)
      return
    }
    move(scene.visibleCamera.panned(by: delta))
  }
}

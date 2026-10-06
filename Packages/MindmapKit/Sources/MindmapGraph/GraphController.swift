import Foundation
import MindmapCore
import QuartzCore
import os

/// Where a node added from the graph goes in the text.
public enum GraphAdd: Equatable, Sendable {
  case sibling(Int)
  case child(Int)
  case group
}

/// An edit made on the graph. The owner applies it to the text, the single source of truth.
public enum GraphEdit: Equatable, Sendable {
  case add(GraphAdd, name: String, at: LayoutPoint)
  case rename(Int, String)
  case toggleDone(Int)
  case priority(Int, MapPriority?)
  case delete(Int)
}

/// The platform-neutral half of the graph pane, shared by the Mac (`NSView`) and iPad (`UIView`)
/// host views: the simulation worker, the display link while something moves, and the camera.
/// Hosts own input, windows and the display link's creation. The display link exists only
/// during simulation or an active drag.
@MainActor
public final class GraphController: NSObject {
  public let scene = GraphScene()
  public var onFreeze: ((UUID, GraphLayout, [String: LayoutPoint]) -> Void)?
  public var onFirstFrame: ((Int) -> Void)?
  /// The simulation's alpha on each applied frame while it moves; nil once frozen. Feeds the
  /// forces panel's "settling N%" status, so it costs nothing while idle.
  public var onSettle: ((Double?) -> Void)?
  /// Set by the host: a display link calling `displayFrame(_:)`, or nil while the host can't
  /// show frames (no window, occluded). The controller adds it to the main run loop.
  var makeDisplayLink: (@MainActor () -> CADisplayLink?)?
  /// The map whose simulation is shown. Worker frames, snapshots and callbacks carry it, so a
  /// result that arrives after a map switch is dropped.
  public private(set) var document: UUID?
  public private(set) var displayedSimulation: LayoutSimulation?
  public var isAnimating: Bool { motionLink != nil }
  public var affectedIndices: Set<Int> { displayedSimulation?.affected ?? [] }
  /// Until the user pans or zooms, the camera fits everything (first show, rebuilds, resizes).
  var following = true
  /// The camera fits the selection (a click or tap) until the user moves it, so it re-fits when
  /// the pane changes size, such as when the detail panel grows with the selection.
  private var fittingSelection = false
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
  private var rasterTask: Task<Void, Never>?
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
  #endif

  public override init() {
    super.init()
    scene.rasterizesAsynchronously = true
    scene.onRasterReady = { [weak self] in
      guard let self, !self.firstFrameReported, let layout = self.scene.layout else { return }
      self.firstFrameReported = true
      os_signpost(.event, log: self.performance, name: "FirstFrame")
      self.onFirstFrame?(layout.nodes.count)
    }
  }

  /// Saved positions show immediately. Fresh layouts and local edits animate off the main thread.
  /// `refit` (new map, reshuffle) goes back to fitting everything.
  public func show(
    _ simulation: LayoutSimulation, title: String, refit: Bool, reuseNodes: Bool = true,
    document: UUID
  ) {
    stopMotion()
    if self.document != document { scene.select(nil) }
    self.document = document
    worker = SimulationWorker(simulation, document: document)
    displayedSimulation = simulation
    dragUpdate = nil
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
      onSettle?(simulation.layout.alpha)
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

  // MARK: Motion

  /// Starts the display link if something can move and the host can show it.
  func resumeMotion() {
    guard motionLink == nil, worker != nil,
      displayedSimulation?.isFrozen == false || dragUpdate?.active == true,
      let link = makeDisplayLink?()
    else { return }
    lastTimestamp = nil
    accumulatedTime = 0
    motionLink = link
    link.add(to: .main, forMode: .common)
    #if DEBUG
      Self.debugLiveDisplayLinks += 1
    #endif
    motionLog.notice("display-link started nodes=\(self.scene.layout?.nodes.count ?? 0)")
  }

  func pauseMotion() {
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

  @objc func displayFrame(_ link: CADisplayLink) {
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
    } else {
      onSettle?(layout.alpha)
    }
    return true
  }

  private func reportFreeze(_ simulation: LayoutSimulation) {
    guard !freezeReported else { return }
    freezeReported = true
    onSettle?(nil)
    if following && simulation.isFullLayout { scene.setCamera(fitCamera) }
    scene.refreshRaster()
    let average = frameCount == 0 ? 0 : frameTotal / Double(frameCount)
    motionLog.notice(
      "display-link stopped frozen nodes=\(simulation.layout.nodes.count) frames=\(self.frameCount) main-average-ms=\(average, privacy: .public) main-worst-ms=\(self.frameWorst, privacy: .public)"
    )
    if let document { onFreeze?(document, simulation.layout, simulation.pins) }
  }

  // MARK: Dragging

  /// Moves `node` (and with `subtree`, its subtree) to a world point while the finger or
  /// mouse holds it.
  func drag(_ node: Int, to point: LayoutPoint, subtree: Bool) {
    following = false
    dragUpdate = GraphDrag(index: node, point: point, active: true, subtree: subtree)
    freezeReported = false
    scene.moveNode(node, to: CGPoint(x: point.x, y: point.y))
    resumeMotion()
  }

  /// Lets go of `node` where it is shown; the simulation relaxes around it.
  func drop(_ node: Int, subtree: Bool) {
    guard worker != nil, let n = scene.layout?.nodes[node] else { return }
    dragUpdate = GraphDrag(
      index: node, point: LayoutPoint(x: n.x, y: n.y), active: false, subtree: subtree)
    resumeMotion()
  }

  // MARK: Camera

  var fitCamera: Camera {
    Camera.fit(scene.layout?.bounds ?? .null, in: scene.size)
  }

  var limits: ClosedRange<Double> { Camera.limits(fitZoom: fitCamera.zoom) }

  /// The host's size changed: keep fitting everything until the user moves the camera.
  func resize(to size: CGSize) {
    let resized = scene.size != size
    scene.setSize(size)
    if resized && following && scene.layout != nil { scene.setCamera(fitCamera) }
    if resized && fittingSelection, let box = scene.selectionBounds {
      let target = Camera.fit(box, in: size, padding: 50)
      // Mid-flight (the panel grows right after a tap), carry on to the new target.
      if scene.isCameraAnimating {
        scene.animateCamera(to: target) { [weak self] in self?.scheduleRaster() }
      } else {
        scene.setCamera(target)
      }
    }
    if resized { scheduleRaster() }
  }

  public func zoomIn() { zoom(by: 1 / 0.7) }
  public func zoomOut() { zoom(by: 1 / 1.4) }

  public func fitAll() {
    following = true
    fittingSelection = false
    scene.animateCamera(to: fitCamera) { [weak self] in self?.scheduleRaster() }
  }

  /// Animated zoom about the center of the pane.
  public func zoom(by factor: Double) {
    following = false
    fittingSelection = false
    let center = CGPoint(x: scene.size.width / 2, y: scene.size.height / 2)
    let target = scene.visibleCamera.zoomed(by: factor, about: center, limits: limits)
    scene.animateCamera(to: target) { [weak self] in self?.scheduleRaster() }
  }

  /// Mouse wheels on both platforms: one line (or 10 precise points) zooms 12%, proportionally,
  /// at most 1.5× per event.
  nonisolated static func wheelZoom(_ delta: Double, precise: Bool) -> Double {
    ScrollZoom.mac(delta, precise: precise)
  }

  /// Moves the camera at once (gestures). Labels re-rasterize shortly after it stops.
  func move(_ camera: Camera) {
    following = false
    fittingSelection = false
    scene.setCamera(camera)
    scheduleRaster()
  }

  /// One-shot debounce, not a timer: nothing is scheduled while idle.
  func scheduleRaster() {
    rasterTask?.cancel()
    rasterTask = Task { [weak self] in
      do { try await Task.sleep(for: .milliseconds(150)) } catch { return }
      self?.scene.refreshRaster()
    }
  }

  /// Highlights `index` (nil clears). With `camera`, animates to fit the highlight, or back to
  /// fit all when a selection was cleared.
  public func select(_ index: Int?, camera: Bool) {
    let had = scene.selection != nil
    scene.select(index)
    guard camera else {
      fittingSelection = false
      return
    }
    if let box = scene.selectionBounds {
      following = false
      fittingSelection = true
      scene.animateCamera(to: Camera.fit(box, in: scene.size, padding: 50)) { [weak self] in
        self?.scheduleRaster()
      }
    } else if had {
      fitAll()
    }
  }
}

import AppKit
import MindmapCore

/// The graph pane. Trackpad: two-finger scroll pans, pinch zooms about the cursor. Mouse: the
/// wheel zooms about the cursor, dragging empty canvas pans. Dragging a node moves and pins it.
/// Nothing runs while idle: no timers, no display link.
public final class GraphView: NSView {
  public let scene = GraphScene()
  /// A node was dropped: its path key and new world position.
  public var onPin: ((String, LayoutPoint) -> Void)?
  /// Until the user pans or zooms, the camera fits everything (first show, rebuilds, resizes).
  private var following = true
  private var press: (point: CGPoint, camera: Camera, node: Int?, grab: CGPoint)?
  private var moved = false
  private var rasterTask: Task<Void, Never>?

  public override init(frame: NSRect) {
    super.init(frame: frame)
    wantsLayer = true
    layerContentsRedrawPolicy = .never
    layer?.addSublayer(scene.root)
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

  /// Shows a new layout. `refit` (new map, reshuffle) goes back to fitting everything.
  public func show(_ layout: GraphLayout, title: String, refit: Bool) {
    if refit { following = true }
    scene.setTitle(title)
    scene.show(layout)
    if following { scene.setCamera(fitCamera) }
    scene.refreshRaster()
  }

  private var fitCamera: Camera {
    Camera.fit(scene.layout?.bounds ?? .null, in: bounds.size)
  }

  public override func layout() {
    super.layout()
    scene.setSize(bounds.size)
    if following && scene.layout != nil { scene.setCamera(fitCamera) }
    scheduleRaster()
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
    scene.animateCamera(to: fitCamera) { [weak self] in self?.scene.refreshRaster() }
  }

  @objc private func zoomInClicked() { zoomIn() }
  @objc private func zoomOutClicked() { zoomOut() }
  @objc private func fitClicked() { fitAll() }

  /// Animated zoom about the center of the pane.
  public func zoom(by factor: Double) {
    following = false
    let center = CGPoint(x: bounds.midX, y: bounds.midY)
    let target = scene.visibleCamera.zoomed(by: factor, about: center, limits: limits)
    scene.animateCamera(to: target) { [weak self] in self?.scene.refreshRaster() }
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

  public override func scrollWheel(with event: NSEvent) {
    let camera = scene.visibleCamera
    if event.hasPreciseScrollingDeltas {
      move(camera.panned(by: CGPoint(x: event.scrollingDeltaX, y: event.scrollingDeltaY)))
    } else if event.scrollingDeltaY != 0 {
      let factor = event.scrollingDeltaY > 0 ? 1.12 : 1 / 1.12
      move(camera.zoomed(by: factor, about: point(event), limits: limits))
    }
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
      let w = press.camera.toWorld(p)
      scene.moveNode(node, to: CGPoint(x: w.x + press.grab.x, y: w.y + press.grab.y))
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
    onPin?(layout.model.nodes[node].pathKey, LayoutPoint(x: n.x, y: n.y))
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

import MindmapCore
import QuartzCore

/// The frozen graph as a Core Animation layer tree, shared by the app and `mindmap-preview`.
/// Pan and zoom only change `world.sublayerTransform` (plus the edge line widths), so the
/// compositor moves everything without redrawing.
@MainActor
public final class GraphScene {
  /// Screen space, y down. Holds the world and the title.
  public let root = CALayer()
  private let world = CALayer()
  private let links = CAShapeLayer()
  private let edges = CAShapeLayer()
  private let nodeContainer = CALayer()
  private let title = CATextLayer()
  public private(set) var layout: GraphLayout?
  private var nodeLayers: [NodeLayer] = []
  private var reusable: [String: NodeLayer] = [:]
  public private(set) var camera = Camera()
  public var screenScale: CGFloat = 2 {
    didSet {
      title.contentsScale = screenScale
      refreshRaster()
    }
  }

  public init() {
    root.isGeometryFlipped = true
    root.backgroundColor = GraphStyle.canvas
    root.masksToBounds = true
    world.anchorPoint = .zero
    for layer in [links, edges] {
      layer.fillColor = nil
      layer.lineCap = .round
      layer.anchorPoint = .zero
    }
    edges.strokeColor = GraphStyle.color(GraphStyle.edge, alpha: GraphStyle.edgeOpacity)
    links.strokeColor = GraphStyle.color(GraphStyle.edge, alpha: GraphStyle.linkOpacity)
    nodeContainer.anchorPoint = .zero
    world.addSublayer(links)
    world.addSublayer(edges)
    world.addSublayer(nodeContainer)
    root.addSublayer(world)
    // Prototype: 15 px, #636366, 10 from the top and 14 from the left. Never a node.
    title.font = GraphStyle.font(size: 15)
    title.fontSize = 15
    title.foregroundColor = GraphStyle.titleColor
    title.contentsScale = screenScale
    title.anchorPoint = .zero
    root.addSublayer(title)
    without { setSize(CGSize(width: 800, height: 600)) }
  }

  public var size: CGSize { root.bounds.size }

  public func setSize(_ size: CGSize) {
    without {
      root.frame = CGRect(origin: root.frame.origin, size: size)
      world.frame = CGRect(origin: .zero, size: size)
      title.frame = CGRect(x: 14, y: 10, width: max(0, size.width - 140), height: 22)
    }
  }

  public func setTitle(_ text: String) {
    without { title.string = text }
  }

  /// Replaces the drawn graph. Node layers whose look didn't change are kept and only moved.
  public func show(_ layout: GraphLayout) {
    self.layout = layout
    var next: [String: NodeLayer] = [:]
    nodeLayers = layout.nodes.indices.map { i in
      let key = layout.model.nodes[i].pathKey
      let layer = reusable[key] ?? NodeLayer()
      next[key] = layer
      return layer
    }
    reusable = next
    without {
      for (i, layer) in nodeLayers.enumerated() {
        layer.look = NodeLook(node: layout.nodes[i], source: layout.model.nodes[i])
        layer.position = CGPoint(x: layout.nodes[i].x, y: layout.nodes[i].y)
      }
      // Deepest first, so groups draw on top (prototype byDepth).
      let order = layout.nodes.indices.sorted {
        let (a, b) = (layout.model.nodes[$0].depth, layout.model.nodes[$1].depth)
        return a != b ? a > b : $0 < $1
      }
      nodeContainer.sublayers = order.map { nodeLayers[$0] }
      rebuildPaths()
    }
  }

  /// Moves one node; its tree edges and cross links follow. Nothing else moves.
  public func moveNode(_ index: Int, to point: CGPoint) {
    guard layout != nil else { return }
    layout!.nodes[index].x = point.x
    layout!.nodes[index].y = point.y
    without {
      nodeLayers[index].position = point
      rebuildPaths()
    }
  }

  private func rebuildPaths() {
    guard let layout else { return }
    let tree = CGMutablePath()
    for (i, node) in layout.model.nodes.enumerated() {
      guard let parent = node.parent else { continue }
      tree.move(to: CGPoint(x: layout.nodes[parent].x, y: layout.nodes[parent].y))
      tree.addLine(to: CGPoint(x: layout.nodes[i].x, y: layout.nodes[i].y))
    }
    edges.path = tree
    // Dashed quadratic curves bowed sideways by 18% of their length.
    let cross = CGMutablePath()
    for link in layout.model.resolvedLinks {
      let a = layout.nodes[link.source]
      let b = layout.nodes[link.target]
      let (mx, my, dx, dy) = ((a.x + b.x) / 2, (a.y + b.y) / 2, b.x - a.x, b.y - a.y)
      cross.move(to: CGPoint(x: a.x, y: a.y))
      cross.addQuadCurve(
        to: CGPoint(x: b.x, y: b.y), control: CGPoint(x: mx - dy * 0.18, y: my + dx * 0.18))
    }
    links.path = cross
  }

  /// Sets the camera immediately.
  public func setCamera(_ camera: Camera) {
    world.removeAllAnimations()
    edges.removeAllAnimations()
    links.removeAllAnimations()
    self.camera = camera
    without { applyCamera(camera) }
  }

  /// The camera as it is on screen right now, including mid-animation.
  public var visibleCamera: Camera {
    guard let shown = world.presentation(), world.animationKeys()?.isEmpty == false else {
      return camera
    }
    let t = shown.sublayerTransform
    return Camera(zoom: t.m11, offset: CGPoint(x: t.m41, y: t.m42))
  }

  /// About 380 ms ease-out cubic, interpolating the visible world rectangle like the
  /// prototype's animTo(). Baked into keyframes so the compositor runs it with no per-frame CPU.
  public func animateCamera(to target: Camera, completion: @escaping @MainActor () -> Void) {
    let start = visibleCamera
    setCamera(target)
    let width = Double(max(size.width, 1))
    func rect(_ c: Camera) -> (x: Double, y: Double, w: Double) {
      (-c.offset.x / c.zoom, -c.offset.y / c.zoom, width / c.zoom)
    }
    let (a, b) = (rect(start), rect(target))
    let steps = 24
    let cameras = (0...steps).map { step -> Camera in
      let t = Double(step) / Double(steps)
      let p = 1 - pow(1 - t, 3)
      let w = a.w + (b.w - a.w) * p
      let zoom = width / w
      let x = a.x + (b.x - a.x) * p
      let y = a.y + (b.y - a.y) * p
      return Camera(zoom: zoom, offset: CGPoint(x: -x * zoom, y: -y * zoom))
    }
    func keyframes(_ path: String, _ values: [Any]) -> CAKeyframeAnimation {
      let animation = CAKeyframeAnimation(keyPath: path)
      animation.values = values
      animation.duration = 0.38
      animation.calculationMode = .linear
      return animation
    }
    CATransaction.begin()
    CATransaction.setCompletionBlock { MainActor.assumeIsolated { completion() } }
    world.add(keyframes("sublayerTransform", cameras.map { transform($0) }), forKey: "camera")
    let widths = cameras.map { 1 / $0.zoom }
    edges.add(keyframes("lineWidth", widths), forKey: "camera")
    links.add(keyframes("lineWidth", widths), forKey: "camera")
    links.add(keyframes("lineDashPattern", cameras.map { dash($0) }), forKey: "dash")
    CATransaction.commit()
  }

  private func transform(_ c: Camera) -> CATransform3D {
    CATransform3DMakeAffineTransform(
      CGAffineTransform(a: c.zoom, b: 0, c: 0, d: c.zoom, tx: c.offset.x, ty: c.offset.y))
  }

  private func dash(_ c: Camera) -> [NSNumber] {
    [3 / c.zoom, 4 / c.zoom].map { NSNumber(value: $0) }
  }

  private func applyCamera(_ c: Camera) {
    world.sublayerTransform = transform(c)
    // 1 px on screen at every zoom level.
    edges.lineWidth = 1 / c.zoom
    links.lineWidth = 1 / c.zoom
    links.lineDashPattern = dash(c)
  }

  /// Re-rasterizes labels for the current zoom. Labels on or near the screen get full resolution;
  /// the rest stay at most at 1× so a deep zoom doesn't allocate huge bitmaps for 500 nodes.
  public func refreshRaster() {
    guard let layout else { return }
    let view = CGRect(origin: .zero, size: size)
    let near = CGRect(
      origin: camera.toWorld(CGPoint(x: -view.width / 2, y: -view.height / 2)),
      size: CGSize(width: view.width * 2 / camera.zoom, height: view.height * 2 / camera.zoom))
    for (i, layer) in nodeLayers.enumerated() {
      let n = layout.nodes[i]
      let box = CGRect(
        x: n.x - n.halfWidth, y: n.y - n.up, width: n.halfWidth * 2, height: n.up + n.down)
      let zoom = box.intersects(near) ? camera.zoom : min(camera.zoom, 1)
      let scale = screenScale * zoom
      if abs(layer.contentsScale - scale) > scale * 0.05 {
        layer.contentsScale = scale
        layer.setNeedsDisplay()
      }
    }
  }

  /// Draws anything pending now (the preview renders without a run loop).
  public func displayNow() {
    title.displayIfNeeded()
    for layer in nodeLayers { layer.displayIfNeeded() }
  }

  /// Nearest node within `radius` view points of `point`.
  public func node(at point: CGPoint, radius: Double) -> Int? {
    guard let layout else { return nil }
    let p = camera.toWorld(point)
    let limit = radius / camera.zoom
    var best: (index: Int, distance: Double)?
    for (i, n) in layout.nodes.enumerated() {
      let d = hypot(n.x - p.x, n.y - p.y)
      if d <= max(limit, n.radius), d < best?.distance ?? .infinity { best = (i, d) }
    }
    return best?.index
  }

  private func without(_ body: () -> Void) {
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    body()
    CATransaction.commit()
  }
}

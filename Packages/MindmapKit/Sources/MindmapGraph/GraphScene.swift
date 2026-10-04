import CoreText
import MindmapCore
import QuartzCore
import os

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
  private var spareLayers: [NodeLayer] = []
  public var rasterizesAsynchronously = false
  public var onRasterReady: (() -> Void)?
  private var rasterTask: Task<Void, Never>?
  private var rasterGeneration = 0
  private var rasterKeys: [LabelRasterKey?] = []
  private var fontNames: [Double: String] = [:]
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
  public func show(_ layout: GraphLayout, reuseNodes: Bool = true) {
    let stage = ContinuousClock.now
    let perf = OSLog(
      subsystem: Bundle.main.bundleIdentifier ?? "mindmap-preview", category: "motion")
    os_signpost(.begin, log: perf, name: "LayerCreation")
    defer {
      os_signpost(.end, log: perf, name: "LayerCreation")
      let duration = stage.duration(to: .now)
      let ms =
        Double(duration.components.seconds) * 1000
        + Double(duration.components.attoseconds) / 1e15
      Logger(subsystem: Bundle.main.bundleIdentifier ?? "mindmap-preview", category: "motion")
        .notice("layers nodes=\(layout.nodes.count) ms=\(ms, privacy: .public)")
    }
    let previous = self.layout
    let previousLayers = nodeLayers
    let matches =
      reuseNodes
      ? previous.map {
        NodeIdentity.match(old: $0.model, new: layout.model).newToOld
      } ?? [:] : [:]
    self.layout = layout
    var next: [String: NodeLayer] = [:]
    var used = Set<ObjectIdentifier>()
    // Prefer identity/path matches, then reuse detached layers when maps have different names.
    let preferred = layout.nodes.indices.map { i -> NodeLayer? in
      matches[i].map { previousLayers[$0] } ?? reusable[layout.model.nodes[i].pathKey]
    }
    let reserved = Set(preferred.compactMap { $0.map(ObjectIdentifier.init) })
    var available = spareLayers + previousLayers.filter { !reserved.contains(ObjectIdentifier($0)) }
    nodeLayers = layout.nodes.indices.map { i in
      let key = layout.model.nodes[i].pathKey
      let layer = preferred[i] ?? available.popLast() ?? NodeLayer()
      used.insert(ObjectIdentifier(layer))
      next[key] = layer
      return layer
    }
    spareLayers = available.filter { !used.contains(ObjectIdentifier($0)) }
    for layer in spareLayers { layer.removeFromSuperlayer() }
    reusable = next
    rasterKeys = Array(repeating: nil, count: nodeLayers.count)
    rasterGeneration += 1
    rasterTask?.cancel()
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

  /// Publishes one simulation frame. Only positions and paths change, never label contents.
  public func applyPositions(_ layout: GraphLayout) {
    guard layout.nodes.count == nodeLayers.count else { return }
    self.layout = layout
    without {
      for (index, node) in layout.nodes.enumerated() {
        nodeLayers[index].position = CGPoint(x: node.x, y: node.y)
      }
      rebuildPaths()
    }
  }

  /// Moves one node; its tree edges and cross links follow. Nothing else moves.
  public func moveNode(_ index: Int, to point: CGPoint) {
    guard let layout, layout.nodes.indices.contains(index) else { return }
    self.layout!.nodes[index].x = point.x
    self.layout!.nodes[index].y = point.y
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

  public func cancelRaster() {
    rasterGeneration += 1
    rasterTask?.cancel()
    rasterTask = nil
  }

  /// Rasterizes at the current zoom. Far-off labels stay at most 1x resolution.
  public func refreshRaster() {
    guard let layout else { return }
    let view = CGRect(origin: .zero, size: size)
    let near = CGRect(
      origin: camera.toWorld(CGPoint(x: -view.width / 2, y: -view.height / 2)),
      size: CGSize(width: view.width * 2 / camera.zoom, height: view.height * 2 / camera.zoom))
    var requests: [(index: Int, key: LabelRasterKey)] = []
    for (i, layer) in nodeLayers.enumerated() {
      let n = layout.nodes[i]
      let box = CGRect(
        x: n.x - n.halfWidth, y: n.y - n.up, width: n.halfWidth * 2, height: n.up + n.down)
      let zoom = box.intersects(near) ? camera.zoom : min(camera.zoom, 1)
      // Nearby scales share a raster, avoiding a bitmap per tiny zoom adjustment.
      let scale = max(0.125, (screenScale * zoom * 8).rounded() / 8)
      guard let look = layer.look else { continue }
      let font =
        fontNames[look.fontSize]
        ?? (CTFontCopyPostScriptName(GraphStyle.font(size: look.fontSize)) as String)
      fontNames[look.fontSize] = font
      let key = LabelRasterKey(look: look, font: font, scale: scale)
      if rasterKeys[i] != key || layer.contents == nil { requests.append((i, key)) }
    }
    guard !requests.isEmpty else {
      onRasterReady?()
      return
    }
    if !rasterizesAsynchronously {
      without {
        for request in requests {
          if let image = NodeRaster.image(look: request.key.look, scale: request.key.scale) {
            nodeLayers[request.index].apply(image, scale: request.key.scale)
            rasterKeys[request.index] = request.key
          }
        }
      }
      onRasterReady?()
      return
    }
    rasterTask?.cancel()
    rasterGeneration += 1
    let generation = rasterGeneration
    rasterTask = Task { [weak self] in
      let results = await LabelRasterCache.shared.render(requests.map(\.key))
      guard let self, !Task.isCancelled, generation == self.rasterGeneration else { return }
      let images = Dictionary(results.map { ($0.key, $0.image) }, uniquingKeysWith: { a, _ in a })
      self.without {
        for request in requests {
          guard let image = images[request.key], self.nodeLayers.indices.contains(request.index),
            self.nodeLayers[request.index].look == request.key.look
          else { continue }
          self.nodeLayers[request.index].apply(image, scale: request.key.scale)
          self.rasterKeys[request.index] = request.key
        }
      }
      self.onRasterReady?()
    }
  }

  /// The preview has no run loop, so it uses the same rasterizer synchronously.
  public func displayNow() {
    title.displayIfNeeded()
    let async = rasterizesAsynchronously
    rasterizesAsynchronously = false
    refreshRaster()
    rasterizesAsynchronously = async
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

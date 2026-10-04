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
  // Prototype layer order: links, edges, nodes, then the highlighted links, edges and nodes.
  private let litLinks = CAShapeLayer()
  private let litEdges = CAShapeLayer()
  private let litNodes = CALayer()
  /// The dot of a node being named on the graph, before its line exists.
  private let ghost = CALayer()
  private let title = CATextLayer()
  public private(set) var layout: GraphLayout?
  /// The selected node and its highlight (ancestors, subtree, cross-link neighbors).
  public private(set) var selection: Int?
  private var lit: [Bool] = []
  private var linked = Set<Int>()
  /// Node indices deepest first, so groups draw on top (prototype byDepth).
  private var order: [Int] = []
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
    for layer in [links, edges, litLinks, litEdges] {
      layer.fillColor = nil
      layer.lineCap = .round
      layer.anchorPoint = .zero
    }
    edges.strokeColor = GraphStyle.color(GraphStyle.edge, alpha: GraphStyle.edgeOpacity)
    links.strokeColor = GraphStyle.color(GraphStyle.edge, alpha: GraphStyle.linkOpacity)
    litEdges.strokeColor = GraphStyle.color(GraphStyle.litEdge)
    litLinks.strokeColor = GraphStyle.color(GraphStyle.litEdge, alpha: 0.9)
    nodeContainer.anchorPoint = .zero
    litNodes.anchorPoint = .zero
    ghost.isHidden = true
    for layer in [links, edges, nodeContainer, litLinks, litEdges, litNodes, ghost] {
      world.addSublayer(layer)
    }
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
    // The selection follows its node through edits (identity), or its path key otherwise.
    if let selected = selection, let previous {
      selection =
        matches.isEmpty
        ? layout.model.nodes.firstIndex { $0.pathKey == previous.model.nodes[selected].pathKey }
        : matches.first { $0.value == selected }?.key
    }
    self.layout = layout
    ghost.isHidden = true
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
      order = layout.nodes.indices.sorted {
        let (a, b) = (layout.model.nodes[$0].depth, layout.model.nodes[$1].depth)
        return a != b ? a > b : $0 < $1
      }
      applySelection()
    }
  }

  /// Highlights `index`, or clears the highlight. Only layer properties change: colors,
  /// opacities, which container a node layer is in and which shape layer an edge belongs to.
  public func select(_ index: Int?) {
    selection = index.flatMap { layout?.nodes.indices.contains($0) == true ? $0 : nil }
    without { applySelection() }
  }

  /// Label boxes of the highlighted nodes (the camera fits these), or nil without a selection.
  public var selectionBounds: CGRect? {
    guard let layout, selection != nil else { return nil }
    return layout.nodes.indices.filter { lit[$0] }.reduce(CGRect.null) {
      let n = layout.nodes[$1]
      return $0.union(
        CGRect(x: n.x - n.halfWidth, y: n.y - n.up, width: n.halfWidth * 2, height: n.up + n.down))
    }
  }

  private func applySelection() {
    guard let layout else { return }
    let count = layout.nodes.count
    lit = Array(repeating: false, count: count)
    linked = []
    if let selection {
      let highlight = Selection.highlight(layout.model, of: selection)
      for i in highlight.nodes { lit[i] = true }
      linked = Set(highlight.linked)
    }
    for (i, layer) in nodeLayers.enumerated() {
      let source = layout.model.nodes[i]
      let state: NodeState =
        selection == nil
        ? .normal
        : i == selection ? .selected : lit[i] ? .lit : linked.contains(i) ? .linked : .dimmed
      layer.style(state, group: source.depth == 0, big: !source.children.isEmpty, done: source.done)
    }
    if selection == nil {
      nodeContainer.sublayers = order.map { nodeLayers[$0] }
      litNodes.sublayers = nil
    } else {
      nodeContainer.sublayers = order.filter { !lit[$0] }.map { nodeLayers[$0] }
      litNodes.sublayers = order.filter { lit[$0] }.map { nodeLayers[$0] }
    }
    let dim = selection != nil
    edges.strokeColor = GraphStyle.color(
      GraphStyle.edge, alpha: dim ? GraphStyle.dimEdgeOpacity : GraphStyle.edgeOpacity)
    links.strokeColor = GraphStyle.color(
      GraphStyle.edge, alpha: dim ? GraphStyle.dimLinkOpacity : GraphStyle.linkOpacity)
    rebuildPaths()
  }

  /// Shows the dot of a node being named at a world point; hidden by the next `show`.
  public func showGhost(at point: CGPoint, group: Bool) {
    let r = group ? 9.0 : 4
    without {
      ghost.bounds = CGRect(x: 0, y: 0, width: r * 2, height: r * 2)
      ghost.position = point
      ghost.cornerRadius = r
      ghost.backgroundColor = GraphStyle.cached(group ? 0x0d0d0d : 0x55555a)
      ghost.borderColor = GraphStyle.cached(0x4a4a4e)
      ghost.borderWidth = group ? 0.6 : 0
      ghost.isHidden = false
    }
  }

  public func hideGhost() {
    without { ghost.isHidden = true }
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

  /// Edges inside the highlight go to the highlighted shape layers, drawn above everything.
  private func rebuildPaths() {
    guard let layout else { return }
    let highlighted = lit.count == layout.nodes.count
    let tree = CGMutablePath()
    let litTree = CGMutablePath()
    for (i, node) in layout.model.nodes.enumerated() {
      guard let parent = node.parent else { continue }
      let path = highlighted && lit[i] ? litTree : tree
      path.move(to: CGPoint(x: layout.nodes[parent].x, y: layout.nodes[parent].y))
      path.addLine(to: CGPoint(x: layout.nodes[i].x, y: layout.nodes[i].y))
    }
    edges.path = tree
    litEdges.path = litTree
    // Dashed quadratic curves bowed sideways by 18% of their length.
    let cross = CGMutablePath()
    let litCross = CGMutablePath()
    for link in layout.model.resolvedLinks {
      let a = layout.nodes[link.source]
      let b = layout.nodes[link.target]
      let (mx, my, dx, dy) = ((a.x + b.x) / 2, (a.y + b.y) / 2, b.x - a.x, b.y - a.y)
      let path = highlighted && (lit[link.source] || lit[link.target]) ? litCross : cross
      path.move(to: CGPoint(x: a.x, y: a.y))
      path.addQuadCurve(
        to: CGPoint(x: b.x, y: b.y), control: CGPoint(x: mx - dy * 0.18, y: my + dx * 0.18))
    }
    links.path = cross
    litLinks.path = litCross
  }

  /// Sets the camera immediately.
  public func setCamera(_ camera: Camera) {
    for layer in [world, edges, links, litEdges, litLinks] { layer.removeAllAnimations() }
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
    for (layer, width) in lineWidths {
      layer.add(keyframes("lineWidth", cameras.map { width / $0.zoom }), forKey: "camera")
    }
    for layer in [links, litLinks] {
      layer.add(keyframes("lineDashPattern", cameras.map { dash($0) }), forKey: "dash")
    }
    CATransaction.commit()
  }

  private func transform(_ c: Camera) -> CATransform3D {
    CATransform3DMakeAffineTransform(
      CGAffineTransform(a: c.zoom, b: 0, c: 0, d: c.zoom, tx: c.offset.x, ty: c.offset.y))
  }

  private func dash(_ c: Camera) -> [NSNumber] {
    [3 / c.zoom, 4 / c.zoom].map { NSNumber(value: $0) }
  }

  /// Screen widths: 1 px edges and links, 1.8 px highlighted edges, 1.3 px highlighted links.
  private var lineWidths: [(CAShapeLayer, Double)] {
    [(edges, 1), (links, 1), (litEdges, 1.8), (litLinks, 1.3)]
  }

  private func applyCamera(_ c: Camera) {
    world.sublayerTransform = transform(c)
    // Constant on screen at every zoom level.
    for (layer, width) in lineWidths { layer.lineWidth = width / c.zoom }
    links.lineDashPattern = dash(c)
    litLinks.lineDashPattern = dash(c)
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
      if rasterKeys[i] != key || !layer.hasRaster { requests.append((i, key)) }
    }
    guard !requests.isEmpty else {
      onRasterReady?()
      return
    }
    if !rasterizesAsynchronously {
      without {
        for request in requests {
          if let image = NodeRaster.images(look: request.key.look, scale: request.key.scale) {
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
      let images = Dictionary(results.map { ($0.key, $0.images) }, uniquingKeysWith: { a, _ in a })
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

  /// Nearest node within `radius` view points of `point`, else the topmost node whose label
  /// box holds it (prototype: the dot, its 14 px hit circle and the label are one target).
  public func node(at point: CGPoint, radius: Double) -> Int? {
    guard let layout else { return nil }
    let p = camera.toWorld(point)
    let limit = radius / camera.zoom
    var best: (index: Int, distance: Double)?
    for (i, n) in layout.nodes.enumerated() {
      let d = hypot(n.x - p.x, n.y - p.y)
      if d <= max(limit, n.radius), d < best?.distance ?? .infinity { best = (i, d) }
    }
    if let best { return best.index }
    let highlighted = lit.count == layout.nodes.count
    let top =
      order.reversed().filter { highlighted && lit[$0] }
      + order.reversed().filter { !(highlighted && lit[$0]) }
    return top.first { i in
      let n = layout.nodes[i]
      return abs(p.x - n.x) <= n.halfWidth && p.y >= n.y - n.up && p.y <= n.y + n.down
    }
  }

  #if DEBUG
    public func debugIsLit(_ i: Int) -> Bool { lit.indices.contains(i) && lit[i] }
    public func debugOpacity(_ i: Int) -> Float { nodeLayers[i].opacity }
    public var debugGhostVisible: Bool { !ghost.isHidden }
    public var debugLitEdgesEmpty: Bool { litEdges.path?.isEmpty ?? true }
  #endif

  private func without(_ body: () -> Void) {
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    body()
    CATransaction.commit()
  }
}

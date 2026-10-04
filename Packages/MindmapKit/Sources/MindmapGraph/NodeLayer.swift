import CoreText
import MindmapCore
import QuartzCore

/// What a label raster depends on. Colors aren't part of it: selection changes them with layer
/// properties, never by re-rasterizing.
struct NodeLook: Hashable, Sendable {
  var radius: Double
  var fontSize: Double
  var lines: [String]
  var done: Bool
  var halfWidth: Double
  var down: Double
  var family: String

  init(node: GraphNode, source: MapNode, family: String) {
    radius = node.radius
    fontSize = node.fontSize
    lines = node.lines
    done = source.done
    halfWidth = node.halfWidth
    down = node.down
    self.family = family
  }
}

/// How a node is drawn relative to the selection (prototype `restore()` and `select()`).
enum NodeState {
  case normal, selected, lit, dimmed, linked
}

/// The label's two rasters: the canvas-colored halo (filled and stroked, so every glyph pixel
/// sits on opaque canvas) and the glyphs in the brightest label color.
struct LabelImages: @unchecked Sendable {
  var halo: CGImage
  var glyphs: CGImage
}

/// One node: a dot, a halo and the label glyphs. Local (0, 0) is the node's center; the scene
/// moves it by `position` only. The label color is the glyph layer's opacity over the halo.
final class NodeLayer: CALayer {
  private let dot = CALayer()
  private let halo = CALayer()
  private let glyphs = CALayer()
  private struct Style: Equatable {
    var state: NodeState
    var group: Bool
    var big: Bool
    var done: Bool
  }
  private var styled: Style?

  var look: NodeLook? {
    didSet {
      guard let look, look != oldValue else { return }
      let margin = 2.0
      let width = (look.halfWidth + margin) * 2
      let height = look.radius + look.down + margin * 2
      bounds = CGRect(
        x: -look.halfWidth - margin, y: -look.radius - margin, width: width, height: height)
      anchorPoint = CGPoint(x: 0.5, y: (look.radius + margin) / height)
      let r = look.radius
      dot.frame = CGRect(x: -r, y: -r, width: r * 2, height: r * 2)
      dot.cornerRadius = r
      halo.frame = bounds
      glyphs.frame = bounds
      halo.contents = nil
      glyphs.contents = nil
      styled = nil
    }
  }

  var hasRaster: Bool { halo.contents != nil }

  override init() {
    super.init()
    needsDisplayOnBoundsChange = false
    allowsGroupOpacity = false
    for layer in [dot, halo, glyphs] { addSublayer(layer) }
  }

  override init(layer: Any) {
    look = (layer as? NodeLayer)?.look
    super.init(layer: layer)
  }

  required init?(coder: NSCoder) { fatalError("not used") }

  func apply(_ images: LabelImages, scale: Double) {
    halo.contentsScale = scale
    glyphs.contentsScale = scale
    halo.contents = images.halo
    glyphs.contents = images.glyphs
  }

  /// Property writes only; skipped when nothing changed. Call inside a no-actions transaction.
  func style(_ state: NodeState, group: Bool, big: Bool, done: Bool) {
    let style = Style(state: state, group: group, big: big, done: done)
    guard style != styled else { return }
    styled = style
    let base: UInt32 = group ? 0x0d0d0d : big ? 0x141416 : 0x55555a
    switch state {
    case .selected:
      dot.backgroundColor = GraphStyle.cached(0x4f2fc4)
      dot.borderWidth = 0
    case .lit:
      dot.backgroundColor = GraphStyle.cached(big ? 0x0d0d0d : 0xa1a1a6)
      dot.borderColor = GraphStyle.cached(0x6a6a70)
      dot.borderWidth = big ? 0.6 : 0
    case .normal, .dimmed, .linked:
      dot.backgroundColor = GraphStyle.cached(base)
      dot.borderColor = GraphStyle.cached(0x4a4a4e)
      dot.borderWidth = big ? 0.6 : 0
    }
    let bright = state == .selected || state == .lit
    glyphs.opacity = Float(
      GraphStyle.labelAlpha(group ? (bright ? 0xf2f2f7 : 0xd1d1d6) : (bright ? 0xd1d1d6 : 0x6e6e73))
    )
    let dim = state == .dimmed ? 0.3 : state == .linked ? 0.8 : 1
    opacity = Float((done ? 0.4 : 1) * dim)
  }
}

/// Core Text and bitmap work stays on a worker, never on the view's display callback.
enum NodeRaster {
  static func images(look: NodeLook, scale: Double) -> LabelImages? {
    guard let halo = image(look: look, scale: scale, halo: true),
      let glyphs = image(look: look, scale: scale, halo: false)
    else { return nil }
    return LabelImages(halo: halo, glyphs: glyphs)
  }

  private static func image(look: NodeLook, scale: Double, halo: Bool) -> CGImage? {
    let margin = 2.0
    let rect = CGRect(
      x: -look.halfWidth - margin, y: -look.radius - margin,
      width: (look.halfWidth + margin) * 2,
      height: look.radius + look.down + margin * 2)
    let scale = max(0.1, scale)
    guard
      let ctx = CGContext(
        data: nil, width: max(1, Int(ceil(rect.width * scale))),
        height: max(1, Int(ceil(rect.height * scale))), bitsPerComponent: 8,
        bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else { return nil }
    ctx.scaleBy(x: scale, y: -scale)
    ctx.translateBy(x: -rect.minX, y: -rect.maxY)
    draw(look: look, in: ctx, halo: halo)
    return ctx.makeImage()
  }

  private static func draw(look: NodeLook, in ctx: CGContext, halo: Bool) {
    let color = halo ? GraphStyle.canvas : GraphStyle.cached(GraphStyle.brightLabel)
    let font = GraphStyle.font(family: look.family, size: look.fontSize)
    ctx.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
    ctx.setLineJoin(.round)
    for (i, text) in look.lines.enumerated() {
      let line = GraphStyle.line(text, family: look.family, size: look.fontSize)
      let width = CTLineGetTypographicBounds(line, nil, nil, nil)
      // Prototype: first baseline at r + font size, then 1.2 em per line, centered.
      let origin = CGPoint(
        x: -width / 2, y: look.radius + look.fontSize + Double(i) * look.fontSize * 1.2)
      ctx.textPosition = origin
      // 3 px halo in the canvas color behind the text, so labels read over lines.
      ctx.setTextDrawingMode(halo ? .fillStroke : .fill)
      ctx.setLineWidth(3)
      ctx.setStrokeColor(color)
      ctx.setFillColor(color)
      CTLineDraw(line, ctx)
      if look.done {
        let y = origin.y - CTFontGetXHeight(font) / 2
        ctx.setStrokeColor(color)
        ctx.setLineWidth(max(1, look.fontSize * 0.07) + (halo ? 3 : 0))
        ctx.strokeLineSegments(between: [
          CGPoint(x: origin.x, y: y), CGPoint(x: origin.x + width, y: y),
        ])
      }
    }
  }
}

import CoreText
import MindmapCore
import QuartzCore

struct NodeLook: Hashable, Sendable {
  var radius: Double
  var fill: UInt32
  var stroked: Bool
  var fontSize: Double
  var lines: [String]
  var labelColor: UInt32
  var done: Bool
  var halfWidth: Double
  var down: Double

  init(node: GraphNode, source: MapNode) {
    radius = node.radius
    let big = !source.children.isEmpty
    fill = source.depth == 0 ? 0x0d0d0d : big ? 0x141416 : 0x55555a
    stroked = big
    fontSize = node.fontSize
    lines = node.lines
    labelColor = source.depth == 0 ? 0xd1d1d6 : 0x6e6e73
    done = source.done
    halfWidth = node.halfWidth
    down = node.down
  }
}

/// One node: its dot and its label with a halo, rasterized once at `contentsScale`. Local (0, 0)
/// is the node's center; the scene moves it by `position` only.
final class NodeLayer: CALayer {
  var look: NodeLook? {
    didSet {
      guard let look, look != oldValue else { return }
      let margin = 2.0
      let width = (look.halfWidth + margin) * 2
      let height = look.radius + look.down + margin * 2
      bounds = CGRect(
        x: -look.halfWidth - margin, y: -look.radius - margin, width: width, height: height)
      anchorPoint = CGPoint(x: 0.5, y: (look.radius + margin) / height)
      opacity = look.done ? 0.4 : 1
      contents = nil
    }
  }

  override init() {
    super.init()
    needsDisplayOnBoundsChange = false
  }

  override init(layer: Any) {
    look = (layer as? NodeLayer)?.look
    super.init(layer: layer)
  }

  required init?(coder: NSCoder) { fatalError("not used") }

  func apply(_ image: CGImage, scale: Double) {
    contentsScale = scale
    contents = image
  }
}

/// Core Text and bitmap work stays on a worker, never on the view's display callback.
enum NodeRaster {
  static func image(look: NodeLook, scale: Double) -> CGImage? {
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
    draw(look: look, in: ctx)
    return ctx.makeImage()
  }

  private static func draw(look: NodeLook, in ctx: CGContext) {
    let r = look.radius
    let dot = CGRect(x: -r, y: -r, width: r * 2, height: r * 2)
    ctx.setFillColor(GraphStyle.color(look.fill))
    ctx.fillEllipse(in: dot)
    if look.stroked {
      ctx.setStrokeColor(GraphStyle.color(0x4a4a4e))
      ctx.setLineWidth(0.6)
      ctx.strokeEllipse(in: dot)
    }
    let color = GraphStyle.color(look.labelColor)
    let font = GraphStyle.font(size: look.fontSize)
    ctx.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
    ctx.setLineJoin(.round)
    for (i, text) in look.lines.enumerated() {
      let line = GraphStyle.line(text, size: look.fontSize)
      let width = CTLineGetTypographicBounds(line, nil, nil, nil)
      // Prototype: first baseline at r + font size, then 1.2 em per line, centered.
      let origin = CGPoint(
        x: -width / 2, y: r + look.fontSize + Double(i) * look.fontSize * 1.2)
      ctx.textPosition = origin
      // 3 px halo in the canvas color behind the text, so labels read over lines.
      ctx.setTextDrawingMode(.stroke)
      ctx.setLineWidth(3)
      ctx.setStrokeColor(GraphStyle.canvas)
      CTLineDraw(line, ctx)
      ctx.textPosition = origin
      ctx.setTextDrawingMode(.fill)
      ctx.setFillColor(color)
      CTLineDraw(line, ctx)
      if look.done {
        let y = origin.y - CTFontGetXHeight(font) / 2
        ctx.setStrokeColor(color)
        ctx.setLineWidth(max(1, look.fontSize * 0.07))
        ctx.strokeLineSegments(between: [
          CGPoint(x: origin.x, y: y), CGPoint(x: origin.x + width, y: y),
        ])
      }
    }
  }
}

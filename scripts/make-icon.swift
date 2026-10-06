// Renders the app icon from code for `make icon`, run with `swift scripts/make-icon.swift`.
// Writes Icon Composer bundles: App/Shared/AppIcon.icon (Release) and App/Shared/Debug/AppIcon-dev.icon (Debug,
// the same icon with an orange badge). Each layer is a full-bleed 1024 px PNG; the system applies
// the macOS shape, glass and shadows. See "App icon" in docs/design.md.
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

// Colors from docs/design.md.
func rgb(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
  CGColor(
    srgbRed: CGFloat(hex >> 16 & 0xff) / 255, green: CGFloat(hex >> 8 & 0xff) / 255,
    blue: CGFloat(hex & 0xff) / 255, alpha: alpha)
}
let groupFill = rgb(0x0d0d0d)
let groupStroke = rgb(0x5a5a5f)
let taskFill = rgb(0x8e8e93)
let edgeColor = rgb(0x8a8a90, 0.75)
let purple = rgb(0x4f2fc4)
let purpleEdge = rgb(0x6a4ff0)
let devOrange = rgb(0xff9f0a)

// The art is drawn in a 1024 canvas, y down, inside the 824 icon body inset by 100.
typealias Dot = (x: CGFloat, y: CGFloat, r: CGFloat)
let edgeWidth: CGFloat = 12
let groups: [Dot] = [(330, 420, 56)]
let tasks: [Dot] = [
  (450, 320, 26), (255, 580, 26), (470, 520, 22),
]
let accents: [Dot] = [
  (650, 590, 50), (770, 450, 28), (720, 730, 28),
]

func circle(_ n: Dot) -> CGRect {
  CGRect(x: n.x - n.r, y: n.y - n.r, width: 2 * n.r, height: 2 * n.r)
}

func line(
  _ ctx: CGContext, from a: Dot,
  to b: Dot
) {
  ctx.move(to: CGPoint(x: a.x, y: a.y))
  ctx.addLine(to: CGPoint(x: b.x, y: b.y))
}

// A paper map folded in three panels.
func drawMap(_ ctx: CGContext) {
  let xs: [CGFloat] = [180, 395, 630, 845]
  let tops: [CGFloat] = [250, 200, 250, 200]
  for i in 0..<3 {
    ctx.move(to: CGPoint(x: xs[i], y: tops[i]))
    ctx.addLine(to: CGPoint(x: xs[i + 1], y: tops[i + 1]))
    ctx.addLine(to: CGPoint(x: xs[i + 1], y: tops[i + 1] + 580))
    ctx.addLine(to: CGPoint(x: xs[i], y: tops[i] + 580))
    ctx.closePath()
    ctx.setFillColor(rgb(i == 1 ? 0x2a2a2d : 0x36363a))
    ctx.fillPath()
  }
}

// One group with its tasks, and a dashed cross link bowing down to the purple branch.
func drawGraph(_ ctx: CGContext) {
  ctx.setLineCap(.round)
  ctx.setLineWidth(edgeWidth)
  ctx.setStrokeColor(edgeColor)
  for t in tasks { line(ctx, from: groups[0], to: t) }
  ctx.strokePath()

  let p = CGPoint(x: tasks[1].x, y: tasks[1].y)
  let q = CGPoint(x: accents[2].x, y: accents[2].y)
  let len = hypot(q.x - p.x, q.y - p.y)
  let bow: CGFloat = 110
  ctx.move(to: p)
  ctx.addQuadCurve(
    to: q,
    control: CGPoint(
      x: (p.x + q.x) / 2 - (q.y - p.y) / len * bow, y: (p.y + q.y) / 2 + (q.x - p.x) / len * bow))
  ctx.setLineWidth(edgeWidth * 0.8)
  ctx.setStrokeColor(edgeColor.copy(alpha: 0.6)!)
  ctx.setLineDash(phase: 0, lengths: [edgeWidth * 1.6, edgeWidth * 1.8])
  ctx.strokePath()
  ctx.setLineDash(phase: 0, lengths: [])

  for g in groups {
    ctx.setFillColor(groupFill)
    ctx.fillEllipse(in: circle(g))
    ctx.setLineWidth(max(8, g.r * 0.12))
    ctx.setStrokeColor(groupStroke)
    ctx.strokeEllipse(in: circle(g).insetBy(dx: g.r * 0.06, dy: g.r * 0.06))
  }
  ctx.setFillColor(taskFill)
  for t in tasks { ctx.fillEllipse(in: circle(t)) }
}

// The selected branch: a purple group and its children.
func drawAccent(_ ctx: CGContext) {
  ctx.setLineCap(.round)
  ctx.setLineWidth(edgeWidth * 1.15)
  ctx.setStrokeColor(purpleEdge)
  for child in accents.dropFirst() { line(ctx, from: accents[0], to: child) }
  ctx.strokePath()
  ctx.setFillColor(purple)
  for n in accents { ctx.fillEllipse(in: circle(n)) }
}

// Dev only: an orange disc in the top-right corner, ringed in graphite so it separates from the art.
func drawBadge(_ ctx: CGContext) {
  let badge = (x: CGFloat(790), y: CGFloat(234), r: CGFloat(92))
  ctx.setFillColor(rgb(0x1e1e1e))
  ctx.fillEllipse(in: circle(badge).insetBy(dx: -18, dy: -18))
  ctx.setFillColor(devOrange)
  ctx.fillEllipse(in: circle(badge))
}

func writeLayer(_ draw: (CGContext) -> Void, to url: URL) throws {
  let ctx = CGContext(
    data: nil, width: 1024, height: 1024, bitsPerComponent: 8, bytesPerRow: 0,
    space: CGColorSpace(name: CGColorSpace.sRGB)!,
    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
  ctx.translateBy(x: 0, y: 1024)
  ctx.scaleBy(x: 1024 / 824, y: -1024 / 824)  // y down, and the 824 body fills the canvas
  ctx.translateBy(x: -100, y: -100)
  draw(ctx)
  let dest = CGImageDestinationCreateWithURL(
    url as CFURL, UTType.png.identifier as CFString, 1, nil)!
  CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
  guard CGImageDestinationFinalize(dest) else { throw CocoaError(.fileWriteUnknown) }
}

// Groups are listed front to back. Only the graph gets Liquid Glass; the map stays flat paper.
func writeIcon(at bundle: URL, badge: Bool) throws {
  let assets = bundle.appendingPathComponent("Assets")
  try? FileManager.default.removeItem(at: bundle)
  try FileManager.default.createDirectory(at: assets, withIntermediateDirectories: true)
  var layers: [(name: String, draw: (CGContext) -> Void)] = [
    ("accent", drawAccent), ("graph", drawGraph), ("map", drawMap),
  ]
  if badge { layers.insert(("badge", drawBadge), at: 0) }
  for layer in layers {
    try writeLayer(layer.draw, to: assets.appendingPathComponent("\(layer.name).png"))
  }
  func group(_ names: [String], glass: Bool) -> [String: Any] {
    [
      "layers": names.map { ["name": $0, "image-name": "\($0).png", "glass": glass] },
      "shadow": ["kind": "neutral", "opacity": 0.5],
      "translucency": ["enabled": false, "value": 0.5],
    ]
  }
  var groups = [group(["accent", "graph"], glass: true), group(["map"], glass: false)]
  if badge { groups.insert(group(["badge"], glass: false), at: 0) }
  let json: [String: Any] = [
    // Canvas #1e1e1e, lifted slightly toward the top, as in the app.
    "fill": [
      "linear-gradient": [
        "srgb:0.16471,0.16471,0.17255,1.00000", "srgb:0.10196,0.10196,0.10196,1.00000",
      ]
    ],
    "groups": groups,
    "supported-platforms": ["squares": "shared"],
  ]
  let data = try JSONSerialization.data(
    withJSONObject: json, options: [.prettyPrinted, .sortedKeys])
  try data.write(to: bundle.appendingPathComponent("icon.json"))
  print(bundle.path)
}

let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
try writeIcon(at: root.appendingPathComponent("App/Shared/AppIcon.icon"), badge: false)
try writeIcon(at: root.appendingPathComponent("App/Shared/Debug/AppIcon-dev.icon"), badge: true)

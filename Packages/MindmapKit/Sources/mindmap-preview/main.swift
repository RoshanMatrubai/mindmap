// Renders a map to a PNG so agents can look at their visual work: the real frozen graph, drawn
// offscreen by the app's own layer code with a fixed seed, fit to 1600×1000.
// Usage: mindmap-preview --fixture <path.mindmap> --out <file.png> [--seed <n>] [--font <family>]
import CoreGraphics
import CoreText
import Foundation
import ImageIO
import MindmapCore
import MindmapGraph
import QuartzCore
import UniformTypeIdentifiers

func fail(_ message: String) -> Never {
  FileHandle.standardError.write(Data((message + "\n").utf8))
  exit(1)
}

func value(after flag: String, in args: [String]) -> String? {
  guard let i = args.firstIndex(of: flag), i + 1 < args.count else { return nil }
  return args[i + 1]
}

let args = CommandLine.arguments
guard let fixture = value(after: "--fixture", in: args), let out = value(after: "--out", in: args)
else {
  fail(
    "usage: mindmap-preview --fixture <path.mindmap> --out <file.png> [--seed <n>] [--font <family>]"
  )
}
let seed = value(after: "--seed", in: args).flatMap(Int.init) ?? 7

let family = value(after: "--font", in: args) ?? GraphFonts.defaultFamily
// The app registers bundled fonts from its Resources; here, from the repo.
let fonts = URL(fileURLWithPath: #filePath).appendingPathComponent(
  "../../../../../App/Shared/Fonts"
)
.standardized
if !GraphFonts.register(family, in: fonts) { fail("cannot register \(family) from \(fonts.path)") }

let text: String
do { text = try String(contentsOfFile: fixture, encoding: .utf8) } catch {
  fail("cannot read \(fixture): \(error.localizedDescription)")
}

let model = MapParser.parse(text: text, today: Date(), calendar: .current)
// Off the main thread, as in the app.
let started = Date()
let layout = await Task.detached(priority: .userInitiated) {
  ForceLayout.run(
    model: model, seed: seed, today: Date(), calendar: .current,
    measure: GraphStyle.measure(family: family))
}.value
let elapsed = Date().timeIntervalSince(started) * 1000
print(
  "layout: \(layout.nodes.count) nodes, \(layout.ticks) ticks, \(String(format: "%.1f", elapsed)) ms"
)

let size = CGSize(width: 1600, height: 1000)
let scene = GraphScene()
scene.labelFamily = family
scene.screenScale = 1
scene.setSize(size)
scene.setTitle((model.title.isEmpty ? "untitled map" : model.title).lowercased())
scene.show(layout)
scene.setCamera(Camera.fit(layout.bounds, in: size))
scene.refreshRaster()
scene.displayNow()

guard
  let ctx = CGContext(
    data: nil, width: Int(size.width), height: Int(size.height), bitsPerComponent: 8,
    bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
    bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue)
else { fail("cannot create bitmap context") }
// render(in:) ignores the root's own geometry flip; flip the bitmap to match the screen.
ctx.translateBy(x: 0, y: size.height)
ctx.scaleBy(x: 1, y: -1)
scene.root.render(in: ctx)

let url = URL(fileURLWithPath: out)
try? FileManager.default.createDirectory(
  at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
guard let image = ctx.makeImage(),
  let dest = CGImageDestinationCreateWithURL(
    url as CFURL, UTType.png.identifier as CFString, 1, nil)
else { fail("cannot write \(out)") }
CGImageDestinationAddImage(dest, image, nil)
guard CGImageDestinationFinalize(dest) else { fail("cannot write \(out)") }
print("wrote \(out)")

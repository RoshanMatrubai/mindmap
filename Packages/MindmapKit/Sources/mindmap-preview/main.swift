// Renders a map to a PNG so agents can look at their visual work.
// Usage: mindmap-preview --fixture <path.mindmap> --out <file.png>
// Placeholder: draws the title and parse stats. Step 2 adds the real graph render.
import CoreGraphics
import CoreText
import Foundation
import ImageIO
import MindmapCore
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
else { fail("usage: mindmap-preview --fixture <path.mindmap> --out <file.png>") }

let text: String
do { text = try String(contentsOfFile: fixture, encoding: .utf8) } catch {
  fail("cannot read \(fixture): \(error.localizedDescription)")
}
let model = MapParser.parse(text: text, today: Date(), calendar: .current)
let title = (model.title.isEmpty ? "mindmap" : model.title).lowercased()

func rgb(_ hex: UInt32) -> CGColor {
  CGColor(
    srgbRed: CGFloat((hex >> 16) & 0xff) / 255, green: CGFloat((hex >> 8) & 0xff) / 255,
    blue: CGFloat(hex & 0xff) / 255, alpha: 1)
}

let width = 1600
let height = 1000
guard
  let ctx = CGContext(
    data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
    space: CGColorSpace(name: CGColorSpace.sRGB)!,
    bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue)
else { fail("cannot create bitmap context") }

ctx.setFillColor(rgb(0x1e1e1e))
ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))

// Title top left, as in the prototype (15 pt at 14, 10 from the corner). CG's origin is bottom left.
let font = CTFontCreateUIFontForLanguage(.system, 15, nil)!
let line = CTLineCreateWithAttributedString(
  NSAttributedString(
    string: title,
    attributes: [
      NSAttributedString.Key(kCTFontAttributeName as String): font,
      NSAttributedString.Key(kCTForegroundColorAttributeName as String): rgb(0x636366),
    ]))
ctx.textPosition = CGPoint(x: 14, y: CGFloat(height) - 10 - CTFontGetAscent(font))
CTLineDraw(line, ctx)

let statsFont = CTFontCreateUIFontForLanguage(.system, 13, nil)!
let statsLine = CTLineCreateWithAttributedString(
  NSAttributedString(
    string: model.statsText,
    attributes: [
      NSAttributedString.Key(kCTFontAttributeName as String): statsFont,
      NSAttributedString.Key(kCTForegroundColorAttributeName as String): rgb(0x636366),
    ]))
ctx.textPosition = CGPoint(x: 14, y: CGFloat(height) - 38 - CTFontGetAscent(statsFont))
CTLineDraw(statsLine, ctx)

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

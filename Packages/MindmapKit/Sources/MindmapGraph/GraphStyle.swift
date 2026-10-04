import CoreGraphics
import CoreText
import Foundation
import MindmapCore

/// Colors and fonts from docs/design.md and the prototype.
public enum GraphStyle {
  public static let canvas = color(0x1e1e1e)
  static let edge = 0x6e6e75 as UInt32
  static let edgeOpacity = 0.55
  static let linkOpacity = 0.35
  static let dimEdgeOpacity = 0.28
  static let dimLinkOpacity = 0.15
  static let litEdge = 0x6a4ff0 as UInt32
  static let titleColor = color(0x636366)

  /// Label glyphs are rasterized in this color; dimmer label colors are its opacity over the halo.
  static let brightLabel: UInt32 = 0xf2f2f7

  /// The glyph opacity that turns `brightLabel` over the canvas into `hex` (channel average).
  static func labelAlpha(_ hex: UInt32) -> Double {
    let shifts: [UInt32] = [16, 8, 0]
    let channel = { (value: UInt32, shift: UInt32) in Double((value >> shift) & 255) }
    return shifts.map {
      (channel(hex, $0) - channel(0x1e1e1e, $0))
        / (channel(brightLabel, $0) - channel(0x1e1e1e, $0))
    }.reduce(0, +) / 3
  }

  private static let palette = Dictionary(
    uniqueKeysWithValues: [
      0x0d0d0d, 0x141416, 0x55555a, 0x4a4a4e, 0x4f2fc4, 0xa1a1a6, 0x6a6a70, brightLabel,
    ].map { ($0, color($0)) })

  /// Node colors are made once and shared, so a selection allocates nothing per node.
  static func cached(_ hex: UInt32) -> CGColor { palette[hex] ?? color(hex) }

  static func color(_ hex: UInt32, alpha: Double = 1) -> CGColor {
    CGColor(
      srgbRed: CGFloat((hex >> 16) & 255) / 255, green: CGFloat((hex >> 8) & 255) / 255,
      blue: CGFloat(hex & 255) / 255, alpha: alpha)
  }

  /// Nunito Sans is registered from the app bundle (ATSApplicationFontsPath) or by the preview
  /// tool. Its variable font defaults to ExtraLight, so ask for Regular (wght 400) explicitly.
  public static func font(size: Double) -> CTFont {
    let wght = 0x7767_6874  // 'wght'
    let descriptor = CTFontDescriptorCreateWithAttributes(
      [
        kCTFontFamilyNameAttribute: "Nunito Sans",
        kCTFontVariationAttribute: [wght: 400],
      ] as CFDictionary)
    let font = CTFontCreateWithFontDescriptor(descriptor, size, nil)
    guard CTFontCopyFamilyName(font) as String == "Nunito Sans" else {
      return CTFontCreateUIFontForLanguage(.system, size, nil)!
    }
    return font
  }

  /// Real label widths for the layout's collision boxes.
  public static let measure: ForceLayout.Measure = { line, size in
    Double(CTLineGetTypographicBounds(GraphStyle.line(line, size: size), nil, nil, nil))
  }

  static func line(_ text: String, size: Double, color: CGColor? = nil) -> CTLine {
    var attributes: [NSAttributedString.Key: Any] = [
      NSAttributedString.Key(kCTFontAttributeName as String): font(size: size)
    ]
    if let color {
      attributes[NSAttributedString.Key(kCTForegroundColorAttributeName as String)] = color
    } else {
      attributes[NSAttributedString.Key(kCTForegroundColorFromContextAttributeName as String)] =
        true
    }
    return CTLineCreateWithAttributedString(
      NSAttributedString(string: text, attributes: attributes))
  }
}

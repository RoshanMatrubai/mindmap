import CoreText
import Foundation
import Testing

@testable import MindmapGraph

private let fontsFolder = URL(fileURLWithPath: #filePath)
  .appendingPathComponent("../../../../../App/Fonts").standardized

/// Every picker family is bundled with its license, registers, and resolves to itself rather
/// than the SF Pro fallback, so the catalog names match the fonts' own family names.
@Test(arguments: GraphFonts.bundled)
func bundledFamilyResolves(_ family: String) throws {
  let slug = family.replacingOccurrences(of: " ", with: "")
  #expect(GraphFonts.files(of: family, in: fontsFolder).count == 1)
  let license = fontsFolder.appending(path: "\(slug)/\(slug)-OFL.txt")
  #expect(try String(contentsOf: license, encoding: .utf8).contains("SIL Open Font License"))
  #expect(GraphFonts.register(family, in: fontsFolder))
  let font = GraphStyle.font(family: family, size: 13)
  #expect(CTFontCopyFamilyName(font) as String == GraphFonts.fontFamily(family))
  #expect(GraphStyle.measure(family: family)("hello", 13) > 10)
}

@Test func everyBundledFolderIsInThePicker() throws {
  let folders = try FileManager.default.contentsOfDirectory(atPath: fontsFolder.path)
    .filter { !$0.hasPrefix(".") }
  let slugs = Set(GraphFonts.bundled.map { $0.replacingOccurrences(of: " ", with: "") })
  #expect(Set(folders) == slugs)
  #expect(GraphFonts.groups.map(\.name) == ["System", "Humanist", "Rounded", "Geometric"])
}

@Test func systemFamiliesNeedNoFiles() {
  #expect(GraphFonts.register(GraphFonts.system, in: fontsFolder))
  let rounded = GraphStyle.font(family: GraphFonts.systemRounded, size: 13)
  let plain = GraphStyle.font(family: GraphFonts.system, size: 13)
  #expect(CTFontCopyPostScriptName(rounded) != CTFontCopyPostScriptName(plain))
  // Unknown families fall back to SF Pro instead of a random font.
  let unknown = GraphStyle.font(family: "No Such Font", size: 13)
  #expect(CTFontCopyPostScriptName(unknown) == CTFontCopyPostScriptName(plain))
}

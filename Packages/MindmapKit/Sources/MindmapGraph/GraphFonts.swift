import CoreText
import Foundation
import os

/// The label font picker's families (docs/design.md "Fonts"). Bundled families ship as one
/// upright file each in App/Shared/Fonts/<Family>/, named `<Family>.ttf` (variable) or
/// `<Family>-Regular.ttf`, without spaces. SF Pro and SF Pro Rounded are system fonts.
public enum GraphFonts {
  public struct Group: Sendable, Identifiable {
    public let name: String
    public let families: [String]
    public var id: String { name }
  }

  public static let defaultFamily = "Nunito Sans"
  public static let system = "SF Pro"
  public static let systemRounded = "SF Pro Rounded"

  public static let groups = [
    Group(name: "System", families: [system, systemRounded]),
    Group(
      name: "Humanist",
      families: [
        "Nunito Sans", "Mulish", "Karla", "Figtree", "Lato", "Open Sans", "Source Sans 3", "Cabin",
        "Red Hat Text", "Albert Sans", "Atkinson Hyperlegible Next", "Inclusive Sans",
        "Reddit Sans", "Gantari", "Lexend", "Readex Pro", "Noto Sans", "Fira Sans", "PT Sans",
        "Public Sans", "IBM Plex Sans", "Libre Franklin", "Overpass", "Asap", "Encode Sans",
        "Hind", "Mukta", "Signika", "Instrument Sans", "Schibsted Grotesk",
      ]),
    Group(
      name: "Rounded",
      families: ["Nunito", "Quicksand", "Varela Round", "M PLUS Rounded 1c", "Rubik"]),
    Group(
      name: "Geometric",
      families: [
        "Outfit", "Manrope", "Poppins", "Urbanist", "Plus Jakarta Sans", "DM Sans", "Work Sans",
        "Onest", "Golos Text", "Commissioner", "Be Vietnam Pro", "Hanken Grotesk", "Kumbh Sans",
      ]),
  ]

  /// The family name inside the font file, when it differs from the picker's (Google's) name.
  public static func fontFamily(_ family: String) -> String {
    family == "M PLUS Rounded 1c" ? "Rounded Mplus 1c" : family
  }

  public static var bundled: [String] {
    groups.flatMap(\.families).filter { $0 != system && $0 != systemRounded }
  }

  private static let registered = OSAllocatedUnfairLock(initialState: Set<String>())

  /// The font files of `family` under `root`: the app's Resources (flat) or App/Shared/Fonts (nested).
  public static func files(of family: String, in root: URL) -> [URL] {
    let slug = family.replacingOccurrences(of: " ", with: "")
    let names: Set = [slug + ".ttf", slug + "-Regular.ttf"]
    let found = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)?
      .compactMap { $0 as? URL }.filter { names.contains($0.lastPathComponent) }
    return found ?? []
  }

  /// Registers a bundled family for this process, once. System families need nothing. Launch
  /// registers only the selected family; the picker registers the rest (off the main thread).
  @discardableResult
  public static func register(_ family: String, in root: URL? = Bundle.main.resourceURL) -> Bool {
    guard family != system, family != systemRounded else { return true }
    guard !registered.withLock({ $0.contains(family) }), let root else { return true }
    let files = files(of: family, in: root)
    guard !files.isEmpty else { return false }
    var ok = true
    for url in files where !CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil) {
      ok = false
    }
    registered.withLock { _ = $0.insert(family) }
    return ok
  }

  public static func registerAll(in root: URL? = Bundle.main.resourceURL) {
    for family in bundled { register(family, in: root) }
  }
}

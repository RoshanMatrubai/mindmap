import Foundation

public struct MapFile: Identifiable, Sendable, Equatable {
  public var id: URL { url }
  public let url: URL
  public let title: String
  public let modified: Date
  /// False for a map iCloud Drive hasn't downloaded to this device yet; its title is then the
  /// file name, and opening it downloads it.
  public let isDownloaded: Bool

  public init(url: URL, title: String, modified: Date, isDownloaded: Bool = true) {
    self.url = url
    self.title = title
    self.modified = modified
    self.isDownloaded = isDownloaded
  }
}

/// File operations run on the app's repository actor, never during typing on the main thread.
public enum MapFiles {
  public static func availableURL(title: String, in folder: URL, excluding current: URL? = nil)
    -> URL
  {
    let stripped = title.replacingOccurrences(of: "/", with: "").replacingOccurrences(
      of: ":", with: ""
    )
    .trimmingCharacters(in: .whitespacesAndNewlines)
    let base = stripped.isEmpty || stripped == "." || stripped == ".." ? "untitled map" : stripped
    var suffix = 1
    while true {
      let name = base + (suffix == 1 ? "" : " \(suffix)") + ".mindmap"
      let url = folder.appendingPathComponent(name)
      if url == current || !FileManager.default.fileExists(atPath: url.path) { return url }
      suffix += 1
    }
  }

  /// Every map in `folder`, newest first. Maps iCloud hasn't downloaded are listed too (by file
  /// name) without reading them: on iPadOS they are hidden `.<name>.icloud` placeholders, on
  /// macOS dataless files.
  public static func list(in folder: URL) throws -> [MapFile] {
    let keys: [URLResourceKey] = [
      .contentModificationDateKey, .isRegularFileKey, .ubiquitousItemDownloadingStatusKey,
    ]
    let urls = try FileManager.default.contentsOfDirectory(
      at: folder, includingPropertiesForKeys: keys, options: [])
    var maps: [URL: MapFile] = [:]
    for url in urls {
      let values = try url.resourceValues(forKeys: Set(keys))
      guard values.isRegularFile == true else { continue }
      let modified = values.contentModificationDate ?? .distantPast
      if let name = MapSync.placeholderTarget(url.lastPathComponent) {
        let target = folder.appendingPathComponent(name)
        if maps[target] == nil {
          maps[target] = MapFile(
            url: target, title: target.deletingPathExtension().lastPathComponent,
            modified: modified, isDownloaded: false)
        }
        continue
      }
      guard url.pathExtension == "mindmap", !url.lastPathComponent.hasPrefix(".") else { continue }
      guard isDownloaded(values) else {
        maps[url] = MapFile(
          url: url, title: url.deletingPathExtension().lastPathComponent, modified: modified,
          isDownloaded: false)
        continue
      }
      let text = try String(contentsOf: url, encoding: .utf8)
      maps[url] = MapFile(
        url: url, title: MapDocument.title(of: text) ?? "untitled map", modified: modified)
    }
    return maps.values.sorted {
      $0.modified == $1.modified
        ? $0.url.lastPathComponent < $1.url.lastPathComponent : $0.modified > $1.modified
    }
  }

  /// Whether the map's contents are on this device (always, outside iCloud Drive).
  public static func isDownloaded(_ url: URL) -> Bool {
    let placeholder = url.deletingLastPathComponent().appendingPathComponent(
      "." + url.lastPathComponent + ".icloud")
    if !FileManager.default.fileExists(atPath: url.path) {
      return !FileManager.default.fileExists(atPath: placeholder.path)
    }
    var fresh = url
    fresh.removeAllCachedResourceValues()
    guard let values = try? fresh.resourceValues(forKeys: [.ubiquitousItemDownloadingStatusKey])
    else { return true }
    return isDownloaded(values)
  }

  private static func isDownloaded(_ values: URLResourceValues) -> Bool {
    guard let status = values.ubiquitousItemDownloadingStatus else { return true }
    return status == .current || status == .downloaded
  }
}

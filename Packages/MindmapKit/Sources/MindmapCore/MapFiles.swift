import Foundation

public struct MapFile: Identifiable, Sendable, Equatable {
  public var id: URL { url }
  public let url: URL
  public let title: String
  public let modified: Date

  public init(url: URL, title: String, modified: Date) {
    self.url = url
    self.title = title
    self.modified = modified
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

  public static func list(in folder: URL) throws -> [MapFile] {
    let urls = try FileManager.default.contentsOfDirectory(
      at: folder, includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
      options: [.skipsHiddenFiles])
    return try urls.filter { $0.pathExtension == "mindmap" }.compactMap { url in
      let values = try url.resourceValues(forKeys: [.contentModificationDateKey, .isRegularFileKey])
      guard values.isRegularFile == true else { return nil }
      let text = try String(contentsOf: url, encoding: .utf8)
      return MapFile(
        url: url, title: MapDocument.title(of: text) ?? "untitled map",
        modified: values.contentModificationDate ?? .distantPast)
    }.sorted {
      $0.modified == $1.modified
        ? $0.url.lastPathComponent < $1.url.lastPathComponent : $0.modified > $1.modified
    }
  }
}

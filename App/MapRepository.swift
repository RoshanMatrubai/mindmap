import Foundation
import MindmapCore

/// Serial file access also keeps autosave and rename from racing one another.
actor MapRepository {
  private var documents: [UUID: URL] = [:]

  struct Saved: Sendable {
    let url: URL
    let loaded: Loaded
  }

  func open(_ url: URL, document: UUID) throws -> Loaded {
    let loaded = try load(url)
    documents[document] = url
    return loaded
  }

  func save(_ text: String, document: UUID) throws -> Saved {
    guard let url = documents[document] else { throw CocoaError(.fileNoSuchFile) }
    return Saved(url: url, loaded: try save(text, to: url))
  }

  func rename(document: UUID, title: String) throws -> URL {
    guard let url = documents[document] else { throw CocoaError(.fileNoSuchFile) }
    let target = try rename(url, title: title)
    documents[document] = target
    return target
  }
  struct Loaded: Sendable {
    let text: String
    let modified: Date?
    let size: Int?
  }

  func list(_ folder: URL) throws -> [MapFile] { try MapFiles.list(in: folder) }

  func loadLayout(document: UUID) -> LayoutSidecar? {
    documents[document].flatMap(LayoutSidecar.load(for:))
  }

  func saveLayout(_ layout: LayoutSidecar, document: UUID) throws {
    guard let url = documents[document] else { throw CocoaError(.fileNoSuchFile) }
    try layout.save(for: url)
  }

  func load(_ url: URL) throws -> Loaded {
    let text = try String(contentsOf: url, encoding: .utf8)
    var fresh = url
    fresh.removeAllCachedResourceValues()
    let values = try fresh.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
    return Loaded(text: text, modified: values.contentModificationDate, size: values.fileSize)
  }

  func changed(_ url: URL, since loaded: Loaded?) throws -> Bool {
    var fresh = url
    fresh.removeAllCachedResourceValues()
    let values = try fresh.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
    return values.contentModificationDate != loaded?.modified || values.fileSize != loaded?.size
  }

  func save(_ text: String, to url: URL) throws -> Loaded {
    try text.write(to: url, atomically: true, encoding: .utf8)
    return try load(url)
  }

  func create(in folder: URL) throws -> URL {
    let url = MapFiles.availableURL(title: "untitled map", in: folder)
    _ = try save("untitled map\n", to: url)
    return url
  }

  func rename(_ url: URL, title: String) throws -> URL {
    let target = MapFiles.availableURL(
      title: title, in: url.deletingLastPathComponent(), excluding: url)
    if target != url {
      try FileManager.default.moveItem(at: url, to: target)
      do { try CalendarSidecar.move(from: url, to: target) } catch {
        log.error("calendar sidecar rename failed")
        // Keep actor-owned document identity valid when the sidecar cannot follow the map.
        do { try FileManager.default.moveItem(at: target, to: url) } catch {
          // A failed rollback must still leave autosave targeting the map that exists.
          for (id, documentURL) in documents where documentURL == url { documents[id] = target }
          throw error
        }
        throw error
      }
      // The layout sidecar follows its map; losing it only costs the remembered layout.
      do { try LayoutSidecar.move(from: url, to: target) } catch {
        log.error("layout sidecar rename failed: \(error, privacy: .public)")
      }
    }
    return target
  }
}

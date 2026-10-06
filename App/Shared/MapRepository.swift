import Foundation
import MindmapCore

/// Serial file access also keeps autosave and rename from racing one another. Every read and
/// write is coordinated (`NSFileCoordinator`), so a maps folder in iCloud Drive is never read
/// half-synced or written under the sync daemon, and reading a file iCloud hasn't downloaded
/// yet downloads it first. The folder presenter is passed along, so the app isn't told about
/// its own writes.
actor MapRepository {
  private var documents: [UUID: URL] = [:]
  private var presenter: MapFolderPresenter?

  struct Saved: Sendable {
    let url: URL
    let loaded: Loaded
  }

  struct Loaded: Sendable {
    let text: String
    let modified: Date?
    let size: Int?
  }

  /// Another device's version of a map: its text, the device that saved it and when.
  struct OtherVersion: Sendable, Equatable {
    let text: String
    let device: String
    let date: Date
  }

  func setPresenter(_ presenter: MapFolderPresenter?) { self.presenter = presenter }

  private func coordinator() -> NSFileCoordinator { NSFileCoordinator(filePresenter: presenter) }

  private func reading<T>(_ url: URL, _ body: (URL) throws -> T) throws -> T {
    var failure: NSError?
    var result: Result<T, Error> = .failure(CocoaError(.fileReadUnknown))
    coordinator().coordinate(readingItemAt: url, options: [], error: &failure) { url in
      result = Result { try body(url) }
    }
    if let failure { throw failure }
    return try result.get()
  }

  private func writing<T>(_ url: URL, _ body: (URL) throws -> T) throws -> T {
    var failure: NSError?
    var result: Result<T, Error> = .failure(CocoaError(.fileWriteUnknown))
    coordinator().coordinate(writingItemAt: url, options: .forReplacing, error: &failure) { url in
      result = Result { try body(url) }
    }
    if let failure { throw failure }
    return try result.get()
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

  func list(_ folder: URL) throws -> [MapFile] {
    try reading(folder) { try MapFiles.list(in: $0) }
  }

  func loadLayout(document: UUID) -> LayoutSidecar? {
    guard let map = documents[document] else { return nil }
    let url = LayoutSidecar.url(for: map)
    // Sidecars sync with their map; one iCloud hasn't fetched yet downloads on the read.
    try? FileManager.default.startDownloadingUbiquitousItem(at: url)
    return try? reading(url) { _ in LayoutSidecar.load(for: map) }
  }

  func saveLayout(_ layout: LayoutSidecar, document: UUID) throws {
    guard let url = documents[document] else { throw CocoaError(.fileNoSuchFile) }
    // Last writer wins: a layout is only remembered positions.
    try writing(LayoutSidecar.url(for: url)) { _ in try layout.save(for: url) }
  }

  func load(_ url: URL) throws -> Loaded {
    try reading(url) { url in
      let text = try String(contentsOf: url, encoding: .utf8)
      var fresh = url
      fresh.removeAllCachedResourceValues()
      let values = try fresh.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
      return Loaded(text: text, modified: values.contentModificationDate, size: values.fileSize)
    }
  }

  /// Who saved the file's current version (iCloud records the device), for a conflict copy.
  func currentSaver(of url: URL) -> String {
    NSFileVersion.currentVersionOfItem(at: url)?.localizedNameOfSavingComputer ?? "another device"
  }

  func changed(_ url: URL, since loaded: Loaded?) throws -> Bool {
    var fresh = url
    fresh.removeAllCachedResourceValues()
    let values = try fresh.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
    return values.contentModificationDate != loaded?.modified || values.fileSize != loaded?.size
  }

  func save(_ text: String, to url: URL) throws -> Loaded {
    try writing(url) { url in try text.write(to: url, atomically: true, encoding: .utf8) }
    return try load(url)
  }

  func create(in folder: URL) throws -> URL {
    let url = MapFiles.availableURL(title: "untitled map", in: folder)
    _ = try save("untitled map\n", to: url)
    return url
  }

  /// A new visible map for `text` (a conflict copy), named after its title.
  func create(_ text: String, in folder: URL) throws -> URL {
    let url = MapFiles.availableURL(
      title: MapDocument.title(of: text) ?? "untitled map", in: folder)
    _ = try save(text, to: url)
    return url
  }

  /// The texts of iCloud's unresolved conflict versions of `url` (other devices' saves that
  /// collided with this one). Each is marked resolved and removed once read; the caller keeps
  /// the texts as conflict copies, so none is lost.
  func takeConflictVersions(of url: URL) throws -> [OtherVersion] {
    guard let versions = NSFileVersion.unresolvedConflictVersionsOfItem(at: url),
      !versions.isEmpty
    else { return [] }
    let texts = try versions.map { version in
      OtherVersion(
        text: try reading(version.url) { try String(contentsOf: $0, encoding: .utf8) },
        device: version.localizedNameOfSavingComputer ?? "another device",
        date: version.modificationDate ?? Date())
    }
    try writing(url) { url in
      for version in versions { version.isResolved = true }
      try NSFileVersion.removeOtherVersionsOfItem(at: url)
    }
    return texts
  }

  func rename(_ url: URL, title: String) throws -> URL {
    let target = MapFiles.availableURL(
      title: title, in: url.deletingLastPathComponent(), excluding: url)
    if target != url {
      try move(url, to: target)
      #if os(macOS)
        // Reminders sync is Mac-only: the iPad never reads, writes or moves its sidecars.
        do { try ReminderSidecar.move(from: url, to: target) } catch {
          log.error("reminders sidecar rename failed")
          // Keep actor-owned document identity valid when the sidecar cannot follow the map.
          do { try move(target, to: url) } catch {
            // A failed rollback must still leave autosave targeting the map that exists.
            for (id, documentURL) in documents where documentURL == url { documents[id] = target }
            throw error
          }
          throw error
        }
      #endif
      // The layout sidecar follows its map; losing it only costs the remembered layout.
      do {
        let (from, to) = (LayoutSidecar.url(for: url), LayoutSidecar.url(for: target))
        if FileManager.default.fileExists(atPath: from.path) { try move(from, to: to) }
      } catch {
        log.error("layout sidecar rename failed: \(error, privacy: .public)")
      }
    }
    return target
  }

  /// A coordinated move, so other devices and presenters see a rename rather than a delete.
  private func move(_ url: URL, to target: URL) throws {
    var failure: NSError?
    var moveError: Error?
    let coordinator = coordinator()
    coordinator.coordinate(
      writingItemAt: url, options: .forMoving, writingItemAt: target, options: .forReplacing,
      error: &failure
    ) { from, to in
      coordinator.item(at: from, willMoveTo: to)
      do {
        try FileManager.default.moveItem(at: from, to: to)
        coordinator.item(at: from, didMoveTo: to)
      } catch { moveError = error }
    }
    if let failure { throw failure }
    if let moveError { throw moveError }
  }
}

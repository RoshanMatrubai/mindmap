import Foundation

/// Data rule: maps never live in a code project. Used to refuse a maps folder near a git work tree.
public enum GitGuard {
  /// The git work tree above `folder`, or inside it when `scanDescendants` is enabled.
  /// Launch checks only parents, without inspecting the saved folder itself.
  /// Folder-picker checks include the folder and its descendants, and run off the main thread.
  public static func workTree(around folder: URL, scanDescendants: Bool = true) -> URL? {
    let fm = FileManager.default
    let folder = folder.standardizedFileURL
    var dir = scanDescendants ? folder.path : folder.deletingLastPathComponent().path
    while true {
      if fm.fileExists(atPath: (dir as NSString).appendingPathComponent(".git")) {
        return URL(fileURLWithPath: dir)
      }
      let parent = (dir as NSString).deletingLastPathComponent
      if parent == dir { break }
      dir = parent
    }
    guard scanDescendants else { return nil }
    let walker = fm.enumerator(
      at: folder, includingPropertiesForKeys: nil, options: .skipsPackageDescendants)
    while let url = walker?.nextObject() as? URL {
      if url.lastPathComponent == ".git" { return url.deletingLastPathComponent() }
    }
    return nil
  }
}

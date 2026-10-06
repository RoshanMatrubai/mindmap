import Foundation
import Testing

@testable import MindmapCore

struct MapFilesTests {
  @Test func titleFileNamesAndCollisions() throws {
    let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let first = MapFiles.availableURL(title: "A/B: Plan", in: folder)
    #expect(first.lastPathComponent == "AB Plan.mindmap")
    try "A/B: Plan\n".write(to: first, atomically: true, encoding: .utf8)
    let second = MapFiles.availableURL(title: "A/B: Plan", in: folder)
    #expect(second.lastPathComponent == "AB Plan 2.mindmap")
    try "other".write(to: second, atomically: true, encoding: .utf8)
    #expect(
      MapFiles.availableURL(title: "A/B: Plan", in: folder).lastPathComponent == "AB Plan 3.mindmap"
    )
    #expect(MapFiles.availableURL(title: "A/B: Plan", in: folder, excluding: first) == first)
    #expect(
      MapFiles.availableURL(title: " /: ", in: folder).lastPathComponent == "untitled map.mindmap")
  }

  @Test func listsMapsByTitleAndModificationDate() throws {
    let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    for (name, text, date) in [
      ("old.mindmap", "\nOld title\n- A", 1.0), ("new.mindmap", "New title\n", 2.0),
      ("ignore.txt", "ignored", 3.0),
    ] {
      let url = folder.appending(path: name)
      try text.write(to: url, atomically: true, encoding: .utf8)
      try FileManager.default.setAttributes(
        [.modificationDate: Date(timeIntervalSince1970: date)], ofItemAtPath: url.path)
    }
    let maps = try MapFiles.list(in: folder)
    #expect(maps.map(\.title) == ["New title", "Old title"])
    #expect(maps.map(\.url.lastPathComponent) == ["new.mindmap", "old.mindmap"])
  }

  @Test func listsMapsICloudHasNotDownloaded() throws {
    let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    try "Real\n".write(
      to: folder.appending(path: "real.mindmap"), atomically: true, encoding: .utf8)
    // iPadOS placeholders: hidden `.<name>.icloud` files, here for a map and for a sidecar.
    for name in [".ghost.mindmap.icloud", "..real.mindmap.layout.json.icloud"] {
      try "plist".write(to: folder.appending(path: name), atomically: true, encoding: .utf8)
    }
    let maps = try MapFiles.list(in: folder)
    #expect(Set(maps.map(\.title)) == ["Real", "ghost"])
    let ghost = try #require(maps.first { $0.title == "ghost" })
    #expect(!ghost.isDownloaded && ghost.url.lastPathComponent == "ghost.mindmap")
    #expect(!MapFiles.isDownloaded(ghost.url))
    #expect(MapFiles.isDownloaded(folder.appending(path: "real.mindmap")))
  }
}

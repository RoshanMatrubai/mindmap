import Foundation
import MindmapCore
import Testing

@Test func diskChangeWithoutEditsReloads() {
  #expect(MapSync.decide(saved: "a\n", open: "a\n", disk: "b\n") == .reload)
}

@Test func ownSaveOrUnchangedDiskDoesNothing() {
  #expect(MapSync.decide(saved: "a\n", open: "b\n", disk: "b\n") == .none)
  #expect(MapSync.decide(saved: "a\n", open: "b\n", disk: "a\n") == .none)
  #expect(MapSync.decide(saved: "a\n", open: "a\n", disk: "a\n") == .none)
}

@Test func diskChangeWithUnsavedEditsKeepsOpenAndCopiesDisk() {
  #expect(MapSync.decide(saved: "a\n", open: "b\n", disk: "c\n") == .keepOpenAndCopyDisk)
}

@Test func conflictTitleNamesDeviceAndTime() {
  let date = Date(timeIntervalSince1970: 1_791_000_000)  // 2026-10-03 04:00 UTC
  let utc = TimeZone(identifier: "UTC")!
  #expect(
    MapSync.conflictTitle("garden", device: "Roshan's iPad", date: date, timeZone: utc)
      == "garden (conflict Roshan's iPad 2026-10-03 04.00)")
  #expect(
    MapSync.conflictTitle("a", device: "Mac: 2/3", date: date, timeZone: utc)
      == "a (conflict Mac 23 2026-10-03 04.00)")
}

@Test func conflictCopyRenamesOnlyTheTitleLine() {
  let date = Date(timeIntervalSince1970: 1_791_000_000)
  let utc = TimeZone(identifier: "UTC")!
  let text = "\n  sample map  \r\ngarden\n- water\n"
  #expect(
    MapSync.conflictCopy(of: text, device: "iPad", date: date, timeZone: utc)
      == "\nsample map (conflict iPad 2026-10-03 04.00)\r\ngarden\n- water\n")
  #expect(
    MapSync.conflictCopy(of: "", device: "iPad", date: date, timeZone: utc)
      == "untitled map (conflict iPad 2026-10-03 04.00)\n")
  #expect(
    MapSync.conflictCopy(of: "solo", device: "iPad", date: date, timeZone: utc)
      == "solo (conflict iPad 2026-10-03 04.00)")
}

@Test func placeholdersNameTheirMap() {
  #expect(MapSync.placeholderTarget(".garden.mindmap.icloud") == "garden.mindmap")
  #expect(MapSync.placeholderTarget(".garden.mindmap.layout.json.icloud") == nil)
  #expect(MapSync.placeholderTarget("garden.mindmap") == nil)
  #expect(MapSync.placeholderTarget("..mindmap.icloud") == nil)
}

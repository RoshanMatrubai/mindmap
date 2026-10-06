import Foundation
import MindmapCore
import Testing

private func edited(
  _ text: String, at cursor: Int, key: EditingKey, length: Int = 0
) throws -> (String, NSRange) {
  let change = try #require(
    OutlineEditing.change(
      text: text, selection: NSRange(location: cursor, length: length), key: key))
  return (
    (text as NSString).replacingCharacters(in: change.range, with: change.replacement),
    change.selection
  )
}

@Test func enterContinuesBulletAtItsIndent() throws {
  let (text, selection) = try edited("title\n\t- task", at: 13, key: .enter)
  #expect(text == "title\n\t- task\n\t- ")
  #expect(selection == NSRange(location: 17, length: 0))
}

@Test(arguments: ["[x]", "[X]", "[ ]"])
func enterDoesNotContinueCheckmark(marker: String) throws {
  let text = "- \(marker) task"
  let (result, _) = try edited(text, at: (text as NSString).length, key: .enter)
  #expect(result == "\(text)\n- ")
}

@Test func enterSplitsBulletAtCursorAndReplacesSelection() throws {
  let (split, selection) = try edited("- first second", at: 8, key: .enter)
  #expect(split == "- first \n- second")
  #expect(selection == NSRange(location: 11, length: 0))
  let (replaced, _) = try edited("- abcdef", at: 4, key: .enter, length: 2)
  #expect(replaced == "- ab\n- ef")
}

@Test func emptyBulletOutdentsBeforeRemovingMarker() throws {
  let (outdented, selection) = try edited("title\n\t\t- ", at: 10, key: .enter)
  #expect(outdented == "title\n\t- ")
  #expect(selection == NSRange(location: 9, length: 0))
  let (removed, cursor) = try edited("title\n- \nnext", at: 8, key: .enter)
  #expect(removed == "title\n\nnext")
  #expect(cursor == NSRange(location: 6, length: 0))
}

@Test func emptyCheckmarkAndWhitespaceBulletAreEmpty() throws {
  #expect(try edited("\t- [x]  ", at: 8, key: .enter).0 == "- [x]  ")
  #expect(try edited("-   ", at: 4, key: .enter).0 == "")
}

@Test func enterOnGroupIsLeftToNativeEditor() {
  #expect(
    OutlineEditing.change(text: "group", selection: NSRange(location: 5, length: 0), key: .enter)
      == nil)
}

@Test func tabIndentsAnywhereInBulletAndMovesCursor() throws {
  let (result, selection) = try edited("group\n- abc", at: 9, key: .tab)
  #expect(result == "group\n\t- abc")
  #expect(selection == NSRange(location: 10, length: 0))
  let (back, cursor) = try edited(result, at: selection.location, key: .backtab)
  #expect(back == "group\n- abc")
  #expect(cursor == NSRange(location: 9, length: 0))
}

@Test func backtabAtZeroDoesNotRemoveBullet() throws {
  let change = OutlineEditing.change(
    text: "- task", selection: NSRange(location: 3, length: 0), key: .backtab)
  #expect(change == nil)
}

@Test func tabOnGroupDoesNotMakeItBullet() {
  #expect(
    OutlineEditing.change(text: "group", selection: NSRange(location: 2, length: 0), key: .tab)
      == nil)
}

@Test func multilineIndentChangesAllAndOnlySelectedBulletLines() throws {
  let text = "- first\ngroup\n\t- second\n- third"
  let (indented, selection) = try edited(text, at: 0, key: .tab, length: 23)
  #expect(indented == "\t- first\ngroup\n\t\t- second\n- third")
  #expect(selection == NSRange(location: 1, length: 24))
  let (outdented, _) = try edited(indented, at: 0, key: .backtab, length: 25)
  #expect(outdented == text)
}

@Test func selectionEndingAtNextLineStartExcludesThatLine() throws {
  let (result, _) = try edited("- a\n- b\n- c", at: 0, key: .tab, length: 4)
  #expect(result == "\t- a\n- b\n- c")
}

@Test func selectionInsideMultipleLinesPreservesSelectedText() throws {
  let (result, selection) = try edited("- abc\n- def", at: 3, key: .tab, length: 6)
  #expect(result == "\t- abc\n\t- def")
  #expect(selection == NSRange(location: 4, length: 7))
}

@Test func starBulletsContinueAsDashesAtEffectiveDepth() throws {
  #expect(try edited("* first", at: 7, key: .enter).0 == "* first\n- ")
  #expect(try edited("** second", at: 9, key: .enter).0 == "** second\n\t- ")
  #expect(try edited("\t*** third", at: 10, key: .enter).0 == "\t*** third\n\t\t\t- ")
  #expect(try edited("** ", at: 3, key: .backtab).0 == "* ")
  #expect(try edited("** ", at: 3, key: .enter).0 == "* ")
}

@Test func spaceIndentationCanOutdentAndContinue() throws {
  #expect(try edited("  - task", at: 8, key: .backtab).0 == "- task")
  #expect(try edited("    - task", at: 10, key: .backtab).0 == "- task")
  #expect(try edited("  - task", at: 8, key: .enter).0 == "  - task\n  - ")
}

@Test func editsPreserveCRLFAndUseUTF16Offsets() throws {
  let (result, selection) = try edited("title\r\n- 🐈", at: 11, key: .enter)
  #expect(result == "title\r\n- 🐈\r\n- ")
  #expect(selection == NSRange(location: 15, length: 0))
  #expect(try edited("- café\r\n- 猫", at: 0, key: .tab, length: 11).0 == "\t- café\r\n\t- 猫")
}

@Test func pasteNormalizesTwoAndFourSpaceIndentation() {
  #expect(
    OutlineEditing.normalizedPaste("title\n  - one\n    - two") == "title\n\t- one\n\t\t- two")
  #expect(
    OutlineEditing.normalizedPaste("title\n    - one\n        - two") == "title\n\t- one\n\t\t- two"
  )
  #expect(OutlineEditing.normalizedPaste("  - one\r\n    - two\r\n") == "\t- one\r\n\t\t- two\r\n")
  #expect(
    OutlineEditing.normalizedPaste("- keep  internal spaces\n\t- tabs")
      == "- keep  internal spaces\n\t- tabs")
  #expect(OutlineEditing.normalizedPaste("   odd\n      spacing") == "   odd\n      spacing")
}

@Test func invalidSelectionsAreRejected() {
  #expect(
    OutlineEditing.change(text: "- a", selection: NSRange(location: 5, length: 0), key: .tab) == nil
  )
  #expect(
    OutlineEditing.change(text: "- a", selection: NSRange(location: 2, length: 9), key: .tab) == nil
  )
}

@Test func blankFinalParagraphDoesNotContinuePreviousBullet() {
  let selection = NSRange(location: 4, length: 0)
  #expect(OutlineEditing.change(text: "- a\n", selection: selection, key: .enter) == nil)
  #expect(OutlineEditing.change(text: "- a\n", selection: selection, key: .tab) == nil)
}

@Test func backtabSelectionLeavesRootBulletsAndGroupsAlone() throws {
  let (result, selection) = try edited(
    "- a\ngroup\n\t- b\n\t\t- c", at: 0, key: .backtab, length: 20)
  #expect(result == "- a\ngroup\n- b\n\t- c")
  #expect(selection == NSRange(location: 0, length: 18))
}

@Test func markdownAndHyphenatedWordsAreNotBullets() {
  #expect(
    OutlineEditing.change(text: "**bold", selection: NSRange(location: 6, length: 0), key: .enter)
      == nil)
  #expect(
    OutlineEditing.change(text: "-word", selection: NSRange(location: 5, length: 0), key: .tab)
      == nil)
}

private func applied(_ text: String, _ change: TextChange?) throws -> (String, NSRange) {
  let change = try #require(change)
  return (
    (text as NSString).replacingCharacters(in: change.range, with: change.replacement),
    change.selection
  )
}

@Test func toggleDoneMarksOpenAndPlainBulletsDone() throws {
  let (text, selection) = try applied(
    "g\n- a\n- [ ] b",
    OutlineEditing.toggleDone(text: "g\n- a\n- [ ] b", selection: .init(location: 5, length: 0)))
  #expect(text == "g\n- [x] a\n- [ ] b")
  #expect(selection == NSRange(location: 9, length: 0))
  let both = "g\n- a\n- [ ] b"
  #expect(
    try applied(
      both, OutlineEditing.toggleDone(text: both, selection: .init(location: 2, length: 11))
    ).0
      == "g\n- [x] a\n- [x] b")
}

@Test func toggleDoneClearsWhenAllDoneAndChecksWhenMixed() throws {
  let done = "- [x] a\n\t- [X] b"
  #expect(
    try applied(
      done, OutlineEditing.toggleDone(text: done, selection: .init(location: 0, length: 16))
    ).0
      == "- a\n\t- b")
  let mixed = "- [x] a\n- b"
  #expect(
    try applied(
      mixed, OutlineEditing.toggleDone(text: mixed, selection: .init(location: 0, length: 11))
    ).0
      == "- [x] a\n- [x] b")
  #expect(
    try applied(
      "- [x]", OutlineEditing.toggleDone(text: "- [x]", selection: .init(location: 5, length: 0))
    ).0
      == "- ")
}

@Test func toggleDoneIgnoresGroupsAndKeepsCursorOnText() throws {
  #expect(OutlineEditing.toggleDone(text: "group", selection: .init(location: 2, length: 0)) == nil)
  let (_, selection) = try applied(
    "- [x] task",
    OutlineEditing.toggleDone(text: "- [x] task", selection: .init(location: 8, length: 0)))
  #expect(selection == NSRange(location: 4, length: 0))
}

@Test func moveBlockSwapsSiblingsWithTheirSubtasks() throws {
  let text = "g\n- a\n\t- a1\n- b\n\t- b1\n\t\t- b2\n- c"
  let cursor = (text as NSString).range(of: "- b").location + 2
  let (up, upSelection) = try applied(
    text,
    OutlineEditing.moveBlock(text: text, selection: .init(location: cursor, length: 0), up: true))
  #expect(up == "g\n- b\n\t- b1\n\t\t- b2\n- a\n\t- a1\n- c")
  #expect(upSelection == NSRange(location: 4, length: 0))
  let (down, downSelection) = try applied(
    text,
    OutlineEditing.moveBlock(text: text, selection: .init(location: cursor, length: 0), up: false))
  #expect(down == "g\n- a\n\t- a1\n- c\n- b\n\t- b1\n\t\t- b2")
  #expect((down as NSString).substring(from: downSelection.location).hasPrefix("b\n\t- b1"))
}

@Test func moveBlockStaysUnderItsParent() {
  let text = "g\n- a\n\t- a1\n- b\nh\n- c"
  func move(_ needle: String, up: Bool) -> TextChange? {
    let at = (text as NSString).range(of: needle).location
    return OutlineEditing.moveBlock(text: text, selection: .init(location: at, length: 0), up: up)
  }
  #expect(move("- a", up: true) == nil)  // first in its group
  #expect(move("\t- a1", up: true) == nil)  // only child
  #expect(move("\t- a1", up: false) == nil)
  #expect(move("- b", up: false) == nil)  // next line is a group
  #expect(move("h", up: true) == nil)  // groups don't move
}

@Test func moveBlockKeepsCRLF() throws {
  let text = "- a\r\n- b"
  #expect(
    try applied(
      text, OutlineEditing.moveBlock(text: text, selection: .init(location: 6, length: 0), up: true)
    ).0
      == "- b\r\n- a")
}

@Test func insertLinkPutsTheCursorInsideEmptyBrackets() throws {
  let change = try #require(
    OutlineEditing.insertLink(text: "- task ", selection: NSRange(location: 7, length: 0)))
  #expect(change.replacement == "[]")
  #expect(change.range == NSRange(location: 7, length: 0))
  #expect(change.selection == NSRange(location: 8, length: 0))
}

@Test func insertLinkWrapsTheSelectedName() throws {
  let change = try #require(
    OutlineEditing.insertLink(text: "- see garden", selection: NSRange(location: 6, length: 6)))
  #expect(change.replacement == "[garden]")
  #expect(change.selection == NSRange(location: 7, length: 6))
}

@Test func insertLinkRefusesASelectionAcrossLines() {
  #expect(
    OutlineEditing.insertLink(text: "- a\n- b", selection: NSRange(location: 2, length: 4)) == nil)
}

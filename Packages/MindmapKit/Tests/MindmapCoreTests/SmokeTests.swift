import Foundation
import MindmapCore
import Testing

let fixtureURL = URL(fileURLWithPath: #filePath)
  .deletingLastPathComponent().deletingLastPathComponent()
  .appendingPathComponent("Fixtures/sample.mindmap")

@Test func titleIsFirstNonEmptyLine() {
  #expect(MapDocument.title(of: "\n  \n  my week \nhome\n- dishes") == "my week")
  #expect(MapDocument(text: "a\nb").title == "a")
}

@Test func blankTextHasNoTitle() {
  #expect(MapDocument.title(of: "") == nil)
  #expect(MapDocument.title(of: " \n\t\n") == nil)
}

@Test func fixtureLoadsWithTitle() throws {
  let text = try String(contentsOf: fixtureURL, encoding: .utf8)
  #expect(MapDocument(text: text).title == "sample map")
}

/// Guards the fixture's shape (docs/roadmap.md step 0), so later perf and layout work has a stable input.
@Test func fixtureHasPrototypeShape() throws {
  let text = try String(contentsOf: fixtureURL, encoding: .utf8)
  let lines = text.split(whereSeparator: \.isNewline).filter {
    !$0.trimmingCharacters(in: .whitespaces).isEmpty
  }.dropFirst()  // title
  let groups = lines.filter { !$0.hasPrefix("-") && !$0.hasPrefix("\t") }
  let deepest = lines.map { $0.prefix(while: { $0 == "\t" }).count }.max() ?? 0
  let model = MapParser.parse(text: text, today: Date(), calendar: .current)
  let links = model.nodes.flatMap(\.linkNames).count
  #expect(groups.count == 18)
  #expect(lines.count == 140)
  #expect(links == 14)
  #expect(deepest == 2)
}

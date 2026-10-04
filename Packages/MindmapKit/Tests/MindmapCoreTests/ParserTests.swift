import Foundation
import Testing

@testable import MindmapCore

private var fixedCalendar: Calendar {
  var calendar = Calendar(identifier: .gregorian)
  calendar.timeZone = TimeZone(secondsFromGMT: 0)!
  return calendar
}

private var fixedToday: Date {
  fixedCalendar.date(from: DateComponents(year: 2026, month: 10, day: 2, hour: 15))!
}

private func parseFixture(_ text: String) -> MapModel {
  MapParser.parse(text: text, today: fixedToday, calendar: fixedCalendar)
}

@Test func titleAndHierarchy() {
  let model = parseFixture(
    "\n My Map \n\nhome\n- task\n\t- child\n\t\t- grandchild\n- sibling\n  school\n- homework")
  #expect(model.title == "My Map")
  #expect(
    model.nodes.map(\.name) == [
      "home", "task", "child", "grandchild", "sibling", "school", "homework",
    ])
  #expect(model.nodes.map(\.depth) == [0, 1, 2, 3, 1, 0, 1])
  #expect(model.nodes.map(\.parent) == [nil, 0, 1, 2, 0, nil, 5])
  #expect(model.nodes[0].children == [1, 4])
  #expect(model.nodes[1].children == [2])
  #expect(model.nodes.map(\.id) == Array(0..<7))
  #expect(model.groupCount == 2)
  #expect(model.nodeCount == 7)
  #expect(model.statsText == "2 groups · 7 nodes · 0 links")
}

@Test func clampedIndentAndLooseGroup() {
  let model = parseFixture("Map\n\t\t- first\n\t\t\t\t- child\n- second\nhome\n- third")
  #expect(model.nodes.map(\.name) == ["loose", "first", "child", "second", "home", "third"])
  #expect(model.nodes.map(\.depth) == [0, 1, 2, 1, 0, 1])
  #expect(model.nodes[0].children == [1, 3])
  #expect(model.warnings.count == 2)
}

@Test(arguments: ["high", "medium", "med", "low", "chill"])
func priorityWords(_ word: String) {
  let node = parseFixture("Map\ngroup\n- Task /\(word.uppercased())").nodes[1]
  #expect(node.name == "Task")
  #expect(node.priority?.rawValue == (word == "med" ? "medium" : word))
}

@Test(arguments: [
  ("today", 0), ("tomorrow", 1), ("tmrw", 1), ("friday", 0), ("saturday", 1), ("sunday", 2),
  ("monday", 3), ("tuesday", 4), ("wednesday", 5), ("thursday", 6),
])
func dueWords(_ value: (String, Int)) {
  let (word, offset) = value
  let node = parseFixture("Map\ngroup\n- Task /\(word.uppercased())").nodes[1]
  #expect(node.name == "Task")
  #expect(node.due?.rawToken == "/\(word.uppercased())")
  #expect(
    node.due?.day
      == fixedCalendar.date(
        byAdding: .day, value: offset, to: fixedCalendar.startOfDay(for: fixedToday)))
}

@Test(arguments: [1, 2, 3, 4, 5, 6, 7])
func weekdayIncludesToday(_ weekday: Int) {
  let words = ["sunday", "monday", "tuesday", "wednesday", "thursday", "friday", "saturday"]
  let date = fixedCalendar.date(byAdding: .day, value: weekday - 6, to: fixedToday)!
  let model = MapParser.parse(
    text: "Map\ngroup\n- Task /\(words[weekday - 1])", today: date, calendar: fixedCalendar)
  #expect(model.nodes[1].due?.day == fixedCalendar.startOfDay(for: date))
}

@Test func unknownMetadataAndTokenBoundaries() {
  let model = parseFixture(
    "Map\ngroup\n- and/or /foo /higher x/high /highway /todayish\n- /high Task /tmrw\n- /high\n- [[missing]]\n- [ ] \n- /foo"
  )
  #expect(
    model.nodes.map(\.name) == [
      "group", "and/or /foo /higher x/high /highway /todayish", "Task", "/foo",
    ])
  #expect(model.nodes[1].due == nil)
  #expect(model.nodes[1].priority == nil)
  #expect(model.nodes[2].priority == .high)
  #expect(model.nodes[2].due?.rawToken == "/tmrw")
}

@Test func linksResolveInSameGroupThenDocumentOrder() {
  let model = parseFixture(
    "Map\none\n- Target\n- Target\ntwo\n- target\n- Source [[ TARGET ]] [[absent]]\nthree\n- Other [[target]]"
  )
  #expect(model.nodes[5].linkNames == [" TARGET ", "absent"])
  #expect(model.resolvedLinks.map(\.target) == [4, 1])
  #expect(model.resolvedLinks.map(\.source) == [5, 7])
  #expect(model.unresolvedLinks.count == 1)
  #expect(model.unresolvedLinks[0].name == "absent")
  #expect(model.linkCount == 2)
  #expect(model.statsText.contains("1 unresolved"))
}

@Test func selfLinksAreIgnoredAndDuplicatesCanLink() {
  let onlySelf = parseFixture("Map\ngroup\n- Me [[me]]")
  #expect(onlySelf.resolvedLinks.isEmpty)
  #expect(onlySelf.unresolvedLinks.isEmpty)
  let duplicates = parseFixture("Map\ngroup\n- Me [[me]]\n- Me")
  #expect(duplicates.resolvedLinks.first?.target == 2)
}

@Test func singleAndDoubleBracketLinks() {
  let model = parseFixture("Map\ng\n- a [b] and [[c]]\nb\nc")
  #expect(model.nodes[1].name == "a  and")
  #expect(model.nodes[1].linkNames == ["b", "c"])
  #expect(model.resolvedLinks.map(\.target) == [2, 3])
}

@Test func doneMarkersAreNotLinks() {
  let model = parseFixture("Map\ng\n- [x] task [e]\n- [ ] open\n- [X] shout\ne")
  #expect(model.nodes.map(\.name) == ["g", "task", "open", "shout", "e"])
  #expect(model.nodes.map(\.done) == [false, true, false, true, false])
  #expect(model.nodes[1].linkNames == ["e"])
  #expect(model.resolvedLinks.map(\.target) == [4])
  #expect(model.unresolvedLinks.isEmpty)
  let tokens = MapParser.metadataTokens(in: "- [x] task [e]").map(\.kind)
  #expect(tokens == [.bullet, .doneMarker, .link])
}

@Test func linkToNodeNamedX() {
  // Only right after the bullet is `[x]` the done marker; anywhere else it links to "x".
  let model = parseFixture("Map\ng\n- task [x]\n- [x] done [x]\n- [x]glued\nx")
  #expect(model.nodes.map(\.name) == ["g", "task", "done", "glued", "x"])
  #expect(model.nodes.map(\.done) == [false, false, true, false, false])
  #expect(model.resolvedLinks.map(\.source) == [1, 2, 3])
  #expect(model.resolvedLinks.allSatisfy { $0.target == 4 })
}

@Test func emptyAndUnbalancedBracketsStayText() {
  let model = parseFixture("Map\ng\n- a [] b\n- c [ ] d\n- open [e\n- close e]\n- [[f]\n- g [h [i]")
  #expect(
    model.nodes.map(\.name) == ["g", "a [] b", "c [ ] d", "open [e", "close e]", "[", "g [h"])
  #expect(model.nodes.flatMap(\.linkNames) == ["f", "i"])
}

@Test func bracketsInOrdinaryTextBecomeLinks() {
  let model = parseFixture("Map\ng\n- read chapter [3]")
  #expect(model.nodes[1].name == "read chapter")
  #expect(model.unresolvedLinks.map(\.name) == ["3"])
}

@Test func doneMarkersAndPasteBullets() {
  let model = parseFixture(
    "Map\ngroup\n- [x] Done\n- [X] Also Done\n- [ ] Open\n* Star\n** Child\n*** Grandchild")
  #expect(
    model.nodes.map(\.name) == [
      "group", "Done", "Also Done", "Open", "Star", "Child", "Grandchild",
    ])
  #expect(model.nodes.map(\.done) == [false, true, true, false, false, false, false])
  #expect(model.nodes.suffix(3).map(\.depth) == [1, 2, 3])
}

@Test(arguments: [2, 4]) func leadingSpaceUnits(_ unit: Int) {
  let indent = String(repeating: " ", count: unit)
  let model = parseFixture("Map\ngroup\n- Task\n\(indent)- Child\n\(indent)\(indent)- Grandchild")
  #expect(model.nodes.map(\.depth) == [0, 1, 2, 3])
}

@Test func emptyAndTitleOnlyDocuments() {
  #expect(parseFixture("").title == "")
  #expect(parseFixture(" \n\t\n").nodes.isEmpty)
  let titleOnly = parseFixture("\nTitle\n\n")
  #expect(titleOnly.title == "Title")
  #expect(titleOnly.nodes.isEmpty)
}

@Test func crlfUnicodeCaseAndSourceRanges() {
  let text = "My MAP\r\n\r\n家🏡\r\n- Café 🧑🏽‍💻 [[不明]]\r\n"
  let model = parseFixture(text)
  #expect(model.title == "My MAP")
  #expect(model.nodes.map(\.name) == ["家🏡", "Café 🧑🏽‍💻"])
  #expect(model.nodes.map(\.sourceLineIndex) == [2, 3])
  let source = text as NSString
  #expect(source.substring(with: model.nodes[0].sourceRange) == "家🏡")
  #expect(source.substring(with: model.nodes[1].sourceRange) == "- Café 🧑🏽‍💻 [[不明]]")
  #expect(source.substring(with: model.unresolvedLinks[0].sourceRange) == "[[不明]]")
  #expect(model.nodes[1].pathKey == "家🏡/café 🧑🏽‍💻")
}

@Test func duplicatePathKeys() {
  let model = parseFixture("Map\nGroup\n- Task\n\t- Child\n- TASK\n\t- Child\nGroup\n- Task")
  #expect(
    model.nodes.map(\.pathKey) == [
      "group", "group/task", "group/task/child", "group/task#2", "group/task#2/child", "group#2",
      "group#2/task",
    ])
  #expect(Set(model.nodes.map(\.pathKey)).count == model.nodes.count)
}

@Test func metadataTokensUseUTF16Ranges() {
  let line = "\t- [X] 🏡 Task /MED /Friday [[Elsewhere]] /foo"
  let tokens = MapParser.metadataTokens(in: line)
  let values = tokens.map { (line as NSString).substring(with: $0.range) }
  #expect(values == ["-", "[X]", "/MED", "/Friday", "[[Elsewhere]]"])
  #expect(MapParser.isDone(line: line))
}

@Test func parserPerformance500Nodes() {
  let text =
    "Benchmark\nGroup\n"
    + (0..<499).map { "- Task \($0) /friday /high [[Task \(($0 + 1) % 499)]]" }.joined(
      separator: "\n")
  _ = parseFixture(text)
  let clock = ContinuousClock()
  let start = clock.now
  var total = 0
  for _ in 0..<20 { total += parseFixture(text).nodeCount }
  let elapsed = start.duration(to: clock.now)
  let parts = elapsed.components
  let milliseconds = (Double(parts.seconds) * 1_000 + Double(parts.attoseconds) / 1e15) / 20
  print(
    "Parser 500 nodes: \(String(format: "%.3f", milliseconds)) ms per parse (20 runs, measured, debug)"
  )
  #expect(total == 10_000)
}

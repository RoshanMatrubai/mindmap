import Foundation
import MindmapCore
import Testing

private let day = Date(timeIntervalSince1970: 1_790_985_600)  // a Saturday, UTC
private var calendar: Calendar {
  var calendar = Calendar(identifier: .gregorian)
  calendar.timeZone = TimeZone(secondsFromGMT: 0)!
  return calendar
}
private func parse(_ text: String) -> MapModel {
  MapParser.parse(text: text, today: day, calendar: calendar)
}
private func index(_ model: MapModel, _ name: String) -> Int {
  model.nodes.firstIndex { $0.name == name }!
}
private func applied(_ text: String, _ change: TextChange?) throws -> (String, String) {
  let change = try #require(change)
  let result = (text as NSString).replacingCharacters(in: change.range, with: change.replacement)
  return (result, (result as NSString).substring(with: change.selection))
}

private let map = """
  t
  home
  - dishes /monday
  - room
  \t- vacuum /high
  \t- desk [[flash]]
  - trash
  school
  - calc /friday /medium
  study
  - flash
  """

// MARK: OutlineEditing for graph edits

@Test func insertSiblingGoesAfterTheWholeBranch() throws {
  let model = parse(map)
  let (text, selected) = try applied(
    map,
    OutlineEditing.insertSibling(text: map, model: model, after: index(model, "room"), name: "new"))
  #expect(text.contains("\t- desk [[flash]]\n- new\n- trash"))
  #expect(selected == "- new")
  let (nested, _) = try applied(
    map,
    OutlineEditing.insertSibling(text: map, model: model, after: index(model, "vacuum"), name: "x"))
  #expect(nested.contains("\t- vacuum /high\n\t- x\n\t- desk"))
  let (group, line) = try applied(
    map,
    OutlineEditing.insertSibling(text: map, model: model, after: index(model, "home"), name: "work")
  )
  #expect(group.contains("- trash\nwork\nschool"))
  #expect(line == "work")
  let (last, _) = try applied(
    map,
    OutlineEditing.insertSibling(text: map, model: model, after: index(model, "flash"), name: "z"))
  #expect(last.hasSuffix("- flash\n- z"))
}

@Test func appendChildIsTheLastChildAtTheRightIndent() throws {
  let model = parse(map)
  let (text, selected) = try applied(
    map, OutlineEditing.appendChild(text: map, model: model, to: index(model, "room"), name: "bed"))
  #expect(text.contains("\t- desk [[flash]]\n\t- bed\n- trash"))
  #expect(selected == "\t- bed")
  let (leaf, _) = try applied(
    map,
    OutlineEditing.appendChild(text: map, model: model, to: index(model, "vacuum"), name: "bags"))
  #expect(leaf.contains("\t- vacuum /high\n\t\t- bags\n\t- desk"))
  let (group, _) = try applied(
    map, OutlineEditing.appendChild(text: map, model: model, to: index(model, "home"), name: "mop"))
  #expect(group.contains("- trash\n- mop\nschool"))
  let spaces = "t\ng\n- a\n    - b\n"
  let (spaced, _) = try applied(
    spaces, OutlineEditing.appendChild(text: spaces, model: parse(spaces), to: 0, name: "c"))
  #expect(spaced == "t\ng\n- a\n    - b\n- c\n")
  let (deeper, _) = try applied(
    spaces, OutlineEditing.appendChild(text: spaces, model: parse(spaces), to: 1, name: "c"))
  #expect(deeper == "t\ng\n- a\n    - b\n    - c\n")
  #expect(OutlineEditing.appendChild(text: map, model: model, to: 1, name: "  \n ") == nil)
}

@Test func appendGroupAddsALineAtTheEndAndNeverATitle() throws {
  #expect(
    try applied("t\n- a\n", OutlineEditing.appendGroup(text: "t\n- a\n", name: "g")) == (
      "t\n- a\ng\n", "g"
    ))
  #expect(
    try applied("t\n- a", OutlineEditing.appendGroup(text: "t\n- a", name: "g")).0 == "t\n- a\ng\n")
  #expect(try applied("", OutlineEditing.appendGroup(text: "", name: "g")).0 == "untitled map\ng\n")
  #expect(
    try applied("\n", OutlineEditing.appendGroup(text: "\n", name: "g")).0 == "\nuntitled map\ng\n")
  let crlf = "t\r\n- a\r\n"
  #expect(
    try applied(crlf, OutlineEditing.appendGroup(text: crlf, name: "g")).0 == "t\r\n- a\r\ng\r\n")
}

@Test func renameKeepsMarkersDatesPrioritiesAndLinks() throws {
  let text = "t\ng\n\t- [x]  old name /monday more /high [[other]]\nother\n"
  let model = parse(text)
  let (result, selected) = try applied(
    text, OutlineEditing.rename(text: text, model: model, node: 1, to: " new name "))
  #expect(result == "t\ng\n\t- [x]  new name /monday /high [[other]]\nother\n")
  #expect(selected == "\t- [x]  new name /monday /high [[other]]")
  #expect(parse(result).nodes[1].done && parse(result).nodes[1].priority == .high)
  let (group, _) = try applied(
    text, OutlineEditing.rename(text: text, model: model, node: 0, to: "G2"))
  #expect(group.hasPrefix("t\nG2\n"))
  let loose = "t\n- a\n- b\n"
  let (named, line) = try applied(
    loose, OutlineEditing.rename(text: loose, model: parse(loose), node: 0, to: "inbox"))
  #expect(named == "t\ninbox\n- a\n- b\n")
  #expect(line == "inbox")
  #expect(OutlineEditing.rename(text: text, model: model, node: 1, to: "") == nil)
}

@Test func deleteBranchRemovesDescendantsAndOneLineEnding() throws {
  let model = parse(map)
  let (text, selected) = try applied(
    map, OutlineEditing.deleteBranch(text: map, model: model, node: index(model, "room")))
  #expect(text.contains("- dishes /monday\n- trash\nschool"))
  #expect(!text.contains("vacuum") && !text.contains("desk"))
  #expect(selected == "home")
  let (group, cursor) = try applied(
    map, OutlineEditing.deleteBranch(text: map, model: model, node: index(model, "school")))
  #expect(group.contains("- trash\nstudy"))
  #expect(cursor == "")
  let (last, _) = try applied(
    map, OutlineEditing.deleteBranch(text: map, model: model, node: index(model, "flash")))
  #expect(last.hasSuffix("- trash\nschool\n- calc /friday /medium\nstudy"))
  let crlf = "t\r\ng\r\n- a\r\n\t- b\r\n- c"
  let (windows, _) = try applied(
    crlf, OutlineEditing.deleteBranch(text: crlf, model: parse(crlf), node: 1))
  #expect(windows == "t\r\ng\r\n- c")
  let (end, _) = try applied(
    crlf, OutlineEditing.deleteBranch(text: crlf, model: parse(crlf), node: 3))
  #expect(end == "t\r\ng\r\n- a\r\n\t- b")
}

@Test func setPriorityWritesReplacesAndClearsTheTag() throws {
  let model = parse(map)
  let dishes = index(model, "dishes")
  #expect(
    try applied(map, OutlineEditing.setPriority(text: map, model: model, node: dishes, .high)).1
      == "- dishes /monday /high")
  let calc = index(model, "calc")
  #expect(
    try applied(map, OutlineEditing.setPriority(text: map, model: model, node: calc, .chill)).1
      == "- calc /friday /chill")
  #expect(
    try applied(map, OutlineEditing.setPriority(text: map, model: model, node: calc, nil)).1
      == "- calc /friday")
  #expect(OutlineEditing.setPriority(text: map, model: model, node: dishes, nil) == nil)
  #expect(OutlineEditing.setPriority(text: map, model: model, node: calc, .medium) == nil)
  let twice = "t\ng\n- a /med x /LOW"
  #expect(
    try applied(twice, OutlineEditing.setPriority(text: twice, model: parse(twice), node: 1, .low))
      .1 == "- a /low x")
  #expect(
    try applied(map, OutlineEditing.setPriority(text: map, model: model, node: 0, .high)).1
      == "home /high")
}

// MARK: Selection

@Test func highlightIsAncestorsSubtreeAndCrossLinkNeighbors() {
  let model = parse(map)
  let room = index(model, "room")
  let (nodes, linked) = Selection.highlight(model, of: room)
  #expect(nodes == Set([index(model, "home"), room, index(model, "vacuum"), index(model, "desk")]))
  #expect(linked == [index(model, "flash")])
  let study = Selection.highlight(model, of: index(model, "study"))
  #expect(study.nodes == Set([index(model, "study"), index(model, "flash")]))
  #expect(study.linked == [index(model, "desk")])
  #expect(Selection.highlight(model, of: 99).nodes.isEmpty)
}

@Test func arrowNavigationOrder() {
  let model = parse(map)
  let n = { index(model, $0) }
  #expect(Selection.neighbor(model, of: n("vacuum"), .parent) == n("room"))
  #expect(Selection.neighbor(model, of: n("room"), .parent) == n("home"))
  #expect(Selection.neighbor(model, of: n("home"), .parent) == nil)
  #expect(Selection.neighbor(model, of: n("home"), .firstChild) == n("dishes"))
  #expect(Selection.neighbor(model, of: n("room"), .firstChild) == n("vacuum"))
  #expect(Selection.neighbor(model, of: n("trash"), .firstChild) == nil)
  #expect(Selection.neighbor(model, of: n("room"), .previousSibling) == n("dishes"))
  #expect(Selection.neighbor(model, of: n("room"), .nextSibling) == n("trash"))
  #expect(Selection.neighbor(model, of: n("trash"), .nextSibling) == nil)
  #expect(Selection.neighbor(model, of: n("dishes"), .previousSibling) == nil)
  #expect(Selection.neighbor(model, of: n("school"), .previousSibling) == n("home"))
  #expect(Selection.neighbor(model, of: n("school"), .nextSibling) == n("study"))
  #expect(Selection.neighbor(model, of: n("study"), .nextSibling) == nil)
}

@Test func detailFieldsForGroupsAndTasks() throws {
  let text = """
    t
    home
    - [x] dishes /today /high
    - room /monday /high
    \t- vacuum /high /saturday
    \t- desk [[flash]]
    - trash /tuesday
    study
    - flash
    """
  let model = parse(text)
  let urgency = ForceLayout.urgency(model, today: day, calendar: calendar)
  let home = try #require(Selection.detail(model, urgency: urgency, of: index(model, "home")))
  #expect(home.name == "home" && home.path.isEmpty)
  // Leaves: dishes (done), vacuum, desk, trash. Open high: room and vacuum. Saturday is today.
  #expect(home.kind == .group(tasks: 4, nextDue: "saturday", highPriority: 2))
  #expect(home.linked.map(\.name) == ["flash"])
  #expect(home.urgencyPercent == Int((urgency[index(model, "home")] * 100).rounded()))
  let vacuum = try #require(Selection.detail(model, urgency: urgency, of: index(model, "vacuum")))
  #expect(vacuum.path == ["home", "room"])
  #expect(vacuum.kind == .task(due: "saturday", priority: .high, done: false, leaf: true))
  #expect(vacuum.urgencyPercent == 100)
  #expect(vacuum.linked.isEmpty)
  let room = try #require(Selection.detail(model, urgency: urgency, of: index(model, "room")))
  #expect(room.kind == .task(due: "monday", priority: .high, done: false, leaf: false))
  #expect(room.linked.map(\.index) == [index(model, "flash")])
  let dishes = try #require(Selection.detail(model, urgency: urgency, of: index(model, "dishes")))
  #expect(dishes.kind == .task(due: "today", priority: .high, done: true, leaf: true))
  #expect(dishes.urgencyPercent == 0)
  let empty = try #require(Selection.detail(model, urgency: urgency, of: index(model, "study")))
  #expect(empty.kind == .group(tasks: 1, nextDue: nil, highPriority: 0))
  #expect(Selection.detail(model, urgency: urgency, of: 42) == nil)
}

@Test func nodeAtLocationPrefersTheBulletOverTheLooseGroup() {
  let text = "t\n- a\n- b\ng\n- c"
  let model = parse(text)
  #expect(Selection.node(model, atLocation: 0) == nil)
  #expect(Selection.node(model, atLocation: 2) == 1)
  #expect(Selection.node(model, atLocation: 5) == 1)
  #expect(Selection.node(model, atLocation: 6) == 2)
  #expect(Selection.node(model, atLocation: 11) == 3)
  #expect(Selection.node(model, atLocation: (text as NSString).length) == 4)
}

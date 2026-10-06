#if DEBUG
  import MindmapCore
  import MindmapGraph
  import UIKit

  /// `-editor-smoke YES` on the iPad: drives every touch gesture through the graph view's DEBUG
  /// hooks (the same input methods the gesture recognizers call, never system touch injection)
  /// on a throwaway map, then restores the original map. Logs `smoke PASS:` / `smoke FAIL:` lines
  /// and a final `touch smoke complete: N checks, F failures` line (CI waits for it).
  @MainActor
  enum TouchSmoke {
    private static var failures = 0
    private static var checks = 0
    private static var started = false

    static func runIfRequested(_ store: PadMapStore) {
      guard UserDefaults.standard.bool(forKey: "editor-smoke"), !started else { return }
      started = true
      Task {
        await run(store)
        log.notice(
          "touch smoke complete: \(checks, privacy: .public) checks, \(failures, privacy: .public) failures"
        )
      }
    }

    static func check(_ passed: Bool, _ name: String) {
      checks += 1
      if !passed { failures += 1 }
      log.notice("smoke \(passed ? "PASS" : "FAIL", privacy: .public): \(name, privacy: .public)")
    }

    /// Bounded waits exist only in this opt-in harness, never in the app's motion loop.
    @discardableResult
    static func wait(
      _ name: String, seconds: Double = 15, until predicate: () -> Bool
    ) async -> Bool {
      let deadline = ContinuousClock.now.advanced(by: .seconds(seconds))
      while !predicate(), ContinuousClock.now < deadline {
        try? await Task.sleep(for: .milliseconds(20))
      }
      let passed = predicate()
      check(passed, name)
      return passed
    }

    @discardableResult
    static func frozen(_ store: PadMapStore, _ view: GraphView) async -> Bool {
      await wait("graph settles and display link stops") {
        !store.isSwitching && store.parsedText == store.text
          && view.scene.layout?.model == store.model && !view.isAnimating
          && view.displayedSimulation?.isFrozen == true && GraphView.debugLiveDisplayLinks == 0
      } && idle()
    }

    @discardableResult
    static func idle() -> Bool {
      let passed = GraphView.debugLiveDisplayLinks == 0 && GraphView.debugIdleFrames == 0
      check(
        passed,
        "display link invalidated after freeze (live \(GraphView.debugLiveDisplayLinks), idle frames \(GraphView.debugIdleFrames))"
      )
      return passed
    }

    static func cameraIdle(_ view: GraphView) async {
      await wait("camera animation finishes") { !view.scene.debugCameraAnimating }
    }

    static func pause(_ milliseconds: Int = 400) async {
      try? await Task.sleep(for: .milliseconds(milliseconds))
    }

    static func index(_ view: GraphView, _ name: String) -> Int? {
      view.scene.layout?.model.nodes.firstIndex { $0.name == name }
    }

    /// A view point that hits `index` (or empty canvas for nil), clear of the title and the zoom
    /// buttons.
    static func target(_ view: GraphView, _ index: Int?) -> CGPoint? {
      guard let layout = view.scene.layout else { return nil }
      let bounds = view.bounds
      guard let index else {
        for y in stride(from: 80.0, to: bounds.height - 30, by: 23) {
          for x in stride(from: 40.0, to: bounds.width - 40, by: 29) {
            let p = CGPoint(x: x, y: y)
            let w = view.scene.camera.toWorld(p)
            let clear = layout.nodes.allSatisfy { hypot($0.x - w.x, $0.y - w.y) > 120 }
            if clear && view.scene.node(at: p, radius: 40) == nil { return p }
          }
        }
        return nil
      }
      let n = layout.nodes[index]
      let p = view.scene.camera.toScreen(CGPoint(x: n.x, y: n.y))
      let inside = p.x > 20 && p.y > 60 && p.x < bounds.width - 20 && p.y < bounds.height - 20
      return inside && view.scene.node(at: p, radius: 22) == index ? p : nil
    }

    static func point(_ layout: GraphLayout, _ i: Int) -> LayoutPoint {
      LayoutPoint(x: layout.nodes[i].x, y: layout.nodes[i].y)
    }

    static func distance(_ a: LayoutPoint, _ b: CGPoint) -> Double {
      hypot(a.x - b.x, a.y - b.y)
    }

    static func near(_ a: Camera, _ b: Camera) -> Bool {
      abs(a.zoom - b.zoom) < 1e-6 * max(1, b.zoom)
        && hypot(a.offset.x - b.offset.x, a.offset.y - b.offset.y) < 1e-3
    }

    static func fitCamera(_ view: GraphView) -> Camera {
      Camera.fit(view.scene.layout?.bounds ?? .null, in: view.scene.size)
    }

    /// Every node outside the affected set kept its exact position.
    private static func fixedCheck(_ before: GraphLayout, view: GraphView, name: String) {
      guard let after = view.scene.layout else { return check(false, name) }
      var old: [String: LayoutPoint] = [:]
      for i in before.nodes.indices { old[before.model.nodes[i].pathKey] = point(before, i) }
      var fixed = 0
      var equal = true
      for i in after.nodes.indices where !view.affectedIndices.contains(i) {
        guard let was = old[after.model.nodes[i].pathKey] else { continue }
        fixed += 1
        equal = equal && was == point(after, i)
      }
      check(fixed > 0 && equal, "\(name), \(fixed) unaffected nodes move exactly zero")
    }

    static func titles(_ items: [GraphMenuItem]) -> [String] { items.map(\.title) }

    static func item(_ items: [GraphMenuItem], _ path: String...) -> GraphMenuItem? {
      var level = items
      var found: GraphMenuItem?
      for title in path {
        found = level.first { $0.title == title }
        level = found?.children ?? []
      }
      return found
    }

    /// Runs a menu action exactly as the system menu's item would.
    static func perform(_ items: [GraphMenuItem], _ path: String..., name: String) {
      var level = items
      var found: GraphMenuItem?
      for title in path {
        found = level.first { $0.title == title }
        level = found?.children ?? []
      }
      guard let action = found?.action else { return check(false, "menu has \(name)") }
      action()
    }

    // MARK: Run

    private static let smokeText = """
      Touch smoke \(UUID().uuidString)
      Group
      - Parent
      \t- Child
      \t- Other child
      - Second /high
      - Linker [Distant]
      Other
      - Distant
      \t- Far leaf

      """

    private static func run(_ store: PadMapStore) async {
      guard
        await wait(
          "initial map ready",
          until: {
            !store.isSwitching && store.currentURL != nil && store.graphView?.scene.layout != nil
          }), let view = store.graphView, await frozen(store, view),
        let original = store.currentURL
      else { return }
      let originalText = store.text
      let savedPreferences = store.preferences
      store.preferences = Preferences()
      defer { store.preferences = savedPreferences }
      // The graph checks run side by side, where the long-press menu has no "Edit Text".
      let savedLayout = store.layout.forcedWide
      store.layout.forcedWide = true
      defer { store.layout.forcedWide = savedLayout }
      await pause(600)
      store.newMap()
      guard
        await wait(
          "New Map opens an empty map",
          until: {
            !store.isSwitching && store.currentURL != original && store.text == "untitled map\n"
          })
      else { return }
      store.text = smokeText
      guard await frozen(store, view) else { return }
      await tapChecks(store, view)
      await doubleTapChecks(store, view)
      await dragChecks(store, view)
      await cameraChecks(store, view)
      await menuChecks(store, view)
      await pointerAndPanelChecks(store, view)
      await backgroundChecks(store, view)
      await editorChecks(store, view)
      await shortcutChecks(store, view)
      await layoutChecks(store, view)
      await syncChecks(store, view)
      await settingsChecks(store, view)
      _ = await wait("text autosave finishes") { !store.hasUnsavedEdits }
      let created = store.currentURL
      store.switchMap(original)
      guard
        await wait(
          "restore original map",
          until: {
            !store.isSwitching && store.currentURL == original && store.text == originalText
          }), await frozen(store, view)
      else { return }
      if let created {
        do {
          try FileManager.default.removeItem(at: created)
          let sidecar = LayoutSidecar.url(for: created)
          if FileManager.default.fileExists(atPath: sidecar.path) {
            try FileManager.default.removeItem(at: sidecar)
          }
          store.activated()
          check(true, "smoke map removed and original map restored")
        } catch { check(false, "smoke cleanup: \(error)") }
      }
    }

    // MARK: Tap

    private static func tapChecks(_ store: PadMapStore, _ view: GraphView) async {
      view.fitAll()
      await cameraIdle(view)
      guard let parent = index(view, "Parent"), let child = index(view, "Child"),
        let distant = index(view, "Distant"), let p = target(view, parent)
      else { return check(false, "tap targets exist") }
      view.debugTap(at: p)
      check(view.selection == parent && store.detail?.name == "Parent", "tap node selects it")
      check(
        view.scene.debugIsLit(child) && !view.scene.debugIsLit(distant),
        "tap highlights the node's branch only")
      check(view.scene.debugCameraAnimating, "tap animates the camera")
      await cameraIdle(view)
      if let box = view.scene.selectionBounds {
        // The detail panel grows with a selection, so the pane may be a little shorter than
        // when the fit was computed: check that the branch is on screen and fills it.
        let camera = view.scene.camera
        let a = camera.toScreen(CGPoint(x: box.minX, y: box.minY))
        let b = camera.toScreen(CGPoint(x: box.maxX, y: box.maxY))
        let shown = CGRect(x: a.x, y: a.y, width: b.x - a.x, height: b.y - a.y)
        let size = view.scene.size
        check(
          CGRect(origin: .zero, size: size).insetBy(dx: -1, dy: -1).contains(shown)
            && (shown.width >= size.width * 0.5 || shown.height >= size.height * 0.5),
          "camera fits the selected branch")
      } else {
        check(false, "selection has bounds")
      }
      await pause()
      guard let empty = target(view, nil) else { return check(false, "empty canvas point") }
      view.debugTap(at: empty)
      check(view.selection == nil && store.detail == nil, "tap empty canvas clears selection")
      await cameraIdle(view)
      check(near(view.scene.camera, fitCamera(view)), "tap empty canvas fits all")
      await pause()
      let before = view.scene.camera
      view.debugTap(at: empty)
      check(
        !view.scene.debugCameraAnimating && view.scene.camera == before,
        "tap empty canvas without a selection leaves the camera")
      await pause()
    }

    // MARK: Double-tap

    private static func doubleTapChecks(_ store: PadMapStore, _ view: GraphView) async {
      view.fitAll()
      await cameraIdle(view)
      guard await frozen(store, view), let second = index(view, "Second"),
        let p = target(view, second)
      else { return check(false, "double-tap target exists") }
      let before = store.text
      view.debugDoubleTap(at: p)
      check(view.debugNamingText == "Second", "double-tap label opens its name for editing")
      view.debugSetNamingText("Ignored")
      view.debugEscapeKey()
      check(!view.isNaming && store.text == before, "Esc cancels the rename")
      await cameraIdle(view)
      await pause()
      guard let again = target(view, second), let empty = target(view, nil) else {
        return check(false, "double-tap target after zoom")
      }
      view.debugDoubleTap(at: again)
      view.debugSetNamingText("Second renamed")
      view.debugTap(at: empty)
      check(!view.isNaming, "tapping away closes the name field")
      check(
        store.text.contains("- Second renamed /high\n"),
        "tapping away saves the rename, keeps metadata")
      guard await frozen(store, view) else { return }
      check(index(view, "Second renamed") != nil, "renamed node shown")
      store.activeUndoManager.undo()
      check(store.text == before, "undo restores the exact text")
      guard await frozen(store, view) else { return }
      store.activeUndoManager.redo()
      check(store.text.contains("- Second renamed /high\n"), "redo applies the rename again")
      guard await frozen(store, view) else { return }
      store.activeUndoManager.undo()
      guard await frozen(store, view) else { return }
      await cameraIdle(view)
      await pause()
      guard let third = index(view, "Second").flatMap({ target(view, $0) }) else {
        return check(false, "double-tap target after undo")
      }
      view.debugDoubleTap(at: third)
      view.debugSetNamingText("Second returned")
      view.debugReturnKey()
      check(
        !view.isNaming && store.text.contains("- Second returned /high\n"),
        "Return saves the rename")
      guard await frozen(store, view) else { return }
      store.activeUndoManager.undo()
      check(store.text == before, "undo the Return rename")
      guard await frozen(store, view) else { return }
      // Double-tap empty canvas: a group at that spot.
      view.fitAll()
      await cameraIdle(view)
      await pause()
      guard let spot = target(view, nil) else { return check(false, "empty canvas point") }
      let world = view.scene.camera.toWorld(spot)
      view.debugDoubleTap(at: spot)
      check(
        view.debugNamingText == "" && view.scene.debugGhostVisible,
        "double-tap empty canvas shows a new group's dot and name field")
      check(store.text == before, "a new node isn't written before it has a name")
      view.debugSetNamingText("Tapped group")
      view.debugReturnKey()
      check(store.text.hasSuffix("Tapped group\n"), "named group appended to the text")
      guard await frozen(store, view), let layout = view.scene.layout,
        let group = index(view, "Tapped group")
      else { return check(false, "tapped group shown") }
      check(
        distance(point(layout, group), world) < 5,
        "new group stays where it was tapped (\(Int(distance(point(layout, group), world))))")
      store.activeUndoManager.undo()
      check(store.text == before, "undo removes the new group")
      await frozen(store, view)
    }

    // MARK: Drag

    private static func dragChecks(_ store: PadMapStore, _ view: GraphView) async {
      view.clearSelection()
      view.fitAll()
      await cameraIdle(view)
      guard await frozen(store, view), let before = view.scene.layout,
        let parent = index(view, "Parent"), let child = index(view, "Child"),
        let start = target(view, parent)
      else { return check(false, "drag parent and subtree exist") }
      // Plain drag, away from the child: only the node moves.
      let camera = view.scene.camera
      let childAt = camera.toScreen(CGPoint(x: before.nodes[child].x, y: before.nodes[child].y))
      let away = max(hypot(start.x - childAt.x, start.y - childAt.y), 1)
      let end = CGPoint(
        x: start.x + (start.x - childAt.x) / away * 40,
        y: start.y + (start.y - childAt.y) / away * 40)
      view.debugTouchDown(at: start)
      for step in 1...8 {
        let t = Double(step) / 8
        view.debugTouchMove(
          to: CGPoint(x: start.x + (end.x - start.x) * t, y: start.y + (end.y - start.y) * t))
        try? await Task.sleep(for: .milliseconds(16))
      }
      check(view.isAnimating, "dragging runs the display link")
      // Checks that something does not happen, so it waits a fixed time for it.
      await pause()
      if let during = view.scene.layout {
        check(point(during, child) == point(before, child), "plain drag: the child stays put")
        check(
          distance(point(during, parent), camera.toWorld(end)) < 0.1,
          "dragged node follows the finger")
      }
      view.debugTouchUp()
      guard await frozen(store, view), let plain = view.scene.layout else { return }
      let key = plain.model.nodes[parent].pathKey
      check(
        point(plain, child) == point(before, child)
          && distance(
            point(plain, parent), CGPoint(x: before.nodes[parent].x, y: before.nodes[parent].y))
            > 1,
        "after a plain drag the node moved and its child didn't")
      check(view.displayedSimulation?.pins[key] == point(plain, parent), "release pins the node")
      fixedCheck(before, view: view, name: "plain drag local relaxation")
      // ⇧-drag with a hardware keyboard: the subtree follows on springs.
      guard let shiftStart = target(view, parent) else { return check(false, "⇧-drag target") }
      let shiftEnd = CGPoint(x: shiftStart.x + 70, y: shiftStart.y + 30)
      view.debugTouchDown(at: shiftStart, shift: true)
      view.debugTouchMove(to: shiftEnd)
      await wait("⇧-drag: the subtree follows on springs") {
        guard let during = view.scene.layout else { return false }
        return point(during, child) != point(plain, child)
      }
      view.debugTouchUp()
      guard await frozen(store, view), let shifted = view.scene.layout else { return }
      fixedCheck(plain, view: view, name: "⇧-drag local relaxation")
      // "Move Branch" from the long-press menu, then a plain drag.
      guard let branchStart = target(view, parent) else { return check(false, "branch target") }
      let items = view.menuItems(at: branchStart)
      perform(items, "Move Branch", name: "Move Branch")
      check(view.debugBranchArmed && store.notice != nil, "Move Branch arms a branch drag")
      let branchEnd = CGPoint(x: branchStart.x - 60, y: branchStart.y + 40)
      view.debugTouchDown(at: branchStart)
      view.debugTouchMove(to: branchEnd)
      await wait("Move Branch drag: the subtree follows") {
        guard let during = view.scene.layout else { return false }
        return point(during, child) != point(shifted, child)
      }
      view.debugTouchUp()
      check(!view.debugBranchArmed, "a branch drag disarms Move Branch")
      await frozen(store, view)
      // Without the arm, the next plain drag moves the node alone again.
      guard let after = view.scene.layout, let again = target(view, parent) else { return }
      // Away from the child, so a plain drag can't push it.
      let childNow = view.scene.camera.toScreen(
        CGPoint(x: after.nodes[child].x, y: after.nodes[child].y))
      let gap = max(hypot(again.x - childNow.x, again.y - childNow.y), 1)
      view.debugTouchDown(at: again)
      view.debugTouchMove(
        to: CGPoint(
          x: again.x + (again.x - childNow.x) / gap * 30,
          y: again.y + (again.y - childNow.y) / gap * 30))
      await pause()
      if let during = view.scene.layout {
        check(point(during, child) == point(after, child), "Move Branch lasts for one drag")
      }
      view.debugTouchUp()
      await frozen(store, view)
    }

    // MARK: Pan and pinch

    private static func cameraChecks(_ store: PadMapStore, _ view: GraphView) async {
      view.fitAll()
      await cameraIdle(view)
      guard let layout = view.scene.layout, let empty = target(view, nil),
        let parent = index(view, "Parent"), let onNode = target(view, parent)
      else { return check(false, "camera targets exist") }
      let positions = layout.nodes
      // One finger on empty canvas pans.
      var before = view.scene.camera
      view.debugTouchDown(at: empty)
      view.debugTouchMove(to: CGPoint(x: empty.x + 50, y: empty.y + 30))
      view.debugTouchUp()
      var after = view.scene.camera
      check(
        after.zoom == before.zoom && abs(after.offset.x - before.offset.x - 50) < 1e-6
          && abs(after.offset.y - before.offset.y - 30) < 1e-6,
        "one-finger drag on empty canvas pans")
      // Two fingers pan, even over a node.
      let moved = CGPoint(x: onNode.x + 50, y: onNode.y + 30)
      before = view.scene.camera
      view.debugTouchDown(at: moved, fingers: 2)
      view.debugTouchMove(to: CGPoint(x: moved.x - 40, y: moved.y + 20))
      view.debugTouchUp()
      after = view.scene.camera
      check(
        abs(after.offset.x - before.offset.x + 40) < 1e-6
          && abs(after.offset.y - before.offset.y - 20) < 1e-6
          && view.scene.layout?.nodes == positions,
        "two-finger pan moves the camera, never a node")
      // Trackpad two-finger scroll.
      before = view.scene.camera
      view.debugPan(by: CGPoint(x: -25, y: 35))
      after = view.scene.camera
      check(
        abs(after.offset.x - before.offset.x + 25) < 1e-6
          && abs(after.offset.y - before.offset.y - 35) < 1e-6 && after.zoom == before.zoom,
        "trackpad scroll pans")
      // A mouse wheel (no gesture phase) zooms about the pointer, by the Mac's wheel rule.
      let pointer = CGPoint(x: view.bounds.width * 0.3, y: view.bounds.height * 0.6)
      before = view.scene.camera
      let underPointer = before.toWorld(pointer)
      view.debugWheel(by: 10, about: pointer)
      after = view.scene.camera
      let stays = after.toWorld(pointer)
      check(
        abs(after.zoom / before.zoom - 1.12) < 1e-9, "mouse wheel up zooms in 12% per 10 points")
      check(
        hypot(stays.x - underPointer.x, stays.y - underPointer.y) < 1e-6,
        "mouse wheel keeps the point under the pointer")
      before = view.scene.camera
      view.debugWheel(by: -500, about: pointer)
      check(
        abs(view.scene.camera.zoom / before.zoom - 1 / pow(1.12, 3.5)) < 1e-9,
        "mouse wheel down zooms out, at most 1.5× per event")
      // Pinch about its center.
      let anchor = CGPoint(x: view.bounds.midX, y: view.bounds.midY)
      before = view.scene.camera
      let world = before.toWorld(anchor)
      view.debugPinch(by: 1.5, about: anchor)
      after = view.scene.camera
      let kept = after.toWorld(anchor)
      check(abs(after.zoom / before.zoom - 1.5) < 1e-9, "pinch zooms by the pinch scale")
      check(
        hypot(kept.x - world.x, kept.y - world.y) < 1e-6, "pinch keeps the point under its center")
      let limits = Camera.limits(fitZoom: fitCamera(view).zoom)
      view.debugPinch(by: 1000, about: anchor)
      check(abs(view.scene.camera.zoom - limits.upperBound) < 1e-9, "pinch stops at 10× fit all")
      view.debugPinch(by: 1e-6, about: anchor)
      check(abs(view.scene.camera.zoom - limits.lowerBound) < 1e-9, "pinch stops at 1/10 fit all")
      check(view.scene.layout?.nodes == positions, "pan and pinch never move nodes")
      check(
        !view.isAnimating && GraphView.debugLiveDisplayLinks == 0,
        "camera moves need no display link")
      view.fitAll()
      await cameraIdle(view)
    }

    // MARK: Long-press menu

    private static func menuChecks(_ store: PadMapStore, _ view: GraphView) async {
      view.clearSelection()
      view.fitAll()
      await cameraIdle(view)
      guard await frozen(store, view), let child = index(view, "Child"),
        let parent = index(view, "Parent"), let group = index(view, "Group"),
        let second = index(view, "Second"), let p = target(view, child)
      else { return check(false, "menu targets exist") }
      let before = store.text
      let taskItems = view.menuItems(at: p)
      check(
        titles(taskItems) == [
          "Add Task", "Add Subtask", "Rename", "Mark Done", "Priority", "Move Branch", "Delete",
        ], "long-press task menu: \(titles(taskItems).joined(separator: ", "))")
      check(
        titles(item(taskItems, "Priority")?.children ?? []) == [
          "High", "Medium", "Low", "Chill", "None",
        ],
        "Priority submenu")
      check(
        view.selection == child && !view.scene.debugCameraAnimating,
        "long-press selects the node without a camera move")
      if let g = target(view, group) {
        check(!titles(view.menuItems(at: g)).contains("Mark Done"), "group menu has no Mark Done")
      }
      if let s = target(view, second) {
        check(
          item(view.menuItems(at: s), "Priority", "High")?.checked == true,
          "Priority shows the node's priority checked")
      }
      if let empty = target(view, nil) {
        check(titles(view.menuItems(at: empty)) == ["New Group"], "long-press empty canvas menu")
      }
      // Each action, then undo.
      func undo(_ name: String) async {
        store.activeUndoManager.undo()
        check(store.text == before, "undo \(name) restores the exact text")
        await frozen(store, view)
      }
      func items(for name: String) -> [GraphMenuItem] {
        guard let i = index(view, name), let point = target(view, i) else {
          check(false, "\(name) is on screen")
          return []
        }
        return view.menuItems(at: point)
      }
      perform(items(for: "Child"), "Mark Done", name: "Mark Done")
      check(store.text.contains("\t- [x] Child\n"), "Mark Done writes [x]")
      await frozen(store, view)
      check(
        item(items(for: "Child"), "Mark Not Done") != nil, "a done task offers Mark Not Done")
      await undo("Mark Done")
      perform(items(for: "Child"), "Priority", "Medium", name: "Priority ▸ Medium")
      check(store.text.contains("\t- Child /medium\n"), "Priority ▸ Medium writes /medium")
      await frozen(store, view)
      await undo("priority")
      perform(items(for: "Child"), "Add Task", name: "Add Task")
      check(
        view.debugNamingText == "" && view.scene.debugGhostVisible,
        "Add Task shows the new dot and an empty name")
      view.debugSetNamingText("Menu task")
      view.debugReturnKey()
      check(
        store.text.contains("\t- Child\n\t- Menu task\n\t- Other child\n"),
        "Add Task writes a sibling")
      await frozen(store, view)
      check(
        index(view, "Menu task") != nil && view.selection == index(view, "Menu task"),
        "the added task is shown and selected")
      await undo("Add Task")
      perform(items(for: "Child"), "Add Subtask", name: "Add Subtask")
      view.debugSetNamingText("Menu subtask")
      view.debugReturnKey()
      check(store.text.contains("\t- Child\n\t\t- Menu subtask\n"), "Add Subtask writes a child")
      await frozen(store, view)
      await undo("Add Subtask")
      perform(items(for: "Child"), "Add Task", name: "Add Task")
      view.debugEscapeKey()
      check(store.text == before && !view.scene.debugGhostVisible, "Esc drops an unnamed task")
      perform(items(for: "Child"), "Rename", name: "Rename")
      check(view.debugNamingText == "Child", "Rename opens the name field")
      view.debugSetNamingText("Child renamed")
      view.debugReturnKey()
      check(store.text.contains("\t- Child renamed\n"), "Rename from the menu saves")
      await frozen(store, view)
      await undo("Rename")
      perform(items(for: "Child"), "Delete", name: "Delete")
      check(!store.text.contains("\t- Child\n"), "Delete removes the node")
      await frozen(store, view)
      check(
        index(view, "Child") == nil && view.selection == index(view, "Parent")
          && index(view, "Parent") == parent,
        "after Delete the parent is selected")
      await undo("Delete")
      check(index(view, "Child") != nil, "undo brings the deleted node back")
      view.clearSelection()
      await cameraIdle(view)
      guard let empty = target(view, nil) else { return check(false, "empty canvas point") }
      perform(view.menuItems(at: empty), "New Group", name: "New Group")
      view.debugSetNamingText("Menu group")
      view.debugReturnKey()
      check(store.text.hasSuffix("Menu group\n"), "New Group from the menu appends a group")
      await frozen(store, view)
      await undo("New Group")
    }

    // MARK: Pointer and detail panel

    private static func pointerAndPanelChecks(_ store: PadMapStore, _ view: GraphView) async {
      view.clearSelection()
      view.fitAll()
      await cameraIdle(view)
      guard let parent = index(view, "Parent"), let p = target(view, parent),
        let empty = target(view, nil)
      else { return check(false, "pointer targets exist") }
      check(view.debugHoverNode(at: p) == parent, "pointer hover finds the node")
      check(view.debugHoverNode(at: empty) == nil, "pointer hover over empty canvas")
      // Detail panel fields, the done checkbox and linked names (the panel's own actions).
      guard let linker = index(view, "Linker"), let distant = index(view, "Distant"),
        let leaf = index(view, "Far leaf"), let second = index(view, "Second"),
        let l = target(view, linker)
      else { return check(false, "panel targets exist") }
      view.debugTap(at: l)
      await cameraIdle(view)
      await pause()
      let linked = store.detail?.linked ?? []
      check(linked.map(\.name) == ["Distant"], "detail panel lists linked names")
      if let first = linked.first { store.selectLinked(first.index) }
      check(
        view.selection == distant && store.detail?.name == "Distant"
          && view.scene.debugCameraAnimating,
        "tapping a linked name selects it with a camera move")
      await cameraIdle(view)
      view.select(second, camera: false)
      store.graphSelected(second)
      if let kind = store.detail?.kind, case .task(_, let priority, _, let isLeaf) = kind {
        check(priority == .high && isLeaf, "task detail shows priority")
      } else {
        check(false, "task detail")
      }
      view.select(leaf, camera: false)
      store.graphSelected(leaf)
      let before = store.text
      store.toggleDone(leaf)
      check(store.text.contains("\t- [x] Far leaf\n"), "detail checkbox marks the task done")
      await frozen(store, view)
      // The panel refreshes right after the graph update, a moment after the freeze.
      await wait("detail shows done after the toggle (\(store.detail?.name ?? "none"))") {
        if let kind = store.detail?.kind, case .task(_, _, let done, _) = kind { return done }
        return false
      }
      store.activeUndoManager.undo()
      check(store.text == before, "undo the checkbox")
      await frozen(store, view)
      view.clearSelection()
      await cameraIdle(view)
    }

    // MARK: Background

    private static func backgroundChecks(_ store: PadMapStore, _ view: GraphView) async {
      guard await frozen(store, view), let parent = index(view, "Parent"),
        let p = target(view, parent)
      else { return check(false, "background drag target") }
      view.debugTouchDown(at: p)
      view.debugTouchMove(to: CGPoint(x: p.x + 20, y: p.y + 20))
      check(GraphView.debugLiveDisplayLinks == 1, "a drag starts one display link")
      view.debugScene(visible: false)
      check(GraphView.debugLiveDisplayLinks == 0, "background scene stops the display link")
      view.debugScene(visible: true)
      check(GraphView.debugLiveDisplayLinks == 1, "foreground scene resumes motion")
      view.debugTouchUp()
      await frozen(store, view)
      await pause(1000)
      idle()
    }
  }
#endif

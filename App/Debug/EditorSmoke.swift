#if DEBUG
  import AppKit
  import MindmapCore
  import MindmapGraph

  /// Opt-in checks deliver events inside this dev app. They never post system-wide events.
  @MainActor
  enum EditorSmoke {
    private static var failures = 0
    private static var checks = 0

    static func runIfRequested() {
      guard UserDefaults.standard.bool(forKey: "editor-smoke") else { return }
      Task {
        editorChecks()
        await fileChecks()
        await appChecks()
        log.notice(
          "native smoke complete: \(checks, privacy: .public) checks, \(failures, privacy: .public) failures"
        )
      }
    }

    private static func check(_ passed: Bool, _ name: String) {
      checks += 1
      if !passed { failures += 1 }
      log.notice(
        "smoke \(passed ? "PASS" : "FAIL", privacy: .public): \(name, privacy: .public)\(passed || NSApp.isActive ? "" : " (app inactive)", privacy: .public)"
      )
    }

    /// Bounded waits exist only in this opt-in harness, never in the app's motion loop.
    @discardableResult
    private static func wait(
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
    private static func frozen(_ store: MapStore) async -> Bool {
      await wait("graph settles and display link stops") {
        !store.isSwitching && store.parsedText == store.text
          && store.graphView?.scene.layout?.model == store.model
          && store.graphView?.isAnimating == false
          && store.graphView?.displayedSimulation?.isFrozen == true
          && GraphView.debugLiveDisplayLinks == 0
      } && displayLinkIdle()
    }

    @discardableResult
    private static func displayLinkIdle() -> Bool {
      let passed = GraphView.debugLiveDisplayLinks == 0 && GraphView.debugIdleFrames == 0
      check(
        passed,
        "display link invalidated after freeze (live \(GraphView.debugLiveDisplayLinks), idle frames \(GraphView.debugIdleFrames))"
      )
      return passed
    }

    private static func editorChecks() {
      let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 400, height: 400),
        styleMask: [.titled], backing: .buffered, defer: false)
      let editor = OutlineTextView(usingTextLayoutManager: true)
      editor.allowsUndo = true
      editor.isRichText = false
      window.contentView = editor
      let original = "Native test\nGroup\n- [x] Done /high\n\t- Child\n- Missing [[absent]]"
      editor.load(original, map: UUID())
      check(editor.textLayoutManager != nil, "TextKit 2 remains enabled")
      let ns = original as NSString
      let done = ns.range(of: "- [x] Done /high")
      check(
        editor.textStorage?.attribute(.strikethroughStyle, at: done.location, effectiveRange: nil)
          != nil, "done syntax has strikethrough")
      editor.setSelectedRange(NSRange(location: NSMaxRange(done), length: 0))
      editor.insertNewline(nil)
      check(
        editor.string.contains("Done /high\n- \n\t- Child"), "done Enter continues plain bullet")
      check(editor.undoManager?.canUndo == true, "native edit registers undo")
      editor.undoManager?.undo()
      check(editor.string == original, "Enter is one undo step")
      editor.undoManager?.redo()
      check(editor.string.contains("Done /high\n- \n"), "redo restores bullet")
      editor.undoManager?.undo()
      editor.setSelectedRange(NSRange(location: done.location + 3, length: 0))
      editor.insertTab(nil)
      check(editor.string.contains("\t- [x] Done"), "Tab works inside bullet")
      editor.undoManager?.undo()
      check(editor.string == original, "Tab is one undo step")
      editor.insertBacktab(nil)
      check(editor.string == original, "Shift Tab at root leaves text unchanged")
      let model = MapParser.parse(text: original, today: Date(), calendar: .current)
      editor.applyUnresolved(model.unresolvedLinks.map(\.sourceRange))
      let link = ns.range(of: "[[absent]]")
      let underline =
        editor.textStorage?.attribute(
          .underlineStyle, at: link.location, effectiveRange: nil) as? Int
      check(
        underline == NSUnderlineStyle.single.rawValue | NSUnderlineStyle.patternDot.rawValue,
        "unresolved links have dotted underline")
      editor.setSelectedRange(NSRange(location: link.location, length: 0))
      editor.insertText("😀 ", replacementRange: editor.selectedRange())
      check(editor.string.contains("😀 [[absent]]"), "Unicode typing is preserved")
      check(editor.textLayoutManager != nil, "styling retains TextKit 2")
    }

    private static func appChecks() async {
      guard let store = AppLifecycle.store else {
        check(false, "app store exists")
        return
      }
      guard
        await wait(
          "initial map ready",
          until: {
            !store.isSwitching && store.currentURL != nil && store.editorView != nil
              && store.graphView?.scene.layout != nil
          }), await frozen(store), let original = store.currentURL,
        let editor = store.editorView as? OutlineTextView,
        let view = store.graphView, let window = view.window
      else { return }
      let originalText = store.text
      var created: URL?
      do {
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
        // Responder-chain commands and first clicks need the app frontmost. macOS refuses
        // activation while the screen is locked or the user works in another app.
        guard
          await wait(
            "dev app owns key window",
            until: {
              NSApp.isActive && NSApp.keyWindow === window
            })
        else { return }
        store.focusEditor()
        menu(.newMap)
        guard
          await wait(
            "New Map opens empty outline",
            until: {
              !store.isSwitching && store.currentURL != original && store.text == "untitled map\n"
            })
        else { return }
        let title = "Smoke " + UUID().uuidString
        replace(editor, with: title + "\nGroup\n- Parent\n\t- Child\n- Second\nOther\n- Distant\n")
        guard await frozen(store) else { return }
        created = store.currentURL
        await shortcutChecks(store, editor: editor, view: view, window: window)
        await gestureChecks(view, window: window)
        await editMotionChecks(store, editor: editor, view: view, window: window)
        await dragChecks(store, view: view, window: window)
        guard await wait("text autosave finishes", until: { !store.hasUnsavedEdits }) else {
          return
        }
        await layoutChecks(store)
        created = store.currentURL
        await displayLinkChecks(store, view: view, window: window)
        await timingChecks(store)
        await activationChecks(store, editor: editor)
        store.switchMap(original)
        guard
          await wait(
            "restore original map",
            until: {
              !store.isSwitching && store.currentURL == original && store.text == originalText
            }), await frozen(store)
        else { return }
        if let created {
          try FileManager.default.removeItem(at: created)
          let sidecar = LayoutSidecar.url(for: created)
          if FileManager.default.fileExists(atPath: sidecar.path) {
            try FileManager.default.removeItem(at: sidecar)
          }
        }
        store.activated()
        check(true, "smoke maps cleaned and original map restored")
      } catch { check(false, "app checks: \(error)") }
    }

    private static func replace(_ editor: OutlineTextView, with text: String) {
      editor.insertText(
        text, replacementRange: NSRange(location: 0, length: (editor.string as NSString).length))
    }

    private static func select(_ name: String, in editor: OutlineTextView, whole: Bool = false) {
      let range = (editor.string as NSString).range(of: name)
      guard range.location != NSNotFound else {
        check(false, "editor contains \(name)")
        return
      }
      editor.setSelectedRange(NSRange(location: range.location, length: whole ? range.length : 0))
    }

    private static func key(
      _ characters: String, code: UInt16, modifiers: NSEvent.ModifierFlags = [], window: NSWindow
    ) -> NSEvent? {
      NSEvent.keyEvent(
        with: .keyDown, location: .zero, modifierFlags: modifiers,
        timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
        context: nil, characters: modifiers.contains(.shift) ? characters.uppercased() : characters,
        charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code)
    }

    private static func menuItem(
      in menu: NSMenu, where matches: (NSMenuItem) -> Bool
    ) -> NSMenuItem? {
      for item in menu.items {
        if matches(item) { return item }
        if let submenu = item.submenu, let found = menuItem(in: submenu, where: matches) {
          return found
        }
      }
      return nil
    }

    /// SwiftUI `.commands` items have no AppKit action until their menu opens, so neither
    /// `performKeyEquivalent` nor `sendAction` reaches them from a synthesized event. The
    /// harness checks that the real menu item carries the shortcut, then runs the same
    /// `AppCommand.perform` the item runs.
    private static func menu(_ command: AppCommand, name: String? = nil) {
      let name = name ?? command.title
      guard let store = AppLifecycle.store, let mainMenu = NSApp.mainMenu,
        let item = menuItem(in: mainMenu, where: { $0.title == command.title })
      else {
        check(false, "menu shortcut \(name) is in the menu bar")
        return
      }
      let shortcut = command.shortcut
      var modifiers: NSEvent.ModifierFlags = []
      if shortcut.modifiers.contains(.command) { modifiers.insert(.command) }
      if shortcut.modifiers.contains(.shift) { modifiers.insert(.shift) }
      if shortcut.modifiers.contains(.control) { modifiers.insert(.control) }
      if shortcut.modifiers.contains(.option) { modifiers.insert(.option) }
      var mask = item.keyEquivalentModifierMask.intersection([.command, .shift, .control, .option])
      if item.keyEquivalent != item.keyEquivalent.lowercased() { mask.insert(.shift) }
      let bound =
        item.keyEquivalent.lowercased() == String(shortcut.key.character).lowercased()
        && mask == modifiers
      check(bound && !command.isDisabled(store), "menu shortcut \(name)")
      if bound && !command.isDisabled(store) { command.perform(store) }
    }

    /// AppKit's own items (Undo, Redo) have real actions.
    private static func systemMenu(_ action: String, name: String) {
      let selector = Selector(action)
      guard let mainMenu = NSApp.mainMenu,
        let item = menuItem(in: mainMenu, where: { $0.action == selector }),
        item.keyEquivalent.lowercased() == "z"
      else {
        check(false, "menu shortcut \(name)")
        return
      }
      check(NSApp.sendAction(selector, to: item.target, from: item), "menu shortcut \(name)")
    }

    private static func sendKey(
      _ characters: String, code: UInt16, modifiers: NSEvent.ModifierFlags = [], window: NSWindow
    ) {
      if let event = key(characters, code: code, modifiers: modifiers, window: window) {
        window.sendEvent(event)
      } else {
        check(false, "native key event created")
      }
    }

    private static func shortcutChecks(
      _ store: MapStore, editor: OutlineTextView, view: GraphView, window: NSWindow
    ) async {
      store.focusEditor()
      select("Second", in: editor, whole: true)
      let before = editor.string
      menu(.toggleDone, name: "Toggle Done ⇧⌘X")
      check(
        editor.string.contains("- [x] Second"),
        "⇧⌘X toggles done with selected text, no cut conflict")
      systemMenu("undo:", name: "Undo")
      check(editor.string == before, "Undo restores done toggle")
      systemMenu("redo:", name: "Redo")
      check(editor.string.contains("- [x] Second"), "Redo restores done toggle")
      menu(.toggleDone, name: "Toggle Done again")
      select("Second", in: editor)
      menu(.indent)
      check(editor.string.contains("\t- Second"), "Indent menu changes level")
      menu(.outdent)
      check(editor.string.contains("\n- Second"), "Outdent menu changes level")
      menu(.moveUp)
      check(
        (editor.string as NSString).range(of: "Second").location
          < (editor.string as NSString).range(of: "Parent").location,
        "Move Up reorders task and branch")
      menu(.moveDown)
      check(
        (editor.string as NSString).range(of: "Second").location
          > (editor.string as NSString).range(of: "Parent").location,
        "Move Down restores task order")
      sendKey("\t", code: 48, window: window)
      check(editor.string.contains("\t- Second"), "native Tab indents")
      // Real Shift-Tab events carry the backtab character.
      sendKey("\u{19}", code: 48, modifiers: .shift, window: window)
      check(editor.string.contains("\n- Second"), "native Shift Tab outdents")
      guard await frozen(store) else { return }
      let zoom = view.scene.camera.zoom
      menu(.zoomIn)
      check(view.scene.camera.zoom > zoom, "Zoom In changes camera")
      let enlarged = view.scene.camera.zoom
      menu(.zoomOut)
      check(view.scene.camera.zoom < enlarged, "Zoom Out changes camera")
      menu(.fitAll)
      menu(.focusGraph)
      check(window.firstResponder === view, "Focus Graph reaches graph view")
      for (characters, code) in [
        ("\u{f700}", UInt16(126)), ("\u{f701}", 125), ("\u{f702}", 123), ("\u{f703}", 124),
      ] {
        let camera = view.scene.visibleCamera
        sendKey(characters, code: code, window: window)
        check(view.scene.camera.offset != camera.offset, "graph arrow key \(code) pans")
      }
      menu(.focusEditor)
      check(window.firstResponder === editor, "Focus Editor reaches text view")
      let map = store.currentURL
      menu(.nextMap)
      guard
        await wait("Next Map switches", until: { !store.isSwitching && store.currentURL != map })
      else { return }
      menu(.previousMap)
      _ = await wait(
        "Previous Map returns", until: { !store.isSwitching && store.currentURL == map })
      _ = await frozen(store)
    }

    private enum ScrollKind: CaseIterable {
      case lineWheel, smoothWheel, trackpad, momentum
    }

    /// Wheels have no phase (smooth ones still send pixel deltas); trackpads always have one.
    private static func scroll(
      _ kind: ScrollKind, lines: Int32 = 3, phase: Int64 = 2, view: GraphView, point: CGPoint
    ) -> NSEvent? {
      let precise = kind != .lineWheel
      guard
        let cg = CGEvent(
          scrollWheelEvent2Source: nil, units: precise ? .pixel : .line,
          wheelCount: 2, wheel1: precise ? lines * 10 : lines, wheel2: precise ? 7 : 0,
          wheel3: 0)
      else { return nil }
      cg.setIntegerValueField(.scrollWheelEventIsContinuous, value: precise ? 1 : 0)
      // CGScrollPhase (began 1, changed 2, ended 4) or CGMomentumScrollPhase (begin 1,
      // continue 2, end 3).
      if kind == .trackpad { cg.setIntegerValueField(.scrollWheelEventScrollPhase, value: phase) }
      if kind == .momentum { cg.setIntegerValueField(.scrollWheelEventMomentumPhase, value: phase) }
      // NSEvent(cgEvent:) leaves the event windowless with locationInWindow = the Cocoa screen
      // point. Place it so that point equals the target in window coordinates.
      let local = view.convert(CGPoint(x: point.x, y: view.bounds.height - point.y), to: nil)
      cg.location = CGPoint(x: local.x, y: (NSScreen.screens.first?.frame.maxY ?? 0) - local.y)
      return NSEvent(cgEvent: cg)
    }

    /// The layer actually drawn under a view point (y down), through the real layer tree.
    private static func drawnLayer(at point: CGPoint, in view: GraphView) -> CALayer? {
      guard let layer = view.layer else { return nil }
      let local = CGPoint(x: point.x, y: view.bounds.height - point.y)
      return layer.hitTest(layer.superlayer.map { layer.convert(local, to: $0) } ?? local)
    }

    private static func gestureChecks(_ view: GraphView, window: NSWindow) async {
      view.fitAll()
      try? await Task.sleep(for: .milliseconds(450))
      // A node toward the lower right, so a wrong y flip would move it away from the cursor.
      let target = CGPoint(x: view.bounds.width * 0.7, y: view.bounds.height * 0.7)
      guard let layout = view.scene.layout,
        let node = layout.nodes.indices.min(by: {
          let a = view.scene.camera.toScreen(CGPoint(x: layout.nodes[$0].x, y: layout.nodes[$0].y))
          let b = view.scene.camera.toScreen(CGPoint(x: layout.nodes[$1].x, y: layout.nodes[$1].y))
          return hypot(a.x - target.x, a.y - target.y) < hypot(b.x - target.x, b.y - target.y)
        })
      else {
        check(false, "gesture anchor node exists")
        return
      }
      let anchor = view.scene.camera.toScreen(
        CGPoint(x: layout.nodes[node].x, y: layout.nodes[node].y))
      let world = view.scene.camera.toWorld(anchor)
      let drawn = drawnLayer(at: anchor, in: view)
      check(drawn != nil && drawn !== view.layer, "a node layer is drawn under the cursor")
      for kind in [ScrollKind.lineWheel, .smoothWheel] {
        for lines: Int32 in [3, 1, -2, -2] {
          guard let event = scroll(kind, lines: lines, view: view, point: anchor)
          else {
            check(false, "\(kind) scroll event created")
            continue
          }
          check(event.phase.isEmpty && event.momentumPhase.isEmpty, "\(kind) has no phase")
          let camera = view.scene.visibleCamera
          window.sendEvent(event)
          let after = view.scene.camera
          check(
            (after.zoom > camera.zoom) == (lines > 0) && after.zoom != camera.zoom,
            "\(kind) \(lines) zooms \(lines > 0 ? "in" : "out")")
          let pinned = after.toWorld(anchor)
          check(
            hypot(pinned.x - world.x, pinned.y - world.y) < 1e-6,
            "\(kind) \(lines) world point under cursor doesn't drift")
          check(
            drawnLayer(at: anchor, in: view) === drawn,
            "\(kind) \(lines) same node drawn under cursor")
        }
      }
      // A real swipe: the gesture, then its momentum. AppKit sends momentum to the gesture's view.
      let camera = view.scene.visibleCamera
      var phased = true
      for (kind, phases) in [(ScrollKind.trackpad, [Int64(1), 2, 4]), (.momentum, [1, 2, 3])] {
        for phase in phases {
          guard let event = scroll(kind, phase: phase, view: view, point: anchor) else {
            check(false, "\(kind) scroll event created")
            continue
          }
          phased = phased && (!event.phase.isEmpty || !event.momentumPhase.isEmpty)
          let before = view.scene.camera
          // AppKit routes real momentum events itself and ignores synthesized ones, so those go
          // straight to the view; this checks the view's classification.
          if kind == .momentum { view.scrollWheel(with: event) } else { window.sendEvent(event) }
          check(
            view.scene.camera.zoom == before.zoom && view.scene.camera.offset != before.offset,
            "\(kind) phase \(phase) scroll pans without zoom")
        }
      }
      check(phased, "trackpad and momentum events carry a phase")
      check(view.scene.camera.zoom == camera.zoom, "a trackpad swipe never zooms")
      let before = view.scene.camera
      view.debugMagnify(by: 0.15, about: anchor)
      check(view.scene.camera.zoom > before.zoom, "magnify handler zooms through DEBUG hook")
      view.fitAll()
      try? await Task.sleep(for: .milliseconds(450))
    }

    private static func points(_ layout: GraphLayout) -> [String: LayoutPoint] {
      Dictionary(
        uniqueKeysWithValues: layout.model.nodes.indices.map {
          (
            layout.model.nodes[$0].pathKey,
            LayoutPoint(x: layout.nodes[$0].x, y: layout.nodes[$0].y)
          )
        })
    }

    private static func fixedCheck(_ before: GraphLayout, view: GraphView, name: String) {
      guard let after = view.scene.layout else {
        check(false, name)
        return
      }
      let positions = points(before)
      var fixed = 0
      var equal = true
      for i in after.nodes.indices where !view.affectedIndices.contains(i) {
        guard let old = positions[after.model.nodes[i].pathKey] else { continue }
        fixed += 1
        equal = equal && old == LayoutPoint(x: after.nodes[i].x, y: after.nodes[i].y)
      }
      check(fixed > 0 && equal, "\(name), \(fixed) unaffected nodes move exactly zero")
    }

    private static func editMotionChecks(
      _ store: MapStore, editor: OutlineTextView, view: GraphView, window: NSWindow
    ) async {
      store.focusEditor()
      guard await frozen(store), let before = view.scene.layout else { return }
      let end = (editor.string as NSString).range(of: "Distant")
      editor.setSelectedRange(NSRange(location: NSMaxRange(end), length: 0))
      sendKey("\r", code: 36, window: window)
      for character in "New task" { sendKey(String(character), code: 0, window: window) }
      check(editor.string.contains("- New task"), "native Return and typing create task line")
      guard await frozen(store) else { return }
      check(
        view.scene.layout?.model.nodes.contains(where: { $0.name == "New task" }) == true,
        "typed task appears in graph")
      fixedCheck(before, view: view, name: "new task local relaxation")
      guard let renameBefore = view.scene.layout,
        let index = renameBefore.model.nodes.firstIndex(where: { $0.name == "Second" })
      else {
        check(false, "rename target exists")
        return
      }
      let oldPoint = LayoutPoint(x: renameBefore.nodes[index].x, y: renameBefore.nodes[index].y)
      select("Second", in: editor, whole: true)
      editor.insertText("Third", replacementRange: editor.selectedRange())
      guard await frozen(store), let renamed = view.scene.layout,
        let renamedIndex = renamed.model.nodes.firstIndex(where: { $0.name == "Third" })
      else { return }
      check(
        LayoutPoint(x: renamed.nodes[renamedIndex].x, y: renamed.nodes[renamedIndex].y) == oldPoint,
        "rename keeps exact position")
      select("Third", in: editor)
      sendKey("\t", code: 48, window: window)
      guard
        await wait(
          "indent parse shown",
          until: {
            store.parsedText == store.text && view.scene.layout?.model == store.model
          }), let initial = view.debugInitialLayout,
        let moved = initial.model.nodes.firstIndex(where: { $0.name == "Third" })
      else { return }
      check(
        LayoutPoint(x: initial.nodes[moved].x, y: initial.nodes[moved].y) == oldPoint,
        "indent keeps old starting position")
      _ = await frozen(store)
      guard let deletedBefore = view.scene.layout else { return }
      let line = (editor.string as NSString).lineRange(
        for: (editor.string as NSString).range(of: "New task"))
      editor.insertText("", replacementRange: line)
      guard await frozen(store), let deletedAfter = view.scene.layout else { return }
      let old = points(deletedBefore)
      check(
        points(deletedAfter).allSatisfy { old[$0.key] == $0.value },
        "deleting task moves no surviving nodes")
    }

    private static func mouse(
      _ type: NSEvent.EventType, point: CGPoint, view: GraphView, window: NSWindow
    ) {
      let local = view.convert(CGPoint(x: point.x, y: view.bounds.height - point.y), to: nil)
      guard
        let event = NSEvent.mouseEvent(
          with: type, location: local, modifierFlags: [],
          timestamp: ProcessInfo.processInfo.systemUptime,
          windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1,
          pressure: 1)
      else {
        check(false, "mouse event created")
        return
      }
      window.sendEvent(event)
    }

    private static func dragChecks(_ store: MapStore, view: GraphView, window: NSWindow) async {
      guard await frozen(store), let before = view.scene.layout else { return }
      view.fitAll()
      try? await Task.sleep(for: .milliseconds(450))
      // Each smoke map gets a random seed. Grab a parent the hit test really returns there (no
      // closer neighbor within the 14 px radius, clear of the zoom buttons), "Parent" first.
      let camera = view.scene.camera
      let candidates = before.model.nodes.indices.filter {
        !before.model.nodes[$0].children.isEmpty
      }
      .sorted {
        (before.model.nodes[$0].name == "Parent" ? 0 : 1)
          < (before.model.nodes[$1].name == "Parent" ? 0 : 1)
      }
      guard
        let index = candidates.first(where: {
          let p = camera.toScreen(CGPoint(x: before.nodes[$0].x, y: before.nodes[$0].y))
          return view.scene.node(at: p, radius: 14) == $0 && p.y > 60 && p.x > 20
            && p.x < view.bounds.width - 100 && p.y < view.bounds.height - 60
        }),
        let child = before.model.nodes[index].children.first
      else {
        check(false, "drag parent and subtree exist")
        return
      }
      let node = before.nodes[index]
      let start = view.scene.camera.toScreen(CGPoint(x: node.x, y: node.y))
      let end = CGPoint(x: start.x + 70, y: start.y + 30)
      mouse(.leftMouseDown, point: start, view: view, window: window)
      mouse(.leftMouseDragged, point: end, view: view, window: window)
      try? await Task.sleep(for: .milliseconds(400))
      if let during = view.scene.layout {
        check(
          during.nodes[child].x != before.nodes[child].x
            || during.nodes[child].y != before.nodes[child].y,
          "drag subtree follows on springs")
        let cursor = view.scene.camera.toWorld(end)
        check(
          hypot(during.nodes[index].x - cursor.x, during.nodes[index].y - cursor.y) < 0.1,
          "dragged node follows cursor")
      }
      mouse(.leftMouseUp, point: end, view: view, window: window)
      guard await frozen(store) else { return }
      fixedCheck(before, view: view, name: "drag local relaxation")
      guard let url = store.currentURL, let after = view.scene.layout else { return }
      let key = after.model.nodes[index].pathKey
      let point = LayoutPoint(x: after.nodes[index].x, y: after.nodes[index].y)
      _ = await wait(
        "drag release pin and frozen positions saved",
        until: {
          let sidecar = LayoutSidecar.load(for: url)
          return sidecar?.pins[key] == point && sidecar?.positions[key] == point
        })
    }

    /// The display link must be gone whenever nothing moves, however motion ended.
    private static func displayLinkChecks(
      _ store: MapStore, view: GraphView, window: NSWindow
    ) async {
      guard await frozen(store), let map = store.currentURL, let layout = view.scene.layout,
        let index = layout.model.nodes.firstIndex(where: { !$0.children.isEmpty })
      else { return }
      view.fitAll()
      try? await Task.sleep(for: .milliseconds(450))
      let node = layout.nodes[index]
      let start = view.scene.camera.toScreen(CGPoint(x: node.x, y: node.y))
      mouse(.leftMouseDown, point: start, view: view, window: window)
      mouse(
        .leftMouseDragged, point: CGPoint(x: start.x + 40, y: start.y), view: view, window: window)
      check(view.isAnimating, "drag starts the display link")
      menu(.nextMap, name: "Next Map mid-drag")
      guard
        await wait(
          "map switch cancels drag", until: { !store.isSwitching && store.currentURL != map })
      else { return }
      mouse(.leftMouseUp, point: CGPoint(x: start.x + 40, y: start.y), view: view, window: window)
      _ = await frozen(store)
      store.switchMap(map)
      guard
        await wait(
          "return after cancelled drag",
          until: {
            !store.isSwitching && store.currentURL == map
          }), await frozen(store)
      else { return }

      menu(.reshuffle)
      guard await wait("reshuffle animates", until: { view.isAnimating }) else { return }
      store.switchMap(by: 1)
      guard
        await wait(
          "switch mid-animation",
          until: {
            !store.isSwitching && store.currentURL != map
          })
      else { return }
      _ = await frozen(store)
      store.switchMap(map)
      guard
        await wait(
          "return after mid-animation switch",
          until: {
            !store.isSwitching && store.currentURL == map
          }), await frozen(store)
      else { return }

      menu(.reshuffle)
      guard await wait("reshuffle animates again", until: { view.isAnimating }) else { return }
      window.miniaturize(nil)
      _ = await wait(
        "occlusion stops the display link",
        until: {
          !view.isAnimating && GraphView.debugLiveDisplayLinks == 0
        })
      window.deminiaturize(nil)
      window.makeKeyAndOrderFront(nil)
      _ = await wait("visible again", until: { window.occlusionState.contains(.visible) })
      _ = await frozen(store)
    }

    private static func activationChecks(_ store: MapStore, editor: OutlineTextView) async {
      guard let url = store.currentURL else { return }
      let original = store.text
      let title = MapDocument.title(of: original) ?? "Smoke"
      let repository = MapRepository()
      do {
        _ = try await repository.save(title + "\nExternal\n- from disk\n", to: url)
        store.activated()
        guard
          await wait(
            "clean activation reloads external edit",
            until: {
              store.text.contains("from disk")
            }), await frozen(store)
        else { return }
        replace(editor, with: title + "\nLocal\n- unsaved edit\n")
        _ = try await repository.save(title + "\nExternal\n- different disk text\n", to: url)
        store.activated()
        check(store.text.contains("unsaved edit"), "dirty activation preserves local edits")
        replace(editor, with: original)
        _ = await wait("restored outline autosaved", until: { !store.hasUnsavedEdits })
        _ = await frozen(store)
      } catch { check(false, "activation checks: \(error)") }
    }

    private static func layoutChecks(_ store: MapStore) async {
      guard let created = store.currentURL else { return }
      store.text = "Renamed " + store.text
      guard
        await wait(
          "map and sidecar rename",
          until: {
            store.currentURL != created
              && store.currentURL?.lastPathComponent.hasPrefix("Renamed") == true
          }), await frozen(store), let renamed = store.currentURL
      else { return }
      _ = await wait(
        "renamed sidecar preserves pins",
        until: {
          LayoutSidecar.load(for: renamed)?.pins.isEmpty == false
        })
      check(LayoutSidecar.load(for: created) == nil, "old sidecar gone after rename")
      let seed = LayoutSidecar.load(for: renamed)?.seed
      if let window = store.graphView?.window {
        menu(.reshuffle)
      }
      guard await frozen(store) else { return }
      _ = await wait(
        "reshuffle saves new seed and clears pins",
        until: {
          let state = LayoutSidecar.load(for: renamed)
          return state?.pins.isEmpty == true && state?.seed != seed
        })
    }

    private static func timingChecks(_ store: MapStore) async {
      guard let saved = store.currentURL, let view = store.graphView else { return }
      let folder = FileManager.default.temporaryDirectory.appending(
        path: "motion-smoke-" + UUID().uuidString)
      do {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        for (fixture, count) in [("sample", 140), ("large", 500)] {
          guard let resource = Bundle.main.url(forResource: fixture, withExtension: "mindmap")
          else {
            check(false, "\(fixture) fixture bundled")
            continue
          }
          let fixtureText = try String(contentsOf: resource, encoding: .utf8)
          let target = MapFiles.availableURL(
            title: MapDocument.title(of: fixtureText) ?? fixture, in: folder)
          try FileManager.default.copyItem(at: resource, to: target)
          store.switchMap(target)
          guard
            await wait(
              "\(count)-node fixture displayed",
              until: {
                !store.isSwitching && store.currentURL == target
                  && view.scene.layout?.model.nodeCount == count
              }), await frozen(store)
          else { continue }
          let metrics = view.debugFrameMetrics
          log.notice(
            "motion metrics nodes=\(count, privacy: .public) main-frame-average-ms=\(metrics.averageMilliseconds, privacy: .public) main-frame-worst-ms=\(metrics.worstMilliseconds, privacy: .public) frames=\(metrics.frames, privacy: .public) display-link-stopped=\(!view.isAnimating, privacy: .public)"
          )
          _ = await wait(
            "\(count)-node positions saved",
            until: {
              LayoutSidecar.load(for: target)?.positions.count == count
            })
          if count == 500 { await crowdedDrag(store, view: view) }
          for trial in 1...3 {
            store.switchMap(saved)
            guard
              await wait(
                "benchmark return map",
                until: {
                  !store.isSwitching && store.currentURL == saved
                }), await frozen(store)
            else { break }
            let start = ContinuousClock.now
            store.switchMap(target)
            guard
              await wait(
                "saved \(count)-node map switch",
                until: {
                  !store.isSwitching && store.currentURL == target
                    && view.scene.layout?.model.nodeCount == count
                })
            else { break }
            let duration = start.duration(to: .now).components
            let milliseconds = Double(duration.seconds) * 1000 + Double(duration.attoseconds) / 1e15
            log.notice(
              "smoke switch nodes=\(count, privacy: .public) trial=\(trial, privacy: .public) observed-ms=\(milliseconds, privacy: .public)"
            )
            check(!view.isAnimating, "saved \(count)-node switch has no settle animation")
          }
        }
        store.switchMap(saved)
        _ = await wait(
          "benchmark map restored", until: { !store.isSwitching && store.currentURL == saved })
        _ = await frozen(store)
      } catch { check(false, "switch timing: \(error)") }
    }

    /// Drags a branch through the middle of the map over about a second, like a user would.
    private static func crowdedDrag(_ store: MapStore, view: GraphView) async {
      guard let window = view.window, let layout = view.scene.layout,
        let index = layout.model.nodes.firstIndex(where: { $0.children.count >= 2 })
      else { return }
      view.fitAll()
      try? await Task.sleep(for: .milliseconds(450))
      let start = view.scene.camera.toScreen(
        CGPoint(x: layout.nodes[index].x, y: layout.nodes[index].y))
      let end = CGPoint(x: view.bounds.midX, y: view.bounds.midY)
      view.debugResetFrameMetrics()
      mouse(.leftMouseDown, point: start, view: view, window: window)
      for step in 1...60 {
        let t = Double(step) / 60
        mouse(
          .leftMouseDragged,
          point: CGPoint(x: start.x + (end.x - start.x) * t, y: start.y + (end.y - start.y) * t),
          view: view, window: window)
        try? await Task.sleep(for: .milliseconds(16))
      }
      mouse(.leftMouseUp, point: end, view: view, window: window)
      guard await frozen(store) else { return }
      let metrics = view.debugFrameMetrics
      let moved = view.affectedIndices.count
      log.notice(
        "motion metrics crowded-drag nodes=500 affected=\(moved, privacy: .public) main-frame-average-ms=\(metrics.averageMilliseconds, privacy: .public) main-frame-worst-ms=\(metrics.worstMilliseconds, privacy: .public) frames=\(metrics.frames, privacy: .public)"
      )
      check(metrics.frames > 30 && moved < 500, "crowded drag animates and stays local")
    }

    private static func fileChecks() async {
      let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
      do {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let repository = MapRepository()
        let first = try await repository.create(in: folder)
        let second = try await repository.create(in: folder)
        check(first != second, "repository creates unique maps")
        _ = try await repository.save("Trip/: Plan\n- task\n", to: first)
        let renamed = try await repository.rename(first, title: "Trip/: Plan")
        check(renamed.lastPathComponent == "Trip Plan.mindmap", "title rename sanitizes filename")
        let document = UUID()
        _ = try await repository.open(renamed, document: document)
        let moved = try await repository.rename(document: document, title: "Renamed")
        _ = try await repository.save("Trip/: Plan\n- task\n", document: document)
        check(
          !FileManager.default.fileExists(atPath: renamed.path),
          "save after rename preserves new filename")
        let loaded = try await repository.load(moved)
        check(loaded.text == "Trip/: Plan\n- task\n", "repository save/load preserves text")
        try "Trip/: Plan\n- external edit\n".write(to: moved, atomically: true, encoding: .utf8)
        check(
          try await repository.changed(moved, since: loaded), "repository detects external edit")
        let maps = try await repository.list(folder)
        check(maps.count == 2, "repository lists maps")
      } catch { check(false, "repository checks: \(error)") }
    }
  }
#endif

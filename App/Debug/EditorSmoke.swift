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
      let original = "Native test\nGroup\n- [x] Done /high\n\t- Child\n- Missing [absent] [[gone]]"
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
      let link = ns.range(of: "[absent]")
      for (token, name) in [(link, "[name]"), (ns.range(of: "[[gone]]"), "[[name]]")] {
        let underline =
          editor.textStorage?.attribute(
            .underlineStyle, at: token.location, effectiveRange: nil) as? Int
        check(
          underline == NSUnderlineStyle.single.rawValue | NSUnderlineStyle.patternDot.rawValue,
          "unresolved \(name) links have dotted underline")
      }
      let marker = ns.range(of: "[x]")
      check(
        editor.textStorage?.attribute(.underlineStyle, at: marker.location, effectiveRange: nil)
          == nil, "the done marker is not a link")
      editor.setSelectedRange(NSRange(location: link.location, length: 0))
      editor.insertText("😀 ", replacementRange: editor.selectedRange())
      check(editor.string.contains("😀 [absent]"), "Unicode typing is preserved")
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
      // Defaults for the run (an aborted run may have left the panel open over the graph).
      let savedPreferences = store.preferences
      store.preferences = Preferences()
      defer { store.preferences = savedPreferences }
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
        await wait("editor editable after New Map") { editor.isEditable }
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
        // After the sidecar checks: deleting and undoing a node re-adds it unpinned, like typing.
        await selectionChecks(store, editor: editor, view: view, window: window)
        await settingsChecks(store, editor: editor, view: view, window: window)
        await reviewFixChecks(store, editor: editor, view: view, window: window)
        await displayLinkChecks(store, view: view, window: window)
        await calendarChecks(store, editor: editor, view: view)
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
          try CalendarSidecar.remove(for: created)
          let sidecar = LayoutSidecar.url(for: created)
          if FileManager.default.fileExists(atPath: sidecar.path) {
            try FileManager.default.removeItem(at: sidecar)
          }
        }
        store.activated()
        check(true, "smoke maps cleaned and original map restored")
      } catch { check(false, "app checks: \(error)") }
    }

    private static func calendarChecks(
      _ store: MapStore, editor: OutlineTextView, view: GraphView
    ) async {
      guard !DebugLaunch.realCalendar, let folder = store.folder else {
        check(false, "calendar smoke requires fake store")
        return
      }
      let original = store.text
      await store.calendarSync.drain()
      if store.calendarSync.enabled {
        store.calendarSync.setEnabled(false, in: folder)
        store.calendarSync.confirmRemoval(in: folder)
        await store.calendarSync.drain()
      }
      replace(
        editor,
        with: (MapDocument.title(of: original) ?? "Calendar smoke")
          + "\nGroup\n- Calendar task /today /high\n\t- [x] Finished child\n- Undated /high\n"
      )
      guard await frozen(store) else { return }
      _ = await store.save()
      menu(.settings, name: "Calendar Settings")
      guard
        await wait(
          "Calendar settings window opens",
          until: {
            DebugControls.settingsVisible && DebugControls.settingsTab != nil
          })
      else { return }
      DebugControls.settingsTab?.wrappedValue = "calendar"
      guard
        await wait(
          "Calendar switch rendered",
          until: {
            DebugControls.calendarToggle != nil
          })
      else { return }
      DebugControls.calendarToggle?.wrappedValue = true
      await store.calendarSync.drain()
      check(
        store.calendarSync.enabled && store.calendarSync.lastError == nil,
        "Calendar settings switch enables fake sync")
      guard let i = store.model.nodes.firstIndex(where: { $0.name == "Calendar task" }) else {
        check(false, "calendar task exists")
        return
      }
      view.select(i, camera: false)
      store.graphSelected(i)
      check(
        store.calendarLine?.hasPrefix("on calendar: ") == true,
        "selected high task detail shows calendar date")
      let identifier = store.calendarSync.records.first { $0.event.title == "Calendar task" }?
        .identifier
      check(
        identifier != nil
          && store.calendarSync.records.contains {
            $0.event.notes.contains("- [x] Finished child")
          }, "high task creates event with done subtask notes")
      if let undated = store.model.nodes.firstIndex(where: { $0.name == "Undated" }) {
        view.select(undated, camera: false)
        store.graphSelected(undated)
        check(store.calendarLine == "not on calendar: no date", "undated high task detail")
      }
      replace(
        editor,
        with: store.text.replacingOccurrences(
          of: "Calendar task /today", with: "Renamed task /tomorrow"))
      guard await frozen(store) else { return }
      // Sync is queued after the graph update and autosave, so wait for its result.
      _ = await wait("editing high task updates same fake event") {
        store.calendarSync.records.contains {
          $0.identifier == identifier && $0.event.title == "Renamed task"
        }
      }
      replace(
        editor,
        with: store.text.replacingOccurrences(
          of: "Renamed task /tomorrow /high", with: "Renamed task /tomorrow"))
      guard await frozen(store) else { return }
      _ = await wait("removing high removes fake calendar event") {
        !store.calendarSync.records.contains { $0.identifier == identifier }
      }
      await store.calendarSync.drain()
      DebugControls.calendarToggle?.wrappedValue = false
      check(
        store.calendarSync.confirmingRemoval && store.calendarSync.enabled,
        "turning sync off presents removal confirmation")
      store.calendarSync.confirmingRemoval = false
      check(store.calendarSync.enabled, "cancel keeps calendar sync enabled")
      DebugControls.calendarToggle?.wrappedValue = false
      store.calendarSync.confirmRemoval(in: folder)
      await store.calendarSync.drain()
      check(
        !store.calendarSync.enabled && store.calendarSync.records.isEmpty,
        "confirmed sync off removes fake calendar and events")
      NSApp.windows.first { $0 !== view.window && $0.isVisible }?.close()
      view.window?.makeKeyAndOrderFront(nil)
      store.focusEditor()
      replace(editor, with: original)
      _ = await frozen(store)
    }

    private static func replace(_ editor: OutlineTextView, with text: String) {
      editor.insertText(
        text, replacementRange: NSRange(location: 0, length: (editor.string as NSString).length))
      if editor.string != text { check(false, "replace: editor editable \(editor.isEditable)") }
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

    /// AppKit closes the automatic undo group when it finishes handling an event. Programmatic
    /// edits and `window.sendEvent` keys aren't events, so without this every step of a run
    /// with nobody at the Mac merges into one undo group. Posts one, as a key press would.
    private static func endEvent() async {
      guard
        let event = NSEvent.otherEvent(
          with: .applicationDefined, location: .zero, modifierFlags: [], timestamp: 0,
          windowNumber: 0, context: nil, subtype: 0, data1: 0, data2: 0)
      else { return check(false, "event boundary created") }
      NSApp.postEvent(event, atStart: false)
      try? await Task.sleep(for: .milliseconds(30))
    }

    /// AppKit's own items (Undo, Redo) have real actions. Each press is a new event.
    private static func systemMenu(_ action: String, name: String) async {
      await endEvent()
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
      await endEvent()
      menu(.toggleDone, name: "Toggle Done ⇧⌘X")
      check(
        editor.string.contains("- [x] Second"),
        "⇧⌘X toggles done with selected text, no cut conflict")
      await systemMenu("undo:", name: "Undo")
      check(editor.string == before, "Undo restores done toggle\(textDiff(before, editor.string))")
      await systemMenu("redo:", name: "Redo")
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
      menu(.fitAll, name: "Fit All ⌥⌘0")
      menu(.focusGraph, name: "Focus Graph ⌥⌘2")
      check(window.firstResponder === view, "Focus Graph reaches graph view")
      sendKey("\u{1b}", code: 53, window: window)
      check(view.selection == nil && store.detail == nil, "Esc clears the selection")
      for (characters, code) in [
        ("\u{f700}", UInt16(126)), ("\u{f701}", 125), ("\u{f702}", 123), ("\u{f703}", 124),
      ] {
        let camera = view.scene.visibleCamera
        sendKey(characters, code: code, window: window)
        check(view.scene.camera.offset != camera.offset, "graph arrow key \(code) pans")
      }
      menu(.focusEditor, name: "Focus Editor ⌥⌘1")
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

    private static func mouseEvent(
      _ type: NSEvent.EventType, point: CGPoint, view: GraphView, window: NSWindow,
      clicks: Int = 1, modifiers: NSEvent.ModifierFlags = []
    ) -> NSEvent? {
      let local = view.convert(CGPoint(x: point.x, y: view.bounds.height - point.y), to: nil)
      return NSEvent.mouseEvent(
        with: type, location: local, modifierFlags: modifiers,
        timestamp: ProcessInfo.processInfo.systemUptime,
        windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: clicks,
        pressure: 1)
    }

    private static func mouse(
      _ type: NSEvent.EventType, point: CGPoint, view: GraphView, window: NSWindow,
      clicks: Int = 1, modifiers: NSEvent.ModifierFlags = []
    ) {
      guard
        let event = mouseEvent(
          type, point: point, view: view, window: window, clicks: clicks, modifiers: modifiers)
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
      // Plain drag, away from the child: only the node moves.
      let childAt = camera.toScreen(CGPoint(x: before.nodes[child].x, y: before.nodes[child].y))
      let away = hypot(start.x - childAt.x, start.y - childAt.y)
      let plainEnd = CGPoint(
        x: start.x + (start.x - childAt.x) / max(away, 1) * 40,
        y: start.y + (start.y - childAt.y) / max(away, 1) * 40)
      mouse(.leftMouseDown, point: start, view: view, window: window)
      mouse(.leftMouseDragged, point: plainEnd, view: view, window: window)
      try? await Task.sleep(for: .milliseconds(400))
      if let during = view.scene.layout {
        check(
          during.nodes[child].x == before.nodes[child].x
            && during.nodes[child].y == before.nodes[child].y,
          "plain drag moves only the node, child stays")
      }
      mouse(.leftMouseUp, point: plainEnd, view: view, window: window)
      guard await frozen(store), let plain = view.scene.layout else { return }
      check(
        plain.nodes[child].x == before.nodes[child].x
          && plain.nodes[child].y == before.nodes[child].y
          && hypot(
            plain.nodes[index].x - before.nodes[index].x,
            plain.nodes[index].y - before.nodes[index].y) > 1,
        "after a plain drag the node moved and its child didn't")
      // ⇧-drag: the subtree follows on springs.
      let shiftStart = view.scene.camera.toScreen(
        CGPoint(x: plain.nodes[index].x, y: plain.nodes[index].y))
      let end = CGPoint(x: shiftStart.x + 70, y: shiftStart.y + 30)
      mouse(.leftMouseDown, point: shiftStart, view: view, window: window, modifiers: .shift)
      mouse(.leftMouseDragged, point: end, view: view, window: window, modifiers: .shift)
      try? await Task.sleep(for: .milliseconds(400))
      if let during = view.scene.layout {
        check(
          during.nodes[child].x != plain.nodes[child].x
            || during.nodes[child].y != plain.nodes[child].y,
          "⇧-drag subtree follows on springs")
        let cursor = view.scene.camera.toWorld(end)
        check(
          hypot(during.nodes[index].x - cursor.x, during.nodes[index].y - cursor.y) < 0.1,
          "dragged node follows cursor")
      }
      mouse(.leftMouseUp, point: end, view: view, window: window, modifiers: .shift)
      guard await frozen(store) else { return }
      fixedCheck(plain, view: view, name: "drag local relaxation")
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
          if count == 500 {
            selectionTiming(store, view: view)
            await crowdedDrag(store, view: view)
          }
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
      mouse(.leftMouseDown, point: start, view: view, window: window, modifiers: .shift)
      for step in 1...60 {
        let t = Double(step) / 60
        mouse(
          .leftMouseDragged,
          point: CGPoint(x: start.x + (end.x - start.x) * t, y: start.y + (end.y - start.y) * t),
          view: view, window: window, modifiers: .shift)
        try? await Task.sleep(for: .milliseconds(16))
      }
      mouse(.leftMouseUp, point: end, view: view, window: window, modifiers: .shift)
      guard await frozen(store) else { return }
      let metrics = view.debugFrameMetrics
      let moved = view.affectedIndices.count
      log.notice(
        "motion metrics crowded-drag nodes=500 affected=\(moved, privacy: .public) main-frame-average-ms=\(metrics.averageMilliseconds, privacy: .public) main-frame-worst-ms=\(metrics.worstMilliseconds, privacy: .public) frames=\(metrics.frames, privacy: .public)"
      )
      check(
        metrics.frames > 30 && moved < 200, "crowded drag animates and stays local (\(moved) moved)"
      )
      fixedCheck(layout, view: view, name: "crowded drag: outside the region")
    }

    // MARK: Selection (roadmap 3b)

    /// The graph shows the parse of the current text, settled.
    @discardableResult
    private static func current(_ store: MapStore, _ name: String) async -> Bool {
      await wait(name) {
        store.parsedText == store.text && store.graphView?.scene.layout?.model == store.model
          && store.graphView?.isAnimating == false
      }
    }

    private static func nodeIndex(_ view: GraphView, _ name: String) -> Int? {
      view.scene.layout?.model.nodes.firstIndex { $0.name == name }
    }

    /// A view point that hits `index` (or empty canvas for nil), clear of the zoom buttons.
    private static func target(_ view: GraphView, _ index: Int?) -> CGPoint? {
      guard let layout = view.scene.layout else { return nil }
      let ok = { (p: CGPoint) in
        p.x > 20 && p.y > 60 && p.x < view.bounds.width - 120 && p.y < view.bounds.height - 20
      }
      guard let index else {
        for y in stride(from: 80.0, to: view.bounds.height - 20, by: 23) {
          for x in stride(from: 30.0, to: view.bounds.width - 130, by: 29) {
            let p = CGPoint(x: x, y: y)
            let w = view.scene.camera.toWorld(p)
            let clear = layout.nodes.allSatisfy { hypot($0.x - w.x, $0.y - w.y) > 120 }
            if clear && view.scene.node(at: p, radius: 14) == nil { return p }
          }
        }
        return nil
      }
      let n = layout.nodes[index]
      let p = view.scene.camera.toScreen(CGPoint(x: n.x, y: n.y))
      return ok(p) && view.scene.node(at: p, radius: 14) == index ? p : nil
    }

    private static func click(
      _ view: GraphView, at p: CGPoint, window: NSWindow, clicks: Int = 1
    ) {
      for count in 1...clicks {
        mouse(.leftMouseDown, point: p, view: view, window: window, clicks: count)
        mouse(.leftMouseUp, point: p, view: view, window: window, clicks: count)
      }
    }

    private static func type(_ text: String, window: NSWindow) {
      for character in text { sendKey(String(character), code: 0, window: window) }
    }

    private static func line(_ editor: OutlineTextView, containing name: String) -> String {
      let ns = editor.string as NSString
      let range = ns.range(of: name)
      guard range.location != NSNotFound else { return "" }
      return ns.substring(with: ns.lineRange(for: range))
        .trimmingCharacters(in: .newlines)
    }

    private static func selectionChecks(
      _ store: MapStore, editor: OutlineTextView, view: GraphView, window: NSWindow
    ) async {
      let title = MapDocument.title(of: store.text) ?? "Smoke"
      replace(
        editor,
        with: title
          + "\nGroup\n- Parent\n\t- Child\n\t- Kid\n- Second /high\nOther\n- Distant [Second]\n")
      guard await frozen(store) else { return }
      view.fitAll()
      try? await Task.sleep(for: .milliseconds(450))

      // Click selects, highlights, fits the camera and selects the editor line.
      guard let parent = nodeIndex(view, "Parent"), let p = target(view, parent),
        let distant = nodeIndex(view, "Distant"), let group = nodeIndex(view, "Group")
      else { return check(false, "selection targets on screen") }
      let fitted = view.scene.camera
      click(view, at: p, window: window)
      check(view.selection == parent && store.detail?.name == "Parent", "click selects a node")
      check(window.firstResponder === view && store.graphFocused, "click focuses the graph")
      check(
        view.scene.debugIsLit(group) && view.scene.debugIsLit(nodeIndex(view, "Kid") ?? -1)
          && !view.scene.debugIsLit(distant) && view.scene.debugOpacity(distant) < 0.35
          && !view.scene.debugLitEdgesEmpty,
        "highlight lights ancestors and subtree, dims the rest")
      let parentRange = store.model.nodes[parent].sourceRange
      check(editor.selectedRange() == parentRange, "click selects the editor line")
      let expected = Camera.fit(
        view.scene.selectionBounds ?? .null, in: view.bounds.size, padding: 50)
      check(
        view.scene.camera != fitted && view.scene.camera == expected,
        "click animates the camera to the branch, once (no editor feedback)")
      try? await Task.sleep(for: .milliseconds(450))

      // The editor cursor highlights without a camera move.
      let still = view.scene.camera
      editor.setSelectedRange(
        NSRange(location: store.model.nodes[distant].sourceRange.location + 3, length: 0))
      check(view.selection == distant && store.detail?.name == "Distant", "editor cursor selects")
      check(
        view.scene.camera == still && view.scene.visibleCamera == still,
        "editor cursor doesn't move the camera")
      check(
        view.scene.debugIsLit(nodeIndex(view, "Other") ?? -1)
          && view.scene.debugOpacity(parent) < 1,
        "editor cursor highlights the branch")

      // Esc clears.
      store.focusGraph()
      sendKey("\u{1b}", code: 53, window: window)
      check(view.selection == nil && store.detail == nil, "Esc clears the selection")
      check(view.scene.debugOpacity(distant) == 1, "clearing restores full opacity")

      // Real key routing: with the editor focused, Return is a text Return even with a selection.
      store.focusEditor()
      editor.setSelectedRange(
        NSRange(location: NSMaxRange(store.model.nodes[distant].sourceRange), length: 0))
      let typed = editor.string
      await endEvent()
      if let event = key("\r", code: 36, window: window) { NSApp.sendEvent(event) }
      check(
        editor.string != typed && !view.isNaming,
        "editor keeps Return while it has focus (app routing)")
      await endEvent()
      editor.undoManager?.undo()
      check(editor.string == typed, "editor Return undone\(textDiff(typed, editor.string))")
      guard await current(store, "graph current after editor Return") else { return }

      // Return adds a sibling after the branch, typed inline.
      view.select(parent, camera: false)
      store.graphSelected(parent)
      store.focusGraph()
      sendKey("\r", code: 36, window: window)
      check(view.isNaming && view.debugNamingText == "", "Return starts naming a new task")
      check(view.scene.debugGhostVisible, "new node's dot shows while naming")
      type("Fresh", window: window)
      sendKey("\r", code: 36, window: window)
      check(
        editor.string.contains("\t- Kid\n- Fresh\n- Second"), "Return adds a task after the branch")
      guard await current(store, "Return parse shown"),
        let fresh = nodeIndex(view, "Fresh")
      else { return }
      check(view.selection == fresh && !view.scene.debugGhostVisible, "new task is selected")
      check(window.firstResponder === view, "graph keeps focus after naming")

      // Tab adds the last child.
      guard let second = nodeIndex(view, "Second") else { return }
      view.select(second, camera: false)
      store.graphSelected(second)
      sendKey("\t", code: 48, window: window)
      type("Sub", window: window)
      sendKey("\r", code: 36, window: window)
      check(editor.string.contains("- Second /high\n\t- Sub\n"), "Tab adds a subtask")
      guard await current(store, "Tab parse shown") else { return }
      check(view.selection == nodeIndex(view, "Sub"), "new subtask is selected")

      // Esc while naming an empty new node removes it.
      let beforeEmpty = editor.string
      sendKey("\r", code: 36, window: window)
      check(view.isNaming, "Return starts another new node")
      sendKey("\u{1b}", code: 53, window: window)
      check(
        !view.isNaming && editor.string == beforeEmpty && !view.scene.debugGhostVisible,
        "Esc on an empty new node removes it")

      // Double-click a label renames it, keeping its metadata.
      view.select(nil, camera: false)
      view.fitAll()  // the camera may still frame the last selection, without "Distant"
      try? await Task.sleep(for: .milliseconds(450))
      guard let d = nodeIndex(view, "Distant"), let dp = target(view, d) else {
        return check(false, "rename target on screen")
      }
      click(view, at: dp, window: window, clicks: 2)
      check(view.debugNamingText == "Distant", "double-click starts a rename with the name")
      try? await Task.sleep(for: .milliseconds(450))
      type("Faraway", window: window)
      sendKey("\r", code: 36, window: window)
      check(line(editor, containing: "Faraway") == "- Faraway [Second]", "rename keeps the link")
      guard await current(store, "rename parse shown") else { return }

      // Double-click empty canvas adds a group at that spot.
      view.select(nil, camera: true)
      view.fitAll()
      try? await Task.sleep(for: .milliseconds(450))
      guard let empty = target(view, nil) else { return check(false, "empty canvas on screen") }
      let spot = view.scene.camera.toWorld(empty)
      click(view, at: empty, window: window, clicks: 2)
      check(view.isNaming && view.scene.debugGhostVisible, "double-click canvas starts a group")
      type("Fresh group", window: window)
      sendKey("\r", code: 36, window: window)
      check(editor.string.hasSuffix("- Faraway [Second]\nFresh group\n"), "group appended")
      guard await frozen(store), let made = nodeIndex(view, "Fresh group"),
        let layout = view.scene.layout
      else { return }
      check(
        hypot(layout.nodes[made].x - spot.x, layout.nodes[made].y - spot.y) < 0.5,
        "new group sits where the canvas was double-clicked")

      // Delete removes the branch, selects the parent, and ⌘Z restores the exact text.
      guard let parentNow = nodeIndex(view, "Parent") else { return }
      view.select(parentNow, camera: false)
      store.graphSelected(parentNow)
      store.focusGraph()
      let beforeDelete = editor.string
      await endEvent()
      sendKey("\u{7f}", code: 51, window: window)
      check(
        !editor.string.contains("Parent") && !editor.string.contains("Child")
          && !editor.string.contains("Kid"), "Delete removes the node and its subtasks")
      guard await current(store, "delete parse shown") else { return }
      check(view.selection == nodeIndex(view, "Group"), "Delete selects the parent")
      await systemMenu("undo:", name: "Undo after Delete")
      check(editor.string == beforeDelete, "⌘Z restores the exact text")
      check(store.text == editor.string, "undo reaches the store (saved and re-parsed)")
      guard await current(store, "undo parse shown") else { return }

      // ⌘1–4 and ⌘0 with the graph focused write, replace and clear the selected node's tag.
      guard let far = nodeIndex(view, "Faraway") else { return }
      view.select(far, camera: false)
      store.graphSelected(far)
      store.focusGraph()
      for (command, expected) in [
        (AppCommand.priorityHigh, "- Faraway [Second] /high"),
        (.priorityMedium, "- Faraway [Second] /medium"),
        (.priorityLow, "- Faraway [Second] /low"),
        (.priorityChill, "- Faraway [Second] /chill"), (.priorityNone, "- Faraway [Second]"),
      ] {
        menu(command, name: "graph priority \(command.title) ⌘")
        let found = line(editor, containing: "Faraway")
        check(found == expected, "\(command.title) writes \(expected) (found \(found))")
        guard await current(store, "priority parse shown") else { return }
      }

      // The detail panel's done checkbox toggles [x].
      guard let fresh2 = nodeIndex(view, "Fresh") else { return }
      view.select(fresh2, camera: false)
      store.graphSelected(fresh2)
      check(
        store.detail?.kind == .task(due: nil, priority: nil, done: false, leaf: true),
        "detail shows an open leaf task")
      store.toggleDone(fresh2)
      check(editor.string.contains("- [x] Fresh\n"), "done checkbox writes [x]")
      guard await current(store, "done parse shown") else { return }
      check(
        store.detail?.kind == .task(due: nil, priority: nil, done: true, leaf: true),
        "detail shows done")
      store.toggleDone(fresh2)
      check(editor.string.contains("\n- Fresh\n"), "done checkbox clears [x]")
      guard await current(store, "undone parse shown") else { return }

      // A linked name selects that node, with a camera move and the editor line.
      guard let secondNow = nodeIndex(view, "Second") else { return }
      view.select(secondNow, camera: false)
      store.graphSelected(secondNow)
      guard let linked = store.detail?.linked.first else {
        return check(false, "detail lists linked names")
      }
      check(linked.name == "Faraway", "linked to lists the cross-linked node")
      let beforeLink = view.scene.camera
      store.selectLinked(linked.index)
      check(
        view.selection == linked.index && view.scene.camera != beforeLink
          && editor.selectedRange() == store.model.nodes[linked.index].sourceRange,
        "linked name selects with camera move")
      try? await Task.sleep(for: .milliseconds(450))

      // Arrow keys move the selection: ↑ parent, ↓ first child, ← → siblings.
      guard let child = nodeIndex(view, "Child"), let kid = nodeIndex(view, "Kid"),
        let parentAgain = nodeIndex(view, "Parent")
      else { return }
      view.select(child, camera: false)
      store.graphSelected(child)
      store.focusGraph()
      for (code, characters, expected, name) in [
        (UInt16(126), "\u{f700}", parentAgain, "↑ parent"),
        (125, "\u{f701}", child, "↓ first child"),
        (124, "\u{f703}", kid, "→ next sibling"),
        (123, "\u{f702}", child, "← previous sibling"),
      ] {
        let camera = view.scene.camera
        sendKey(characters, code: code, window: window)
        check(
          view.selection == expected && view.scene.camera != camera
            && editor.selectedRange() == store.model.nodes[expected].sourceRange,
          "arrow \(name)")
      }
      try? await Task.sleep(for: .milliseconds(450))

      // Right-click menus.
      if let cp = target(view, child),
        let event = mouseEvent(.rightMouseDown, point: cp, view: view, window: window),
        let menu = view.menu(for: event)
      {
        let titles = menu.items.map(\.title)
        let priorities = menu.items.first { $0.title == "Priority" }?.submenu?.items.map(\.title)
        check(
          ["Add Task", "Add Subtask", "Rename", "Mark Done", "Priority", "Delete"].allSatisfy(
            titles.contains) && priorities == ["High", "Medium", "Low", "Chill", "None"],
          "node right-click menu items: \(titles)")
      } else {
        check(false, "node right-click menu")
      }
      if let ep = target(view, nil),
        let event = mouseEvent(.rightMouseDown, point: ep, view: view, window: window)
      {
        check(view.menu(for: event)?.items.map(\.title) == ["New Group"], "canvas right-click menu")
      }

      // Menu items exist with their shortcuts (graph focused, with a selection).
      view.select(child, camera: false)
      store.graphSelected(child)
      store.focusGraph()
      for command in [
        AppCommand.selectParent, .selectFirstChild, .selectNextSibling, .selectPreviousSibling,
        .clearSelection,
      ] {
        menu(command)
      }
      view.select(child, camera: false)
      store.graphSelected(child)
      store.focusEditor()
      check(
        AppCommand.addTask.isDisabled(store) && AppCommand.deleteNode.isDisabled(store),
        "graph key commands are disabled while the editor has focus")

      // A map switch clears the selection.
      view.select(child, camera: false)
      store.graphSelected(child)
      let map = store.currentURL
      store.switchMap(by: 1)
      guard
        await wait("switch for selection", until: { !store.isSwitching && store.currentURL != map })
      else { return }
      check(view.selection == nil && store.detail == nil, "map switch clears the selection")
      store.switchMap(map!)
      _ = await wait(
        "switch back after selection", until: { !store.isSwitching && store.currentURL == map })
      _ = await frozen(store)
    }

    // MARK: Settings, forces panel, fonts and shortcuts (roadmap 4)

    /// For failure messages: where two texts first differ, escaped.
    private static func textDiff(_ expected: String, _ found: String) -> String {
      guard expected != found else { return "" }
      let prefix = zip(expected, found).prefix { $0 == $1 }.count
      func near(_ text: String) -> String {
        String(text.dropFirst(max(0, prefix - 12)).prefix(40)).debugDescription
      }
      return " (expected \(near(expected)), found \(near(found)))"
    }

    private static func pins(_ view: GraphView) -> [String: LayoutPoint] {
      view.displayedSimulation?.pins ?? [:]
    }

    private static func settingsChecks(
      _ store: MapStore, editor: OutlineTextView, view: GraphView, window: NSWindow
    ) async {
      defer { store.preferences = Preferences() }
      let title = MapDocument.title(of: store.text) ?? "Smoke"
      replace(
        editor,
        with: title
          + "\nGroup\n- Parent\n\t- Child\n\t- Kid\n- Second /high\nOther\n- Distant [Second]\n- Near\n"
      )
      guard await frozen(store) else { return }
      view.fitAll()
      try? await Task.sleep(for: .milliseconds(450))

      // ⌘1–4 and ⌘0 in the editor: the current or selected bullet lines.
      store.focusEditor()
      let ns = editor.string as NSString
      let start = ns.range(of: "Child").location
      editor.setSelectedRange(
        NSRange(location: start, length: NSMaxRange(ns.range(of: "Kid")) - start))
      menu(.priorityMedium, name: "editor priority Medium ⌘2")
      check(
        line(editor, containing: "Child") == "\t- Child /medium"
          && line(editor, containing: "Kid") == "\t- Kid /medium",
        "⌘2 sets the selected bullet lines' priority")
      select("Second", in: editor)
      menu(.priorityChill, name: "editor priority Chill ⌘4")
      check(
        line(editor, containing: "Second") == "- Second /chill",
        "⌘4 replaces the tag on the cursor line")
      for command in [AppCommand.priorityHigh, .priorityLow] {
        menu(command, name: "editor priority \(command.title)")
      }
      check(line(editor, containing: "Second") == "- Second /low", "⌘1 and ⌘3 in the editor")
      menu(.priorityNone, name: "editor priority None ⌘0")
      check(line(editor, containing: "Second") == "- Second", "⌘0 clears the cursor line's tag")
      editor.setSelectedRange(
        NSRange(location: start, length: NSMaxRange(ns.range(of: "Kid")) - start))
      menu(.priorityNone, name: "editor priority None on lines")
      check(!editor.string.contains("/medium"), "⌘0 clears the selected lines")
      guard await frozen(store) else { return }

      // ⌥⌘F shows and hides the floating panel (5 sliders) in the main window.
      check(!DebugControls.panelVisible, "forces panel hidden by default")
      menu(.toggleForcesPanel, name: "Forces Panel ⌥⌘F")
      _ = await wait("forces panel shows") {
        store.preferences.showForcesPanel && DebugControls.panelVisible
          && DebugControls.shown.keys.filter { $0.hasPrefix("panel ") }.count == 5
      }
      menu(.toggleForcesPanel, name: "Forces Panel ⌥⌘F again")
      _ = await wait("forces panel hides") {
        !store.preferences.showForcesPanel && !DebugControls.panelVisible
      }
      store.preferences.showForcesPanel = true
      _ = await wait("forces panel back for the next checks") { DebugControls.panelVisible }
      guard await frozen(store) else { return }
      displayLinkIdle()

      // A dropped node is pinned; force changes reshuffle once, after the slider stops, keeping it.
      guard
        let layout = view.scene.layout,
        let near = ([nodeIndex(view, "Near")].compactMap { $0 } + Array(layout.nodes.indices))
          .first(where: { layout.model.nodes[$0].children.isEmpty && target(view, $0) != nil }),
        let p = target(view, near)
      else { return check(false, "pin target on screen") }
      mouse(.leftMouseDown, point: p, view: view, window: window)
      mouse(.leftMouseDragged, point: CGPoint(x: p.x + 30, y: p.y + 20), view: view, window: window)
      mouse(.leftMouseUp, point: CGPoint(x: p.x + 30, y: p.y + 20), view: view, window: window)
      guard await frozen(store), !pins(view).isEmpty else {
        return check(false, "drag pins a node")
      }
      let pinned = pins(view)
      let reshuffles = store.debugReshuffles
      let seed = view.scene.layout?.seed
      for repel in stride(from: 500.0, through: 700, by: 50) {
        store.preferences.forces.repel = repel  // a slider drag: one change per frame or so
        try? await Task.sleep(for: .milliseconds(40))
      }
      check(store.debugReshuffles == reshuffles, "no reshuffle while the slider moves")
      _ = await wait("one reshuffle after the slider stops", seconds: 3) {
        store.debugReshuffles == reshuffles + 1
      }
      // The model is unchanged, so wait for the new layout itself before waiting for its settle.
      _ = await wait("the force change used a new seed") { view.scene.layout?.seed != seed }
      guard await frozen(store), let shuffled = view.scene.layout else { return }
      try? await Task.sleep(for: .milliseconds(300))
      check(store.debugReshuffles == reshuffles + 1, "exactly one debounced reshuffle")
      let key = pinned.keys.first!
      let index = shuffled.model.nodes.firstIndex { $0.pathKey == key }
      check(
        pins(view) == pinned
          && index.map { LayoutPoint(x: shuffled.nodes[$0].x, y: shuffled.nodes[$0].y) }
            == pinned[key],
        "the auto reshuffle keeps pinned nodes in place")

      // Label size: bigger labels, same seed and positions; only new overlaps move.
      guard let sized = view.scene.layout else { return }
      store.preferences.labelSize = 1.6
      let group = sized.model.nodes.firstIndex { $0.depth == 0 } ?? 0
      _ = await wait("label size resizes labels") {
        view.scene.layout.map { abs($0.nodes[group].fontSize - 16 * 1.6) < 1e-9 } == true
      }
      guard await frozen(store), let big = view.scene.layout else { return }
      check(
        big.seed == sized.seed && store.debugReshuffles == reshuffles + 1,
        "label size doesn't reshuffle")
      fixedCheck(sized, view: view, name: "label size push-apart")
      menu(.smallerLabels, name: "Smaller Labels ⌥⌘-")
      check(abs(store.preferences.labelSize - 1.55) < 1e-9, "⌥⌘- steps the label size down")
      menu(.biggerLabels, name: "Bigger Labels ⌥⌘=")
      check(abs(store.preferences.labelSize - 1.6) < 1e-9, "⌥⌘= steps the label size up")
      store.preferences.labelSize = 1
      _ = await wait("label size back to 1") {
        view.scene.layout.map { abs($0.nodes[group].fontSize - 16) < 1e-9 } == true
      }
      guard await frozen(store), let small = view.scene.layout else { return }

      // Font: re-measured labels, local push-apart, no reshuffle.
      for family in ["Quicksand", "Outfit", GraphFonts.systemRounded] {
        store.preferences.labelFont = family
        _ = await wait("font \(family) shown") { view.scene.labelFamily == family }
        guard await frozen(store), let shown = view.scene.layout else { return }
        check(
          view.scene.labelFamily == family && shown.seed == small.seed
            && store.debugReshuffles == reshuffles + 1, "font \(family) applied without reshuffle")
      }
      check(
        view.scene.layout?.nodes.map(\.halfWidth) != small.nodes.map(\.halfWidth),
        "a font change re-measures label boxes")
      store.preferences.labelFont = GraphFonts.defaultFamily
      _ = await wait("default font back") { view.scene.labelFamily == GraphFonts.defaultFamily }
      guard await frozen(store) else { return }

      // ⌘, opens Settings; it and the panel edit the same value in both directions.
      menu(.settings, name: "Settings ⌘,")
      var settings: NSWindow?
      _ = await wait("Settings window opens") {
        settings = NSApp.windows.first { $0 !== window && $0.isVisible }
        return settings != nil && DebugControls.settingsVisible
          && DebugControls.sliders["settings Link distance"] != nil
      }
      guard let settings, let panel = DebugControls.sliders["panel link distance"],
        let other = DebugControls.sliders["settings Link distance"]
      else { return check(false, "link distance sliders in the panel and Settings") }
      func shown(_ key: String) -> Double? { DebugControls.shown[key] }
      store.preferences.forces.linkDistance = 150
      _ = await wait("a store change shows in the panel and Settings") {
        shown("panel link distance") == 150 && shown("settings Link distance") == 150
      }
      panel.wrappedValue = 100  // what the panel's slider does when dragged
      _ = await wait("the panel slider updates the store and Settings") {
        store.preferences.forces.linkDistance == 100 && shown("settings Link distance") == 100
      }
      other.wrappedValue = 60
      _ = await wait("the Settings slider updates the store and the panel") {
        store.preferences.forces.linkDistance == 60 && shown("panel link distance") == 60
      }
      settings.close()
      window.makeKeyAndOrderFront(nil)
      guard await frozen(store) else { return }

      // Animate settle off: a reshuffle shows the frozen result with no display link.
      store.preferences.animateSettle = false
      let previousSeed = view.scene.layout?.seed
      var animated = false
      menu(.reshuffle, name: "Reshuffle with animate off")
      _ = await wait("animate-off reshuffle shown") {
        animated = animated || view.isAnimating || GraphView.debugLiveDisplayLinks > 0
        return view.scene.layout?.seed != previousSeed
          && view.displayedSimulation?.isFrozen == true
      }
      try? await Task.sleep(for: .milliseconds(200))
      check(!animated && !view.isAnimating, "animate off computes the layout without animating")
      store.preferences.animateSettle = true
      guard await frozen(store) else { return }
    }

    /// The two fixes from the 3b review.
    private static func reviewFixChecks(
      _ store: MapStore, editor: OutlineTextView, view: GraphView, window: NSWindow
    ) async {
      guard await frozen(store), let map = store.currentURL else { return }
      // 1. Editor undo and redo reach the store, the file and a reopened map.
      func reopen(_ name: String) async -> Bool {
        guard await wait("\(name): autosaved", until: { !store.hasUnsavedEdits }) else {
          return false
        }
        store.switchMap(by: 1)
        guard
          await wait(
            "\(name): switched away", until: { !store.isSwitching && store.currentURL != map })
        else { return false }
        store.switchMap(map)
        return await wait("\(name): switched back") {
          !store.isSwitching && store.currentURL == map
        }
      }
      store.focusEditor()
      let before = editor.string
      editor.setSelectedRange(NSRange(location: (before as NSString).length, length: 0))
      await endEvent()
      if !before.hasSuffix("\n") { sendKey("\r", code: 36, window: window) }
      for character in "- undo me" { sendKey(String(character), code: 0, window: window) }
      check(
        editor.string.contains("- undo me") && store.text == editor.string, "typed line in store")
      for _ in 0..<4 where editor.string != before {
        await systemMenu("undo:", name: "Undo typed line")
      }
      check(
        editor.string == before && store.text == before,
        "⌘Z restores the pre-typing text in the store\(textDiff(before, editor.string))\(textDiff(before, store.text))"
      )
      guard await reopen("after undo") else { return }
      check(store.text == before, "undone text survives autosave and a map switch")
      editor.setSelectedRange(NSRange(location: 0, length: 0))
      // The reopened map has a fresh undo stack, so type and undo again before redoing.
      store.focusEditor()
      editor.setSelectedRange(NSRange(location: (editor.string as NSString).length, length: 0))
      await endEvent()
      for character in "- redo me" { sendKey(String(character), code: 0, window: window) }
      let typed = editor.string
      for _ in 0..<4 where editor.string != before {
        await systemMenu("undo:", name: "Undo before redo")
      }
      for _ in 0..<4 where editor.string != typed {
        await systemMenu("redo:", name: "Redo typed line")
      }
      check(editor.string == typed && store.text == typed, "⇧⌘Z restores the line in the store")
      guard await reopen("after redo") else { return }
      check(store.text == typed, "redone text survives autosave and a map switch")
      replace(editor, with: before)
      guard await frozen(store) else { return }

      // 2. A refused graph edit says so in the detail panel instead of failing silently.
      guard let index = nodeIndex(view, "Second") else { return check(false, "refusal target") }
      view.select(index, camera: false)
      store.graphSelected(index)
      editor.setSelectedRange(NSRange(location: (editor.string as NSString).length, length: 0))
      await endEvent()
      editor.insertText("x", replacementRange: editor.selectedRange())  // the parse is now stale
      let refused = !store.applyGraphEdit(.priority(index, .high))
      check(
        refused && store.notice == "couldn't apply that edit, try again",
        "refused edit shows a notice")
      check(!editor.string.contains("/high"), "a refused edit changes nothing")
      _ = await wait("the notice clears by itself", seconds: 5) { store.notice == nil }
      await endEvent()
      editor.undoManager?.undo()
      guard await frozen(store) else { return }
    }

    /// Main-thread time to apply a selection on the 500-node fixture.
    private static func selectionTiming(_ store: MapStore, view: GraphView) {
      guard let model = view.scene.layout?.model,
        let group = model.nodes.firstIndex(where: { $0.depth == 0 && $0.children.count > 3 }),
        let leaf = model.nodes.firstIndex(where: { $0.depth > 0 && $0.children.isEmpty })
      else { return }
      for (name, index) in [("group", Optional(group)), ("leaf", leaf), ("clear", nil)] {
        var samples: [Double] = []
        for _ in 0..<5 {
          view.select(index == nil ? group : nil, camera: false)
          let start = ContinuousClock.now
          view.select(index, camera: true)
          store.graphSelected(index)
          let d = start.duration(to: .now).components
          samples.append(Double(d.seconds) * 1000 + Double(d.attoseconds) / 1e15)
        }
        log.notice(
          "selection apply nodes=500 kind=\(name, privacy: .public) median-ms=\(samples.sorted()[2], privacy: .public) worst-ms=\(samples.max() ?? 0, privacy: .public)"
        )
        check(samples.sorted()[2] < 8, "500-node \(name) selection applies in under 8 ms")
      }
      view.select(nil, camera: false)
      store.graphSelected(nil)
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

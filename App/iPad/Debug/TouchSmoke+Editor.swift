#if DEBUG
  import MindmapCore
  import MindmapGraph
  import UIKit

  /// Roadmap step i3: the editor's outline keys and colors, the keyboard bar, the hardware
  /// shortcuts, editor↔graph sync and the narrow and wide layouts.
  extension TouchSmoke {
    private static func range(_ editor: OutlineTextView, _ text: String) -> NSRange {
      (editor.string as NSString).range(of: text)
    }

    /// Puts the cursor (or a selection) on `text`, as a tap in the editor would.
    private static func place(_ editor: OutlineTextView, on text: String, at end: Bool = false) {
      let found = range(editor, text)
      guard found.location != NSNotFound else { return check(false, "editor contains \(text)") }
      editor.selectedRange = NSRange(location: end ? NSMaxRange(found) : found.location, length: 0)
      editor.textViewDidChangeSelection(editor)
    }

    /// Back to `text` in one editor change (itself undoable, like any edit).
    private static func restore(_ editor: OutlineTextView, _ text: String) {
      editor.perform(
        TextChange(
          range: NSRange(location: 0, length: (editor.string as NSString).length),
          replacement: text, selection: NSRange(location: 0, length: 0)))
    }

    private static func bar(_ editor: OutlineTextView, _ path: String...) {
      var level = editor.debugBarItems
      var found: KeyboardBarItem?
      for title in path {
        found = level.first { $0.title == title }
        level = found?.children ?? []
      }
      guard let action = found?.action else {
        return check(false, "keyboard bar has \(path.joined(separator: " ▸ "))")
      }
      action()
    }

    // MARK: Editor

    static func editorChecks(_ store: PadMapStore, _ view: GraphView) async {
      guard await frozen(store, view), let editor = store.editorView else {
        return check(false, "editor exists")
      }
      store.focusEditor()
      await pause(300)
      check(editor.isFirstResponder, "the editor takes the keyboard")
      check(editor.string == store.text, "the editor shows the store's text")
      check(editor.textLayoutManager != nil, "the editor uses TextKit 2")
      if #available(iOS 18.0, *) {
        check(editor.writingToolsBehavior == .none, "Writing Tools are off")
      }
      let before = store.text
      check(editor.debugColor(at: range(editor, "/high").location) == 0xc98589, "/high colored")
      check(editor.debugColor(at: range(editor, "[Distant]").location) == 0x8f78e8, "links colored")
      check(editor.debugColor(at: range(editor, "- Parent").location) == 0x48484a, "bullets dimmed")
      // Return, Tab and ⇧Tab follow the outline rules.
      place(editor, on: "- Second /high", at: true)
      editor.debugType("\n")
      check(editor.string.contains("- Second /high\n- \n"), "Return continues the bullet")
      editor.debugType("\t")
      check(editor.string.contains("- Second /high\n\t- \n"), "Tab indents the new bullet")
      editor.debugBacktab()
      check(editor.string.contains("- Second /high\n- \n"), "⇧Tab outdents it")
      editor.debugType("Typed task")
      check(store.text == editor.string, "typing reaches the store")
      guard await frozen(store, view) else { return }
      check(index(view, "Typed task") != nil, "a typed task appears in the graph")
      restore(editor, before)
      await frozen(store, view)
      // Unresolved links get a dotted underline once parsed; done lines are struck through.
      place(editor, on: "- Linker [Distant]", at: true)
      editor.debugType("\n")
      editor.debugType("Missing [nowhere]")
      await frozen(store, view)
      await wait("unresolved link is dotted") {
        editor.debugDotted(at: range(editor, "[nowhere]").location)
      }
      restore(editor, before)
      await frozen(store, view)
      // The keyboard bar.
      check(
        editor.inputAccessoryView != nil
          && editor.debugBarItems.map(\.title) == [
            "Indent", "Outdent", "Toggle Done", "Priority", "Insert Link", "Move Up", "Move Down",
            "Hide Keyboard",
          ], "keyboard bar: \(editor.debugBarItems.map(\.title).joined(separator: ", "))")
      place(editor, on: "Second")
      bar(editor, "Indent")
      check(editor.string.contains("\t- Second /high"), "bar Indent")
      bar(editor, "Outdent")
      check(editor.string == before, "bar Outdent")
      bar(editor, "Toggle Done")
      check(editor.string.contains("- [x] Second /high"), "bar Toggle Done")
      await pause(100)
      check(
        editor.debugStruck(at: range(editor, "[x] Second").location), "done line struck through")
      bar(editor, "Toggle Done")
      check(editor.string == before, "bar Toggle Done again reopens it")
      bar(editor, "Priority", "Medium")
      check(editor.string.contains("- Second /medium\n"), "bar Priority ▸ Medium")
      bar(editor, "Priority", "None")
      check(editor.string.contains("- Second\n"), "bar Priority ▸ None")
      bar(editor, "Priority", "High")
      check(editor.string == before, "bar Priority ▸ High")
      place(editor, on: "- Second /high", at: true)
      bar(editor, "Insert Link")
      let link = range(editor, "/high[]")
      check(
        link.location != NSNotFound && editor.selectedRange.location == NSMaxRange(link) - 1,
        "bar Insert Link puts the cursor inside []")
      restore(editor, before)
      place(editor, on: "Second")
      bar(editor, "Move Down")
      check(editor.string.contains("- Linker [Distant]\n- Second /high\n"), "bar Move Down")
      bar(editor, "Move Up")
      check(editor.string == before, "bar Move Up")
      bar(editor, "Hide Keyboard")
      await pause(300)
      check(!editor.isFirstResponder, "bar Hide Keyboard")
      await frozen(store, view)
      // Graph → editor: a tap selects the node's line. Editor → graph: the cursor highlights its
      // node without moving the camera.
      view.fitAll()
      await cameraIdle(view)
      guard let parent = index(view, "Parent"), let p = target(view, parent) else {
        return check(false, "sync target")
      }
      view.debugTap(at: p)
      check(
        editor.selectedRange == store.model.nodes[parent].sourceRange,
        "tapping a node selects its line")
      await cameraIdle(view)
      await pause()
      let camera = view.scene.camera
      place(editor, on: "Far leaf")
      check(
        view.selection == index(view, "Far leaf") && !view.scene.debugCameraAnimating
          && view.scene.camera == camera, "the cursor highlights its node, camera stays")
      // Graph edits share the editor's undo stack.
      guard let child = index(view, "Child"), let c = target(view, child) else { return }
      perform(view.menuItems(at: c), "Mark Done", name: "Mark Done")
      check(editor.string.contains("\t- [x] Child\n"), "a graph edit changes the editor's text")
      await frozen(store, view)
      check(store.activeUndoManager === editor.undoManager, "one undo stack for text and graph")
      editor.undoManager?.undo()
      check(
        editor.string == before && store.text == before, "the editor's undo reverts a graph edit")
      await frozen(store, view)
      view.clearSelection()
      await cameraIdle(view)
    }

    // MARK: Hardware keyboard

    static func shortcutChecks(_ store: PadMapStore, _ view: GraphView) async {
      guard await frozen(store, view), let editor = store.editorView else { return }
      let titles = Set(AppCommand.iPad.map(\.title))
      let expected = [
        "New Map", "Next Map", "Previous Map", "Toggle Done", "Indent", "Outdent", "Move Up",
        "Move Down", "Zoom In", "Zoom Out", "Fit All", "Reshuffle", "Focus Editor", "Focus Graph",
        "Clear Selection", "High", "Medium", "Low", "Chill", "None",
      ]
      check(expected.allSatisfy(titles.contains), "the iPad menus carry the Mac's commands")
      let before = store.text
      func run(_ command: AppCommand) {
        check(!command.isDisabled(store), "\(command.title) enabled")
        command.perform(store)
      }
      run(.focusEditor)
      await pause(300)
      check(editor.isFirstResponder && !store.graphFocused, "⌥⌘1 focuses the editor")
      place(editor, on: "Second")
      check(AppCommand.clearSelection.isDisabled(store), "Esc stays with the editor")
      run(.toggleDone)
      check(editor.string.contains("- [x] Second"), "⇧⌘X toggles done in the editor")
      run(.toggleDone)
      run(.priorityLow)
      check(editor.string.contains("- Second /low\n"), "⌘3 sets low priority")
      run(.priorityHigh)
      check(editor.string == before, "⌘1 sets high priority")
      run(.indent)
      check(editor.string.contains("\t- Second /high"), "⌘] indents")
      run(.outdent)
      run(.moveDown)
      check(editor.string.contains("- Linker [Distant]\n- Second /high\n"), "⌃⌘↓ moves down")
      run(.moveUp)
      check(editor.string == before, "⌃⌘↑ moves back up")
      await frozen(store, view)
      run(.focusGraph)
      await pause(300)
      check(view.isFirstResponder && store.graphFocused, "⌥⌘2 focuses the graph")
      guard let parent = index(view, "Parent"), let p = target(view, parent) else { return }
      view.debugTap(at: p)
      await cameraIdle(view)
      run(.selectFirstChild)
      check(view.selection == index(view, "Child"), "↓ selects the first child")
      run(.selectParent)
      check(view.selection == parent, "↑ selects the parent")
      run(.clearSelection)
      check(view.selection == nil, "Esc clears the selection")
      await cameraIdle(view)
      let zoom = view.scene.camera.zoom
      run(.zoomIn)
      await cameraIdle(view)
      check(view.scene.camera.zoom > zoom, "⌘= zooms in")
      run(.fitAll)
      await cameraIdle(view)
      check(!AppCommand.nextMap.isDisabled(store), "⇧⌘] can switch maps")
    }

    // MARK: Layout

    static func layoutChecks(_ store: PadMapStore, _ view: GraphView) async {
      guard await frozen(store, view), let editor = store.editorView else { return }
      store.layout.forcedWide = true
      await pause(600)
      check(
        store.layout.isWide && editor.bounds.width >= 300 && view.bounds.width >= 400
          && view.isOnScreen, "wide: editor and graph side by side")
      store.layout.forcedWide = false
      store.layout.pane = .map
      await pause(600)
      check(
        !store.layout.isWide && editor.bounds.width == 0 && view.isOnScreen,
        "narrow Map shows only the graph")
      view.fitAll()
      await cameraIdle(view)
      guard let child = index(view, "Child"), let c = target(view, child) else {
        return check(false, "narrow target")
      }
      let items = view.menuItems(at: c)
      check(item(items, "Edit Text") != nil, "narrow: the node menu offers Edit Text")
      perform(items, "Edit Text", name: "Edit Text")
      await pause(600)
      check(
        store.layout.pane == .text && editor.isFirstResponder
          && editor.selectedRange == store.model.nodes[child].sourceRange,
        "Edit Text jumps to the node's line in Text")
      check(
        !view.isOnScreen && editor.bounds.width > 0 && GraphView.debugLiveDisplayLinks == 0,
        "narrow Text hides the graph and runs no display link")
      store.layout.pane = .map
      await pause(600)
      check(view.isOnScreen && editor.bounds.width == 0, "back to Map")
      store.layout.forcedWide = true
      await pause(600)
      check(
        item(view.menuItems(at: target(view, child) ?? c), "Edit Text") == nil, "wide: no Edit Text"
      )
      view.clearSelection()
      await cameraIdle(view)
    }
  }
#endif

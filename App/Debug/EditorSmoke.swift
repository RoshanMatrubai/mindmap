#if DEBUG
  import AppKit
  import MindmapCore

  /// Opt-in native checks use a hidden test window and temp files, never real maps.
  @MainActor
  enum EditorSmoke {
    static func runIfRequested() {
      guard UserDefaults.standard.bool(forKey: "editor-smoke") else { return }
      let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 400, height: 400),
        styleMask: [.titled], backing: .buffered, defer: false)
      let editor = OutlineTextView(usingTextLayoutManager: true)
      editor.allowsUndo = true
      editor.isRichText = false
      window.contentView = editor
      let original = "Native test\nGroup\n- [x] Done /high\n\t- Child\n- Missing [[absent]]"
      let identity = UUID()
      editor.load(original, map: identity)
      precondition(editor.textLayoutManager != nil, "TextKit 2 must remain enabled")
      let ns = original as NSString
      let done = ns.range(of: "- [x] Done /high")
      precondition(
        editor.textStorage?.attribute(.strikethroughStyle, at: done.location, effectiveRange: nil)
          != nil)
      editor.setSelectedRange(NSRange(location: NSMaxRange(done), length: 0))
      editor.insertNewline(nil)
      precondition(
        editor.string.contains("Done /high\n- \n\t- Child"), "done Enter continues plain bullet")
      precondition(editor.undoManager?.canUndo == true, "native edit must register undo")
      editor.undoManager?.undo()
      precondition(editor.string == original, "Enter is one undo step")
      editor.undoManager?.redo()
      precondition(editor.string.contains("Done /high\n- \n"), "redo restores bullet")
      editor.undoManager?.undo()
      editor.setSelectedRange(NSRange(location: done.location + 3, length: 0))
      editor.insertTab(nil)
      precondition(editor.string.contains("\t- [x] Done"), "Tab works inside bullet")
      editor.undoManager?.undo()
      precondition(editor.string == original, "Tab is one undo step")
      editor.setSelectedRange(NSRange(location: done.location + 3, length: 0))
      editor.insertBacktab(nil)
      precondition(editor.string == original, "Shift Tab at root must leave text unchanged")
      let model = MapParser.parse(text: original, today: Date(), calendar: .current)
      editor.applyUnresolved(model.unresolvedLinks.map(\.sourceRange))
      let link = ns.range(of: "[[absent]]")
      let underline =
        editor.textStorage?.attribute(.underlineStyle, at: link.location, effectiveRange: nil)
        as? Int
      precondition(
        underline == NSUnderlineStyle.single.rawValue | NSUnderlineStyle.patternDot.rawValue)
      editor.setSelectedRange(NSRange(location: link.location, length: 0))
      editor.insertText("😀 ", replacementRange: editor.selectedRange())
      precondition(editor.string.contains("😀 [[absent]]"), "Unicode typing is preserved")
      precondition(editor.textLayoutManager != nil, "styling must not fall back to TextKit 1")
      log.notice(
        "native editor smoke passed: TextKit 2, highlighting, unresolved underline, Enter/Tab undo, Unicode"
      )
      Task {
        await fileChecks()
        await storeChecks()
      }
    }

    private static func storeChecks() async {
      guard let store = AppLifecycle.store else { preconditionFailure("missing app store") }
      do {
        try await Task.sleep(for: .milliseconds(1400))
        precondition(!store.isSwitching)
        guard let original = store.currentURL else { preconditionFailure("missing initial map") }
        let originalText = store.text
        store.newMap()
        try await Task.sleep(for: .milliseconds(200))
        precondition(store.currentURL != original && store.text == "untitled map\n")
        let title = "Smoke/: " + UUID().uuidString
        store.text = title + "\nGroup\n- [X] Done /HIGH\n"
        try await Task.sleep(for: .milliseconds(1300))
        precondition(store.model.title == title && store.model.nodeCount == 2)
        precondition(store.model.nodes.last?.done == true)
        precondition(!store.hasUnsavedEdits)
        guard let created = store.currentURL else { preconditionFailure("new map missing") }
        precondition(created.lastPathComponent.hasPrefix("Smoke "))
        let repository = MapRepository()
        let saved = try await repository.load(created)
        precondition(saved.text == store.text)
        _ = try await repository.save(title + "\nExternal\n- from disk\n", to: created)
        store.activated()
        try await Task.sleep(for: .milliseconds(200))
        precondition(store.text.contains("from disk"), "clean activation reloads external edit")
        store.text = title + "\nLocal\n- unsaved edit\n"
        _ = try await repository.save(title + "\nExternal\n- different disk text\n", to: created)
        store.activated()
        precondition(
          store.text.contains("unsaved edit"), "dirty activation must preserve local edits")
        let renamed = try await layoutChecks(store, created: created, title: title)
        store.switchMap(original)
        try await Task.sleep(for: .milliseconds(200))
        precondition(store.currentURL == original && store.text == originalText)
        try FileManager.default.removeItem(at: renamed)
        try FileManager.default.removeItem(at: LayoutSidecar.url(for: renamed))
        store.activated()
        log.notice(
          "native store smoke passed: new map, debounced save/rename/parse, live stats, map switch, clean/dirty activation reload, layout sidecar pins/rename/reshuffle"
        )
      } catch { fatalError("native store smoke failed: \(error)") }
    }

    /// Pins reach the sidecar, survive rebuilds and renames, and reshuffle clears them.
    private static func layoutChecks(_ store: MapStore, created: URL, title: String) async throws
      -> URL
    {
      try await Task.sleep(for: .milliseconds(1300))
      let key = "local/unsaved edit"
      let point = LayoutPoint(x: 321, y: -123)
      store.pin(key, at: point)
      try await Task.sleep(for: .milliseconds(800))
      precondition(LayoutSidecar.load(for: created)?.pins[key] == point, "pin saved to sidecar")
      store.text += "- more\n"
      try await Task.sleep(for: .milliseconds(1000))
      guard let layout = store.graph?.layout,
        let index = layout.model.nodes.firstIndex(where: { $0.pathKey == key })
      else { preconditionFailure("rebuilt layout missing") }
      precondition(
        layout.nodes[index].x == point.x && layout.nodes[index].y == point.y,
        "pinned node stays across rebuilds")
      store.text = "Renamed " + store.text
      try await Task.sleep(for: .milliseconds(2000))
      guard let renamed = store.currentURL, renamed != created else {
        preconditionFailure("map was not renamed")
      }
      precondition(LayoutSidecar.load(for: renamed)?.pins[key] == point, "sidecar follows rename")
      precondition(LayoutSidecar.load(for: created) == nil, "old sidecar is gone")
      let seed = LayoutSidecar.load(for: renamed)?.seed
      store.reshuffle()
      try await Task.sleep(for: .milliseconds(800))
      let shuffled = LayoutSidecar.load(for: renamed)
      precondition(
        shuffled?.pins.isEmpty == true && shuffled?.seed != seed, "reshuffle clears pins")
      return renamed
    }

    private static func fileChecks() async {
      let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
      do {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let repository = MapRepository()
        let first = try await repository.create(in: folder)
        let second = try await repository.create(in: folder)
        precondition(first != second)
        _ = try await repository.save("Trip/: Plan\n- task\n", to: first)
        let renamed = try await repository.rename(first, title: "Trip/: Plan")
        precondition(renamed.lastPathComponent == "Trip Plan.mindmap")
        let document = UUID()
        _ = try await repository.open(renamed, document: document)
        let moved = try await repository.rename(document: document, title: "Renamed")
        _ = try await repository.save("Trip/: Plan\n- task\n", document: document)
        precondition(
          !FileManager.default.fileExists(atPath: renamed.path),
          "save after rename must not recreate old filename")
        let loaded = try await repository.load(moved)
        precondition(loaded.text == "Trip/: Plan\n- task\n")
        try "Trip/: Plan\n- external edit\n".write(to: moved, atomically: true, encoding: .utf8)
        let changed = try await repository.changed(moved, since: loaded)
        precondition(changed)
        let maps = try await repository.list(folder)
        precondition(maps.count == 2)
        log.notice(
          "native repository smoke passed: new maps, title rename, save/load, external modification"
        )
      } catch { fatalError("native repository smoke failed: \(error)") }
    }
  }
#endif

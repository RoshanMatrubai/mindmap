#if DEBUG
  import MindmapCore
  import MindmapGraph
  import UIKit

  /// Roadmap step i4: the maps folder as another device would change it. Writes go through a
  /// separate file coordinator (as iCloud's would), never through the app's own repository.
  extension TouchSmoke {
    private static func externalWrite(_ text: String, to url: URL) -> Bool {
      var failure: NSError?
      var written = false
      NSFileCoordinator(filePresenter: nil).coordinate(
        writingItemAt: url, options: .forReplacing, error: &failure
      ) { url in
        written = (try? text.write(to: url, atomically: true, encoding: .utf8)) != nil
      }
      return failure == nil && written
    }

    private static func files(in folder: URL) -> [URL] {
      (try? FileManager.default.contentsOfDirectory(
        at: folder, includingPropertiesForKeys: nil, options: [])) ?? []
    }

    static func syncChecks(_ store: PadMapStore, _ view: GraphView) async {
      guard await frozen(store, view), let folder = store.folder, let url = store.currentURL else {
        return check(false, "sync checks need a map")
      }
      _ = await wait("autosave before sync checks") { !store.hasUnsavedEdits }
      check(
        NSFileCoordinator.filePresenters.contains { $0.presentedItemURL == folder },
        "the maps folder has a file presenter")
      let before = store.text
      // Another device edits the map while this one has no unsaved edits: reload in place,
      // keeping the selection and the camera.
      view.fitAll()
      await cameraIdle(view)
      guard let parent = index(view, "Parent") else { return check(false, "sync node") }
      view.select(parent, camera: false)
      store.graphSelected(parent)
      let camera = view.scene.camera
      let remote = before + "- Remote task\n"
      check(externalWrite(remote, to: url), "external write")
      await wait("a change from another device reloads the open map") { store.text == remote }
      guard await frozen(store, view) else { return }
      check(index(view, "Remote task") != nil, "the reloaded map shows the new task")
      await pause(300)
      check(
        view.selection == index(view, "Parent"),
        "reload keeps the selection (\(view.selection.map { store.model.nodes[$0].name } ?? "none"))"
      )
      check(view.scene.camera == camera, "reload keeps the camera")
      check(!store.hasUnsavedEdits, "a reload leaves nothing to save")
      // A change from another device while this one has unsaved edits: keep the open text, save
      // the other version as a visible conflict copy.
      let local = remote + "- Local task\n"
      let other = remote + "- Other device task\n"
      store.text = local
      check(externalWrite(other, to: url), "external write during unsaved edits")
      await wait("the other version is kept as a conflict copy", seconds: 20) {
        files(in: folder).contains { $0.lastPathComponent.contains("(conflict ") }
      }
      let copy = files(in: folder).first { $0.lastPathComponent.contains("(conflict ") }
      if let copy, let text = try? String(contentsOf: copy, encoding: .utf8) {
        check(
          text.hasSuffix("- Other device task\n") && text.contains("(conflict "),
          "the conflict copy holds the other text under its own title")
      }
      check(store.text == local, "the open text wins")
      await wait("the open text is saved over the disk version") {
        !store.hasUnsavedEdits
          && (try? String(contentsOf: url, encoding: .utf8)) == local
      }
      check(store.notice?.contains("kept the other version") == true, "the panel says so")
      await wait("the conflict copy is in the map list") {
        store.maps.contains { $0.title.contains("(conflict ") }
      }
      if let copy {
        try? FileManager.default.removeItem(at: copy)
        try? FileManager.default.removeItem(at: LayoutSidecar.url(for: copy))
      }
      // A map iCloud hasn't downloaded yet is listed by name.
      let placeholder = folder.appendingPathComponent(".Cloud only.mindmap.icloud")
      try? Data("placeholder".utf8).write(to: placeholder)
      await wait("a not yet downloaded map is listed") {
        store.maps.contains { $0.title == "Cloud only" && !$0.isDownloaded }
      }
      try? FileManager.default.removeItem(at: placeholder)
      // Reminders stay Mac-only: a rename never moves or creates a reminders sidecar here.
      let reminders = ReminderSidecar.url(for: url)
      try? Data("{}".utf8).write(to: reminders)
      let renamed = "Sync renamed " + UUID().uuidString.prefix(8)
      if let range = store.text.range(of: MapDocument.title(of: store.text) ?? "") {
        store.text.replaceSubrange(range, with: renamed)
      }
      await wait("title change renames the file", seconds: 20) {
        store.currentURL?.lastPathComponent == renamed + ".mindmap"
      }
      if let moved = store.currentURL {
        check(
          FileManager.default.fileExists(atPath: reminders.path)
            && !FileManager.default.fileExists(atPath: ReminderSidecar.url(for: moved).path),
          "the iPad never moves the reminders sidecar")
        check(
          FileManager.default.fileExists(atPath: LayoutSidecar.url(for: moved).path),
          "the layout sidecar follows the rename")
      }
      try? FileManager.default.removeItem(at: reminders)
      store.text = before
      await frozen(store, view)
      let title = MapDocument.title(of: before) ?? ""
      await wait("the map takes its title back", seconds: 20) {
        store.currentURL?.lastPathComponent == title + ".mindmap" && !store.hasUnsavedEdits
      }
    }
  }
#endif

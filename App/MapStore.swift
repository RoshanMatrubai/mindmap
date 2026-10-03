import AppKit
import MindmapCore
import MindmapGraph
import Observation

/// A frozen layout for the graph pane. `generation` changes only when there is something new to
/// draw; `refit` asks the pane to fit everything again (new map, reshuffle).
struct GraphUpdate {
  let layout: GraphLayout
  let refit: Bool
  let generation: Int
}

@MainActor @Observable
final class MapStore {
  var text = "untitled map\n" {
    didSet {
      if !loadingText && text != oldValue { edited(oldTitle: MapDocument.title(of: oldValue)) }
    }
  }
  private(set) var folder: URL?
  private(set) var maps: [MapFile] = []
  private(set) var currentURL: URL?
  private(set) var documentID = UUID()
  private(set) var model = MapParser.parse(text: "", today: Date(), calendar: .current)
  private(set) var parsedText = ""
  private(set) var isSwitching = true
  private(set) var graph: GraphUpdate?
  @ObservationIgnored weak var graphView: GraphView?
  @ObservationIgnored weak var editorView: NSTextView?
  @ObservationIgnored private var layoutState = LayoutSidecar(seed: LayoutSidecar.randomSeed())
  @ObservationIgnored private var layoutSaveTask: Task<Void, Never>?
  @ObservationIgnored private(set) var hasUnsavedLayout = false
  @ObservationIgnored private var refitNext = true
  var errorMessage: String?
  private var savedText = ""
  private var loaded: MapRepository.Loaded?
  private var loadingText = false
  private var scoped: URL?
  private let repository = MapRepository()
  private var saveTask: Task<Void, Never>?
  private var parseTask: Task<Void, Never>?
  private var renameTask: Task<Void, Never>?
  private static let bookmarkKey = "mapsFolderBookmark"
  private static let lastMapKey = "lastOpenMap"
  var hasUnsavedEdits: Bool { text != savedText }

  init() {
    #if DEBUG
      if let url = DebugLaunch.containerMapsFolder {
        Task {
          await use(url)
          if let fixture = DebugLaunch.fixtureText { text = fixture }
        }
        log.notice("maps folder: dev container")
      } else {
        restore()
      }
    #else
      restore()
    #endif
  }

  private func edited(oldTitle: String?) {
    scheduleParse()
    saveTask?.cancel()
    saveTask = Task {
      do { try await Task.sleep(for: .milliseconds(300)) } catch { return }
      _ = await save()
    }
    if MapDocument.title(of: text) != oldTitle { scheduleRename() }
  }

  /// Parse and run the whole layout off the main thread, then hand the frozen result to the graph.
  /// Each rebuild uses the map's seed; pinned nodes are fixed points.
  private func scheduleParse(debounce: Bool = true) {
    parseTask?.cancel()
    let snapshot = text
    let seed = layoutState.seed
    let pins = layoutState.pins
    parseTask = Task {
      if debounce {
        do { try await Task.sleep(for: .milliseconds(300)) } catch { return }
      }
      let today = Date()
      let calendar = Calendar.current
      let (result, layout) = await Task.detached(priority: .userInitiated) {
        let model = MapParser.parse(text: snapshot, today: today, calendar: calendar)
        let layout = ForceLayout.run(
          model: model, seed: seed, pins: pins, today: today, calendar: calendar,
          measure: GraphStyle.measure)
        return (model, layout)
      }.value
      guard !Task.isCancelled, text == snapshot else { return }
      model = result
      parsedText = snapshot
      graph = GraphUpdate(
        layout: layout, refit: refitNext, generation: (graph?.generation ?? 0) + 1)
      refitNext = false
    }
  }

  /// ⇧⌘R: a new seed, no pins, a fresh layout fitted to the window.
  func reshuffle() {
    layoutState = LayoutSidecar(seed: LayoutSidecar.randomSeed())
    refitNext = true
    scheduleParse(debounce: false)
    scheduleLayoutSave()
  }

  /// A dropped node stays where it was put until reshuffle.
  func pin(_ key: String, at point: LayoutPoint) {
    layoutState.pins[key] = point
    scheduleLayoutSave()
  }

  private func scheduleLayoutSave() {
    hasUnsavedLayout = true
    layoutSaveTask?.cancel()
    layoutSaveTask = Task {
      do { try await Task.sleep(for: .milliseconds(500)) } catch { return }
      await saveLayout()
    }
  }

  private func saveLayout() async {
    guard hasUnsavedLayout, currentURL != nil else { return }
    hasUnsavedLayout = false
    do { try await repository.saveLayout(layoutState, document: documentID) } catch {
      report("save layout", error)
    }
  }

  func focusEditor() {
    if let editorView { editorView.window?.makeFirstResponder(editorView) }
  }

  func focusGraph() {
    if let graphView { graphView.window?.makeFirstResponder(graphView) }
  }

  /// ⇧⌘] / ⇧⌘[: the next or previous map in the switcher's order, wrapping around.
  func switchMap(by offset: Int) {
    guard maps.count > 1, let current = maps.firstIndex(where: { $0.url == currentURL }) else {
      return
    }
    switchMap(maps[(current + offset + maps.count) % maps.count].url)
  }

  private func scheduleRename() {
    renameTask?.cancel()
    renameTask = Task {
      do { try await Task.sleep(for: .seconds(1)) } catch { return }
      await rename()
    }
  }

  @discardableResult
  func save() async -> Bool {
    guard currentURL != nil, hasUnsavedEdits else { return true }
    let identity = documentID
    let snapshot = text
    do {
      let result = try await repository.save(snapshot, document: identity)
      guard documentID == identity else { return true }
      savedText = snapshot
      loaded = result.loaded
      // Update this map's entry in place; the folder is re-listed only on new map, rename,
      // switch and activation.
      if let index = maps.firstIndex(where: { $0.url == result.url }) {
        maps[index] = MapFile(
          url: result.url, title: MapDocument.title(of: snapshot) ?? "untitled map",
          modified: result.loaded.modified ?? Date())
      }
      return true
    } catch {
      report("autosave", error)
      return false
    }
  }

  private func rename() async {
    guard currentURL != nil else { return }
    let identity = documentID
    let title = MapDocument.title(of: text) ?? "untitled map"
    guard await save(), documentID == identity else { return }
    do {
      let target = try await repository.rename(document: identity, title: title)
      guard documentID == identity else { return }
      currentURL = target
      remember()
      try await refreshMaps()
    } catch { report("rename", error) }
  }

  func switchMap(_ url: URL) {
    guard !isSwitching, url != currentURL else { return }
    isSwitching = true
    Task {
      defer { isSwitching = false }
      saveTask?.cancel()
      renameTask?.cancel()
      guard await save() else { return }
      await rename()
      await open(url)
    }
  }

  func newMap() {
    guard !isSwitching, let folder else { return }
    isSwitching = true
    Task {
      defer { isSwitching = false }
      saveTask?.cancel()
      renameTask?.cancel()
      guard await save() else { return }
      await rename()
      do { await open(try await repository.create(in: folder)) } catch { report("new map", error) }
    }
  }

  private func open(_ url: URL) async {
    layoutSaveTask?.cancel()
    await saveLayout()
    do {
      let identity = UUID()
      let result = try await repository.open(url, document: identity)
      let remembered = await repository.loadLayout(document: identity)
      currentURL = url
      documentID = identity
      loaded = result
      layoutState = remembered ?? LayoutSidecar(seed: LayoutSidecar.randomSeed())
      refitNext = true
      if remembered == nil { scheduleLayoutSave() }
      savedText = result.text
      loadingText = true
      text = result.text
      loadingText = false
      remember()
      scheduleParse()
      try await refreshMaps()
      scheduleRename()
    } catch { report("open map", error) }
  }

  /// Activation is the only external-change trigger. Dirty text always wins.
  func activated() {
    guard !isSwitching, !hasUnsavedEdits, let url = currentURL, let folder else { return }
    Task {
      do {
        let changed = try await repository.changed(url, since: loaded)
        guard !hasUnsavedEdits, currentURL == url, !isSwitching else { return }
        if changed {
          let result = try await repository.load(url)
          guard !hasUnsavedEdits, currentURL == url, !isSwitching else { return }
          loaded = result
          savedText = result.text
          loadingText = true
          text = result.text
          loadingText = false
          scheduleParse()
        }
        let result = try await repository.list(folder)
        if self.folder == folder { maps = result }
      } catch { report("reload map", error) }
    }
  }

  func chooseFolder() {
    guard !isSwitching else { return }
    let panel = NSOpenPanel()
    panel.message =
      "choose where to keep your maps. a folder inside Documents keeps them private from other apps."
    panel.prompt = "Use Folder"
    panel.canChooseFiles = false
    panel.canChooseDirectories = true
    panel.canCreateDirectories = true
    let home = String(cString: getpwuid(getuid())!.pointee.pw_dir)
    panel.directoryURL = URL(fileURLWithPath: home).appending(path: "Documents")
    guard panel.runModal() == .OK, let url = panel.url else { return }
    isSwitching = true
    Task {
      defer { isSwitching = false }
      let access = url.startAccessingSecurityScopedResource()
      let repo = await Task.detached(priority: .userInitiated) { GitGuard.workTree(around: url) }
        .value
      if let repo {
        if access { url.stopAccessingSecurityScopedResource() }
        errorMessage =
          "choose a folder outside code projects. \(url.lastPathComponent) is inside or contains a git repository (\(repo.path))."
        return
      }
      saveTask?.cancel()
      renameTask?.cancel()
      guard await save() else {
        if access { url.stopAccessingSecurityScopedResource() }
        return
      }
      await rename()
      do {
        let bookmark = try url.bookmarkData(options: .withSecurityScope)
        UserDefaults.standard.set(bookmark, forKey: Self.bookmarkKey)
        if let scoped { scoped.stopAccessingSecurityScopedResource() }
        scoped = access ? url : nil
        await use(url)
      } catch {
        if access { url.stopAccessingSecurityScopedResource() }
        report("maps folder bookmark", error)
      }
    }
  }

  private func restore() {
    isSwitching = false
    guard let data = UserDefaults.standard.data(forKey: Self.bookmarkKey) else { return }
    var stale = false
    do {
      let url = try URL(
        resolvingBookmarkData: data, options: .withSecurityScope, bookmarkDataIsStale: &stale)
      guard url.startAccessingSecurityScopedResource() else {
        log.error("maps folder bookmark grants no access")
        return
      }
      if stale {
        // Still resolves and grants access: renew it quietly instead of asking again.
        do {
          UserDefaults.standard.set(
            try url.bookmarkData(options: .withSecurityScope), forKey: Self.bookmarkKey)
          log.notice("renewed stale maps folder bookmark")
        } catch { log.error("renewing stale bookmark failed: \(error, privacy: .public)") }
      }
      guard GitGuard.workTree(around: url, scanDescendants: false) == nil else {
        url.stopAccessingSecurityScopedResource()
        return
      }
      scoped = url
      isSwitching = true
      Task { await use(url) }
    } catch { report("restore maps folder", error) }
  }

  private func use(_ url: URL) async {
    defer { isSwitching = false }
    folder = url
    do {
      maps = try await repository.list(url)
      let remembered = UserDefaults.standard.string(forKey: Self.lastMapKey)
      let target = maps.first { $0.url.lastPathComponent == remembered }?.url ?? maps.first?.url
      if let target { await open(target) } else { await open(try await repository.create(in: url)) }
    } catch { report("maps folder", error) }
  }

  private func refreshMaps() async throws {
    guard let folder else { return }
    let result = try await repository.list(folder)
    guard self.folder == folder else { return }
    maps = result
  }

  func finishSaving() async -> Bool {
    isSwitching = true
    layoutSaveTask?.cancel()
    await saveLayout()
    let result = await save()
    if !result { isSwitching = false }
    return result
  }

  private func remember() {
    UserDefaults.standard.set(currentURL?.lastPathComponent, forKey: Self.lastMapKey)
  }

  private func report(_ action: String, _ error: Error) {
    log.error("\(action, privacy: .public) failed: \(error, privacy: .public)")
    errorMessage = "\(action) failed: \(error.localizedDescription)"
  }
}

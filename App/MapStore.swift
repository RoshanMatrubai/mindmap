import AppKit
import MindmapCore
import MindmapGraph
import Observation
import os

/// A simulation and its initial or most recently frozen presentation.
struct GraphUpdate {
  var layout: GraphLayout
  let simulation: LayoutSimulation
  let refit: Bool
  let reuseNodes: Bool
  let generation: Int
  let documentID: UUID
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
  @ObservationIgnored private var restoreNext = false
  @ObservationIgnored private var freshNext = true
  @ObservationIgnored private var switchPending = false
  @ObservationIgnored private var switchDocumentID: UUID?
  var errorMessage: String?
  private var savedText = ""
  private var loaded: MapRepository.Loaded?
  private var loadingText = false
  private var scoped: URL?
  private let repository = MapRepository()
  private var saveTask: Task<Void, Never>?
  private var parseTask: Task<Void, Never>?
  private var renameTask: Task<Void, Never>?
  private var switchStarted = ContinuousClock.now
  private let performance = OSLog(subsystem: Bundle.main.bundleIdentifier!, category: "motion")
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

  /// Edits start from the displayed positions, not the original seed. Parsing and preparing
  /// collision boxes stay off the main thread; only moving graphs get display ticks.
  private func scheduleParse(debounce: Bool = true) {
    parseTask?.cancel()
    let snapshot = text
    let identity = documentID
    let state = layoutState
    let hasPrevious = graph?.documentID == identity
    let restore = restoreNext || (!hasPrevious && !freshNext && !state.positions.isEmpty)
    let fresh = freshNext || (!hasPrevious && !restore)
    let refit = refitNext || !hasPrevious
    restoreNext = false
    freshNext = false
    refitNext = false
    parseTask = Task {
      if debounce {
        do { try await Task.sleep(for: .milliseconds(300)) } catch { return }
      }
      var previousSimulation: LayoutSimulation?
      if !fresh && !restore {
        // The view may not have shown this map's latest graph yet. Never match against another map.
        previousSimulation = await graphView?.simulationSnapshot(for: identity)
        if previousSimulation == nil, let graph, graph.documentID == identity {
          previousSimulation = graph.simulation
        }
      }
      let previous = previousSimulation?.layout
      let pins = previousSimulation?.pins ?? state.pins
      guard !Task.isCancelled, documentID == identity else { return }
      let today = Date()
      let calendar = Calendar.current
      let (result, simulation) = await Task.detached(priority: .userInitiated) {
        let performance = OSLog(subsystem: Bundle.main.bundleIdentifier!, category: "motion")
        let parseStart = ContinuousClock.now
        os_signpost(.begin, log: performance, name: "Parse")
        let model = MapParser.parse(text: snapshot, today: today, calendar: calendar)
        os_signpost(.end, log: performance, name: "Parse")
        let parseMS = Self.milliseconds(parseStart.duration(to: .now))
        let layoutStart = ContinuousClock.now
        os_signpost(.begin, log: performance, name: "LayoutPreparation")
        let simulation: LayoutSimulation
        if restore {
          simulation = LayoutSimulation(
            model: model, sidecar: state, today: today, calendar: calendar,
            measure: GraphStyle.measure)
        } else if let previous {
          simulation = LayoutSimulation(
            previous: previous, model: model, pins: pins, today: today,
            calendar: calendar, measure: GraphStyle.measure)
        } else {
          simulation = LayoutSimulation(
            model: model, seed: state.seed, pins: state.pins, today: today,
            calendar: calendar, measure: GraphStyle.measure)
        }
        os_signpost(.end, log: performance, name: "LayoutPreparation")
        let layoutMS = Self.milliseconds(layoutStart.duration(to: .now))
        log.notice(
          "motion prepare nodes=\(model.nodeCount) parse-ms=\(parseMS, privacy: .public) layout-ms=\(layoutMS, privacy: .public)"
        )
        return (model, simulation)
      }.value
      guard !Task.isCancelled, documentID == identity, text == snapshot else { return }
      model = result
      parsedText = snapshot
      layoutState.pins = simulation.pins
      graph = GraphUpdate(
        layout: simulation.layout, simulation: simulation, refit: refit,
        reuseNodes: !restore && !fresh, generation: (graph?.generation ?? 0) + 1,
        documentID: identity)
    }
  }

  /// A freeze records all positions, including nodes pushed during a drag.
  func graphFrozen(document: UUID, _ layout: GraphLayout, pins: [String: LayoutPoint]) {
    guard document == documentID, layout.model == model else { return }
    graph?.layout = layout
    layoutState = LayoutSidecar(
      seed: layout.seed, pins: pins,
      positions: Dictionary(
        uniqueKeysWithValues: zip(layout.model.nodes, layout.nodes).map {
          ($0.0.pathKey, LayoutPoint(x: $0.1.x, y: $0.1.y))
        }))
    scheduleLayoutSave()
  }

  /// Saving current worker positions also covers a switch or Quit during an animation.
  private func captureLayout() async {
    parseTask?.cancel()
    guard let simulation = await graphView?.stopAndSnapshot(for: documentID),
      simulation.layout.model == model
    else { return }
    layoutState = simulation.snapshotSidecar()
    graph?.layout = simulation.layout
    hasUnsavedLayout = true
  }

  /// ⇧⌘R: a new seed, no pins, a fresh layout fitted to the window.
  func reshuffle() {
    layoutState = LayoutSidecar(seed: LayoutSidecar.randomSeed())
    refitNext = true
    freshNext = true
    restoreNext = false
    scheduleParse(debounce: false)
    scheduleLayoutSave()
  }

  /// A dropped node stays where it was put until reshuffle.
  func pin(document: UUID, _ key: String, at point: LayoutPoint) {
    guard document == documentID else { return }
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
      hasUnsavedLayout = true
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
    beginSwitch()
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
    log.notice(
      "motion new-map requested switching=\(self.isSwitching) folder=\(self.folder != nil)")
    guard !isSwitching, let folder else { return }
    beginSwitch()
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
    await captureLayout()
    beginSwitch()
    layoutSaveTask?.cancel()
    await saveLayout()
    do {
      let identity = UUID()
      let readStart = ContinuousClock.now
      os_signpost(.begin, log: performance, name: "FileRead")
      let result = try await repository.open(url, document: identity)
      os_signpost(.end, log: performance, name: "FileRead")
      log.notice(
        "motion file-read ms=\(Self.milliseconds(readStart.duration(to: .now)), privacy: .public)")
      let remembered = await repository.loadLayout(document: identity)
      currentURL = url
      documentID = identity
      switchDocumentID = identity
      loaded = result
      layoutState = remembered ?? LayoutSidecar(seed: LayoutSidecar.randomSeed())
      refitNext = true
      restoreNext = remembered != nil
      freshNext = remembered == nil
      savedText = result.text
      loadingText = true
      text = result.text
      loadingText = false
      remember()
      scheduleParse(debounce: false)
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
    await captureLayout()
    layoutSaveTask?.cancel()
    await saveLayout()
    let result = await save()
    if !result { isSwitching = false }
    return result
  }

  private func remember() {
    UserDefaults.standard.set(currentURL?.lastPathComponent, forKey: Self.lastMapKey)
  }

  private func beginSwitch() {
    guard !switchPending else { return }
    switchStarted = .now
    switchPending = true
    switchDocumentID = nil
    os_signpost(.begin, log: performance, name: "MapSwitch")
  }

  func graphShown(document: UUID) {
    guard switchPending, switchDocumentID == document, documentID == document else { return }
    switchPending = false
    os_signpost(.end, log: performance, name: "MapSwitch")
    log.notice(
      "motion switch nodes=\(self.model.nodeCount) first-frame-ms=\(Self.milliseconds(self.switchStarted.duration(to: .now)), privacy: .public)"
    )
  }

  nonisolated private static func milliseconds(_ duration: Duration) -> Double {
    let c = duration.components
    return Double(c.seconds) * 1000 + Double(c.attoseconds) / 1e15
  }

  private func report(_ action: String, _ error: Error) {
    log.error("\(action, privacy: .public) failed: \(error, privacy: .public)")
    errorMessage = "\(action) failed: \(error.localizedDescription)"
  }
}

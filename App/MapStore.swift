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
  /// The label font the simulation measured with.
  let family: String
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
  /// The detail panel's content; nil without a selection.
  private(set) var detail: NodeDetail?
  /// Calendar status is separate from graph layout and stays idle between sync triggers.
  let calendarSync = CalendarSyncController()
  @ObservationIgnored private var dayObserver: NSObjectProtocol?

  var calendarLine: String? {
    guard let detail, model.nodes.indices.contains(detail.index) else { return nil }
    return calendarSync.line(for: model.nodes[detail.index], in: currentURL)
  }

  /// The graph view is first responder, so plain keys act on the graph.
  var graphFocused = false
  /// App-wide settings, edited live by the forces panel and the Settings window.
  var preferences = Preferences(defaults: .standard) {
    didSet { preferencesChanged(from: oldValue) }
  }
  /// The forces panel's status: the settle's alpha in percent while the graph moves, else nil.
  private(set) var settlePercent: Int?
  /// A brief message in the detail panel, such as a refused graph edit.
  private(set) var notice: String?
  /// Every bundled font is registered, so the picker can preview each one.
  private(set) var allFontsRegistered = false
  /// Opens the Settings window (set by the main window, which has the environment action).
  @ObservationIgnored var openSettings: (() -> Void)?
  @ObservationIgnored private var reshuffleTask: Task<Void, Never>?
  @ObservationIgnored private var noticeTask: Task<Void, Never>?
  @ObservationIgnored private var resizeNext = false
  /// The label font's registration. Layouts wait for it before measuring labels.
  @ObservationIgnored private var labelFontReady: Task<Void, Never>?
  #if DEBUG
    /// Reshuffles started, by any route (⇧⌘R, buttons, force changes).
    @ObservationIgnored private(set) var debugReshuffles = 0
  #endif
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
  /// What to select once the graph shows the parse of the current text.
  private enum PendingSelection {
    case keep, cursor
    case location(Int)
    case clear
  }
  @ObservationIgnored private var pendingSelection = PendingSelection.keep
  /// Where a node added on the graph appears: the start of its new line and its world point.
  @ObservationIgnored private var pendingPlacement: (location: Int, point: LayoutPoint)?
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
    registerLabelFont()
    dayObserver = NotificationCenter.default.addObserver(
      forName: .NSCalendarDayChanged, object: nil, queue: .main
    ) { [weak self] _ in
      Task { @MainActor [weak self] in
        guard let self, let folder = self.folder else { return }
        self.scheduleParse(debounce: false)
        self.calendarSync.sync(in: folder, open: nil, all: true)
      }
    }
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
    let placement = pendingPlacement
    let resize = resizeNext && hasPrevious && !restore && !fresh
    let params = preferences.forces
    let family = preferences.labelFont
    let measure = GraphStyle.measure(family: family)
    let animate = preferences.animateSettle
    resizeNext = false
    restoreNext = false
    freshNext = false
    refitNext = false
    let fontReady = labelFontReady
    parseTask = Task {
      if debounce {
        do { try await Task.sleep(for: .milliseconds(300)) } catch { return }
      }
      await fontReady?.value
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
        var simulation: LayoutSimulation
        if restore {
          simulation = LayoutSimulation(
            model: model, sidecar: state, params: params, today: today, calendar: calendar,
            measure: measure)
        } else if let previous, resize, previous.model == model {
          simulation = LayoutSimulation(
            resizing: previous, pins: pins, params: params, today: today, calendar: calendar,
            measure: measure)
        } else if let previous {
          let placed = placement.flatMap { p in
            model.nodes.first { $0.sourceRange.location == p.location && $0.sourceRange.length > 0 }
              .map { [$0.id: p.point] }
          }
          simulation = LayoutSimulation(
            previous: previous, model: model, pins: pins, placements: placed ?? [:],
            params: params, today: today, calendar: calendar, measure: measure)
        } else {
          simulation = LayoutSimulation(
            model: model, seed: state.seed, pins: state.pins, params: params, today: today,
            calendar: calendar, measure: measure)
        }
        // Animate settle off: compute the motion here and show only the frozen result.
        while !animate && !simulation.isFrozen { simulation.advance(by: 1) }
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
      if placement != nil { pendingPlacement = nil }
      layoutState.pins = simulation.pins
      graph = GraphUpdate(
        layout: simulation.layout, simulation: simulation, refit: refit,
        reuseNodes: !restore && !fresh, generation: (graph?.generation ?? 0) + 1,
        documentID: identity, family: family)
      // After the graph update, so a save never delays drawing. Never sync a stale parse.
      if calendarSync.enabled, let folder, await save(), documentID == identity,
        text == snapshot, let url = currentURL
      {
        calendarSync.sync(in: folder, open: (url, result))
      }
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

  /// ⇧⌘R: a new seed, no pins, a fresh layout fitted to the window. A force change keeps pins.
  func reshuffle(keepingPins: Bool = false) {
    #if DEBUG
      debugReshuffles += 1
    #endif
    layoutState = LayoutSidecar(
      seed: LayoutSidecar.randomSeed(), pins: keepingPins ? layoutState.pins : [:])
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

  // MARK: Preferences

  private func preferencesChanged(from old: Preferences) {
    guard preferences != old else { return }
    preferences.save(to: .standard)
    if preferences.labelFont != old.labelFont { registerLabelFont() }
    if preferences.forcesDiffer(from: old) {
      // About 200 ms after the slider stops: a new seed, keeping pins (decision 3).
      reshuffleTask?.cancel()
      reshuffleTask = Task {
        do { try await Task.sleep(for: .milliseconds(200)) } catch { return }
        reshuffle(keepingPins: true)
      }
    } else if preferences.labelSize != old.labelSize || preferences.labelFont != old.labelFont {
      // New label boxes, same positions; only new overlaps are pushed apart. No reshuffle.
      resizeNext = true
      scheduleParse(debounce: false)
    }
  }

  /// Registers only the selected label font (the picker registers the rest), off the main
  /// thread: registering on it during launch delayed the first window by about 60 ms.
  private func registerLabelFont() {
    let family = preferences.labelFont
    labelFontReady = Task.detached(priority: .userInitiated) { GraphFonts.register(family) }
  }

  func settleChanged(_ alpha: Double?) {
    let percent = alpha.map { Int(($0 * 100).rounded()) }
    if percent != settlePercent { settlePercent = percent }
  }

  /// The picker previews every family; registering them all at launch costs about 70 ms.
  func registerAllFonts() {
    guard !allFontsRegistered else { return }
    let started = ContinuousClock.now
    Task {
      await Task.detached(priority: .userInitiated) { GraphFonts.registerAll() }.value
      allFontsRegistered = true
      log.notice(
        "fonts registered all ms=\(Self.milliseconds(started.duration(to: .now)), privacy: .public)"
      )
    }
  }

  // MARK: Selection and graph edits

  /// The graph shows the parse of the current text, so its indices and the text's ranges agree.
  private var graphIsCurrent: Bool {
    parsedText == text && graphView?.scene.layout?.model == model
  }

  private var outline: OutlineTextView? { editorView as? OutlineTextView }

  /// Graph → editor: a click, arrow key or right-click selected a node (or cleared it).
  func graphSelected(_ index: Int?) {
    refreshDetail()
    guard let index, graphIsCurrent, model.nodes.indices.contains(index) else { return }
    outline?.selectLine(model.nodes[index].sourceRange)
  }

  /// Editor → graph: the cursor moved. Highlights its line's node without moving the camera.
  func editorSelectionChanged(_ range: NSRange) {
    guard graphIsCurrent else {
      pendingSelection = .cursor
      return
    }
    pendingSelection = .keep
    selectNode(at: range.location)
  }

  /// A linked name in the detail panel: select it like a graph click.
  func selectLinked(_ index: Int) {
    graphView?.select(index, camera: true)
    graphSelected(graphView?.selection)
  }

  private func selectNode(at location: Int) {
    graphView?.select(Selection.node(model, atLocation: location), camera: false)
    refreshDetail()
  }

  /// After the view shows a new graph: apply the selection an edit asked for, then refresh the
  /// panel (counts and urgency may have changed).
  func graphDidUpdate() {
    guard graphIsCurrent else { return refreshDetail() }
    switch pendingSelection {
    case .keep: break
    case .cursor: selectNode(at: outline?.selectedRange().location ?? 0)
    case .location(let location): selectNode(at: location)
    case .clear: graphView?.select(nil, camera: false)
    }
    pendingSelection = .keep
    refreshDetail()
  }

  private func refreshDetail() {
    guard let layout = graphView?.scene.layout, let index = graphView?.selection else {
      detail = nil
      return
    }
    let next = Selection.detail(layout.model, urgency: layout.nodes.map(\.urgency), of: index)
    if next != detail { detail = next }
  }

  /// Applies a graph edit as a text replacement through the editor, so it is one step in the
  /// editor's undo stack, autosaves and re-parses (at once, not debounced) like typing.
  @discardableResult
  func applyGraphEdit(_ edit: GraphEdit) -> Bool {
    guard graphIsCurrent, let outline, outline.isEditable, outline.string == text else {
      return refuse(edit)
    }
    let nodes = model.nodes
    var placement: LayoutPoint?
    let change: TextChange?
    switch edit {
    case .add(let add, let name, let point):
      placement = point
      switch add {
      case .sibling(let i):
        change = OutlineEditing.insertSibling(text: text, model: model, after: i, name: name)
      case .child(let i):
        change = OutlineEditing.appendChild(text: text, model: model, to: i, name: name)
      case .group: change = OutlineEditing.appendGroup(text: text, name: name)
      }
    case .rename(let i, let name):
      change = OutlineEditing.rename(text: text, model: model, node: i, to: name)
    case .toggleDone(let i):
      change = OutlineEditing.toggleDone(
        text: text, selection: NSRange(location: nodes[i].sourceRange.location, length: 0))
    case .priority(let i, let priority):
      change = OutlineEditing.setPriority(text: text, model: model, node: i, priority)
    case .delete(let i):
      change = OutlineEditing.deleteBranch(text: text, model: model, node: i)
    }
    guard let change else { return false }
    // Deleting a group clears the selection; deleting a task selects its parent.
    if case .delete(let i) = edit, nodes[i].parent == nil {
      pendingSelection = .clear
    } else {
      pendingSelection = .location(change.selection.location)
    }
    pendingPlacement = placement.map { (change.selection.location, $0) }
    var applied = false
    outline.quietly { applied = outline.perform(change) }
    guard applied else {
      pendingPlacement = nil
      return refuse(edit)
    }
    outline.selectLine(change.selection)
    scheduleParse(debounce: false)
    return true
  }

  /// The editor and the store (or the graph's parse) disagree, say mid-typing. Nothing changes;
  /// the detail panel says so for a few seconds instead of failing silently.
  private func refuse(_ edit: GraphEdit) -> Bool {
    log.notice(
      "graph edit refused: \(String(describing: edit), privacy: .public) current=\(self.graphIsCurrent) editor-matches=\(self.outline?.string == self.text)"
    )
    notice = "couldn't apply that edit, try again"
    noticeTask?.cancel()
    noticeTask = Task {
      try? await Task.sleep(for: .seconds(3))
      if !Task.isCancelled { notice = nil }
    }
    return false
  }

  /// ⌘1–4 and ⌘0: the selected node with the graph focused, else the editor's bullet lines.
  func setPriority(_ priority: MapPriority?) {
    if graphFocused {
      if let i = graphView?.selection { applyGraphEdit(.priority(i, priority)) }
    } else if let outline, outline.window?.firstResponder === outline {
      outline.perform(
        OutlineEditing.setPriority(
          text: outline.string, selection: outline.selectedRange(), priority))
    }
  }

  func toggleDone(_ index: Int) { applyGraphEdit(.toggleDone(index)) }

  /// ⇧⌘X with the graph focused toggles the selected task; otherwise the editor's lines.
  func toggleDoneFromMenu() {
    if graphFocused, let i = graphView?.selection {
      applyGraphEdit(.toggleDone(i))
    } else {
      NSApp.sendAction(#selector(OutlineTextView.toggleDone(_:)), to: nil, from: nil)
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
      await calendarSync.beginFileChange()
      defer { calendarSync.endFileChange(in: folder, map: currentURL) }
      guard documentID == identity else { return }
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
      // A map switch clears the selection.
      graphView?.select(nil, camera: false)
      pendingSelection = .keep
      pendingPlacement = nil
      detail = nil
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
        await calendarSync.beginFileChange()
        defer { calendarSync.endFileChange(in: folder, map: currentURL) }
        let bookmark = try url.bookmarkData(options: .withSecurityScope)
        guard await calendarSync.relocate(to: url) else {
          if access { url.stopAccessingSecurityScopedResource() }
          errorMessage = calendarSync.lastError
          return
        }
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
    await calendarSync.drain()
    folder = url
    calendarSync.start(in: url)
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
    await calendarSync.drain()
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
    #if DEBUG
      DebugLaunch.logLaunch("first-graph-frame")
    #endif
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

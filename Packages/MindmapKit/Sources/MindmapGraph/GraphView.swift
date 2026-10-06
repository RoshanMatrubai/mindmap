#if os(macOS)
  import AppKit
  import MindmapCore
  import QuartzCore

  /// The graph pane. Trackpad: two-finger scroll pans, pinch zooms about the cursor. Mouse: the
  /// wheel zooms about the cursor, dragging empty canvas pans. Dragging a node moves and pins it
  /// (⇧-drag brings its subtree). Clicking selects; double-clicking names. Motion and the camera
  /// live in the shared `GraphController`; this view adds AppKit input and the window.
  public final class GraphView: NSView, NSTextFieldDelegate {
    public let controller = GraphController()
    public var scene: GraphScene { controller.scene }
    /// A node was dropped: the shown document, its path key and new world position.
    public var onPin: ((UUID, String, LayoutPoint) -> Void)?
    /// The user selected a node on the graph (click, arrows, Esc, right-click). Not called for
    /// `select(_:camera:)`, so the owner can sync the editor without a loop.
    public var onSelect: ((Int?) -> Void)?
    /// Returns false when the edit couldn't be applied.
    public var onEdit: ((GraphEdit) -> Bool)?
    public var onFocus: ((Bool) -> Void)?
    public var selection: Int? { scene.selection }
    public var isNaming: Bool { naming != nil }
    private var press: (point: CGPoint, camera: Camera, node: Int?, grab: CGPoint, shift: Bool)?
    private enum NamingKind { case rename, sibling, child, group }
    /// Targets are path keys, resolved on commit, so a rebuild meanwhile can't shift them.
    private var naming: (kind: NamingKind, key: String?, point: LayoutPoint)?
    private lazy var field: NSTextField = {
      let field = NSTextField(string: "")
      field.isBordered = false
      field.focusRingType = .none
      field.drawsBackground = true
      field.backgroundColor = NSColor(cgColor: GraphStyle.canvas)
      field.textColor = NSColor(cgColor: GraphStyle.cached(GraphStyle.brightLabel))
      field.alignment = .center
      field.cell?.isScrollable = true
      field.wantsLayer = true
      field.layer?.borderColor = GraphStyle.cached(0x4f2fc4)
      field.layer?.borderWidth = 1
      field.layer?.cornerRadius = 4
      field.delegate = self
      return field
    }()
    private var moved = false
    public var onFreeze: ((UUID, GraphLayout, [String: LayoutPoint]) -> Void)? {
      get { controller.onFreeze }
      set { controller.onFreeze = newValue }
    }
    public var onFirstFrame: ((Int) -> Void)? {
      get { controller.onFirstFrame }
      set { controller.onFirstFrame = newValue }
    }
    public var onSettle: ((Double?) -> Void)? {
      get { controller.onSettle }
      set { controller.onSettle = newValue }
    }
    public var document: UUID? { controller.document }
    public var displayedSimulation: LayoutSimulation? { controller.displayedSimulation }
    public var isAnimating: Bool { controller.isAnimating }
    public var affectedIndices: Set<Int> { controller.affectedIndices }

    #if DEBUG
      public static var debugLiveDisplayLinks: Int { GraphController.debugLiveDisplayLinks }
      public static var debugIdleFrames: Int { GraphController.debugIdleFrames }
      public var debugInitialLayout: GraphLayout? { controller.debugInitialLayout }
      public var debugFrameMetrics:
        (averageMilliseconds: Double, worstMilliseconds: Double, frames: Int)
      { controller.debugFrameMetrics }
      public func debugResetFrameMetrics() { controller.debugResetFrameMetrics() }
      /// The inline name field's text while naming, else nil.
      public var debugNamingText: String? { naming == nil ? nil : field.stringValue }
      public func debugMagnify(by magnification: Double, about point: CGPoint) {
        controller.move(
          scene.visibleCamera.zoomed(by: 1 + magnification, about: point, limits: controller.limits)
        )
      }
    #endif

    public override init(frame: NSRect) {
      super.init(frame: frame)
      wantsLayer = true
      layerContentsRedrawPolicy = .never
      layer?.addSublayer(scene.root)
      scene.setSize(frame.size)
      // macOS 14's view display link follows the window's screen; none while hidden.
      controller.makeDisplayLink = { [weak self] in
        guard let self, self.window?.occlusionState.contains(.visible) == true else { return nil }
        return self.displayLink(
          target: self.controller, selector: #selector(GraphController.displayFrame(_:)))
      }
      let buttons = [
        button("plus", "Zoom in", #selector(zoomInClicked)),
        button("minus", "Zoom out", #selector(zoomOutClicked)),
        button("arrow.up.left.and.arrow.down.right", "Fit all", #selector(fitClicked)),
      ]
      for (i, b) in buttons.enumerated() {
        // Prototype: 28 px buttons, 6 apart, 10 from the top and 12 from the right.
        b.frame = NSRect(
          x: frame.width - 12 - 28 - Double(2 - i) * 34, y: frame.height - 10 - 28, width: 28,
          height: 28)
        b.autoresizingMask = [.minXMargin, .minYMargin]
        addSubview(b)
      }
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    /// Prototype `.zb` button: #232326 fill, 0.5 px #3a3a3c border, 6 px corners, #a1a1a6 icon.
    private func button(_ symbol: String, _ label: String, _ action: Selector) -> NSView {
      let image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)!
        .withSymbolConfiguration(.init(pointSize: 11, weight: .regular))!
      let b = NSButton(image: image, target: self, action: action)
      b.isBordered = false
      b.contentTintColor = NSColor(cgColor: GraphStyle.color(0xa1a1a6))
      b.toolTip = label
      b.frame = NSRect(x: 0, y: 0, width: 28, height: 28)
      b.autoresizingMask = [.width, .height]
      let box = NSView(frame: b.frame)
      box.wantsLayer = true
      box.layer?.backgroundColor = GraphStyle.color(0x232326)
      box.layer?.borderColor = GraphStyle.color(0x3a3a3c)
      box.layer?.borderWidth = 0.5
      box.layer?.cornerRadius = 6
      box.addSubview(b)
      return box
    }

    public override var acceptsFirstResponder: Bool { true }
    public override var isOpaque: Bool { true }

    /// Saved positions show immediately. Fresh layouts and local edits animate off the main thread.
    /// `refit` (new map, reshuffle) goes back to fitting everything.
    public func show(
      _ simulation: LayoutSimulation, title: String, refit: Bool, reuseNodes: Bool = true,
      document: UUID
    ) {
      if controller.document != document { finishNaming(commit: false) }
      press = nil
      controller.show(
        simulation, title: title, refit: refit, reuseNodes: reuseNodes, document: document)
    }

    public func simulationSnapshot(for document: UUID) async -> LayoutSimulation? {
      await controller.simulationSnapshot(for: document)
    }

    public func stopAndSnapshot(for document: UUID) async -> LayoutSimulation? {
      await controller.stopAndSnapshot(for: document)
    }

    public override func viewDidMoveToWindow() {
      super.viewDidMoveToWindow()
      NotificationCenter.default.removeObserver(
        self, name: NSWindow.didChangeOcclusionStateNotification, object: nil)
      if let window {
        NotificationCenter.default.addObserver(
          self, selector: #selector(occlusionChanged),
          name: NSWindow.didChangeOcclusionStateNotification, object: window)
        scene.colorSpace = window.colorSpace?.cgColorSpace ?? scene.colorSpace
        controller.resumeMotion()
      } else {
        controller.pauseMotion()
      }
    }

    @objc private func occlusionChanged(_ notification: Notification) {
      if window?.occlusionState.contains(.visible) == true {
        controller.resumeMotion()
      } else {
        controller.pauseMotion()
      }
    }

    public override func layout() {
      super.layout()
      controller.resize(to: bounds.size)
    }

    public override func viewDidChangeBackingProperties() {
      super.viewDidChangeBackingProperties()
      scene.screenScale = window?.backingScaleFactor ?? 2
      scene.colorSpace = window?.colorSpace?.cgColorSpace ?? scene.colorSpace
    }

    public override func resetCursorRects() {
      addCursorRect(bounds, cursor: .openHand)
    }

    // MARK: Camera commands

    public func zoomIn() { controller.zoomIn() }
    public func zoomOut() { controller.zoomOut() }
    public func fitAll() { controller.fitAll() }
    public func zoom(by factor: Double) { controller.zoom(by: factor) }

    @objc private func zoomInClicked() { zoomIn() }
    @objc private func zoomOutClicked() { zoomOut() }
    @objc private func fitClicked() { fitAll() }

    private var limits: ClosedRange<Double> { controller.limits }
    private func move(_ camera: Camera) { controller.move(camera) }

    // MARK: Input

    /// View coordinates, y down like the scene.
    private func point(_ event: NSEvent) -> CGPoint {
      let p = convert(event.locationInWindow, from: nil)
      return CGPoint(x: p.x, y: bounds.height - p.y)
    }

    /// Trackpad (and Magic Mouse) scrolls carry a gesture or momentum phase and pan. Wheels have
    /// neither, even smooth-scrolling ones with precise deltas, and zoom about the cursor.
    public override func scrollWheel(with event: NSEvent) {
      finishNaming(commit: true)
      let camera = scene.visibleCamera
      if !event.phase.isEmpty || !event.momentumPhase.isEmpty {
        move(camera.panned(by: CGPoint(x: event.scrollingDeltaX, y: event.scrollingDeltaY)))
      } else if event.scrollingDeltaY != 0 {
        move(
          camera.zoomed(
            by: Self.wheelZoom(event.scrollingDeltaY, precise: event.hasPreciseScrollingDeltas),
            about: point(event), limits: limits))
      }
    }

    /// One line (or 10 precise points) zooms 12%, proportionally, at most 1.5× per event.
    nonisolated static func wheelZoom(_ delta: Double, precise: Bool) -> Double {
      GraphController.wheelZoom(delta, precise: precise)
    }

    public override func magnify(with event: NSEvent) {
      finishNaming(commit: true)
      move(
        scene.visibleCamera.zoomed(by: 1 + event.magnification, about: point(event), limits: limits)
      )
    }

    public override func mouseDown(with event: NSEvent) {
      window?.makeFirstResponder(self)
      let p = point(event)
      let camera = scene.visibleCamera
      scene.setCamera(camera)
      // Prototype hit circle: about 14 px.
      let node = scene.node(at: p, radius: 14)
      var grab = CGPoint.zero
      if let node, let n = scene.layout?.nodes[node] {
        let w = camera.toWorld(p)
        grab = CGPoint(x: n.x - w.x, y: n.y - w.y)
      }
      press = (p, camera, node, grab, event.modifierFlags.contains(.shift))
      moved = false
    }

    public override func mouseDragged(with event: NSEvent) {
      guard let press else { return }
      let p = point(event)
      let delta = CGPoint(x: p.x - press.point.x, y: p.y - press.point.y)
      if !moved && abs(delta.x) + abs(delta.y) <= 4 { return }
      moved = true
      if let node = press.node {
        let w = press.camera.toWorld(p)
        controller.drag(
          node, to: LayoutPoint(x: w.x + press.grab.x, y: w.y + press.grab.y), subtree: press.shift)
      } else {
        NSCursor.closedHand.set()
        move(press.camera.panned(by: delta))
      }
    }

    public override func mouseUp(with event: NSEvent) {
      defer {
        press = nil
        window?.invalidateCursorRects(for: self)
      }
      guard let press else { return }
      if !moved {
        if event.clickCount >= 2 {
          if let node = press.node {
            beginRename(node)
          } else {
            let w = press.camera.toWorld(press.point)
            beginAdd(.group, at: LayoutPoint(x: w.x, y: w.y))
          }
        } else {
          userSelect(press.node)
        }
        return
      }
      guard let node = press.node, let layout = scene.layout else { return }
      let n = layout.nodes[node]
      controller.drop(node, subtree: press.shift)
      if let document {
        onPin?(document, layout.model.nodes[node].pathKey, LayoutPoint(x: n.x, y: n.y))
      }
    }

    /// With a selection: Esc clears, Return adds a task, Tab a subtask, Delete removes, arrows
    /// move the selection. The same actions are menu items (AppCommand); this covers keys that
    /// reach the view directly.
    public override func keyDown(with event: NSEvent) {
      if event.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty,
        selection != nil
      {
        switch event.keyCode {
        case 53: return clearSelection()
        case 36, 76: return addTask()
        case 48: return addSubtask()
        case 51, 117: return deleteSelection()
        case 126: return navigate(.parent)
        case 125: return navigate(.firstChild)
        case 123: return navigate(.previousSibling)
        case 124: return navigate(.nextSibling)
        default: break
        }
      }
      let step = 60.0
      let delta: CGPoint
      switch event.specialKey {
      case .leftArrow?: delta = CGPoint(x: step, y: 0)
      case .rightArrow?: delta = CGPoint(x: -step, y: 0)
      case .upArrow?: delta = CGPoint(x: 0, y: step)
      case .downArrow?: delta = CGPoint(x: 0, y: -step)
      default:
        super.keyDown(with: event)
        return
      }
      move(scene.visibleCamera.panned(by: delta))
    }

    // MARK: Selection

    public override func becomeFirstResponder() -> Bool {
      onFocus?(true)
      return true
    }

    public override func resignFirstResponder() -> Bool {
      onFocus?(false)
      return true
    }

    /// Highlights `index` (nil clears). With `camera`, animates to fit the highlight, or back to
    /// fit all when a selection was cleared.
    public func select(_ index: Int?, camera: Bool) { controller.select(index, camera: camera) }

    private func userSelect(_ index: Int?, camera: Bool = true) {
      select(index, camera: camera)
      onSelect?(scene.selection)
    }

    public func clearSelection() { userSelect(nil) }

    public func navigate(_ move: SelectionMove) {
      guard let selection, let model = scene.layout?.model else { return }
      if let next = Selection.neighbor(model, of: selection, move) { userSelect(next) }
    }

    public func addTask() { selection.map { beginAdd(.sibling($0)) } }
    public func addSubtask() { selection.map { beginAdd(.child($0)) } }
    public func deleteSelection() { selection.map { _ = onEdit?(.delete($0)) } }

    // MARK: Naming on the graph

    /// Shows the new node's dot and an empty name field: by its parent (the spawn rule), or at
    /// `point` for a group. Nothing reaches the text until the name is committed.
    public func beginAdd(_ add: GraphAdd, at point: LayoutPoint? = nil) {
      finishNaming(commit: true)
      guard let layout = scene.layout, let simulation = controller.displayedSimulation,
        simulation.layout.model == layout.model
      else { return }
      let kind: NamingKind
      let key: String?
      let p: LayoutPoint
      var group = false
      switch add {
      case .group:
        (kind, key, group) = (.group, nil, true)
        p = point ?? simulation.spawnPoint(around: selection, depth: 0)
      case .sibling(let i):
        let node = layout.model.nodes[i]
        (kind, key, group) = (.sibling, node.pathKey, node.depth == 0)
        p = simulation.spawnPoint(around: group ? i : node.parent, depth: node.depth)
      case .child(let i):
        let node = layout.model.nodes[i]
        (kind, key) = (.child, node.pathKey)
        p = simulation.spawnPoint(around: i, depth: node.depth + 1)
      }
      scene.showGhost(at: CGPoint(x: p.x, y: p.y), group: group)
      startNaming(
        (kind, key, p), text: "", radius: group ? 9 : 4, fontSize: group ? 16 : 13)
    }

    /// Double-click on a label: edit the name in place. Return saves, Esc cancels.
    public func beginRename(_ index: Int) {
      finishNaming(commit: true)
      guard let layout = scene.layout, layout.nodes.indices.contains(index) else { return }
      let node = layout.nodes[index]
      startNaming(
        (.rename, layout.model.nodes[index].pathKey, LayoutPoint(x: node.x, y: node.y)),
        text: layout.model.nodes[index].name, radius: node.radius, fontSize: node.fontSize)
    }

    private func startNaming(
      _ target: (kind: NamingKind, key: String?, point: LayoutPoint), text: String,
      radius: Double, fontSize: Double
    ) {
      naming = target
      let size = max(11, min(28, fontSize * scene.camera.zoom))
      let font = GraphStyle.font(family: scene.labelFamily, size: size) as NSFont
      field.font = font
      field.stringValue = text
      let width = max(160, (text as NSString).size(withAttributes: [.font: font]).width + 40)
      let height = ceil(size * 1.5) + 4
      // Where the label starts: just below the dot.
      let top = scene.camera.toScreen(
        CGPoint(x: target.point.x, y: target.point.y + radius + 2))
      field.frame = NSRect(
        x: top.x - width / 2, y: bounds.height - top.y - height, width: width, height: height)
      addSubview(field)
      window?.makeFirstResponder(field)
      field.currentEditor()?.selectAll(nil)
    }

    /// Commits a non-empty name (as a rename or an insert) or cancels. An empty new node is never
    /// written, so cancelling it leaves the text as it was.
    public func finishNaming(commit: Bool) {
      guard let target = naming else { return }
      naming = nil
      let name = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
      if window?.firstResponder === field.currentEditor() { window?.makeFirstResponder(self) }
      field.removeFromSuperview()
      let model = scene.layout?.model
      let index = target.key.flatMap { key in model?.nodes.firstIndex { $0.pathKey == key } }
      var edit: GraphEdit?
      if commit && !name.isEmpty {
        switch target.kind {
        case .rename:
          if let index, model?.nodes[index].name != name { edit = .rename(index, name) }
        case .sibling: edit = index.map { .add(.sibling($0), name: name, at: target.point) }
        case .child: edit = index.map { .add(.child($0), name: name, at: target.point) }
        case .group: edit = .add(.group, name: name, at: target.point)
        }
      }
      // The ghost stays until the rebuilt graph replaces it with the real node.
      if edit.flatMap({ onEdit?($0) }) != true { scene.hideGhost() }
    }

    public func control(
      _ control: NSControl, textView: NSTextView, doCommandBy selector: Selector
    ) -> Bool {
      switch selector {
      case #selector(cancelOperation(_:)), #selector(NSResponder.complete(_:)):
        finishNaming(commit: false)
      case #selector(insertNewline(_:)), #selector(insertTab(_:)):
        finishNaming(commit: true)
      default: return false
      }
      return true
    }

    /// Clicking elsewhere commits, like Finder.
    public func controlTextDidEndEditing(_ notification: Notification) {
      finishNaming(commit: true)
    }

    // MARK: Context menu

    public override func menu(for event: NSEvent) -> NSMenu? {
      finishNaming(commit: true)
      let p = point(event)
      let menu = NSMenu()
      menu.autoenablesItems = false
      func item(_ title: String, _ action: Selector, _ value: Any? = nil) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        item.representedObject = value
        return item
      }
      guard let index = scene.node(at: p, radius: 14), let model = scene.layout?.model else {
        let w = scene.camera.toWorld(p)
        menu.addItem(item("New Group", #selector(menuNewGroup(_:)), [w.x, w.y]))
        return menu
      }
      if selection != index { userSelect(index, camera: false) }
      let node = model.nodes[index]
      menu.addItem(item("Add Task", #selector(menuAddTask(_:))))
      menu.addItem(item("Add Subtask", #selector(menuAddSubtask(_:))))
      menu.addItem(item("Rename", #selector(menuRename(_:))))
      if node.depth > 0 {
        menu.addItem(item(node.done ? "Mark Not Done" : "Mark Done", #selector(menuToggleDone(_:))))
      }
      let priority = NSMenuItem(title: "Priority", action: nil, keyEquivalent: "")
      priority.submenu = NSMenu()
      priority.submenu?.autoenablesItems = false
      for (title, value) in [
        ("High", MapPriority.high), ("Medium", .medium), ("Low", .low), ("Chill", .chill),
      ] {
        let choice = item(title, #selector(menuPriority(_:)), value.rawValue)
        choice.state = node.priority == value ? .on : .off
        priority.submenu?.addItem(choice)
      }
      priority.submenu?.addItem(item("None", #selector(menuPriority(_:)), ""))
      menu.addItem(priority)
      menu.addItem(.separator())
      menu.addItem(item("Delete", #selector(menuDelete(_:))))
      return menu
    }

    @objc private func menuNewGroup(_ sender: NSMenuItem) {
      guard let w = sender.representedObject as? [Double] else { return }
      beginAdd(.group, at: LayoutPoint(x: w[0], y: w[1]))
    }
    @objc private func menuAddTask(_ sender: Any?) { addTask() }
    @objc private func menuAddSubtask(_ sender: Any?) { addSubtask() }
    @objc private func menuRename(_ sender: Any?) { selection.map(beginRename) }
    @objc private func menuToggleDone(_ sender: Any?) {
      selection.map { _ = onEdit?(.toggleDone($0)) }
    }
    @objc private func menuPriority(_ sender: NSMenuItem) {
      guard let selection, let raw = sender.representedObject as? String else { return }
      _ = onEdit?(.priority(selection, MapPriority(rawValue: raw)))
    }
    @objc private func menuDelete(_ sender: Any?) { deleteSelection() }
  }
#endif

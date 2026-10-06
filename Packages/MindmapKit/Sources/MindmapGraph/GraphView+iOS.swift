#if os(iOS)
  import MindmapCore
  import QuartzCore
  import UIKit

  /// One entry of the graph's long-press menu. The menu is built from these, so the DEBUG smoke
  /// harness runs exactly the actions the system menu shows.
  public struct GraphMenuItem {
    public let title: String
    public var symbol: String?
    public var checked = false
    public var destructive = false
    public var children: [GraphMenuItem] = []
    public var action: (@MainActor () -> Void)?
  }

  /// The iPad graph pane: the shared scene with touch, pointer and trackpad input. Tap selects,
  /// double-tap renames (or adds a group on empty canvas), a one-finger drag moves a node (⇧ or
  /// "Move Branch" brings its subtree) or pans, two fingers pan, pinch zooms, long-press opens
  /// the context menu. Motion and the camera live in the shared `GraphController`; the drag rules
  /// are the Mac's (the same `drag` and `drop`).
  public final class GraphView: UIView, UIGestureRecognizerDelegate,
    UIContextMenuInteractionDelegate, UIPointerInteractionDelegate, UITextFieldDelegate
  {
    public let controller = GraphController()
    public var scene: GraphScene { controller.scene }
    /// A node was dropped: the shown document, its path key and new world position.
    public var onPin: ((UUID, String, LayoutPoint) -> Void)?
    /// The user selected a node on the graph (tap, menu). Not called for `select(_:camera:)`.
    public var onSelect: ((Int?) -> Void)?
    /// Returns false when the edit couldn't be applied.
    public var onEdit: ((GraphEdit) -> Bool)?
    public var onFocus: ((Bool) -> Void)?
    /// A short message for the detail panel, such as how to use "Move Branch".
    public var onMessage: ((String) -> Void)?
    /// The store's undo manager (no editor before roadmap step i3), so the system undo
    /// commands and gestures reach graph edits.
    public var externalUndoManager: UndoManager?
    public var selection: Int? { scene.selection }
    public var isNaming: Bool { naming != nil }
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

    /// Touch hit circle around a dot, in view points (the Mac's mouse uses 14).
    static let touchRadius = 22.0
    /// Two taps this close in time and space are a double-tap.
    static let doubleTapInterval = 0.35
    static let doubleTapDistance = 30.0

    private var press: (point: CGPoint, camera: Camera, node: Int?, grab: CGPoint, subtree: Bool)?
    private var lastTap: (time: TimeInterval, point: CGPoint, node: Int?, world: CGPoint)?
    /// "Move Branch" armed for this node (a path key, so a rebuild can't shift it).
    private var branchKey: String?
    private enum NamingKind { case rename, sibling, child, group }
    /// Targets are path keys, resolved on commit, so a rebuild meanwhile can't shift them.
    private var naming: (kind: NamingKind, key: String?, point: LayoutPoint)?
    private lazy var field: NamingField = {
      let field = NamingField()
      field.borderStyle = .none
      field.backgroundColor = UIColor(cgColor: GraphStyle.canvas)
      field.textColor = UIColor(cgColor: GraphStyle.cached(GraphStyle.brightLabel))
      field.textAlignment = .center
      field.autocorrectionType = .no
      field.autocapitalizationType = .none
      field.returnKeyType = .done
      field.layer.borderColor = GraphStyle.cached(0x4f2fc4)
      field.layer.borderWidth = 1
      field.layer.cornerRadius = 4
      field.delegate = self
      field.onEscape = { [weak self] in self?.finishNaming(commit: false) }
      return field
    }()
    /// Where the context menu points: an invisible view at the pressed node or spot.
    private let menuAnchor = UIView()
    private var sceneObservers: [NSObjectProtocol] = []

    public override init(frame: CGRect) {
      super.init(frame: frame)
      isOpaque = true
      backgroundColor = UIColor(cgColor: GraphStyle.canvas)
      layer.addSublayer(scene.root)
      scene.setSize(frame.size)
      controller.makeDisplayLink = { [weak self] in
        guard let self, let window = self.window,
          window.windowScene?.activationState != .background
        else { return nil }
        let link = CADisplayLink(
          target: self.controller, selector: #selector(GraphController.displayFrame(_:)))
        // ProMotion iPads settle at up to 120 Hz; the link exists only while the graph moves.
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 120, preferred: 120)
        return link
      }
      menuAnchor.isUserInteractionEnabled = false
      menuAnchor.backgroundColor = .clear
      addSubview(menuAnchor)
      installGestures()
      let buttons = [
        button("plus", "Zoom in", #selector(zoomInTapped)),
        button("minus", "Zoom out", #selector(zoomOutTapped)),
        button("arrow.up.left.and.arrow.down.right", "Fit all", #selector(fitTapped)),
      ]
      for (i, b) in buttons.enumerated() {
        // Prototype: 28 px buttons, 6 apart, 10 from the top and 12 from the right.
        b.frame = CGRect(
          x: frame.width - 12 - 28 - Double(2 - i) * 34, y: 10, width: 28, height: 28)
        b.autoresizingMask = [.flexibleLeftMargin, .flexibleBottomMargin]
        addSubview(b)
      }
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    /// Prototype `.zb` button: #232326 fill, 0.5 px #3a3a3c border, 6 px corners, #a1a1a6 icon.
    private func button(_ symbol: String, _ label: String, _ action: Selector) -> UIView {
      let b = UIButton(type: .system)
      b.setImage(
        UIImage(
          systemName: symbol,
          withConfiguration: UIImage.SymbolConfiguration(pointSize: 11, weight: .regular)),
        for: .normal)
      b.tintColor = UIColor(cgColor: GraphStyle.color(0xa1a1a6))
      b.backgroundColor = UIColor(cgColor: GraphStyle.color(0x232326))
      b.layer.borderColor = GraphStyle.color(0x3a3a3c)
      b.layer.borderWidth = 0.5
      b.layer.cornerRadius = 6
      b.accessibilityLabel = label
      b.isPointerInteractionEnabled = true
      b.addTarget(self, action: action, for: .touchUpInside)
      return b
    }

    @objc private func zoomInTapped() { zoomIn() }
    @objc private func zoomOutTapped() { zoomOut() }
    @objc private func fitTapped() { fitAll() }

    public override var canBecomeFirstResponder: Bool { true }
    public override var undoManager: UndoManager? { externalUndoManager ?? super.undoManager }

    public override func becomeFirstResponder() -> Bool {
      let became = super.becomeFirstResponder()
      if became { onFocus?(true) }
      return became
    }

    public override func resignFirstResponder() -> Bool {
      let resigned = super.resignFirstResponder()
      if resigned { onFocus?(false) }
      return resigned
    }

    /// Saved positions show immediately. Fresh layouts and local edits animate off the main thread.
    /// `refit` (new map, reshuffle) goes back to fitting everything.
    public func show(
      _ simulation: LayoutSimulation, title: String, refit: Bool, reuseNodes: Bool = true,
      document: UUID
    ) {
      if controller.document != document {
        finishNaming(commit: false)
        branchKey = nil
      }
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

    public override func layoutSubviews() {
      super.layoutSubviews()
      controller.resize(to: bounds.size)
    }

    /// No window, or a scene in the background (another app, the app switcher, a locked
    /// screen): no display link, so nothing moves or draws off screen.
    public override func didMoveToWindow() {
      super.didMoveToWindow()
      for observer in sceneObservers { NotificationCenter.default.removeObserver(observer) }
      sceneObservers = []
      guard let window else { return controller.pauseMotion() }
      scene.screenScale = window.traitCollection.displayScale
      if let windowScene = window.windowScene {
        let center = NotificationCenter.default
        sceneObservers = [
          center.addObserver(
            forName: UIScene.didEnterBackgroundNotification, object: windowScene, queue: .main
          ) { [weak self] _ in MainActor.assumeIsolated { self?.sceneVisibilityChanged(false) } },
          center.addObserver(
            forName: UIScene.willEnterForegroundNotification, object: windowScene, queue: .main
          ) { [weak self] _ in MainActor.assumeIsolated { self?.sceneVisibilityChanged(true) } },
        ]
      }
      controller.resumeMotion()
    }

    private func sceneVisibilityChanged(_ visible: Bool) {
      if visible { controller.resumeMotion() } else { controller.pauseMotion() }
    }

    // MARK: Camera commands

    public func zoomIn() { controller.zoomIn() }
    public func zoomOut() { controller.zoomOut() }
    public func fitAll() { controller.fitAll() }
    public func zoom(by factor: Double) { controller.zoom(by: factor) }

    // MARK: Gestures

    private func installGestures() {
      let tap = UITapGestureRecognizer(target: self, action: #selector(tapRecognized(_:)))
      tap.delegate = self
      addGestureRecognizer(tap)
      // One finger drags a node or pans; two fingers pan. Pointer drags count as one finger.
      let pan = UIPanGestureRecognizer(target: self, action: #selector(panRecognized(_:)))
      pan.maximumNumberOfTouches = 2
      pan.delegate = self
      addGestureRecognizer(pan)
      // Trackpad two-finger scrolls and mouse wheels pan.
      let scroll = UIPanGestureRecognizer(target: self, action: #selector(scrollRecognized(_:)))
      scroll.allowedScrollTypesMask = .all
      scroll.allowedTouchTypes = []
      scroll.delegate = self
      addGestureRecognizer(scroll)
      let pinch = UIPinchGestureRecognizer(target: self, action: #selector(pinchRecognized(_:)))
      pinch.delegate = self
      addGestureRecognizer(pinch)
      addInteraction(UIContextMenuInteraction(delegate: self))
      addInteraction(UIPointerInteraction(delegate: self))
    }

    public func gestureRecognizer(
      _ gestureRecognizer: UIGestureRecognizer,
      shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer
    ) -> Bool {
      // Pinch and pan together: zoom about the fingers while they move.
      (gestureRecognizer is UIPinchGestureRecognizer && other is UIPanGestureRecognizer)
        || (gestureRecognizer is UIPanGestureRecognizer && other is UIPinchGestureRecognizer)
    }

    /// Buttons and the name field keep their own touches.
    public func gestureRecognizer(
      _ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch
    ) -> Bool {
      !(touch.view is UIControl)
    }

    public override func gestureRecognizerShouldBegin(_ recognizer: UIGestureRecognizer) -> Bool {
      // No zooming while a finger holds a node.
      if recognizer is UIPinchGestureRecognizer { return press?.node == nil }
      return super.gestureRecognizerShouldBegin(recognizer)
    }

    @objc private func tapRecognized(_ recognizer: UITapGestureRecognizer) {
      guard recognizer.state == .ended else { return }
      handleTap(at: recognizer.location(in: self), time: CACurrentMediaTime())
    }

    @objc private func panRecognized(_ recognizer: UIPanGestureRecognizer) {
      let p = recognizer.location(in: self)
      switch recognizer.state {
      case .began:
        let t = recognizer.translation(in: self)
        touchDown(
          at: CGPoint(x: p.x - t.x, y: p.y - t.y),
          shift: recognizer.modifierFlags.contains(.shift),
          fingers: recognizer.numberOfTouches)
        touchMoved(to: p)
      case .changed: touchMoved(to: p)
      case .ended, .cancelled, .failed: touchUp()
      default: break
      }
    }

    @objc private func scrollRecognized(_ recognizer: UIPanGestureRecognizer) {
      guard recognizer.state == .began || recognizer.state == .changed else { return }
      pan(by: recognizer.translation(in: self))
      recognizer.setTranslation(.zero, in: self)
    }

    @objc private func pinchRecognized(_ recognizer: UIPinchGestureRecognizer) {
      guard recognizer.state == .began || recognizer.state == .changed else { return }
      pinch(by: recognizer.scale, about: recognizer.location(in: self))
      recognizer.scale = 1
    }

    // MARK: Input (gesture recognizers and the DEBUG hooks both call these)

    /// A single tap selects (or clears and fits all); a second tap within 0.35 s renames the
    /// node the first one hit, or adds a group where it landed. Tapping away cancels naming.
    func handleTap(at point: CGPoint, time: TimeInterval) {
      if naming != nil {
        finishNaming(commit: false)
        lastTap = nil
        return
      }
      if !isFirstResponder { _ = becomeFirstResponder() }
      if let last = lastTap, time - last.time <= Self.doubleTapInterval,
        hypot(point.x - last.point.x, point.y - last.point.y) <= Self.doubleTapDistance
      {
        lastTap = nil
        if let node = last.node {
          beginRename(node)
        } else {
          beginAdd(.group, at: LayoutPoint(x: last.world.x, y: last.world.y))
        }
        return
      }
      let camera = scene.visibleCamera
      let node = scene.node(at: point, radius: Self.touchRadius)
      lastTap = (time, point, node, camera.toWorld(point))
      branchKey = nil
      userSelect(node)
    }

    /// A finger (or the pointer) went down and started moving. On a node it drags that node;
    /// with ⇧ held or "Move Branch" armed for it, the node brings its subtree.
    func touchDown(at point: CGPoint, shift: Bool, fingers: Int = 1) {
      finishNaming(commit: false)
      lastTap = nil
      let camera = scene.visibleCamera
      scene.setCamera(camera)
      let node = fingers > 1 ? nil : scene.node(at: point, radius: Self.touchRadius)
      var grab = CGPoint.zero
      var subtree = shift
      if let node, let layout = scene.layout {
        let n = layout.nodes[node]
        let w = camera.toWorld(point)
        grab = CGPoint(x: n.x - w.x, y: n.y - w.y)
        subtree = subtree || layout.model.nodes[node].pathKey == branchKey
      }
      press = (point, camera, node, grab, subtree)
    }

    func touchMoved(to point: CGPoint) {
      guard let press else { return }
      if let node = press.node {
        let w = press.camera.toWorld(point)
        controller.drag(
          node, to: LayoutPoint(x: w.x + press.grab.x, y: w.y + press.grab.y),
          subtree: press.subtree)
      } else {
        // Relative to the visible camera, so a pinch at the same time composes with it.
        let camera = scene.visibleCamera
        let shown = camera.toScreen(press.camera.toWorld(press.point))
        controller.move(camera.panned(by: CGPoint(x: point.x - shown.x, y: point.y - shown.y)))
      }
    }

    /// Lets go: a dragged node is pinned where it is shown and the graph settles around it.
    func touchUp() {
      defer { press = nil }
      guard let press, let node = press.node, let layout = scene.layout else { return }
      if press.subtree { branchKey = nil }
      let n = layout.nodes[node]
      controller.drop(node, subtree: press.subtree)
      if let document {
        onPin?(document, layout.model.nodes[node].pathKey, LayoutPoint(x: n.x, y: n.y))
      }
    }

    /// Two-finger and trackpad pans.
    func pan(by delta: CGPoint) {
      finishNaming(commit: false)
      controller.move(scene.visibleCamera.panned(by: delta))
    }

    /// Pinch: zoom about the pinch center within the Mac's limits (1/10 to 10× fit all).
    func pinch(by factor: Double, about point: CGPoint) {
      finishNaming(commit: false)
      controller.move(
        scene.visibleCamera.zoomed(by: factor, about: point, limits: controller.limits))
    }

    // MARK: Selection

    /// Highlights `index` (nil clears). With `camera`, animates to fit the highlight, or back to
    /// fit all when a selection was cleared.
    public func select(_ index: Int?, camera: Bool) { controller.select(index, camera: camera) }

    private func userSelect(_ index: Int?, camera: Bool = true) {
      select(index, camera: camera)
      onSelect?(scene.selection)
    }

    public func clearSelection() { userSelect(nil) }

    public func addTask() { selection.map { beginAdd(.sibling($0)) } }
    public func addSubtask() { selection.map { beginAdd(.child($0)) } }
    public func deleteSelection() { selection.map { _ = onEdit?(.delete($0)) } }

    // MARK: Context menu

    /// The long-press menu at a view point. On a node it selects the node (no camera move) and
    /// offers Add Task, Add Subtask, Rename, Mark Done/Not Done (tasks), Priority, Move Branch and
    /// Delete; on empty canvas, New Group there.
    public func menuItems(at point: CGPoint) -> [GraphMenuItem] {
      finishNaming(commit: false)
      guard let index = scene.node(at: point, radius: Self.touchRadius),
        let model = scene.layout?.model
      else {
        let w = scene.camera.toWorld(point)
        return [
          GraphMenuItem(title: "New Group", symbol: "plus.circle") { [weak self] in
            self?.beginAdd(.group, at: LayoutPoint(x: w.x, y: w.y))
          }
        ]
      }
      if selection != index { userSelect(index, camera: false) }
      let node = model.nodes[index]
      let key = node.pathKey
      var items = [
        GraphMenuItem(title: "Add Task", symbol: "plus") { [weak self] in self?.addTask() },
        GraphMenuItem(title: "Add Subtask", symbol: "arrow.turn.down.right") { [weak self] in
          self?.addSubtask()
        },
        GraphMenuItem(title: "Rename", symbol: "pencil") { [weak self] in
          guard let self, let i = self.selection else { return }
          self.beginRename(i)
        },
      ]
      if node.depth > 0 {
        items.append(
          GraphMenuItem(
            title: node.done ? "Mark Not Done" : "Mark Done",
            symbol: node.done ? "circle" : "checkmark.circle"
          ) { [weak self] in
            guard let self, let i = self.selection else { return }
            _ = self.onEdit?(.toggleDone(i))
          })
      }
      let priorities: [(String, MapPriority?)] = [
        ("High", .high), ("Medium", .medium), ("Low", .low), ("Chill", .chill), ("None", nil),
      ]
      items.append(
        GraphMenuItem(
          title: "Priority", symbol: "flag",
          children: priorities.map { title, value in
            GraphMenuItem(title: title, checked: value != nil && node.priority == value) {
              [weak self] in
              guard let self, let i = self.selection else { return }
              _ = self.onEdit?(.priority(i, value))
            }
          }))
      items.append(
        GraphMenuItem(title: "Move Branch", symbol: "arrow.up.and.down.and.arrow.left.and.right") {
          [weak self] in
          self?.branchKey = key
          self?.onMessage?("drag the node to move its branch")
        })
      items.append(
        GraphMenuItem(title: "Delete", symbol: "trash", destructive: true) { [weak self] in
          self?.deleteSelection()
        })
      return items
    }

    private static func menu(_ items: [GraphMenuItem]) -> [UIMenuElement] {
      var elements: [UIMenuElement] = items.filter { !$0.destructive }.map(element)
      let destructive = items.filter(\.destructive).map(element)
      // Delete sits apart, like the Mac menu's separator.
      if !destructive.isEmpty {
        elements.append(UIMenu(title: "", options: .displayInline, children: destructive))
      }
      return elements
    }

    private static func element(_ item: GraphMenuItem) -> UIMenuElement {
      let image = item.symbol.flatMap { UIImage(systemName: $0) }
      if !item.children.isEmpty {
        return UIMenu(title: item.title, image: image, children: item.children.map(element))
      }
      let action = item.action
      return UIAction(
        title: item.title, image: image,
        attributes: item.destructive ? .destructive : [], state: item.checked ? .on : .off
      ) { _ in MainActor.assumeIsolated { action?() } }
    }

    public func contextMenuInteraction(
      _ interaction: UIContextMenuInteraction,
      configurationForMenuAtLocation location: CGPoint
    ) -> UIContextMenuConfiguration? {
      guard press == nil else { return nil }
      lastTap = nil
      let items = menuItems(at: location)
      var anchor = location
      if let index = scene.node(at: location, radius: Self.touchRadius),
        let n = scene.layout?.nodes[index]
      {
        anchor = scene.camera.toScreen(CGPoint(x: n.x, y: n.y))
      }
      menuAnchor.frame = CGRect(x: anchor.x - 12, y: anchor.y - 12, width: 24, height: 24)
      let menu = UIMenu(children: Self.menu(items))
      return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { _ in menu }
    }

    /// The menu points at the node without lifting a snapshot of the whole graph.
    public func contextMenuInteraction(
      _ interaction: UIContextMenuInteraction, configuration: UIContextMenuConfiguration,
      highlightPreviewForItemWithIdentifier identifier: any NSCopying
    ) -> UITargetedPreview? { anchorPreview }

    public func contextMenuInteraction(
      _ interaction: UIContextMenuInteraction, configuration: UIContextMenuConfiguration,
      dismissalPreviewForItemWithIdentifier identifier: any NSCopying
    ) -> UITargetedPreview? { anchorPreview }

    private var anchorPreview: UITargetedPreview {
      let parameters = UIPreviewParameters()
      parameters.backgroundColor = .clear
      parameters.visiblePath = UIBezierPath(ovalIn: menuAnchor.bounds)
      return UITargetedPreview(view: menuAnchor, parameters: parameters)
    }

    // MARK: Pointer

    /// The node under the pointer, if any: hovering hugs its dot.
    func hoverNode(at point: CGPoint) -> Int? {
      press == nil ? scene.node(at: point, radius: 14) : nil
    }

    public func pointerInteraction(
      _ interaction: UIPointerInteraction, regionFor request: UIPointerRegionRequest,
      defaultRegion: UIPointerRegion
    ) -> UIPointerRegion? {
      guard let index = hoverNode(at: request.location), let n = scene.layout?.nodes[index] else {
        return defaultRegion
      }
      let c = scene.camera.toScreen(CGPoint(x: n.x, y: n.y))
      let r = max(n.radius * scene.camera.zoom, 6) + 6
      return UIPointerRegion(
        rect: CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2),
        identifier: NSNumber(value: index))
    }

    public func pointerInteraction(
      _ interaction: UIPointerInteraction, styleFor region: UIPointerRegion
    ) -> UIPointerStyle? {
      guard region.identifier is NSNumber else { return nil }
      return UIPointerStyle(
        shape: .roundedRect(region.rect, radius: region.rect.width / 2), constrainedAxes: [])
    }

    // MARK: Naming on the graph

    /// Shows the new node's dot and an empty name field: by its parent (the spawn rule), or at
    /// `point` for a group. Nothing reaches the text until the name is committed.
    public func beginAdd(_ add: GraphAdd, at point: LayoutPoint? = nil) {
      finishNaming(commit: false)
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

    /// Double-tap on a label: edit the name in place. Return saves; Esc or tapping away cancels.
    public func beginRename(_ index: Int) {
      finishNaming(commit: false)
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
      let size = max(13, min(28, fontSize * scene.camera.zoom))
      let font = GraphStyle.font(family: scene.labelFamily, size: size) as UIFont
      field.font = font
      field.text = text
      let width = max(180, (text as NSString).size(withAttributes: [.font: font]).width + 44)
      let height = ceil(size * 1.5) + 10
      // Where the label starts: just below the dot.
      let top = scene.camera.toScreen(
        CGPoint(x: target.point.x, y: target.point.y + radius + 2))
      field.frame = CGRect(x: top.x - width / 2, y: top.y, width: width, height: height)
      addSubview(field)
      field.becomeFirstResponder()
      field.selectedTextRange = field.textRange(
        from: field.beginningOfDocument, to: field.endOfDocument)
    }

    /// Commits a non-empty name (as a rename or an insert) or cancels. An empty new node is never
    /// written, so cancelling it leaves the text as it was.
    public func finishNaming(commit: Bool) {
      guard let target = naming else { return }
      naming = nil
      let name = (field.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
      if field.isFirstResponder { _ = becomeFirstResponder() }
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

    public func textFieldShouldReturn(_ textField: UITextField) -> Bool {
      finishNaming(commit: true)
      return false
    }

    /// The keyboard went away some other way (its hide key): cancel, like tapping away.
    public func textFieldDidEndEditing(_ textField: UITextField) {
      finishNaming(commit: false)
    }

    #if DEBUG
      public static var debugLiveDisplayLinks: Int { GraphController.debugLiveDisplayLinks }
      public static var debugIdleFrames: Int { GraphController.debugIdleFrames }
      /// The inline name field's text while naming, else nil.
      public var debugNamingText: String? { naming == nil ? nil : field.text }
      public var debugBranchArmed: Bool { branchKey != nil }
      public func debugSetNamingText(_ text: String) { field.text = text }
      public func debugTap(at point: CGPoint) { handleTap(at: point, time: CACurrentMediaTime()) }
      public func debugDoubleTap(at point: CGPoint) {
        let time = CACurrentMediaTime()
        handleTap(at: point, time: time)
        handleTap(at: point, time: time + 0.1)
      }
      public func debugTouchDown(at point: CGPoint, shift: Bool = false, fingers: Int = 1) {
        touchDown(at: point, shift: shift, fingers: fingers)
      }
      public func debugTouchMove(to point: CGPoint) { touchMoved(to: point) }
      public func debugTouchUp() { touchUp() }
      public func debugPan(by delta: CGPoint) { pan(by: delta) }
      public func debugPinch(by factor: Double, about point: CGPoint) {
        pinch(by: factor, about: point)
      }
      public func debugHoverNode(at point: CGPoint) -> Int? { hoverNode(at: point) }
      public func debugReturnKey() { _ = textFieldShouldReturn(field) }
      public func debugEscapeKey() { field.onEscape?() }
      public func debugScene(visible: Bool) { sceneVisibilityChanged(visible) }
      /// Shows the real context menu for a screenshot. UIKit has no public call for this, so
      /// DEBUG builds use the interaction's private presenter; Release never contains it.
      public func debugPresentMenu(at point: CGPoint) -> Bool {
        guard
          let interaction = interactions.compactMap({ $0 as? UIContextMenuInteraction }).first
        else { return false }
        let selector = NSSelectorFromString("_presentMenuAtLocation:")
        guard interaction.responds(to: selector) else { return false }
        typealias Present = @convention(c) (AnyObject, Selector, CGPoint) -> Void
        let present = unsafeBitCast(interaction.method(for: selector), to: Present.self)
        present(interaction, selector, point)
        return true
      }
    #endif
  }

  /// The inline name field. Esc cancels (UIKit text fields ignore it).
  final class NamingField: UITextField {
    var onEscape: (@MainActor () -> Void)?

    override var keyCommands: [UIKeyCommand]? {
      let escape = UIKeyCommand(
        input: UIKeyCommand.inputEscape, modifierFlags: [], action: #selector(escapePressed))
      escape.wantsPriorityOverSystemBehavior = true
      return [escape]
    }

    @objc private func escapePressed() { onEscape?() }
  }
#endif

#if os(iOS)
  import MindmapCore
  import QuartzCore
  import UIKit

  /// The iPad graph pane: hosts the shared scene and runs its settle. Touch input comes with
  /// roadmap step i2. Motion and the camera live in the shared `GraphController`.
  public final class GraphView: UIView {
    public let controller = GraphController()
    public var scene: GraphScene { controller.scene }

    public override init(frame: CGRect) {
      super.init(frame: frame)
      isOpaque = true
      layer.addSublayer(scene.root)
      scene.setSize(frame.size)
      controller.makeDisplayLink = { [weak self] in
        guard let self, self.window != nil else { return nil }
        let link = CADisplayLink(
          target: self.controller, selector: #selector(GraphController.displayFrame(_:)))
        // ProMotion iPads settle at up to 120 Hz; the link exists only while the graph moves.
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 120, preferred: 120)
        return link
      }
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    public func show(
      _ simulation: LayoutSimulation, title: String, refit: Bool, reuseNodes: Bool = true,
      document: UUID
    ) {
      controller.show(
        simulation, title: title, refit: refit, reuseNodes: reuseNodes, document: document)
    }

    public override func layoutSubviews() {
      super.layoutSubviews()
      controller.resize(to: bounds.size)
    }

    public override func didMoveToWindow() {
      super.didMoveToWindow()
      if let window {
        scene.screenScale = window.traitCollection.displayScale
        controller.resumeMotion()
      } else {
        controller.pauseMotion()
      }
    }
  }
#endif

import CoreGraphics

/// Maps world units to view points (both y down): screen = world × zoom + offset.
public struct Camera: Sendable, Equatable {
  public var zoom: Double
  public var offset: CGPoint

  public init(zoom: Double = 1, offset: CGPoint = .zero) {
    self.zoom = zoom
    self.offset = offset
  }

  public func toWorld(_ p: CGPoint) -> CGPoint {
    CGPoint(x: (p.x - offset.x) / zoom, y: (p.y - offset.y) / zoom)
  }

  public func toScreen(_ p: CGPoint) -> CGPoint {
    CGPoint(x: p.x * zoom + offset.x, y: p.y * zoom + offset.y)
  }

  /// Prototype fitBox(): pad the box, match the view's aspect, never narrower than 380 units.
  public static func fit(_ box: CGRect, in size: CGSize, padding: Double = 30) -> Camera {
    guard size.width > 0, size.height > 0 else { return Camera() }
    var box = box.isNull || box.isEmpty ? CGRect(x: -200, y: -150, width: 400, height: 300) : box
    box = box.insetBy(dx: -padding, dy: -padding)
    let aspect = size.width / size.height
    if box.width / box.height < aspect {
      box = box.insetBy(dx: -(box.height * aspect - box.width) / 2, dy: 0)
    } else {
      box = box.insetBy(dx: 0, dy: -(box.width / aspect - box.height) / 2)
    }
    if box.width < 380 {
      let k = 380 / box.width
      box = box.insetBy(
        dx: -(box.width * k - box.width) / 2, dy: -(box.height * k - box.height) / 2)
    }
    let zoom = size.width / box.width
    return Camera(zoom: zoom, offset: CGPoint(x: -box.minX * zoom, y: -box.minY * zoom))
  }

  /// Zoom range: 1/10 of "fit all" out to 10× in.
  public static func limits(fitZoom: Double) -> ClosedRange<Double> {
    (fitZoom / 10)...(fitZoom * 10)
  }

  /// Zooms by `factor` keeping `anchor` (a view point) fixed, clamped to `limits`.
  public func zoomed(by factor: Double, about anchor: CGPoint, limits: ClosedRange<Double>)
    -> Camera
  {
    let target = min(max(zoom * factor, limits.lowerBound), limits.upperBound)
    let world = toWorld(anchor)
    return Camera(
      zoom: target, offset: CGPoint(x: anchor.x - world.x * target, y: anchor.y - world.y * target))
  }

  public func panned(by delta: CGPoint) -> Camera {
    Camera(zoom: zoom, offset: CGPoint(x: offset.x + delta.x, y: offset.y + delta.y))
  }
}

extension GraphLayout {
  /// Bounds of every label box, as the prototype's fitBox() measures them.
  public var bounds: CGRect {
    nodes.reduce(CGRect.null) {
      $0.union(
        CGRect(
          x: $1.x - $1.halfWidth, y: $1.y - $1.up, width: $1.halfWidth * 2, height: $1.up + $1.down)
      )
    }
  }
}

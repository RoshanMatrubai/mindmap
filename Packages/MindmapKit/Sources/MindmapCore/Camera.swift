import CoreGraphics
import Foundation

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

extension Camera {
  /// One update of a touch gesture: a pinch, or with `minimumTouches: 1` a pan. The content point
  /// under `previousCentroid` moves to `centroid` and the zoom changes by `scale` about it, so it
  /// stays under the fingers. The camera stays exactly where it is when fewer than
  /// `minimumTouches` touches are down, or on a frame where the touch count changed: a lifted
  /// (or added) finger moves the centroid without the content moving under the fingers.
  public func gestureStep(
    from previousCentroid: CGPoint, to centroid: CGPoint, scale: Double, touches: Int,
    previousTouches: Int, minimumTouches: Int = 2, limits: ClosedRange<Double>
  ) -> Camera {
    guard touches >= minimumTouches, touches == previousTouches else { return self }
    return panned(
      by: CGPoint(x: centroid.x - previousCentroid.x, y: centroid.y - previousCentroid.y)
    )
    .zoomed(by: scale, about: centroid, limits: limits)
  }
}

/// Scroll wheel deltas to zoom factors, shared by the Mac and iPad so one wheel notch zooms the
/// same everywhere: 12% per notch.
public enum ScrollZoom {
  /// One wheel notch: one line on the Mac, or 10 points of precise (smooth-scrolling) delta.
  public static let perNotch = 1.12
  public static let pointsPerNotch = 10.0

  /// The Mac: a line wheel's lines, or a precise delta in points, proportionally, at most 1.5×
  /// (3.5 notches) per event, as AppKit can coalesce several notches into one event.
  public static func mac(_ delta: Double, precise: Bool) -> Double {
    let notches = max(-3.5, min(3.5, precise ? delta / pointsPerNotch : delta))
    return pow(perNotch, notches)
  }

  /// The iPad's discrete scrolls (a mouse wheel, or the Mac's mouse through Universal Control):
  /// UIKit reports each notch as one event of several points, so a delta is read in points and
  /// one event zooms at most one notch, however large its delta. Small deltas stay proportional.
  public static func iPadWheel(_ delta: Double) -> Double {
    pow(perNotch, max(-1, min(1, delta / pointsPerNotch)))
  }
}

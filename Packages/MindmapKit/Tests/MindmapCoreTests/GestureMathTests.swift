import CoreGraphics
import Foundation
import MindmapCore
import Testing

private let limits = 0.01...100.0

@Test func pinchKeepsTheContentUnderTheCentroid() {
  let camera = Camera(zoom: 1.3, offset: CGPoint(x: 40, y: -25))
  let previous = CGPoint(x: 300, y: 420)
  let centroid = CGPoint(x: 318, y: 401)
  let world = camera.toWorld(previous)
  let next = camera.gestureStep(
    from: previous, to: centroid, scale: 1.4, touches: 2, previousTouches: 2, limits: limits)
  let shown = next.toScreen(world)
  #expect(abs(shown.x - centroid.x) < 1e-9 && abs(shown.y - centroid.y) < 1e-9)
  #expect(abs(next.zoom - 1.3 * 1.4) < 1e-12)
}

@Test func oneTouchLeftMovesNothing() {
  let camera = Camera(zoom: 2, offset: CGPoint(x: 10, y: 10))
  // One finger lifted earlier: the centroid is now the other finger, far away.
  let next = camera.gestureStep(
    from: CGPoint(x: 300, y: 300), to: CGPoint(x: 520, y: 140), scale: 1.05, touches: 1,
    previousTouches: 1, limits: limits)
  #expect(next == camera)
}

@Test func theFrameATouchLiftsMovesNothing() {
  let camera = Camera(zoom: 2, offset: CGPoint(x: 10, y: 10))
  let next = camera.gestureStep(
    from: CGPoint(x: 300, y: 300), to: CGPoint(x: 520, y: 140), scale: 0.98, touches: 1,
    previousTouches: 2, limits: limits)
  #expect(next == camera)
  // A one-finger pan also skips the frame its touch count changes (a finger lands or lifts).
  let pan = camera.gestureStep(
    from: CGPoint(x: 300, y: 300), to: CGPoint(x: 520, y: 140), scale: 1, touches: 1,
    previousTouches: 2, minimumTouches: 1, limits: limits)
  #expect(pan == camera)
}

@Test func onePanAfterAPinchStartsFromZero() {
  let camera = Camera(zoom: 2, offset: CGPoint(x: 10, y: 10))
  let next = camera.gestureStep(
    from: CGPoint(x: 100, y: 100), to: CGPoint(x: 112, y: 95), scale: 1, touches: 1,
    previousTouches: 1, minimumTouches: 1, limits: limits)
  #expect(next.zoom == 2 && next.offset == CGPoint(x: 22, y: 5))
}

@Test func pinchScaleIsClamped() {
  let camera = Camera(zoom: 2, offset: .zero)
  let p = CGPoint(x: 200, y: 200)
  let bounded = 1.0...4.0
  let up = camera.gestureStep(
    from: p, to: p, scale: 100, touches: 2, previousTouches: 2, limits: bounded)
  #expect(up.zoom == 4)
  let down = camera.gestureStep(
    from: p, to: p, scale: 0.001, touches: 2, previousTouches: 2, limits: bounded)
  #expect(down.zoom == 1)
  // The clamped zoom still keeps the point under the centroid.
  let world = camera.toWorld(p)
  #expect(abs(up.toScreen(world).x - p.x) < 1e-9)
}

@Test func oneIPadWheelNotchIsOneMacNotch() {
  let macNotch = ScrollZoom.mac(1, precise: false)
  #expect(macNotch == 1.12)
  #expect(ScrollZoom.mac(10, precise: true) == macNotch)
  // A notch arrives as one discrete event of several points; any size is one notch.
  for delta in [10.0, 16, 40, 120] {
    #expect(ScrollZoom.iPadWheel(delta) == macNotch)
    #expect(abs(ScrollZoom.iPadWheel(-delta) - 1 / macNotch) < 1e-12)
  }
}

@Test func hugeScrollDeltasAreClamped() {
  #expect(ScrollZoom.iPadWheel(10_000) == 1.12)
  #expect(abs(ScrollZoom.iPadWheel(-10_000) - 1 / 1.12) < 1e-12)
  #expect(ScrollZoom.mac(10_000, precise: true) == pow(1.12, 3.5))
  #expect(ScrollZoom.mac(10_000, precise: true) < 1.5)
}

@Test func smallScrollDeltasZoomSmoothly() {
  #expect(abs(ScrollZoom.mac(2.5, precise: true) - pow(1.12, 0.25)) < 1e-12)
  #expect(abs(ScrollZoom.iPadWheel(2.5) - pow(1.12, 0.25)) < 1e-12)
  #expect(ScrollZoom.iPadWheel(0) == 1)
}

import CoreText
import Foundation
import os

struct LabelRasterKey: Hashable, Sendable {
  var look: NodeLook
  var font: String
  var scale: Double
}

struct LabelRasterResult: Sendable {
  var key: LabelRasterKey
  var image: CGImage
}

/// A bounded memory-only cache. Keys include text, font, size, scale and every drawn style.
actor LabelRasterCache {
  static let shared = LabelRasterCache()
  private var images: [LabelRasterKey: CGImage] = [:]
  private var order: [LabelRasterKey] = []

  func render(_ keys: [LabelRasterKey]) -> [LabelRasterResult] {
    let perf = OSLog(
      subsystem: Bundle.main.bundleIdentifier ?? "mindmap-preview", category: "motion")
    let log = Logger(
      subsystem: Bundle.main.bundleIdentifier ?? "mindmap-preview", category: "motion")
    let started = ContinuousClock.now
    os_signpost(.begin, log: perf, name: "LabelRasterization")
    var result: [LabelRasterResult] = []
    var misses = 0
    for key in keys {
      if Task.isCancelled { break }
      if let image = images[key] {
        result.append(LabelRasterResult(key: key, image: image))
      } else if let image = NodeRaster.image(look: key.look, scale: key.scale) {
        misses += 1
        images[key] = image
        order.append(key)
        result.append(LabelRasterResult(key: key, image: image))
        if order.count > 2048 { images.removeValue(forKey: order.removeFirst()) }
      }
    }
    os_signpost(.end, log: perf, name: "LabelRasterization")
    let duration = started.duration(to: .now)
    let ms =
      Double(duration.components.seconds) * 1000
      + Double(duration.components.attoseconds) / 1e15
    log.notice(
      "label-raster count=\(keys.count) misses=\(misses) ms=\(ms, privacy: .public)")
    return result
  }
}

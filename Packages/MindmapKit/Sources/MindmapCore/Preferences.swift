import Foundation

/// App-wide settings (docs/design.md "Settings"). Each value has its own UserDefaults key, so a
/// launch argument such as `-labelFont Quicksand` overrides it. Values are clamped on load.
public struct Preferences: Equatable, Sendable {
  /// `textSize` is the label size.
  public var forces = ForceParams()
  public var animateSettle = true
  public var labelFont = "Nunito Sans"
  public var editorFontSize = 13.0
  public var showForcesPanel = false

  public static let labelSizeRange = 0.6...2.0
  public static let labelSizeStep = 0.05
  public static let centerRange = 0.0...0.12
  public static let repelRange = 50.0...2000
  public static let linkForceRange = 0.05...1.5
  public static let linkDistanceRange = 20.0...200
  public static let editorFontSizeRange = 11.0...18

  public init() {}

  public var labelSize: Double {
    get { forces.textSize }
    set { forces.textSize = newValue }
  }

  /// ⌥⌘= / ⌥⌘-: moves the label size by whole steps on the 0.05 grid, within range.
  public mutating func stepLabelSize(by steps: Int) {
    let grid = (labelSize / Self.labelSizeStep).rounded() + Double(steps)
    labelSize = Self.clamp(grid * Self.labelSizeStep, Self.labelSizeRange, 1)
  }

  /// The layout forces changed (label size aside), which calls for a reshuffle.
  public func forcesDiffer(from other: Preferences) -> Bool {
    var mine = forces
    mine.textSize = other.forces.textSize
    return mine != other.forces
  }

  private enum Key {
    static let labelSize = "labelSize"
    static let center = "center"
    static let repel = "repel"
    static let linkForce = "linkForce"
    static let linkDistance = "linkDistance"
    static let urgency = "urgency"
    static let animateSettle = "animateSettle"
    static let labelFont = "labelFont"
    static let editorFontSize = "editorFontSize"
    static let showForcesPanel = "showForcesPanel"
  }

  public init(defaults: UserDefaults) {
    let fallback = Preferences()
    func number(_ key: String, _ range: ClosedRange<Double>, _ value: Double) -> Double {
      defaults.object(forKey: key) == nil
        ? value : Self.clamp(defaults.double(forKey: key), range, value)
    }
    func flag(_ key: String, _ value: Bool) -> Bool {
      defaults.object(forKey: key) == nil ? value : defaults.bool(forKey: key)
    }
    forces.textSize = number(Key.labelSize, Self.labelSizeRange, fallback.labelSize)
    forces.center = number(Key.center, Self.centerRange, fallback.forces.center)
    forces.repel = number(Key.repel, Self.repelRange, fallback.forces.repel)
    forces.linkForce = number(Key.linkForce, Self.linkForceRange, fallback.forces.linkForce)
    forces.linkDistance = number(
      Key.linkDistance, Self.linkDistanceRange, fallback.forces.linkDistance)
    forces.urgency =
      defaults.string(forKey: Key.urgency).flatMap(UrgencyMode.init(rawValue:))
      ?? fallback.forces.urgency
    animateSettle = flag(Key.animateSettle, fallback.animateSettle)
    labelFont =
      defaults.string(forKey: Key.labelFont).flatMap { $0.isEmpty ? nil : $0 }
      ?? fallback.labelFont
    editorFontSize = number(
      Key.editorFontSize, Self.editorFontSizeRange, fallback.editorFontSize)
    showForcesPanel = flag(Key.showForcesPanel, fallback.showForcesPanel)
  }

  public func save(to defaults: UserDefaults) {
    defaults.set(labelSize, forKey: Key.labelSize)
    defaults.set(forces.center, forKey: Key.center)
    defaults.set(forces.repel, forKey: Key.repel)
    defaults.set(forces.linkForce, forKey: Key.linkForce)
    defaults.set(forces.linkDistance, forKey: Key.linkDistance)
    defaults.set(forces.urgency.rawValue, forKey: Key.urgency)
    defaults.set(animateSettle, forKey: Key.animateSettle)
    defaults.set(labelFont, forKey: Key.labelFont)
    defaults.set(editorFontSize, forKey: Key.editorFontSize)
    defaults.set(showForcesPanel, forKey: Key.showForcesPanel)
  }

  private static func clamp(_ value: Double, _ range: ClosedRange<Double>, _ fallback: Double)
    -> Double
  {
    value.isFinite ? min(max(value, range.lowerBound), range.upperBound) : fallback
  }
}

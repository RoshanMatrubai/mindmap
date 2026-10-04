import Foundation
import Testing

@testable import MindmapCore

private func scratchDefaults() -> UserDefaults {
  let name = "mindmap-tests-" + UUID().uuidString
  let defaults = UserDefaults(suiteName: name)!
  defaults.removePersistentDomain(forName: name)
  return defaults
}

@Test func preferencesDefaultsMatchDesign() {
  let prefs = Preferences(defaults: scratchDefaults())
  #expect(prefs == Preferences())
  #expect(prefs.labelSize == 1)
  #expect(prefs.forces.center == 0.04 && prefs.forces.repel == 450)
  #expect(prefs.forces.linkForce == 0.6 && prefs.forces.linkDistance == 70)
  #expect(prefs.forces.urgency == .pullIn)
  #expect(prefs.animateSettle && !prefs.showForcesPanel)
  #expect(prefs.labelFont == "Nunito Sans" && prefs.editorFontSize == 13)
}

@Test func preferencesRoundTrip() {
  let defaults = scratchDefaults()
  var prefs = Preferences()
  prefs.labelSize = 1.35
  prefs.forces.center = 0.1
  prefs.forces.repel = 900
  prefs.forces.linkForce = 1.2
  prefs.forces.linkDistance = 150
  prefs.forces.urgency = .pushOut
  prefs.animateSettle = false
  prefs.labelFont = "Quicksand"
  prefs.editorFontSize = 16
  prefs.showForcesPanel = true
  prefs.save(to: defaults)
  #expect(Preferences(defaults: defaults) == prefs)
}

@Test func preferencesClampAndIgnoreJunk() {
  let defaults = scratchDefaults()
  defaults.set(9.0, forKey: "labelSize")
  defaults.set(-1.0, forKey: "center")
  defaults.set(10.0, forKey: "repel")
  defaults.set(5.0, forKey: "linkForce")
  defaults.set(1000.0, forKey: "linkDistance")
  defaults.set("sideways", forKey: "urgency")
  defaults.set(40.0, forKey: "editorFontSize")
  defaults.set("", forKey: "labelFont")
  let prefs = Preferences(defaults: defaults)
  #expect(prefs.labelSize == 2 && prefs.forces.center == 0 && prefs.forces.repel == 50)
  #expect(prefs.forces.linkForce == 1.5 && prefs.forces.linkDistance == 200)
  #expect(prefs.forces.urgency == .pullIn && prefs.editorFontSize == 18)
  #expect(prefs.labelFont == "Nunito Sans")
}

/// Launch arguments arrive as strings (`-labelSize 1.5 -animateSettle NO`).
@Test func preferencesReadStringValues() {
  let defaults = scratchDefaults()
  defaults.set("1.5", forKey: "labelSize")
  defaults.set("NO", forKey: "animateSettle")
  defaults.set("off", forKey: "urgency")
  let prefs = Preferences(defaults: defaults)
  #expect(prefs.labelSize == 1.5 && !prefs.animateSettle && prefs.forces.urgency == .off)
}

@Test func labelSizeStepsStayOnGridAndInRange() {
  var prefs = Preferences()
  prefs.stepLabelSize(by: 1)
  #expect(abs(prefs.labelSize - 1.05) < 1e-9)
  prefs.stepLabelSize(by: -3)
  #expect(abs(prefs.labelSize - 0.9) < 1e-9)
  prefs.stepLabelSize(by: -100)
  #expect(prefs.labelSize == 0.6)
  prefs.stepLabelSize(by: 100)
  #expect(prefs.labelSize == 2)
  prefs.labelSize = 1.013  // off grid (a slider) snaps to the grid first
  prefs.stepLabelSize(by: 1)
  #expect(abs(prefs.labelSize - 1.05) < 1e-9)
}

@Test func onlyForceChangesCallForReshuffle() {
  let base = Preferences()
  var sized = base
  sized.labelSize = 1.5
  sized.labelFont = "Outfit"
  sized.animateSettle = false
  #expect(!sized.forcesDiffer(from: base))
  var pulled = base
  pulled.forces.urgency = .off
  #expect(pulled.forcesDiffer(from: base))
  var repelled = base
  repelled.forces.repel = 451
  #expect(repelled.forcesDiffer(from: base))
}

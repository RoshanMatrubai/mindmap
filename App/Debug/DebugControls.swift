#if DEBUG
  import SwiftUI

  /// What the forces panel and Settings window last rendered, for the smoke harness. SwiftUI
  /// draws sliders without NSSlider and builds no accessibility tree without a client, so the
  /// views record each slider's binding and shown value here. Excluded from Release builds.
  @MainActor
  enum DebugControls {
    /// Keyed "panel <label>" or "settings <label>".
    static var sliders: [String: Binding<Double>] = [:]
    static var shown: [String: Double] = [:]
    static var panelVisible = false
    static var settingsVisible = false
    static var settingsTab: Binding<String>?
    static var calendarToggle: Binding<Bool>?

    static func record(_ key: String, _ binding: Binding<Double>) {
      sliders[key] = binding
      shown[key] = binding.wrappedValue
    }
  }
#endif

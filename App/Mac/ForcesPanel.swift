import MindmapCore
import MindmapGraph
import SwiftUI

/// Prototype `#forces`: floating top left in the graph pane. Edits the same preferences as the
/// Settings window, live in both directions. Force changes reshuffle about 200 ms after the
/// slider stops (MapStore); label size and font only push new overlaps apart.
struct ForcesPanel: View {
  @Bindable var store: MacMapStore

  var body: some View {
    VStack(alignment: .leading, spacing: 7) {
      slider("label size", $store.preferences.labelSize, Preferences.labelSizeRange, step: 0.05)
      HStack {
        Text("forces (auto reshuffle)")
        Spacer()
        Text(store.settlePercent.map { "settling \($0)%" } ?? "frozen")
      }
      .foregroundStyle(Palette.color(0x636366))
      slider("center", $store.preferences.forces.center, Preferences.centerRange, step: 0.002)
      slider("repel", $store.preferences.forces.repel, Preferences.repelRange, step: 25)
      slider(
        "link force", $store.preferences.forces.linkForce, Preferences.linkForceRange, step: 0.05)
      slider(
        "link distance", $store.preferences.forces.linkDistance, Preferences.linkDistanceRange,
        step: 5)
      UrgencyPicker(selection: $store.preferences.forces.urgency)
        .controlSize(.mini)
      HStack(spacing: 6) {
        Button("reshuffle") { AppCommand.reshuffle.perform(store) }
          .disabled(AppCommand.reshuffle.isDisabled(store))
        Button("animate: \(store.preferences.animateSettle ? "on" : "off")") {
          store.preferences.animateSettle.toggle()
        }
      }
      .buttonStyle(PanelButtonStyle())
      FontPicker(store: store, label: "font")
        .controlSize(.mini)
    }
    .font(.system(size: 11))
    .foregroundStyle(Palette.color(0x8e8e93))
    .tint(Palette.color(0x4f2fc4))
    .padding(.vertical, 10)
    .padding(.horizontal, 12)
    .frame(width: 210)
    .background(
      RoundedRectangle(cornerRadius: 10).fill(Palette.color(0x1e1e20).opacity(0.92))
    )
    .overlay(
      RoundedRectangle(cornerRadius: 10).strokeBorder(Palette.color(0x2c2c2e), lineWidth: 0.5)
    )
    #if DEBUG
      .onAppear { DebugControls.panelVisible = true }
      .onDisappear { DebugControls.panelVisible = false }
    #endif
  }

  private func slider(
    _ label: String, _ value: Binding<Double>, _ range: ClosedRange<Double>, step: Double
  ) -> some View {
    #if DEBUG
      DebugControls.record("panel " + label, value)
    #endif
    return HStack(spacing: 8) {
      Text(label).lineLimit(1).fixedSize()
      Spacer(minLength: 0)
      Slider(value: snapped(value, step: step), in: range)
        .controlSize(.mini)
        .frame(width: 104)
        .accessibilityLabel(label)
    }
  }
}

/// Pull in / off / push out.
struct UrgencyPicker: View {
  @Binding var selection: UrgencyMode

  var body: some View {
    Picker("urgency", selection: $selection) {
      Text("pull in").tag(UrgencyMode.pullIn)
      Text("off").tag(UrgencyMode.off)
      Text("push out").tag(UrgencyMode.pushOut)
    }
    .pickerStyle(.segmented)
  }
}

/// A popup of every family, grouped like the Settings window's previewed list.
struct FontPicker: View {
  @Bindable var store: MacMapStore
  let label: String

  var body: some View {
    Picker(label, selection: $store.preferences.labelFont) {
      ForEach(GraphFonts.groups) { group in
        Section(group.name) {
          ForEach(group.families, id: \.self) { Text($0).tag($0) }
        }
      }
    }
  }
}

/// Prototype `.zb`: #232326 fill, 0.5 px #3a3a3c border, 6 px corners, 28 px tall.
private struct PanelButtonStyle: ButtonStyle {
  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .font(.system(size: 11))
      .foregroundStyle(Palette.color(0xa1a1a6))
      .padding(.horizontal, 8)
      .frame(height: 28)
      .background(
        RoundedRectangle(cornerRadius: 6)
          .fill(Palette.color(configuration.isPressed ? 0x2c2c2e : 0x232326))
      )
      .overlay(
        RoundedRectangle(cornerRadius: 6).strokeBorder(Palette.color(0x3a3a3c), lineWidth: 0.5)
      )
      .contentShape(Rectangle())
  }
}

/// Snaps to `step` without the tick marks SwiftUI draws for `Slider(step:)` (the prototype has
/// none).
func snapped(_ value: Binding<Double>, step: Double) -> Binding<Double> {
  Binding(get: { value.wrappedValue }, set: { value.wrappedValue = ($0 / step).rounded() * step })
}

enum Palette {
  static func color(_ hex: UInt32) -> Color {
    Color(
      .sRGB, red: Double((hex >> 16) & 255) / 255, green: Double((hex >> 8) & 255) / 255,
      blue: Double(hex & 255) / 255)
  }
}

import MindmapCore
import MindmapGraph
import SwiftUI

/// The Graph settings tab, shared by the Mac's Settings window and the iPad's settings sheet:
/// forces, urgency, animate settle and a reshuffle button.
struct GraphSettingsForm: View {
  @Bindable var store: MapStore

  var body: some View {
    Form {
      Section("Forces (changes reshuffle, keeping moved nodes)") {
        settingsSlider(
          "Center", $store.preferences.forces.center, Preferences.centerRange, step: 0.002
        ) {
          String(format: "%.3f", $0)
        }
        settingsSlider("Repel", $store.preferences.forces.repel, Preferences.repelRange, step: 25) {
          String(format: "%.0f", $0)
        }
        settingsSlider(
          "Link force", $store.preferences.forces.linkForce, Preferences.linkForceRange, step: 0.05
        ) { String(format: "%.2f", $0) }
        settingsSlider(
          "Link distance", $store.preferences.forces.linkDistance, Preferences.linkDistanceRange,
          step: 5
        ) { String(format: "%.0f", $0) }
        LabeledContent("Urgency") {
          UrgencyPicker(selection: $store.preferences.forces.urgency).labelsHidden()
        }
      }
      Section {
        Toggle("Animate settle", isOn: $store.preferences.animateSettle)
        LabeledContent("Layout") {
          Button("Reshuffle") { store.reshuffle() }
            .disabled(store.currentURL == nil)
        }
      }
    }
    .formStyle(.grouped)
  }
}

/// The Text settings tab: the label font (each name in its own font), label size and editor size.
struct TextSettingsForm: View {
  @Bindable var store: MapStore

  var body: some View {
    Form {
      Section("Graph label font") {
        // Plain rows: a List inside a grouped Form drops each row's font.
        ScrollView {
          LazyVStack(alignment: .leading, spacing: 0) {
            ForEach(GraphFonts.groups) { group in
              Text(group.name)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.top, 10)
                .padding(.bottom, 4)
              ForEach(group.families, id: \.self) { family in
                fontRow(family)
              }
            }
          }
          .padding(.horizontal, 4)
        }
        // Rebuilt once every family is registered, so each name shows in its own font.
        .id(store.allFontsRegistered)
        .frame(height: 260)
        .onAppear { store.registerAllFonts() }
      }
      Section("Sizes") {
        settingsSlider(
          "Label size", $store.preferences.labelSize, Preferences.labelSizeRange,
          step: Preferences.labelSizeStep
        ) { String(format: "%.2f×", $0) }
        settingsSlider(
          "Editor size", $store.preferences.editorFontSize, Preferences.editorFontSizeRange,
          step: 1
        ) { String(format: "%.0f pt", $0) }
      }
    }
    .formStyle(.grouped)
  }

  /// Each name in its own font. SwiftUI ignores a variation-instanced CTFont, so bundled
  /// families go by name.
  private static func preview(_ family: String) -> Font {
    switch family {
    case GraphFonts.system: .system(size: 14)
    case GraphFonts.systemRounded: .system(size: 14, design: .rounded)
    default: .custom(GraphFonts.fontFamily(family), size: 14)
    }
  }

  private func fontRow(_ family: String) -> some View {
    let selected = store.preferences.labelFont == family
    return Button {
      store.preferences.labelFont = family
    } label: {
      Text(family)
        .font(Self.preview(family))
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 4)
        .padding(.horizontal, 8)
        .background(
          RoundedRectangle(cornerRadius: 5).fill(selected ? Color.accentColor : .clear)
        )
        .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
  }
}

extension View {
  func settingsSlider(
    _ label: String, _ value: Binding<Double>, _ range: ClosedRange<Double>, step: Double,
    format: @escaping (Double) -> String
  ) -> some View {
    #if DEBUG
      DebugControls.record("settings " + label, value)
    #endif
    return LabeledContent(label) {
      HStack {
        Slider(value: snapped(value, step: step), in: range).labelsHidden().accessibilityLabel(
          label)
        Text(format(value.wrappedValue))
          .monospacedDigit()
          .foregroundStyle(.secondary)
          .frame(width: 54, alignment: .trailing)
      }
    }
  }
}

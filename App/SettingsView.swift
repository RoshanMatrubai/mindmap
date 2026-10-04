import MindmapCore
import MindmapGraph
import SwiftUI

/// ⌘,: the same preferences as the forces panel. Graph: forces, urgency, animate settle and a
/// reshuffle button. Text: the label font, label size and editor size.
struct SettingsView: View {
  @Bindable var store: MapStore
  @State private var tab = Self.initialTab

  private static var initialTab: String {
    #if DEBUG
      if let requested = DebugLaunch.settingsTab?.lowercased(),
        ["text", "calendar"].contains(requested)
      {
        return requested
      }
    #endif
    return "graph"
  }

  var body: some View {
    TabView(selection: $tab) {
      graph.tabItem { Label("Graph", systemImage: "point.3.connected.trianglepath.dotted") }
        .tag("graph")
      text.tabItem { Label("Text", systemImage: "textformat") }
        .tag("text")
      calendar.tabItem { Label("Calendar", systemImage: "calendar") }.tag("calendar")
    }
    .frame(width: 480)
    .preferredColorScheme(.dark)
    #if DEBUG
      .onAppear {
        DebugControls.settingsVisible = true
        DebugControls.settingsTab = $tab
      }
      .onDisappear { DebugControls.settingsVisible = false }
    #endif
  }

  private var calendarBinding: Binding<Bool> {
    let binding = Binding(
      get: { store.calendarSync.enabled },
      set: { value in
        if let folder = store.folder { store.calendarSync.setEnabled(value, in: folder) }
      })
    #if DEBUG
      DebugControls.calendarToggle = binding
    #endif
    return binding
  }

  private var calendar: some View {
    Form {
      Section {
        Toggle("Calendar sync", isOn: calendarBinding)
          .disabled(store.folder == nil || store.calendarSync.busy)
        Text(store.calendarSync.status).font(.callout).foregroundStyle(.secondary)
        if store.calendarSync.access == .denied {
          Button("Open Calendar Privacy Settings") { store.calendarSync.openPrivacySettings() }
        }
      }
    }
    .formStyle(.grouped)
    .confirmationDialog(
      store.calendarSync.removalMessage,
      isPresented: Binding(
        get: { store.calendarSync.confirmingRemoval },
        set: { store.calendarSync.confirmingRemoval = $0 }), titleVisibility: .visible
    ) {
      Button("Remove Calendar", role: .destructive) {
        if let folder = store.folder { store.calendarSync.confirmRemoval(in: folder) }
      }
      Button("Cancel", role: .cancel) {}
    }
  }

  private var graph: some View {
    Form {
      Section("Forces (changes reshuffle, keeping moved nodes)") {
        slider("Center", $store.preferences.forces.center, Preferences.centerRange, step: 0.002) {
          String(format: "%.3f", $0)
        }
        slider("Repel", $store.preferences.forces.repel, Preferences.repelRange, step: 25) {
          String(format: "%.0f", $0)
        }
        slider(
          "Link force", $store.preferences.forces.linkForce, Preferences.linkForceRange, step: 0.05
        ) { String(format: "%.2f", $0) }
        slider(
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
          Button("Reshuffle") { AppCommand.reshuffle.perform(store) }
            .disabled(AppCommand.reshuffle.isDisabled(store))
        }
      }
    }
    .formStyle(.grouped)
  }

  private var text: some View {
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
        slider(
          "Label size", $store.preferences.labelSize, Preferences.labelSizeRange,
          step: Preferences.labelSizeStep
        ) { String(format: "%.2f×", $0) }
        slider(
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

  private func slider(
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

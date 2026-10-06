import MindmapCore
import MindmapGraph
import SwiftUI

/// ⌘,: the same preferences as the forces panel. Graph: forces, urgency, animate settle and a
/// reshuffle button. Text: the label font, label size and editor size.
struct SettingsView: View {
  @Bindable var store: MacMapStore
  @State private var tab = Self.initialTab

  private static var initialTab: String {
    #if DEBUG
      if let requested = DebugLaunch.settingsTab?.lowercased(),
        ["text", "reminders"].contains(requested)
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
      reminders.tabItem { Label("Reminders", systemImage: "checklist") }.tag("reminders")
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

  private var remindersBinding: Binding<Bool> {
    let binding = Binding(
      get: { store.reminderSync.enabled },
      set: { value in
        if let folder = store.folder { store.reminderSync.setEnabled(value, in: folder) }
      })
    #if DEBUG
      DebugControls.remindersToggle = binding
    #endif
    return binding
  }

  /// Today at the setting's time; only the hour and minute matter.
  private var remindAtBinding: Binding<Date> {
    let calendar = Calendar.current
    return Binding(
      get: {
        let minutes = store.reminderSync.remindAt
        return calendar.date(
          bySettingHour: minutes / 60, minute: minutes % 60, second: 0, of: Date()) ?? Date()
      },
      set: { date in
        let time = calendar.dateComponents([.hour, .minute], from: date)
        store.reminderSync.setRemindAt(
          (time.hour ?? 0) * 60 + (time.minute ?? 0), in: store.folder)
      })
  }

  private var reminders: some View {
    Form {
      Section {
        Toggle("Reminders sync", isOn: remindersBinding)
          .disabled(store.folder == nil || store.reminderSync.busy)
        DatePicker("Remind at", selection: remindAtBinding, displayedComponents: .hourAndMinute)
        Text(store.reminderSync.status).font(.callout).foregroundStyle(.secondary)
        if store.reminderSync.access == .denied {
          Button("Open Reminders Privacy Settings") { store.reminderSync.openPrivacySettings() }
        }
      }
    }
    .formStyle(.grouped)
    .confirmationDialog(
      store.reminderSync.removalMessage,
      isPresented: Binding(
        get: { store.reminderSync.confirmingRemoval },
        set: { store.reminderSync.confirmingRemoval = $0 }), titleVisibility: .visible
    ) {
      Button("Remove List", role: .destructive) {
        if let folder = store.folder { store.reminderSync.confirmRemoval(in: folder) }
      }
      Button("Cancel", role: .cancel) {}
    }
  }

  private var graph: some View { GraphSettingsForm(store: store) }

  private var text: some View { TextSettingsForm(store: store) }
}

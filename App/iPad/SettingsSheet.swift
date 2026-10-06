import SwiftUI

/// ⌘, and the toolbar's gear: the Mac's Graph and Text settings tabs (no Reminders, which are
/// Mac-only). Values are per device and apply live, as on the Mac.
struct SettingsSheet: View {
  @Bindable var store: PadMapStore
  @Environment(\.dismiss) private var dismiss

  var body: some View {
    NavigationStack {
      Group {
        switch store.layout.settingsTab {
        case .graph: GraphSettingsForm(store: store)
        case .text: TextSettingsForm(store: store)
        }
      }
      .navigationTitle("Settings")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .principal) {
          Picker("Tab", selection: Bindable(store.layout).settingsTab) {
            Text("Graph").tag(PadLayout.SettingsTab.graph)
            Text("Text").tag(PadLayout.SettingsTab.text)
          }
          .pickerStyle(.segmented)
          .frame(width: 220)
        }
        ToolbarItem(placement: .confirmationAction) {
          Button("Done") { dismiss() }
        }
      }
    }
    .preferredColorScheme(.dark)
    #if DEBUG
      .onAppear { DebugControls.settingsVisible = true }
      .onDisappear { DebugControls.settingsVisible = false }
    #endif
  }
}

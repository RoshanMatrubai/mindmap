import AppKit
import MindmapCore
import SwiftUI

struct ContentView: View {
  @Bindable var store: MapStore
  @Environment(\.openSettings) private var openSettings

  var body: some View {
    HSplitView {
      OutlineEditor(store: store)
        .frame(minWidth: 300, idealWidth: 400)
      VStack(spacing: 0) {
        GraphPane(store: store)
          .overlay(alignment: .topLeading) {
            // Prototype: 40 from the top (below the title), 14 from the left.
            if store.preferences.showForcesPanel {
              ForcesPanel(store: store).padding(.top, 40).padding(.leading, 14)
            }
          }
        DetailPanel(store: store)
      }
      .frame(minWidth: 400)
    }
    .frame(minWidth: 900, minHeight: 600)
    .preferredColorScheme(.dark)
    .toolbar {
      ToolbarItem {
        Menu {
          ForEach(store.maps) { map in
            Button {
              store.switchMap(map.url)
            } label: {
              if map.url == store.currentURL {
                Label(map.title, systemImage: "checkmark")
              } else {
                Text(map.title)
              }
            }
          }
        } label: {
          Text(store.title ?? "untitled map")
        }
        .disabled(store.isSwitching)
        .help("Switch maps")
      }
      ToolbarItem {
        Toggle(isOn: $store.preferences.showForcesPanel) {
          Label("Forces", systemImage: "slider.horizontal.3")
        }
        .help("Show or hide the forces panel (⌥⌘F)")
      }
    }
    .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in
      store.activated()
    }
    .onAppear {
      store.openSettings = { openSettings() }
      #if DEBUG
        DebugLaunch.logLaunch("window")
        EditorSmoke.runIfRequested()
        Benchmark.runIfRequested(store)
        DebugLaunch.applyWindowSize()
      #endif
      if store.folder == nil && !store.isSwitching {
        DispatchQueue.main.async { store.chooseFolder() }
      }
    }
    .alert(
      "map file",
      isPresented: Binding(
        get: { store.errorMessage != nil }, set: { if !$0 { store.errorMessage = nil } })
    ) {
      Button("OK") { store.errorMessage = nil }
    } message: {
      Text(store.errorMessage ?? "")
    }
  }
}

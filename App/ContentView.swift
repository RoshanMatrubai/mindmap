import AppKit
import MindmapCore
import SwiftUI

struct ContentView: View {
  @Bindable var store: MapStore

  var body: some View {
    HSplitView {
      OutlineEditor(store: store)
        .frame(minWidth: 300, idealWidth: 400)
      GraphPane(store: store)
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
          Text(MapDocument.title(of: store.text) ?? "untitled map")
        }
        .disabled(store.isSwitching)
        .help("Switch maps")
      }
    }
    .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in
      store.activated()
    }
    .onAppear {
      #if DEBUG
        EditorSmoke.runIfRequested()
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

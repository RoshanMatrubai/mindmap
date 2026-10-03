import AppKit
import MindmapCore
import SwiftUI

struct ContentView: View {
  @Bindable var store: MapStore

  var body: some View {
    HSplitView {
      OutlineEditor(store: store)
        .frame(minWidth: 300, idealWidth: 400)
      ZStack(alignment: .topLeading) {
        Color(red: 0x1e / 255, green: 0x1e / 255, blue: 0x1e / 255)
        VStack(alignment: .leading, spacing: 10) {
          Text((store.model.title.isEmpty ? "untitled map" : store.model.title).lowercased())
            .font(.system(size: 15))
            .foregroundStyle(Color(red: 0x63 / 255, green: 0x63 / 255, blue: 0x66 / 255))
          Text(store.model.statsText)
            .font(.system(size: 13))
            .foregroundStyle(Color(red: 0x8e / 255, green: 0x8e / 255, blue: 0x93 / 255))
        }
        .padding(.leading, 14)
        .padding(.top, 10)
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

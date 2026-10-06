import MindmapGraph
import SwiftUI

/// Wide windows (landscape, large Stage Manager windows) show the editor and the graph side by
/// side with a draggable divider; narrow ones show one pane, switched from the toolbar. Both
/// views stay in the window either way, so the editor keeps its undo stack and the graph its
/// layers; a hidden graph runs no display link.
struct ContentView: View {
  @Bindable var store: PadMapStore
  /// The editor's share of a wide window.
  @AppStorage("editorFraction") private var editorFraction = 0.36
  @State private var dragStart: Double?

  /// Narrower than this is a narrow window: every iPad in portrait, split view, small windows.
  static let wideWidth = 1100.0

  var body: some View {
    NavigationStack {
      GeometryReader { geometry in
        let width = geometry.size.width
        let wide = isWide(width)
        let editorWidth = wide ? clampedEditor(width) : (store.layout.pane == .text ? width : 0)
        let graphWidth = wide ? max(0, width - editorWidth - 9) : width - editorWidth
        HStack(spacing: 0) {
          OutlineEditor(store: store)
            .frame(width: editorWidth)
            .clipped()
          if wide {
            divider(width)
          }
          VStack(spacing: 0) {
            GraphPane(store: store, visible: graphWidth > 0, offersEditText: !wide)
            DetailPanel(store: store)
          }
          .frame(width: graphWidth)
          .clipped()
        }
        .onAppear { store.layout.isWide = wide }
        .onChange(of: wide) { _, wide in store.layout.isWide = wide }
      }
      .background(Color(cgColor: GraphStyle.canvas).ignoresSafeArea())
      .navigationBarTitleDisplayMode(.inline)
      .toolbarBackground(Color(red: 0.11, green: 0.11, blue: 0.12), for: .navigationBar)
      .toolbarBackground(.visible, for: .navigationBar)
      .toolbar { toolbar }
    }
    .preferredColorScheme(.dark)
    .onAppear {
      // The dev app already uses its container; otherwise the user picks the maps folder.
      if store.folder == nil && !store.isSwitching { store.chooseFolder() }
      #if DEBUG
        DebugLaunch.logLaunch("window")
        DebugLaunch.applyLayout(store)
        TouchSmoke.runIfRequested(store)
      #endif
    }
    .sheet(isPresented: Bindable(store.layout).pickingFolder) {
      FolderPicker { url in store.adoptFolder(url) }
        .ignoresSafeArea()
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

  private func isWide(_ width: Double) -> Bool {
    #if DEBUG
      if let forced = store.layout.forcedWide { return forced }
    #endif
    return width >= Self.wideWidth
  }

  /// The editor keeps at least 300 points and the graph 400.
  private func clampedEditor(_ width: Double) -> Double {
    min(max(width * editorFraction, 300), max(300, width - 409))
  }

  private func divider(_ width: Double) -> some View {
    Rectangle()
      .fill(Color(red: 0.16, green: 0.16, blue: 0.16))
      .frame(width: 1)
      .padding(.horizontal, 4)
      .frame(maxHeight: .infinity)
      .contentShape(Rectangle())
      .hoverEffect()
      .gesture(
        DragGesture(minimumDistance: 1)
          .onChanged { value in
            let start = dragStart ?? editorFraction
            dragStart = start
            editorFraction = min(0.7, max(0.2, start + value.translation.width / max(width, 1)))
          }
          .onEnded { _ in dragStart = nil }
      )
      .accessibilityLabel("Resize editor")
  }

  @ToolbarContentBuilder private var toolbar: some ToolbarContent {
    ToolbarItem(placement: .topBarLeading) {
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
        Divider()
        Button("New Map", systemImage: "plus") { store.newMap() }
          .disabled(AppCommand.newMap.isDisabled(store))
        Button("Change Maps Folder…", systemImage: "folder") { store.chooseFolder() }
      } label: {
        HStack(spacing: 4) {
          Text(store.title ?? "untitled map")
          Image(systemName: "chevron.down").font(.caption)
        }
      }
      .disabled(store.isSwitching)
      .accessibilityLabel("Switch maps")
    }
    if !store.layout.isWide {
      ToolbarItem(placement: .principal) {
        Picker("Show", selection: Bindable(store.layout).pane) {
          Text("Text").tag(PadLayout.Pane.text)
          Text("Map").tag(PadLayout.Pane.map)
        }
        .pickerStyle(.segmented)
        .frame(width: 180)
      }
    }
  }
}

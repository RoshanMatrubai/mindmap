import AppKit
import SwiftUI

/// Every app menu command with a shortcut. The menu bar and the DEBUG smoke harness both run
/// `perform`, because SwiftUI menu items have no AppKit action until their menu opens.
@MainActor
enum AppCommand: CaseIterable {
  case newMap, nextMap, previousMap
  case toggleDone, indent, outdent, moveUp, moveDown
  case zoomIn, zoomOut, fitAll, reshuffle, focusEditor, focusGraph

  var title: String {
    switch self {
    case .newMap: "New Map"
    case .nextMap: "Next Map"
    case .previousMap: "Previous Map"
    case .toggleDone: "Toggle Done"
    case .indent: "Indent"
    case .outdent: "Outdent"
    case .moveUp: "Move Up"
    case .moveDown: "Move Down"
    case .zoomIn: "Zoom In"
    case .zoomOut: "Zoom Out"
    case .fitAll: "Fit All"
    case .reshuffle: "Reshuffle"
    case .focusEditor: "Focus Editor"
    case .focusGraph: "Focus Graph"
    }
  }

  var shortcut: KeyboardShortcut {
    switch self {
    case .newMap: KeyboardShortcut("n", modifiers: .command)
    case .nextMap: KeyboardShortcut("]", modifiers: [.command, .shift])
    case .previousMap: KeyboardShortcut("[", modifiers: [.command, .shift])
    case .toggleDone: KeyboardShortcut("x", modifiers: [.command, .shift])
    case .indent: KeyboardShortcut("]", modifiers: .command)
    case .outdent: KeyboardShortcut("[", modifiers: .command)
    case .moveUp: KeyboardShortcut(.upArrow, modifiers: [.control, .command])
    case .moveDown: KeyboardShortcut(.downArrow, modifiers: [.control, .command])
    case .zoomIn: KeyboardShortcut("=", modifiers: .command)
    case .zoomOut: KeyboardShortcut("-", modifiers: .command)
    case .fitAll: KeyboardShortcut("0", modifiers: .command)
    case .reshuffle: KeyboardShortcut("r", modifiers: [.command, .shift])
    case .focusEditor: KeyboardShortcut("1", modifiers: .command)
    case .focusGraph: KeyboardShortcut("2", modifiers: .command)
    }
  }

  func isDisabled(_ store: MapStore) -> Bool {
    switch self {
    case .newMap: store.folder == nil || store.isSwitching
    case .nextMap, .previousMap: store.maps.count < 2 || store.isSwitching
    case .reshuffle: store.currentURL == nil
    default: false
    }
  }

  func perform(_ store: MapStore) {
    switch self {
    case .newMap: store.newMap()
    case .nextMap: store.switchMap(by: 1)
    case .previousMap: store.switchMap(by: -1)
    // Editor commands go to whichever outline editor has focus.
    case .toggleDone:
      NSApp.sendAction(#selector(OutlineTextView.toggleDone(_:)), to: nil, from: nil)
    case .indent: NSApp.sendAction(#selector(OutlineTextView.indentLines(_:)), to: nil, from: nil)
    case .outdent: NSApp.sendAction(#selector(OutlineTextView.outdentLines(_:)), to: nil, from: nil)
    case .moveUp: NSApp.sendAction(#selector(OutlineTextView.moveLineUp(_:)), to: nil, from: nil)
    case .moveDown:
      NSApp.sendAction(#selector(OutlineTextView.moveLineDown(_:)), to: nil, from: nil)
    case .zoomIn: store.graphView?.zoomIn()
    case .zoomOut: store.graphView?.zoomOut()
    case .fitAll: store.graphView?.fitAll()
    case .reshuffle: store.reshuffle()
    case .focusEditor: store.focusEditor()
    case .focusGraph: store.focusGraph()
    }
  }

  func button(_ store: MapStore) -> some View {
    Button(title) { perform(store) }
      .keyboardShortcut(shortcut)
      .disabled(isDisabled(store))
  }
}

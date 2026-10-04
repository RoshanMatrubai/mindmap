import AppKit
import SwiftUI

/// Every app menu command with a shortcut. The menu bar and the DEBUG smoke harness both run
/// `perform`, because SwiftUI menu items have no AppKit action until their menu opens.
@MainActor
enum AppCommand: CaseIterable {
  case newMap, nextMap, previousMap
  case toggleDone, indent, outdent, moveUp, moveDown
  case zoomIn, zoomOut, fitAll, reshuffle, focusEditor, focusGraph
  // Graph selection. Plain keys are enabled only while the graph has focus, so the editor keeps
  // Return, Tab, Delete, Esc and the arrows.
  case clearSelection, addTask, addSubtask, deleteNode
  case selectParent, selectFirstChild, selectPreviousSibling, selectNextSibling
  case priorityHigh, priorityMedium, priorityLow, priorityChill, priorityNone

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
    case .clearSelection: "Clear Selection"
    case .addTask: "Add Task"
    case .addSubtask: "Add Subtask"
    case .deleteNode: "Delete Node"
    case .selectParent: "Select Parent"
    case .selectFirstChild: "Select First Child"
    case .selectPreviousSibling: "Select Previous Sibling"
    case .selectNextSibling: "Select Next Sibling"
    case .priorityHigh: "High"
    case .priorityMedium: "Medium"
    case .priorityLow: "Low"
    case .priorityChill: "Chill"
    case .priorityNone: "None"
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
    case .clearSelection: KeyboardShortcut(.escape, modifiers: [])
    case .addTask: KeyboardShortcut(.return, modifiers: [])
    case .addSubtask: KeyboardShortcut(.tab, modifiers: [])
    case .deleteNode: KeyboardShortcut(.delete, modifiers: [])
    case .selectParent: KeyboardShortcut(.upArrow, modifiers: [])
    case .selectFirstChild: KeyboardShortcut(.downArrow, modifiers: [])
    case .selectPreviousSibling: KeyboardShortcut(.leftArrow, modifiers: [])
    case .selectNextSibling: KeyboardShortcut(.rightArrow, modifiers: [])
    case .priorityHigh: KeyboardShortcut("1", modifiers: [.option, .command])
    case .priorityMedium: KeyboardShortcut("2", modifiers: [.option, .command])
    case .priorityLow: KeyboardShortcut("3", modifiers: [.option, .command])
    case .priorityChill: KeyboardShortcut("4", modifiers: [.option, .command])
    case .priorityNone: KeyboardShortcut("0", modifiers: [.option, .command])
    }
  }

  func isDisabled(_ store: MapStore) -> Bool {
    switch self {
    case .newMap: store.folder == nil || store.isSwitching
    case .nextMap, .previousMap: store.maps.count < 2 || store.isSwitching
    case .reshuffle: store.currentURL == nil
    case .clearSelection, .addTask, .addSubtask, .deleteNode, .selectParent, .selectFirstChild,
      .selectPreviousSibling, .selectNextSibling:
      !store.graphFocused || store.detail == nil
    case .priorityHigh, .priorityMedium, .priorityLow, .priorityChill, .priorityNone:
      store.detail == nil
    default: false
    }
  }

  func perform(_ store: MapStore) {
    switch self {
    case .newMap: store.newMap()
    case .nextMap: store.switchMap(by: 1)
    case .previousMap: store.switchMap(by: -1)
    // Editor commands go to whichever outline editor has focus.
    case .toggleDone: store.toggleDoneFromMenu()
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
    case .clearSelection: store.graphView?.clearSelection()
    case .addTask: store.graphView?.addTask()
    case .addSubtask: store.graphView?.addSubtask()
    case .deleteNode: store.graphView?.deleteSelection()
    case .selectParent: store.graphView?.navigate(.parent)
    case .selectFirstChild: store.graphView?.navigate(.firstChild)
    case .selectPreviousSibling: store.graphView?.navigate(.previousSibling)
    case .selectNextSibling: store.graphView?.navigate(.nextSibling)
    case .priorityHigh: store.setPriority(.high)
    case .priorityMedium: store.setPriority(.medium)
    case .priorityLow: store.setPriority(.low)
    case .priorityChill: store.setPriority(.chill)
    case .priorityNone: store.setPriority(nil)
    }
  }

  func button(_ store: MapStore) -> some View {
    Button(title) { perform(store) }
      .keyboardShortcut(shortcut)
      .disabled(isDisabled(store))
  }
}

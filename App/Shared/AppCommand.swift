import SwiftUI

/// Every app menu command with a shortcut, shared by the Mac and the iPad so names and keys
/// match. Each platform adds `isDisabled`, `perform` and `button` (App/Mac/AppCommand+Mac.swift,
/// App/iPad/AppCommand+iPad.swift). The menu bar and the DEBUG smoke harnesses both run
/// `perform`, because SwiftUI menu items have no platform action until their menu opens.
@MainActor
enum AppCommand: CaseIterable {
  case newMap, nextMap, previousMap
  case toggleDone, indent, outdent, moveUp, moveDown
  case zoomIn, zoomOut, fitAll, reshuffle, focusEditor, focusGraph
  case settings, toggleForcesPanel, biggerLabels, smallerLabels
  // Graph selection. Plain keys are enabled only while the graph has focus, so the editor keeps
  // Return, Tab, Delete, Esc and the arrows.
  case clearSelection, addTask, addSubtask, deleteNode
  case selectParent, selectFirstChild, selectPreviousSibling, selectNextSibling
  // The selected node with the graph focused, else the editor's current or selected bullets.
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
    case .settings: "Settings…"
    case .toggleForcesPanel: "Forces Panel"
    case .biggerLabels: "Bigger Labels"
    case .smallerLabels: "Smaller Labels"
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
    case .fitAll: KeyboardShortcut("0", modifiers: [.option, .command])
    case .reshuffle: KeyboardShortcut("r", modifiers: [.command, .shift])
    case .focusEditor: KeyboardShortcut("1", modifiers: [.option, .command])
    case .focusGraph: KeyboardShortcut("2", modifiers: [.option, .command])
    case .settings: KeyboardShortcut(",", modifiers: .command)
    case .toggleForcesPanel: KeyboardShortcut("f", modifiers: [.option, .command])
    case .biggerLabels: KeyboardShortcut("=", modifiers: [.option, .command])
    case .smallerLabels: KeyboardShortcut("-", modifiers: [.option, .command])
    case .clearSelection: KeyboardShortcut(.escape, modifiers: [])
    case .addTask: KeyboardShortcut(.return, modifiers: [])
    case .addSubtask: KeyboardShortcut(.tab, modifiers: [])
    case .deleteNode: KeyboardShortcut(.delete, modifiers: [])
    case .selectParent: KeyboardShortcut(.upArrow, modifiers: [])
    case .selectFirstChild: KeyboardShortcut(.downArrow, modifiers: [])
    case .selectPreviousSibling: KeyboardShortcut(.leftArrow, modifiers: [])
    case .selectNextSibling: KeyboardShortcut(.rightArrow, modifiers: [])
    case .priorityHigh: KeyboardShortcut("1", modifiers: .command)
    case .priorityMedium: KeyboardShortcut("2", modifiers: .command)
    case .priorityLow: KeyboardShortcut("3", modifiers: .command)
    case .priorityChill: KeyboardShortcut("4", modifiers: .command)
    case .priorityNone: KeyboardShortcut("0", modifiers: .command)
    }
  }
}

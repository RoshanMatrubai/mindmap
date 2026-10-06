import AppKit
import MindmapCore
import SwiftUI

/// The Mac's half of `AppCommand`: when each command is enabled and what it does.
extension AppCommand {
  func isDisabled(_ store: MacMapStore) -> Bool {
    switch self {
    case .newMap: store.folder == nil || store.isSwitching
    case .nextMap, .previousMap: store.maps.count < 2 || store.isSwitching
    case .reshuffle: store.currentURL == nil
    case .clearSelection, .addTask, .addSubtask, .deleteNode, .selectParent, .selectFirstChild,
      .selectPreviousSibling, .selectNextSibling:
      !store.graphFocused || store.detail == nil
    case .priorityHigh, .priorityMedium, .priorityLow, .priorityChill, .priorityNone:
      store.graphFocused && store.detail == nil
    case .biggerLabels: store.preferences.labelSize >= Preferences.labelSizeRange.upperBound
    case .smallerLabels: store.preferences.labelSize <= Preferences.labelSizeRange.lowerBound
    default: false
    }
  }

  func perform(_ store: MacMapStore) {
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
    case .settings: store.openSettings?()
    case .toggleForcesPanel: store.preferences.showForcesPanel.toggle()
    case .biggerLabels: store.preferences.stepLabelSize(by: 1)
    case .smallerLabels: store.preferences.stepLabelSize(by: -1)
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

  func button(_ store: MacMapStore) -> some View {
    Button(title) { perform(store) }
      .keyboardShortcut(shortcut)
      .disabled(isDisabled(store))
  }
}

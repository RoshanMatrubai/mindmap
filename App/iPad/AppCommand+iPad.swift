import MindmapCore
import SwiftUI

/// The iPad's half of `AppCommand`: the same names and keys as the Mac, in the iPadOS menu bar
/// and the ⌘-hold overlay.
extension AppCommand {
  /// Every command the iPad offers: all of the Mac's.
  static let iPad: [AppCommand] = allCases

  func isDisabled(_ store: PadMapStore) -> Bool {
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

  func perform(_ store: PadMapStore) {
    switch self {
    case .newMap: store.newMap()
    case .nextMap: store.switchMap(by: 1)
    case .previousMap: store.switchMap(by: -1)
    case .toggleDone: store.toggleDoneFromMenu()
    case .indent: store.editor { $0.indentLines() }
    case .outdent: store.editor { $0.outdentLines() }
    case .moveUp: store.editor { $0.moveLineUp() }
    case .moveDown: store.editor { $0.moveLineDown() }
    case .zoomIn: store.graphView?.zoomIn()
    case .zoomOut: store.graphView?.zoomOut()
    case .fitAll: store.graphView?.fitAll()
    case .reshuffle: store.reshuffle()
    case .focusEditor: store.focusEditor()
    case .focusGraph: store.focusGraph()
    case .settings: store.layout.showingSettings = true
    case .toggleForcesPanel: store.layout.showingForces.toggle()
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

  func button(_ store: PadMapStore) -> some View {
    Button(title) { perform(store) }
      .keyboardShortcut(shortcut)
      .disabled(isDisabled(store))
  }
}

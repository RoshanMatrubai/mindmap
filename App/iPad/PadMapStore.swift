import MindmapCore
import MindmapGraph
import Observation
import UIKit

/// How the iPad window shows the map: editor and graph side by side when wide, else one of
/// them, switched from the toolbar.
@MainActor @Observable
final class PadLayout {
  enum Pane: String, CaseIterable {
    case text, map
  }
  /// The pane a narrow window shows.
  var pane = Pane.map
  /// Side by side (wide windows).
  var isWide = false
  /// The folder picker is up (Release, or the dev app with `-use-folder-picker YES`).
  var pickingFolder = false
  /// The settings sheet (⌘,) and the forces popover (⌥⌘F) are up.
  var showingSettings = false
  var showingForces = false
  enum SettingsTab: String { case graph, text }
  var settingsTab = SettingsTab.graph
  #if DEBUG
    /// The smoke harness and `-layout wide|narrow` force a layout; nil follows the window.
    var forcedWide: Bool?
  #endif
}

/// The iPad's half of the store: the UIKit outline editor and the layout. Everything
/// platform-neutral is in `MapStore` (App/Shared).
@MainActor
final class PadMapStore: MapStore {
  let layout = PadLayout()
  weak var editorView: OutlineTextView?

  /// Graph edits and editor typing share the editor's undo stack once it exists.
  var activeUndoManager: UndoManager { editorView?.undoManager ?? undoManager }

  override func switchingChanged() { editorView?.isEditable = !isSwitching }

  override func revealInEditor(_ range: NSRange) { editorView?.selectLine(range) }

  override var editorCursor: Int { editorView?.selectedRange.location ?? 0 }

  override var editorAcceptsEdits: Bool {
    guard let editorView else { return super.editorAcceptsEdits }
    return editorView.isEditable && editorView.string == text
  }

  /// Through the editor, so a graph edit is one step in the editor's undo stack (as on the Mac).
  override func applyTextChange(_ change: TextChange) -> Bool {
    guard let editorView else { return super.applyTextChange(change) }
    var applied = false
    editorView.quietly { applied = editorView.perform(change) }
    if applied { editorView.selectLine(change.selection) }
    return applied
  }

  private var editorFocused: Bool { editorView?.isFirstResponder == true }

  /// ⌘1–4 and ⌘0: the selected node with the graph focused, else the editor's bullet lines.
  func setPriority(_ priority: MapPriority?) {
    if graphFocused {
      if let i = graphView?.selection { applyGraphEdit(.priority(i, priority)) }
    } else if editorFocused {
      editorView?.setPriority(priority)
    }
  }

  /// ⇧⌘X with the graph focused toggles the selected task; otherwise the editor's lines.
  func toggleDoneFromMenu() {
    if graphFocused, let i = graphView?.selection {
      applyGraphEdit(.toggleDone(i))
    } else if editorFocused {
      editorView?.toggleDone()
    }
  }

  /// Editor commands act only while the editor has the keyboard.
  func editor(_ body: (OutlineTextView) -> Void) {
    if let editorView, editorFocused { body(editorView) }
  }

  func focusEditor() {
    if !layout.isWide { layout.pane = .text }
    _ = editorView?.becomeFirstResponder()
  }

  func focusGraph() {
    if !layout.isWide { layout.pane = .map }
    _ = graphView?.becomeFirstResponder()
  }

  /// "Edit Text" on a node in a narrow window: the Text pane with the node's line selected.
  func editText(_ index: Int) {
    layout.pane = .text
    guard model.nodes.indices.contains(index) else { return }
    _ = editorView?.becomeFirstResponder()
    editorView?.selectLine(model.nodes[index].sourceRange)
  }

  func chooseFolder() {
    guard !isSwitching else { return }
    layout.pickingFolder = true
  }
}

import AppKit
import MindmapCore
import MindmapGraph

/// The Mac's half of the store: the AppKit outline editor, the folder panel and Reminders sync.
/// Everything platform-neutral is in `MapStore` (App/Shared).
@MainActor
final class MacMapStore: MapStore {
  /// Reminders status is separate from graph layout and stays idle between sync triggers.
  let reminderSync = ReminderSyncController()
  weak var editorView: NSTextView?
  /// Opens the Settings window (set by the main window, which has the environment action).
  var openSettings: (() -> Void)?

  private var outline: OutlineTextView? { editorView as? OutlineTextView }

  override var reminderLine: String? {
    guard let detail, model.nodes.indices.contains(detail.index) else { return nil }
    return reminderSync.line(for: model.nodes[detail.index], in: currentURL)
  }

  // MARK: Editor

  override func switchingChanged() { editorView?.isEditable = !isSwitching }

  override func revealInEditor(_ range: NSRange) { outline?.selectLine(range) }

  override var editorCursor: Int { outline?.selectedRange().location ?? 0 }

  override var editorAcceptsEdits: Bool {
    guard let outline else { return false }
    return outline.isEditable && outline.string == text
  }

  /// Through the editor, so a graph edit is one step in the editor's undo stack.
  override func applyTextChange(_ change: TextChange) -> Bool {
    guard let outline else { return false }
    var applied = false
    outline.quietly { applied = outline.perform(change) }
    if applied { outline.selectLine(change.selection) }
    return applied
  }

  /// ⌘1–4 and ⌘0: the selected node with the graph focused, else the editor's bullet lines.
  func setPriority(_ priority: MapPriority?) {
    if graphFocused {
      if let i = graphView?.selection { applyGraphEdit(.priority(i, priority)) }
    } else if let outline, outline.window?.firstResponder === outline {
      outline.perform(
        OutlineEditing.setPriority(
          text: outline.string, selection: outline.selectedRange(), priority))
    }
  }

  /// ⇧⌘X with the graph focused toggles the selected task; otherwise the editor's lines.
  func toggleDoneFromMenu() {
    if graphFocused, let i = graphView?.selection {
      applyGraphEdit(.toggleDone(i))
    } else {
      NSApp.sendAction(#selector(OutlineTextView.toggleDone(_:)), to: nil, from: nil)
    }
  }

  func focusEditor() {
    if let editorView { editorView.window?.makeFirstResponder(editorView) }
  }

  func focusGraph() {
    if let graphView { graphView.window?.makeFirstResponder(graphView) }
  }

  // MARK: Maps folder

  func chooseFolder() {
    guard !isSwitching else { return }
    let panel = NSOpenPanel()
    panel.message =
      "choose where to keep your maps. a folder inside Documents keeps them private from other apps."
    panel.prompt = "Use Folder"
    panel.canChooseFiles = false
    panel.canChooseDirectories = true
    panel.canCreateDirectories = true
    let home = String(cString: getpwuid(getuid())!.pointee.pw_dir)
    panel.directoryURL = URL(fileURLWithPath: home).appending(path: "Documents")
    guard panel.runModal() == .OK, let url = panel.url else { return }
    adoptFolder(url)
  }

  // MARK: Reminders sync

  override func dayChanged() {
    super.dayChanged()
    if let folder { reminderSync.sync(in: folder, open: nil, all: true) }
  }

  /// Never sync a stale parse.
  override func didParse(_ model: MapModel, text snapshot: String, document identity: UUID) async {
    if reminderSync.enabled, let folder, await save(), documentID == identity,
      text == snapshot, let url = currentURL
    {
      reminderSync.sync(in: folder, open: (url, model))
    }
  }

  override func beginFileChange() async { await reminderSync.beginFileChange() }

  override func endFileChange() { reminderSync.endFileChange(in: folder, map: currentURL) }

  override func drainSync() async { await reminderSync.drain() }

  override func folderWillMove(to url: URL) async -> Bool {
    guard await reminderSync.relocate(to: url) else {
      errorMessage = reminderSync.lastError
      return false
    }
    return true
  }

  override func folderOpened(_ url: URL) { reminderSync.start(in: url) }
}

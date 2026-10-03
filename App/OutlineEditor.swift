import AppKit
import MindmapCore
import SwiftUI

struct OutlineEditor: NSViewRepresentable {
  @Bindable var store: MapStore

  func makeNSView(context: Context) -> NSScrollView {
    let scroll = NSScrollView()
    scroll.hasVerticalScroller = true
    scroll.drawsBackground = false
    let view = OutlineTextView(usingTextLayoutManager: true)
    view.isRichText = false
    view.allowsUndo = true
    view.isAutomaticQuoteSubstitutionEnabled = false
    view.isAutomaticDashSubstitutionEnabled = false
    view.isAutomaticTextReplacementEnabled = false
    view.isAutomaticSpellingCorrectionEnabled = false
    view.isContinuousSpellCheckingEnabled = false
    view.isGrammarCheckingEnabled = false
    view.backgroundColor = editorColor(0x1a1a1c)
    view.insertionPointColor = editorColor(0xc7c7cc)
    view.selectedTextAttributes = [.backgroundColor: editorColor(0x4f2fc4)]
    view.textContainerInset = NSSize(width: 14, height: 12)
    view.isVerticallyResizable = true
    view.isHorizontallyResizable = false
    view.autoresizingMask = [.width]
    view.textContainer?.widthTracksTextView = true
    view.textContainer?.containerSize = NSSize(
      width: scroll.contentSize.width, height: CGFloat.greatestFiniteMagnitude)
    view.minSize = .zero
    view.maxSize = NSSize(
      width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
    view.onChange = { text in store.text = text }
    view.load(store.text, map: store.documentID)
    scroll.documentView = view
    store.editorView = view
    return scroll
  }

  func updateNSView(_ scroll: NSScrollView, context: Context) {
    guard let view = scroll.documentView as? OutlineTextView else { return }
    view.onChange = { text in store.text = text }
    view.isEditable = !store.isSwitching
    if view.string != store.text || view.mapID != store.documentID {
      view.load(store.text, map: store.documentID)
    }
    if store.parsedText == view.string {
      view.applyUnresolved(store.model.unresolvedLinks.map(\.sourceRange))
    }
  }
}

private func editorColor(_ hex: UInt32) -> NSColor {
  NSColor(
    srgbRed: CGFloat((hex >> 16) & 255) / 255, green: CGFloat((hex >> 8) & 255) / 255,
    blue: CGFloat(hex & 255) / 255, alpha: 1)
}

/// TextKit 2 owns layout. Syntax styling touches only paragraphs affected by an edit.
final class OutlineTextView: NSTextView, @preconcurrency NSTextStorageDelegate {
  var onChange: ((String) -> Void)?
  private(set) var mapID: UUID?
  private var styling = false
  private var unresolved: [NSRange] = []
  private let editorFont = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
  private var baseAttributes: [NSAttributedString.Key: Any] {
    let paragraph = NSMutableParagraphStyle()
    paragraph.tabStops = []
    paragraph.defaultTabInterval =
      ("000" as NSString).size(withAttributes: [.font: editorFont]).width
    paragraph.lineSpacing = 3
    return [.font: editorFont, .foregroundColor: editorColor(0xc7c7cc), .paragraphStyle: paragraph]
  }

  func load(_ text: String, map: UUID?) {
    let selection = selectedRange()
    let changedMap = mapID != map
    styling = true
    string = text
    styling = false
    mapID = map
    unresolved = []
    textStorage?.delegate = self
    style(NSRange(location: 0, length: (text as NSString).length))
    typingAttributes = baseAttributes
    undoManager?.removeAllActions()
    setSelectedRange(
      NSRange(
        location: changedMap ? 0 : min(selection.location, (text as NSString).length), length: 0))
  }

  override func didChangeText() {
    super.didChangeText()
    typingAttributes = baseAttributes
    onChange?(string)
  }

  func textStorage(
    _ storage: NSTextStorage, didProcessEditing editedMask: NSTextStorageEditActions,
    range editedRange: NSRange, changeInLength delta: Int
  ) {
    guard !styling, editedMask.contains(.editedCharacters) else { return }
    // Keep cached underline coordinates valid until the debounced parse catches up.
    let oldEnd = editedRange.location + editedRange.length - delta
    unresolved = unresolved.compactMap { range in
      if NSMaxRange(range) <= editedRange.location { return range }
      if range.location >= oldEnd {
        return NSRange(location: range.location + delta, length: range.length)
      }
      return nil
    }
    let bounded = NSRange(
      location: min(editedRange.location, storage.length),
      length: min(editedRange.length, max(0, storage.length - editedRange.location)))
    style((string as NSString).paragraphRange(for: bounded))
  }

  private func style(_ range: NSRange) {
    guard let storage = textStorage, range.length > 0 else { return }
    styling = true
    storage.beginEditing()
    storage.setAttributes(baseAttributes, range: range)
    let ns = string as NSString
    var offset = range.location
    while offset < NSMaxRange(range) {
      let lineRange = ns.lineRange(for: NSRange(location: offset, length: 0))
      let line = ns.substring(with: lineRange)
      let done = MapParser.isDone(line: line)
      if done {
        storage.addAttributes(
          [
            .foregroundColor: editorColor(0xc7c7cc).withAlphaComponent(0.45),
            .strikethroughStyle: NSUnderlineStyle.single.rawValue,
          ], range: lineRange)
      }
      for token in MapParser.metadataTokens(in: line) {
        let hex: UInt32
        switch token.kind {
        case .due: hex = 0x8e8e93
        case .priority(let priority):
          switch priority {
          case .high: hex = 0xc98589
          case .medium: hex = 0xc2a26a
          case .low, .chill: hex = 0x7f9cd1
          }
        case .link: hex = 0x8f78e8
        case .bullet, .doneMarker: hex = 0x48484a
        }
        let absolute = NSRange(location: offset + token.range.location, length: token.range.length)
        storage.addAttribute(
          .foregroundColor, value: editorColor(hex).withAlphaComponent(done ? 0.45 : 1),
          range: absolute)
      }
      offset = NSMaxRange(lineRange)
    }
    for token in unresolved where NSIntersectionRange(token, range).length > 0 {
      storage.addAttribute(
        .underlineStyle,
        value: NSUnderlineStyle.single.rawValue | NSUnderlineStyle.patternDot.rawValue, range: token
      )
    }
    storage.endEditing()
    styling = false
  }

  func applyUnresolved(_ ranges: [NSRange]) {
    guard unresolved != ranges else { return }
    let affected = Set((unresolved + ranges).map { ($0.location) })
    unresolved = ranges
    let ns = string as NSString
    for location in affected where location < ns.length {
      style(ns.paragraphRange(for: NSRange(location: location, length: 0)))
    }
  }

  override func insertNewline(_ sender: Any?) { apply(.enter) { super.insertNewline(sender) } }
  override func insertTab(_ sender: Any?) { apply(.tab) { super.insertTab(sender) } }
  override func insertBacktab(_ sender: Any?) { apply(.backtab) { super.insertBacktab(sender) } }

  private func apply(_ key: EditingKey, fallback: () -> Void) {
    if !perform(OutlineEditing.change(text: string, selection: selectedRange(), key: key)) {
      fallback()
    }
  }

  // Menu commands (Outline menu), sent through the responder chain.
  @objc func toggleDone(_ sender: Any?) {
    perform(OutlineEditing.toggleDone(text: string, selection: selectedRange()))
  }
  @objc func indentLines(_ sender: Any?) {
    perform(OutlineEditing.change(text: string, selection: selectedRange(), key: .tab))
  }
  @objc func outdentLines(_ sender: Any?) {
    perform(OutlineEditing.change(text: string, selection: selectedRange(), key: .backtab))
  }
  @objc func moveLineUp(_ sender: Any?) {
    perform(OutlineEditing.moveBlock(text: string, selection: selectedRange(), up: true))
  }
  @objc func moveLineDown(_ sender: Any?) {
    perform(OutlineEditing.moveBlock(text: string, selection: selectedRange(), up: false))
  }

  /// Applies a change as one undo step. `false` when there was nothing to do.
  @discardableResult
  private func perform(_ change: TextChange?) -> Bool {
    guard let change, isEditable else { return false }
    breakUndoCoalescing()
    undoManager?.beginUndoGrouping()
    insertText(change.replacement, replacementRange: change.range)
    setSelectedRange(change.selection)
    undoManager?.endUndoGrouping()
    breakUndoCoalescing()
    return true
  }

  override func paste(_ sender: Any?) {
    guard let pasted = NSPasteboard.general.string(forType: .string) else { return }
    breakUndoCoalescing()
    undoManager?.beginUndoGrouping()
    insertText(OutlineEditing.normalizedPaste(pasted), replacementRange: selectedRange())
    undoManager?.endUndoGrouping()
    breakUndoCoalescing()
  }
}

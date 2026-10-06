import MindmapCore
import SwiftUI
import UIKit

/// The iPad outline editor: a TextKit 2 `UITextView` with the Mac editor's rules (Return, Tab
/// and ⇧Tab through `OutlineEditing`), its syntax colors and its undo behavior. Graph edits go
/// through `perform`, so they share the editor's undo stack, as on the Mac.
struct OutlineEditor: UIViewRepresentable {
  @Bindable var store: PadMapStore

  func makeUIView(context: Context) -> OutlineTextView {
    // A nil text container means TextKit 2 (iOS 16+), through the designated initializer, so
    // `configure()` runs; the `usingTextLayoutManager:` convenience initializer skips it.
    let view = OutlineTextView(frame: .zero, textContainer: nil)
    view.onChange = { text in store.editorChanged(text) }
    view.onSelectionChange = { range in store.editorSelectionChanged(range) }
    view.onFocus = { focused in if focused { store.graphFocused = false } }
    view.fontSize = store.preferences.editorFontSize
    view.load(store.text, map: store.documentID)
    view.isEditable = !store.isSwitching
    store.editorView = view
    return view
  }

  func updateUIView(_ view: OutlineTextView, context: Context) {
    view.onChange = { text in store.editorChanged(text) }
    view.fontSize = store.preferences.editorFontSize
    // `text` isn't observed; this revision changes when text arrives from outside the editor.
    _ = store.textRevision
    if view.string != store.text || view.mapID != store.documentID {
      view.load(store.text, map: store.documentID)
    }
    if store.parsedText == view.string {
      view.applyUnresolved(store.model.unresolvedLinks.map(\.sourceRange))
    }
  }
}

func editorColor(_ hex: UInt32, alpha: CGFloat = 1) -> UIColor {
  UIColor(
    red: CGFloat((hex >> 16) & 255) / 255, green: CGFloat((hex >> 8) & 255) / 255,
    blue: CGFloat(hex & 255) / 255, alpha: alpha)
}

/// One keyboard bar button: the bar is built from these, so the DEBUG harness runs exactly the
/// actions the bar shows.
struct KeyboardBarItem {
  let title: String
  let symbol: String
  var children: [KeyboardBarItem] = []
  var action: (@MainActor () -> Void)?
}

/// TextKit 2 owns layout. Syntax styling touches only paragraphs affected by an edit.
final class OutlineTextView: UITextView, UITextViewDelegate, @preconcurrency NSTextStorageDelegate {
  var onChange: ((String) -> Void)?
  /// The cursor or selection moved (typing, taps, arrows). Not for `selectLine`, so a graph tap
  /// that selects its line can't select again.
  var onSelectionChange: ((NSRange) -> Void)?
  var onFocus: ((Bool) -> Void)?
  private var quietSelection = false
  private(set) var mapID: UUID?
  private var styling = false
  /// A change from `perform`: Return and Tab inside it are text, not commands.
  private var performing = false
  private var unresolved: [NSRange] = []
  private var editorFont = UIFont.monospacedSystemFont(ofSize: 13, weight: .regular)
  /// The editor text size setting (SF Mono, 11–18 pt), shared with the Mac.
  var fontSize: Double = 13 {
    didSet {
      guard fontSize != oldValue else { return }
      editorFont = .monospacedSystemFont(ofSize: fontSize, weight: .regular)
      style(NSRange(location: 0, length: (string as NSString).length))
      typingAttributes = baseAttributes
    }
  }
  var string: String { text ?? "" }

  private var baseAttributes: [NSAttributedString.Key: Any] {
    let paragraph = NSMutableParagraphStyle()
    paragraph.tabStops = []
    paragraph.defaultTabInterval =
      ("000" as NSString).size(withAttributes: [.font: editorFont]).width
    paragraph.lineSpacing = 3
    return [.font: editorFont, .foregroundColor: editorColor(0xc7c7cc), .paragraphStyle: paragraph]
  }

  override init(frame: CGRect, textContainer: NSTextContainer?) {
    super.init(frame: frame, textContainer: textContainer)
    configure()
  }

  required init?(coder: NSCoder) { fatalError("not used") }

  private func configure() {
    delegate = self
    backgroundColor = editorColor(0x1a1a1c)
    tintColor = editorColor(0x8f78e8)
    textContainerInset = UIEdgeInsets(top: 12, left: 10, bottom: 12, right: 10)
    autocorrectionType = .no
    autocapitalizationType = .none
    spellCheckingType = .no
    smartQuotesType = .no
    smartDashesType = .no
    smartInsertDeleteType = .no
    inlinePredictionType = .no
    keyboardAppearance = .dark
    alwaysBounceVertical = true
    keyboardDismissMode = .interactive
    // An outline has no use for Writing Tools; off, the editor skips their setup and checks.
    if #available(iOS 18.0, *) { writingToolsBehavior = .none }
    inputAccessoryView = makeKeyboardBar()
  }

  func load(_ text: String, map: UUID?) {
    let selection = selectedRange
    let changedMap = mapID != map
    styling = true
    self.text = text
    styling = false
    mapID = map
    unresolved = []
    textStorage.delegate = self
    style(NSRange(location: 0, length: (text as NSString).length))
    typingAttributes = baseAttributes
    undoManager?.removeAllActions()
    quietly {
      selectedRange = NSRange(
        location: changedMap ? 0 : min(selection.location, (text as NSString).length), length: 0)
    }
  }

  /// Runs `body` without reporting selection changes.
  func quietly(_ body: () -> Void) {
    let old = quietSelection
    quietSelection = true
    body()
    quietSelection = old
  }

  /// Graph → editor: selects a node's line and scrolls it into view.
  func selectLine(_ range: NSRange) {
    let length = (string as NSString).length
    guard range.location <= length else { return }
    let range = NSRange(
      location: range.location, length: min(range.length, length - range.location))
    quietly { selectedRange = range }
    scrollRangeToVisible(range)
  }

  func textViewDidChangeSelection(_ textView: UITextView) {
    if !quietSelection && !styling { onSelectionChange?(selectedRange) }
  }

  override func becomeFirstResponder() -> Bool {
    let became = super.becomeFirstResponder()
    if became { onFocus?(true) }
    return became
  }

  override func resignFirstResponder() -> Bool {
    let resigned = super.resignFirstResponder()
    if resigned { onFocus?(false) }
    return resigned
  }

  func textStorage(
    _ storage: NSTextStorage, didProcessEditing editedMask: NSTextStorage.EditActions,
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
    let paragraph = (storage.string as NSString).paragraphRange(for: bounded)
    // Styling changes attributes, which TextKit doesn't allow inside its own editing pass.
    DispatchQueue.main.async { [weak self] in
      guard let self else { return }
      let length = (self.string as NSString).length
      let range = NSIntersectionRange(paragraph, NSRange(location: 0, length: length))
      self.style((self.string as NSString).paragraphRange(for: range))
    }
    // Every character change passes here, including undo and redo. The store must never hold
    // text the editor doesn't show.
    onChange?(storage.string)
  }

  /// The Mac editor's colors: dimmed bullets and done markers, dates, priorities, links, done
  /// lines struck through at 45%, dotted underlines under unresolved links.
  private func style(_ range: NSRange) {
    guard range.length > 0, NSMaxRange(range) <= textStorage.length else { return }
    styling = true
    let storage = textStorage
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
            .foregroundColor: editorColor(0xc7c7cc, alpha: 0.45),
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
          .foregroundColor, value: editorColor(hex, alpha: done ? 0.45 : 1), range: absolute)
      }
      offset = NSMaxRange(lineRange)
    }
    for token in unresolved
    where NSIntersectionRange(token, range).length > 0 && NSMaxRange(token) <= storage.length {
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

  #if DEBUG
    /// Whether a range carries the done strikethrough / the unresolved dotted underline.
    func debugStruck(at location: Int) -> Bool {
      textStorage.attribute(.strikethroughStyle, at: location, effectiveRange: nil) != nil
    }
    func debugDotted(at location: Int) -> Bool {
      (textStorage.attribute(.underlineStyle, at: location, effectiveRange: nil) as? Int)
        == NSUnderlineStyle.single.rawValue | NSUnderlineStyle.patternDot.rawValue
    }
    /// The real color of the character at `location` as 0xRRGGBB.
    func debugColor(at location: Int) -> UInt32? {
      guard
        let color = textStorage.attribute(.foregroundColor, at: location, effectiveRange: nil)
          as? UIColor
      else { return nil }
      var (r, g, b, a) = (CGFloat(0), CGFloat(0), CGFloat(0), CGFloat(0))
      color.getRed(&r, green: &g, blue: &b, alpha: &a)
      return UInt32((r * 255).rounded()) << 16 | UInt32((g * 255).rounded()) << 8
        | UInt32((b * 255).rounded())
    }
    /// Typing `text` at the cursor, through the same delegate path as the keyboard.
    func debugType(_ text: String) {
      if textView(self, shouldChangeTextIn: selectedRange, replacementText: text) {
        insertText(text)
      }
    }
    func debugBacktab() { backtabPressed() }
    var debugBarItems: [KeyboardBarItem] { barItems }
  #endif

  // MARK: Outline keys

  /// Return and Tab follow the outline rules (as on the Mac); everything else is plain typing.
  func textView(
    _ textView: UITextView, shouldChangeTextIn range: NSRange, replacementText text: String
  ) -> Bool {
    guard !performing else { return true }
    let key: EditingKey
    switch text {
    case "\n": key = .enter
    case "\t": key = .tab
    default: return true
    }
    return !perform(OutlineEditing.change(text: string, selection: range, key: key))
  }

  /// ⇧Tab outdents; UIKit text views ignore it otherwise.
  override var keyCommands: [UIKeyCommand]? {
    let backtab = UIKeyCommand(
      input: "\t", modifierFlags: .shift, action: #selector(backtabPressed))
    backtab.wantsPriorityOverSystemBehavior = true
    return (super.keyCommands ?? []) + [backtab]
  }

  @objc private func backtabPressed() { outdentLines() }

  func toggleDone() { perform(OutlineEditing.toggleDone(text: string, selection: selectedRange)) }
  func indentLines() {
    perform(OutlineEditing.change(text: string, selection: selectedRange, key: .tab))
  }
  func outdentLines() {
    perform(OutlineEditing.change(text: string, selection: selectedRange, key: .backtab))
  }
  func moveLineUp() {
    perform(OutlineEditing.moveBlock(text: string, selection: selectedRange, up: true))
  }
  func moveLineDown() {
    perform(OutlineEditing.moveBlock(text: string, selection: selectedRange, up: false))
  }
  func setPriority(_ priority: MapPriority?) {
    perform(OutlineEditing.setPriority(text: string, selection: selectedRange, priority))
  }
  func insertLink() { perform(OutlineEditing.insertLink(text: string, selection: selectedRange)) }

  /// Applies a change as one undo step. `false` when there was nothing to do. Graph edits use it
  /// too, so they share the editor's undo stack.
  @discardableResult
  func perform(_ change: TextChange?) -> Bool {
    guard let change, isEditable,
      let start = position(from: beginningOfDocument, offset: change.range.location),
      let end = position(from: start, offset: change.range.length),
      let range = textRange(from: start, to: end)
    else { return false }
    undoManager?.beginUndoGrouping()
    performing = true
    replace(range, withText: change.replacement)
    performing = false
    selectedRange = change.selection
    undoManager?.endUndoGrouping()
    return true
  }

  override func paste(_ sender: Any?) {
    guard let pasted = UIPasteboard.general.string else { return super.paste(sender) }
    perform(
      TextChange(
        range: selectedRange, replacement: OutlineEditing.normalizedPaste(pasted),
        selection: NSRange(
          location: selectedRange.location
            + (OutlineEditing.normalizedPaste(pasted) as NSString).length, length: 0)))
  }

  // MARK: Keyboard bar

  /// Shown above the on-screen keyboard: the Outline menu's editing commands by touch.
  private var barItems: [KeyboardBarItem] {
    let priorities: [(String, MapPriority?)] = [
      ("High", .high), ("Medium", .medium), ("Low", .low), ("Chill", .chill), ("None", nil),
    ]
    return [
      KeyboardBarItem(title: "Indent", symbol: "increase.indent") { [weak self] in
        self?.indentLines()
      },
      KeyboardBarItem(title: "Outdent", symbol: "decrease.indent") { [weak self] in
        self?.outdentLines()
      },
      KeyboardBarItem(title: "Toggle Done", symbol: "checkmark.square") { [weak self] in
        self?.toggleDone()
      },
      KeyboardBarItem(
        title: "Priority", symbol: "flag",
        children: priorities.map { title, value in
          KeyboardBarItem(title: title, symbol: "flag") { [weak self] in
            self?.setPriority(value)
          }
        }),
      KeyboardBarItem(title: "Insert Link", symbol: "link") { [weak self] in
        self?.insertLink()
      },
      KeyboardBarItem(title: "Move Up", symbol: "arrow.up") { [weak self] in
        self?.moveLineUp()
      },
      KeyboardBarItem(title: "Move Down", symbol: "arrow.down") { [weak self] in
        self?.moveLineDown()
      },
      KeyboardBarItem(title: "Hide Keyboard", symbol: "keyboard.chevron.compact.down") {
        [weak self] in
        _ = self?.resignFirstResponder()
      },
    ]
  }

  private func makeKeyboardBar() -> UIToolbar {
    let bar = UIToolbar(frame: CGRect(x: 0, y: 0, width: 600, height: 44))
    bar.barStyle = .black
    bar.tintColor = editorColor(0xc7c7cc)
    var items: [UIBarButtonItem] = []
    for item in barItems {
      let image = UIImage(systemName: item.symbol)
      let button: UIBarButtonItem
      if item.children.isEmpty {
        let action = item.action
        button = UIBarButtonItem(
          title: item.title, image: image,
          primaryAction: UIAction(title: item.title) { _ in
            MainActor.assumeIsolated { action?() }
          })
      } else {
        let menu = UIMenu(
          title: item.title,
          children: item.children.map { child in
            let action = child.action
            return UIAction(title: child.title) { _ in MainActor.assumeIsolated { action?() } }
          })
        button = UIBarButtonItem(title: item.title, image: image, menu: menu)
      }
      button.accessibilityLabel = item.title
      if item.title == "Hide Keyboard" { items.append(.flexibleSpace()) }
      items.append(button)
    }
    bar.items = items
    bar.sizeToFit()
    return bar
  }
}

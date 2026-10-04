import AppKit

/// Let the final debounced write finish before a normal Quit.
@MainActor
final class AppLifecycle: NSObject, NSApplicationDelegate {
  static weak var store: MapStore?

  /// ⌘+ (⇧⌘= or keypad +) also zooms in; a menu item can hold only one of ⌘= and ⌘+.
  func applicationDidFinishLaunching(_ notification: Notification) {
    NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
      // ⌥⌘= is Bigger Labels, so ⌥ excludes the event.
      guard event.modifierFlags.contains(.command), !event.modifierFlags.contains(.option),
        event.charactersIgnoringModifiers == "+"
      else {
        return event
      }
      Self.store?.graphView?.zoomIn()
      return nil
    }
  }

  func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
    guard let store = Self.store,
      store.currentURL != nil || store.hasUnsavedEdits || store.hasUnsavedLayout
    else {
      return .terminateNow
    }
    Task { sender.reply(toApplicationShouldTerminate: await store.finishSaving()) }
    return .terminateLater
  }
}

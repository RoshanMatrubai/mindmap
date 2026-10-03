import AppKit

/// Let the final debounced write finish before a normal Quit.
@MainActor
final class AppLifecycle: NSObject, NSApplicationDelegate {
  static weak var store: MapStore?

  func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
    guard let store = Self.store, store.hasUnsavedEdits else { return .terminateNow }
    Task { sender.reply(toApplicationShouldTerminate: await store.finishSaving()) }
    return .terminateLater
  }
}

import Foundation

/// Watches the maps folder for changes made elsewhere: another device through iCloud Drive,
/// Finder, another app. Event-driven (`NSFilePresenter`), nothing polls; the system calls it
/// only when something in the folder changes. The app's own coordinated writes pass this
/// presenter along, so they don't come back as changes.
final class MapFolderPresenter: NSObject, NSFilePresenter, @unchecked Sendable {
  let presentedItemURL: URL?
  let presentedItemOperationQueue: OperationQueue
  /// A map changed, appeared, moved, was deleted or gained a version; nil when the folder
  /// itself changed or the item isn't known.
  private let onChange: @Sendable (URL?) -> Void

  init(folder: URL, onChange: @escaping @Sendable (URL?) -> Void) {
    presentedItemURL = folder
    let queue = OperationQueue()
    queue.maxConcurrentOperationCount = 1
    queue.qualityOfService = .utility
    presentedItemOperationQueue = queue
    self.onChange = onChange
  }

  func presentedItemDidChange() { onChange(nil) }
  func presentedSubitemDidChange(at url: URL) { onChange(url) }
  func presentedSubitemDidAppear(at url: URL) { onChange(url) }
  func presentedSubitem(at oldURL: URL, didMoveTo newURL: URL) { onChange(nil) }
  func presentedSubitem(at url: URL, didGain version: NSFileVersion) { onChange(url) }

}

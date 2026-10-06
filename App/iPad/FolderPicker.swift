import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// The maps folder picker (Release, and the dev app with `-use-folder-picker YES`): a folder
/// anywhere in Files, including iCloud Drive. The store keeps a bookmark to it.
struct FolderPicker: UIViewControllerRepresentable {
  let onPick: (URL) -> Void

  func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
    let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.folder])
    picker.allowsMultipleSelection = false
    picker.delegate = context.coordinator
    return picker
  }

  func updateUIViewController(_ picker: UIDocumentPickerViewController, context: Context) {}

  func makeCoordinator() -> Coordinator { Coordinator(onPick: onPick) }

  final class Coordinator: NSObject, UIDocumentPickerDelegate {
    let onPick: (URL) -> Void
    init(onPick: @escaping (URL) -> Void) { self.onPick = onPick }

    func documentPicker(
      _ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]
    ) {
      if let url = urls.first { onPick(url) }
    }
  }
}

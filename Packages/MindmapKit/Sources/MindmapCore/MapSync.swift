import Foundation

/// Decisions for a maps folder that another device edits too (iCloud Drive). Pure, so the apps'
/// file presenters only gather the texts and act on the answer.
public enum MapSync {
  /// What to do when the open map's file changed on disk.
  public enum Action: Equatable, Sendable {
    /// Nothing new: the disk holds what is open (often this app's own save) or what was last
    /// saved while newer edits wait to be written.
    case none
    /// No unsaved edits: show the disk version in place.
    case reload
    /// Unsaved edits and a different disk version: keep the open text as the map and save the
    /// disk version as a conflict copy, so no text is lost.
    case keepOpenAndCopyDisk
  }

  /// `saved` is the text last read from or written to the file, `open` the text on screen and
  /// `disk` the file's new contents.
  public static func decide(saved: String, open: String, disk: String) -> Action {
    if disk == open || disk == saved { return .none }
    return open == saved ? .reload : .keepOpenAndCopyDisk
  }

  /// "<title> (conflict <device name> <yyyy-MM-dd HH.mm>)". No colons: the title names the file.
  public static func conflictTitle(
    _ title: String, device: String, date: Date, timeZone: TimeZone = .current
  ) -> String {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = timeZone
    let c = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: date)
    func two(_ value: Int?) -> String { String(format: "%02d", value ?? 0) }
    let stamp =
      "\(c.year ?? 0)-\(two(c.month))-\(two(c.day)) \(two(c.hour)).\(two(c.minute))"
    let device = device.replacingOccurrences(of: ":", with: "").replacingOccurrences(
      of: "/", with: "")
    return "\(title) (conflict \(device) \(stamp))"
  }

  /// The conflict copy's text: `text` with its title line renamed, so the copy gets its own
  /// visible file name and list entry. Everything after the title stays byte for byte.
  public static func conflictCopy(
    of text: String, device: String, date: Date, timeZone: TimeZone = .current
  ) -> String {
    let title = MapDocument.title(of: text) ?? "untitled map"
    let renamed = conflictTitle(title, device: device, date: date, timeZone: timeZone)
    let ns = text as NSString
    var location = 0
    while location < ns.length {
      let line = ns.lineRange(for: NSRange(location: location, length: 0))
      let content = ns.substring(with: line).trimmingCharacters(in: .whitespacesAndNewlines)
      if !content.isEmpty {
        let body = ns.substring(with: line)
        let ending = String(body.reversed().prefix { $0.isNewline }.reversed())
        return ns.replacingCharacters(in: line, with: renamed + ending)
      }
      location = NSMaxRange(line)
    }
    return renamed + "\n" + text
  }

  /// iPadOS shows a file that iCloud hasn't downloaded yet as a hidden placeholder,
  /// `.<name>.icloud`. Returns `<name>` for a map's placeholder, else nil.
  public static func placeholderTarget(_ fileName: String) -> String? {
    guard fileName.hasPrefix("."), fileName.hasSuffix(".mindmap.icloud") else { return nil }
    let name = String(fileName.dropFirst().dropLast(".icloud".count))
    return name == ".mindmap" || name.isEmpty ? nil : name
  }
}

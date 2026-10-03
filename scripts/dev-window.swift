// Helpers for `make screenshot`, run with `swift scripts/dev-window.swift`.
//   id <owner>   prints the window ID of <owner>'s main window (exact owner-name match), exit 1 if none
//   blank <png>  exit 0 if the image is one flat color (what screencapture gives without Screen Recording)
import CoreGraphics
import Foundation
import ImageIO

let args = CommandLine.arguments
switch args.count == 3 ? args[1] : "" {
case "id":
  let windows =
    CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
  let id =
    windows.first {
      $0[kCGWindowOwnerName as String] as? String == args[2]
        && $0[kCGWindowLayer as String] as? Int == 0
    }?[kCGWindowNumber as String] as? Int
  guard let id else { exit(1) }
  print(id)
case "blank":
  guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: args[2]) as CFURL, nil),
    let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
    let data = image.dataProvider?.data as Data?
  else { exit(0) }
  let px = image.bitsPerPixel / 8
  let first = data.prefix(px)
  let blank = (0..<image.height).allSatisfy { y in
    (0..<image.width).allSatisfy { x in
      let i = data.startIndex + y * image.bytesPerRow + x * px
      return data[i..<i + px] == first
    }
  }
  exit(blank ? 0 : 1)
default:
  FileHandle.standardError.write(
    "usage: dev-window.swift id <owner> | blank <png>\n".data(using: .utf8)!)
  exit(2)
}

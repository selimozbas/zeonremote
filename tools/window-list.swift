// Lists the on-screen windows of a process: "<id> <width>x<height> <title>"
// Usage: swift tools/window-list.swift <owner name>
import CoreGraphics
import Foundation

let owner = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "Zeon Remote"
let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
  as? [[String: Any]] ?? []
for w in list where (w[kCGWindowOwnerName as String] as? String) == owner {
  guard (w[kCGWindowLayer as String] as? Int) == 0 else { continue }
  let id = w[kCGWindowNumber as String] as? Int ?? 0
  let b = w[kCGWindowBounds as String] as? [String: CGFloat] ?? [:]
  let title = w[kCGWindowName as String] as? String ?? ""
  print("\(id) \(Int(b["Width"] ?? 0))x\(Int(b["Height"] ?? 0)) \(title)")
}

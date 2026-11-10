// Prints the on-screen windows a process owns that a person could see:
// layer 0 (normal windows; the menu-bar status item is on a higher layer)
// with nonzero alpha and a real size. One line per window, nothing if none.
// Usage: visible-windows <pid>
import CoreGraphics
import Foundation

guard CommandLine.arguments.count == 2, let pid = Int(CommandLine.arguments[1]) else {
    FileHandle.standardError.write(Data("usage: visible-windows <pid>\n".utf8))
    exit(2)
}
let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
for window in windows where (window[kCGWindowOwnerPID as String] as? Int) == pid {
    let layer = window[kCGWindowLayer as String] as? Int ?? 0
    let alpha = window[kCGWindowAlpha as String] as? Double ?? 1
    let bounds = window[kCGWindowBounds as String] as? [String: Double] ?? [:]
    let width = bounds["Width"] ?? 0
    let height = bounds["Height"] ?? 0
    guard layer == 0, alpha > 0, width > 1, height > 1 else { continue }
    print("layer=\(layer) alpha=\(alpha) size=\(Int(width))x\(Int(height))")
}

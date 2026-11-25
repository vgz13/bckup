import AppKit
// Draws the app icon (1024px PNG): dark rounded square, SD card with a check mark.
let size: CGFloat = 1024
let img = NSImage(size: NSSize(width: size, height: size))
img.lockFocus()
let rect = NSRect(x: 100, y: 100, width: 824, height: 824)
let bg = NSBezierPath(roundedRect: rect, xRadius: 185, yRadius: 185)
NSGradient(starting: NSColor(calibratedRed: 0.10, green: 0.13, blue: 0.16, alpha: 1),
           ending: NSColor(calibratedRed: 0.05, green: 0.06, blue: 0.08, alpha: 1))!.draw(in: bg, angle: -90)
let cfg = NSImage.SymbolConfiguration(pointSize: 470, weight: .semibold)
    .applying(.init(paletteColors: [NSColor(calibratedRed: 0.35, green: 0.85, blue: 0.55, alpha: 1)]))
if let sym = NSImage(systemSymbolName: "sdcard.fill", accessibilityDescription: nil)?.withSymbolConfiguration(cfg) {
    let s = sym.size
    sym.draw(in: NSRect(x: (size - s.width) / 2, y: (size - s.height) / 2 + 20, width: s.width, height: s.height))
}
let chk = NSImage.SymbolConfiguration(pointSize: 250, weight: .bold)
    .applying(.init(paletteColors: [.white, NSColor(calibratedRed: 0.10, green: 0.13, blue: 0.16, alpha: 1)]))
if let c = NSImage(systemSymbolName: "checkmark.circle.fill", accessibilityDescription: nil)?.withSymbolConfiguration(chk) {
    let s = c.size
    c.draw(in: NSRect(x: 600, y: 170, width: s.width, height: s.height))
}
img.unlockFocus()
let rep = NSBitmapImageRep(data: img.tiffRepresentation!)!
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))

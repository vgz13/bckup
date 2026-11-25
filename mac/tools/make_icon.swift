import AppKit

// BCKUP app icon (1024 px PNG): yellow rounded square, dark SD card, lightning bolt badge top-right.
let size: CGFloat = 1024
let img = NSImage(size: NSSize(width: size, height: size))
img.lockFocus()

let ink = NSColor(calibratedRed: 0.11, green: 0.10, blue: 0.08, alpha: 1)

// Background: warm yellow with a gentle top-to-bottom shade.
let rect = NSRect(x: 100, y: 100, width: 824, height: 824)
let bg = NSBezierPath(roundedRect: rect, xRadius: 185, yRadius: 185)
NSGradient(starting: NSColor(calibratedRed: 1.00, green: 0.84, blue: 0.20, alpha: 1),
           ending: NSColor(calibratedRed: 0.98, green: 0.71, blue: 0.05, alpha: 1))!.draw(in: bg, angle: -90)

// SD card, centred slightly low so the badge has room.
let cardCfg = NSImage.SymbolConfiguration(pointSize: 440, weight: .semibold).applying(.init(paletteColors: [ink]))
if let card = NSImage(systemSymbolName: "sdcard.fill", accessibilityDescription: nil)?.withSymbolConfiguration(cardCfg) {
    let s = card.size
    card.draw(in: NSRect(x: (size - s.width) / 2 - 30, y: (size - s.height) / 2 - 40, width: s.width, height: s.height))
}

// Lightning badge, top-right: dark disc with a yellow bolt, ringed in the background colour.
let center = CGPoint(x: 735, y: 735)
let r: CGFloat = 150
NSColor(calibratedRed: 1.00, green: 0.80, blue: 0.16, alpha: 1).setFill()
NSBezierPath(ovalIn: NSRect(x: center.x - r - 22, y: center.y - r - 22, width: (r + 22) * 2, height: (r + 22) * 2)).fill()
ink.setFill()
NSBezierPath(ovalIn: NSRect(x: center.x - r, y: center.y - r, width: r * 2, height: r * 2)).fill()
let boltCfg = NSImage.SymbolConfiguration(pointSize: 190, weight: .heavy)
    .applying(.init(paletteColors: [NSColor(calibratedRed: 1.00, green: 0.82, blue: 0.18, alpha: 1)]))
if let bolt = NSImage(systemSymbolName: "bolt.fill", accessibilityDescription: nil)?.withSymbolConfiguration(boltCfg) {
    let s = bolt.size
    bolt.draw(in: NSRect(x: center.x - s.width / 2, y: center.y - s.height / 2, width: s.width, height: s.height))
}

img.unlockFocus()
let rep = NSBitmapImageRep(data: img.tiffRepresentation!)!
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))

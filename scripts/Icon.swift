import AppKit
let output = CommandLine.arguments[1]
let image = NSImage(size: NSSize(width: 1024, height: 1024))
image.lockFocus()
NSColor(calibratedRed: 0.10, green: 0.17, blue: 0.29, alpha: 1).setFill()
NSBezierPath(roundedRect: NSRect(x: 40, y: 40, width: 944, height: 944), xRadius: 210, yRadius: 210).fill()
for i in (0..<3).reversed() {
    let x = CGFloat(210 + i * 45), y = CGFloat(250 + i * 100)
    NSColor(calibratedWhite: 1, alpha: CGFloat(0.5 + Double(2-i)*0.2)).setFill()
    NSBezierPath(roundedRect: NSRect(x: x, y: y, width: 480, height: 185), xRadius: 35, yRadius: 35).fill()
    NSColor(calibratedRed: 0.15, green: 0.3, blue: 0.45, alpha: 1).setFill()
    NSBezierPath(roundedRect: NSRect(x: x+40, y: y+75, width: 260, height: 30), xRadius: 15, yRadius: 15).fill()
}
NSColor(calibratedRed: 0.2, green: 0.85, blue: 0.7, alpha: 1).setFill()
NSBezierPath(roundedRect: NSRect(x: 620, y: 260, width: 150, height: 100), xRadius: 25, yRadius: 25).fill()
image.unlockFocus()
let rep = NSBitmapImageRep(data: image.tiffRepresentation!)!
try rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: output))

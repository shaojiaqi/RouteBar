import AppKit
let image = NSImage(size: NSSize(width: 1024, height: 1024))
image.lockFocus()
let bg = NSBezierPath(roundedRect: NSRect(x: 44, y: 44, width: 936, height: 936), xRadius: 208, yRadius: 208)
NSGradient(starting: NSColor(calibratedRed: 0.12, green: 0.23, blue: 0.34, alpha: 1), ending: NSColor(calibratedRed: 0.04, green: 0.11, blue: 0.20, alpha: 1))!.draw(in: bg, angle: -65)
let nodes = [NSPoint(x: 512, y: 730), NSPoint(x: 295, y: 335), NSPoint(x: 729, y: 335)]
let path = NSBezierPath(); path.lineWidth = 36; path.lineCapStyle = .round; path.move(to: nodes[1]); path.line(to: nodes[0]); path.line(to: nodes[2])
NSColor(calibratedRed: 0.32, green: 0.76, blue: 0.91, alpha: 1).setStroke(); path.stroke()
for (index, p) in nodes.enumerated() {
    let r: CGFloat = index == 0 ? 73 : 59
    NSColor.white.setFill(); NSBezierPath(ovalIn: NSRect(x: p.x - r, y: p.y - r, width: r * 2, height: r * 2)).fill()
}
image.unlockFocus()
let bitmap = NSBitmapImageRep(data: image.tiffRepresentation!)!
try bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))

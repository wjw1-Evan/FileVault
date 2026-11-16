import AppKit

// Draw the FileVault app icon: rounded square, vault dial + clock hand.
let size = CGFloat(1024)
let img = NSImage(size: NSSize(width: size, height: size))
img.lockFocus()
guard let ctx = NSGraphicsContext.current?.cgContext else { exit(1) }

// Background: rounded rect with vertical gradient (indigo -> deep navy).
let rect = CGRect(x: 100, y: 100, width: 824, height: 824)
let path = NSBezierPath(roundedRect: rect, xRadius: 180, yRadius: 180)
path.addClip()
let colors = [NSColor(calibratedRed: 0.22, green: 0.28, blue: 0.62, alpha: 1).cgColor,
              NSColor(calibratedRed: 0.09, green: 0.11, blue: 0.27, alpha: 1).cgColor]
let grad = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors as CFArray, locations: [0, 1])!
ctx.drawLinearGradient(grad, start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 100), options: [])

// Vault dial: outer ring + inner disc.
let dial = NSBezierPath(ovalIn: CGRect(x: 262, y: 262, width: 500, height: 500))
NSColor(calibratedWhite: 0.96, alpha: 1).setStroke()
dial.lineWidth = 34
dial.stroke()
let spokes = NSBezierPath()
for i in 0..<12 {
    let a = CGFloat(i) / 12 * 2 * .pi
    let r1: CGFloat = 168
    let r2: CGFloat = i % 3 == 0 ? 214 : 190
    spokes.move(to: NSPoint(x: 512 + r1 * cos(a), y: 512 + r1 * sin(a)))
    spokes.line(to: NSPoint(x: 512 + r2 * cos(a), y: 512 + r2 * sin(a)))
}
NSColor(calibratedWhite: 0.96, alpha: 1).setStroke()
spokes.lineWidth = 22
spokes.lineCapStyle = .round
spokes.stroke()

// Clock hand: green handle pointing to 10 o'clock.
let hand = NSBezierPath()
hand.move(to: NSPoint(x: 512, y: 512))
hand.line(to: NSPoint(x: 512 - 120, y: 512 + 120))
NSColor(calibratedRed: 0.30, green: 0.85, blue: 0.45, alpha: 1).setStroke()
hand.lineWidth = 40
hand.lineCapStyle = .round
hand.stroke()
let hub = NSBezierPath(ovalIn: CGRect(x: 512 - 52, y: 512 - 52, width: 104, height: 104))
NSColor(calibratedRed: 0.30, green: 0.85, blue: 0.45, alpha: 1).setFill()
hub.fill()
img.unlockFocus()

// Export PNG 1024.
guard CommandLine.arguments.count > 1, !CommandLine.arguments[1].isEmpty else {
    FileHandle.standardError.write(Data("用法: swift scripts/make_icon.swift <输出.png>\n".utf8))
    exit(2)
}
guard let tiff = img.tiffRepresentation,
      let rep = NSBitmapImageRep(data: tiff),
      let png = rep.representation(using: .png, properties: [:]) else {
    FileHandle.standardError.write(Data("✗ 无法生成图标位图\n".utf8))
    exit(1)
}
do {
    try png.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
} catch {
    FileHandle.standardError.write(Data("✗ 写入图标失败：\(error)\n".utf8))
    exit(1)
}
print("icon written")

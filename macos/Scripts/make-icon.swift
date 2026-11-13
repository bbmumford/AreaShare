import AppKit

// Draws the app icon, a red frame with its grab tab on a dark tile, and
// writes it as a 1024-pixel PNG to the path given as the only argument.

guard CommandLine.arguments.count == 2 else {
    FileHandle.standardError.write(Data("usage: make-icon.swift <output.png>\n".utf8))
    exit(2)
}

let side = 1024
guard let bitmap = NSBitmapImageRep(
    bitmapDataPlanes: nil, pixelsWide: side, pixelsHigh: side, bitsPerSample: 8, samplesPerPixel: 4,
    hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
    let context = NSGraphicsContext(bitmapImageRep: bitmap)
else { exit(1) }

NSGraphicsContext.current = context

// The tile, inset the way macOS icons are so its size matches its neighbours.
let tile = NSBezierPath(roundedRect: NSRect(x: 100, y: 100, width: 824, height: 824), xRadius: 185, yRadius: 185)
NSGradient(colors: [NSColor(srgbRed: 0.20, green: 0.23, blue: 0.29, alpha: 1),
                    NSColor(srgbRed: 0.09, green: 0.10, blue: 0.14, alpha: 1)])?.draw(in: tile, angle: -90)

// A faint desktop behind the frame: two window shapes.
NSColor(white: 1, alpha: 0.10).setFill()
NSBezierPath(roundedRect: NSRect(x: 190, y: 250, width: 330, height: 420), xRadius: 24, yRadius: 24).fill()
NSBezierPath(roundedRect: NSRect(x: 470, y: 400, width: 370, height: 330), xRadius: 24, yRadius: 24).fill()

// The frame and its tab.
let red = NSColor(srgbRed: 0.90, green: 0.18, blue: 0.18, alpha: 1)
red.setStroke()
red.setFill()
let frame = NSBezierPath(rect: NSRect(x: 330, y: 330, width: 420, height: 290))
frame.lineWidth = 34
frame.lineJoinStyle = .miter
frame.stroke()
NSBezierPath(roundedRect: NSRect(x: 313, y: 620, width: 210, height: 62), xRadius: 18, yRadius: 18).fill()
NSBezierPath(rect: NSRect(x: 313, y: 620, width: 210, height: 22)).fill()

context.flushGraphics()
guard let png = bitmap.representation(using: .png, properties: [:]) else { exit(1) }
do {
    try png.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
} catch {
    FileHandle.standardError.write(Data("\(error.localizedDescription)\n".utf8))
    exit(1)
}

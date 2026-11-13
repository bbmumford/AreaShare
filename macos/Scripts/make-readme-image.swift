import AppKit

// Composes the ReadMe picture: the outline as the app draws it, laid over a
// drawn stand-in desktop so the picture shows nobody's actual screen.
//
//   make-readme-image.swift <outline.png> <x> <y> <width> <height> <output.png>
//
// <outline.png> is the outline on a transparent background, as written by
// `AreaShare --render-frame`; x, y, width, height are the region within it,
// in pixels from the top-left.

let arguments = CommandLine.arguments
guard arguments.count == 7, let capture = NSImage(contentsOfFile: arguments[1]),
      let captureImage = capture.cgImage(forProposedRect: nil, context: nil, hints: nil),
      let rx = Double(arguments[2]), let ry = Double(arguments[3]),
      let rw = Double(arguments[4]), let rh = Double(arguments[5])
else {
    FileHandle.standardError.write(Data("usage: make-readme-image.swift <outline.png> <x> <y> <width> <height> <output.png>\n".utf8))
    exit(2)
}

// The picture shows the region with a margin of desktop around it.
let margin = 260.0
let crop = CGRect(x: rx - margin, y: ry - margin, width: rw + 2 * margin, height: rh + 2 * margin)
let scale = 1600.0 / crop.width
let size = CGSize(width: 1600, height: (crop.height * scale).rounded())

guard let bitmap = NSBitmapImageRep(
    bitmapDataPlanes: nil, pixelsWide: Int(size.width), pixelsHigh: Int(size.height), bitsPerSample: 8,
    samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
    let context = NSGraphicsContext(bitmapImageRep: bitmap)
else { exit(1) }
NSGraphicsContext.current = context
let cg = context.cgContext
// Work in crop pixels with the origin at the top-left.
cg.translateBy(x: 0, y: size.height)
cg.scaleBy(x: scale, y: -scale)

func fill(_ rect: CGRect, _ white: CGFloat, alpha: CGFloat = 1, radius: CGFloat = 0) {
    cg.setFillColor(NSColor(white: white, alpha: alpha).cgColor)
    cg.addPath(CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil))
    cg.fillPath()
}

/// A stand-in app window: title bar, sidebar and lines of "text".
func window(_ frame: CGRect, tint: NSColor) {
    fill(frame, 0.13, radius: 14)
    fill(CGRect(x: frame.minX, y: frame.minY, width: frame.width, height: 44), 0.19, radius: 14)
    fill(CGRect(x: frame.minX, y: frame.minY + 30, width: frame.width, height: 14), 0.19)
    for (index, color) in [NSColor.systemRed, .systemYellow, .systemGreen].enumerated() {
        cg.setFillColor(color.withAlphaComponent(0.85).cgColor)
        cg.fillEllipse(in: CGRect(x: frame.minX + 18 + Double(index) * 24, y: frame.minY + 15, width: 14, height: 14))
    }
    let sidebar = min(260.0, frame.width * 0.22)
    fill(CGRect(x: frame.minX, y: frame.minY + 44, width: sidebar, height: frame.height - 58), 0.16)
    var y = frame.minY + 76
    var row = 0
    while y < frame.maxY - 40 {
        fill(CGRect(x: frame.minX + 20, y: y, width: sidebar - 40 - Double(row % 3) * 26, height: 12), 0.30, radius: 6)
        y += 34
        row += 1
    }
    cg.setFillColor(tint.withAlphaComponent(0.75).cgColor)
    cg.addPath(CGPath(roundedRect: CGRect(x: frame.minX + sidebar + 40, y: frame.minY + 84, width: min(420, frame.width * 0.3), height: 26),
                      cornerWidth: 8, cornerHeight: 8, transform: nil))
    cg.fillPath()
    y = frame.minY + 150
    row = 0
    let textWidth = frame.width - sidebar - 80
    while y < frame.maxY - 40 {
        let shorten = [0.0, 0.18, 0.06, 0.42, 0.0, 0.27][row % 6]
        if row % 6 != 5 {
            fill(CGRect(x: frame.minX + sidebar + 40, y: y, width: textWidth * (1 - shorten), height: 12), 0.34, radius: 6)
        }
        y += 30
        row += 1
    }
}

// Desktop.
cg.setFillColor(NSColor(srgbRed: 0.07, green: 0.08, blue: 0.11, alpha: 1).cgColor)
cg.fill(CGRect(origin: .zero, size: crop.size))
// Two windows: one the frame is fitted around, one it leaves out.
window(CGRect(x: margin - 520, y: margin + 120, width: 900, height: rh + 400), tint: .systemTeal)
window(CGRect(x: margin + rw * 0.45, y: margin - 150, width: rw * 0.9, height: rh * 0.75), tint: .systemPurple)
window(CGRect(x: margin + 40, y: margin + 40, width: rw - 80, height: rh - 80), tint: .systemBlue)
// Dim everything the audience does not see.
cg.setFillColor(NSColor(white: 0, alpha: 0.45).cgColor)
cg.addRect(CGRect(origin: .zero, size: crop.size))
cg.addRect(CGRect(x: margin, y: margin, width: rw, height: rh))
cg.fillPath(using: .evenOdd)

// The real outline on top.
if let outline = captureImage.cropping(to: crop.intersection(CGRect(x: 0, y: 0, width: captureImage.width, height: captureImage.height))) {
    let visible = crop.intersection(CGRect(x: 0, y: 0, width: captureImage.width, height: captureImage.height))
    let target = CGRect(x: visible.minX - crop.minX, y: visible.minY - crop.minY, width: visible.width, height: visible.height)
    cg.saveGState()
    cg.translateBy(x: 0, y: target.maxY + target.minY)
    cg.scaleBy(x: 1, y: -1)
    cg.draw(outline, in: target)
    cg.restoreGState()
}

context.flushGraphics()
guard let png = bitmap.representation(using: .png, properties: [:]) else { exit(1) }
do {
    try png.write(to: URL(fileURLWithPath: arguments[6]))
} catch {
    FileHandle.standardError.write(Data("\(error.localizedDescription)\n".utf8))
    exit(1)
}

import AppKit
import AreaShareCore

// AreaShare shares one rectangle of a large desktop through any conferencing
// app that can share a window. See ReadMe.md.

/// Writes a picture of the outline, drawn by the same view the app shows,
/// around a `width` by `height` region with `margin` points of empty space on
/// every side. Used to make the ReadMe picture without photographing anyone's
/// screen:
///
///     AreaShare --render-frame <output.png> <width> <height> <margin>
@MainActor
func renderFrame(_ arguments: [String]) -> Int32 {
    guard arguments.count == 4, let width = Double(arguments[1]), let height = Double(arguments[2]),
          let margin = Double(arguments[3]), width > 0, height > 0, margin >= 0
    else {
        FileHandle.standardError.write(Data("usage: AreaShare --render-frame <output.png> <width> <height> <margin>\n".utf8))
        return 2
    }
    let canvas = CGRect(x: 0, y: 0, width: width + 2 * margin, height: height + 2 * margin)
    let region = CGRect(x: margin, y: margin, width: width, height: height)
    let view = FrameView(frame: canvas)
    view.label = "AreaShare   \(Int(width)) × \(Int(height))"
    view.layout = FrameLayout(region: region, usable: canvas, metrics: view.metrics)
    guard let bitmap = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: Int(canvas.width), pixelsHigh: Int(canvas.height), bitsPerSample: 8,
        samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
        let context = NSGraphicsContext(bitmapImageRep: bitmap), let layer = view.layer
    else { return 1 }
    layer.frame = canvas
    layer.render(in: context.cgContext)
    context.flushGraphics()
    guard let png = bitmap.representation(using: .png, properties: [:]),
          (try? png.write(to: URL(fileURLWithPath: arguments[0]))) != nil
    else { return 1 }
    return 0
}

// The process starts on the main thread, which is what the main actor is.
MainActor.assumeIsolated {
    let arguments = CommandLine.arguments
    if let flag = arguments.firstIndex(of: "--render-frame") {
        exit(renderFrame(Array(arguments[(flag + 1)...])))
    }
    // AreaShare --check-update: report what the updater finds, and download
    // and verify an update without installing it.
    // AreaShare --install-update: the same, then replace this app with it.
    if arguments.contains("--check-update") || arguments.contains("--install-update") {
        let install = arguments.contains("--install-update")
        Task { @MainActor in exit(await Updater().runFromCommandLine(install: install)) }
        RunLoop.main.run()
    }
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    // A regular app with a Dock icon: window pickers reliably list the
    // windows of regular apps.
    app.setActivationPolicy(.regular)
    app.run()
}

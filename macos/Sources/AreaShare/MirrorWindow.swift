import AppKit
import IOSurface

/// The window to pick in a conferencing app's "share a window" list. It lies
/// exactly over the region, shows a live copy of what the region shows, and
/// lets every click through, so wherever it ends up in the window order the
/// desktop looks and behaves as if it were not there.
///
/// It has no title bar because a window share includes the whole window: the
/// audience must get the copied pixels and nothing else.
final class MirrorWindow: NSWindow {
    private let pictureLayer = CALayer()

    init(region: CGRect) {
        super.init(contentRect: region, styleMask: [.borderless], backing: .buffered, defer: false)
        title = "AreaShare"
        isOpaque = true
        backgroundColor = .black
        hasShadow = false
        ignoresMouseEvents = true
        isReleasedWhenClosed = false
        isExcludedFromWindowsMenu = true
        isRestorable = false
        animationBehavior = .none
        // An ordinary window level: window pickers list ordinary windows
        // only. Present on every Space, including beside full-screen apps,
        // because a window on another Space stops being captured.
        level = .normal
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]

        pictureLayer.contentsGravity = .resize
        pictureLayer.backgroundColor = NSColor.black.cgColor
        pictureLayer.actions = ["contents": NSNull(), "bounds": NSNull(), "position": NSNull()]
        let view = NSView(frame: NSRect(origin: .zero, size: region.size))
        view.layer = pictureLayer
        view.wantsLayer = true
        contentView = view
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    /// Shows a picture from the recorder.
    func show(_ surface: IOSurface) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        pictureLayer.contents = surface
        CATransaction.commit()
    }

    /// Puts the window behind every other ordinary window if any of them is
    /// underneath it. A conferencing app raises the window it starts
    /// sharing; raised, the mirror would show the desktop a frame late.
    func sinkIfRaised() {
        guard isVisible,
              let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
                as? [[CFString: Any]]
        else { return }
        let own = ProcessInfo.processInfo.processIdentifier
        var passedMirror = false
        // The list runs from the frontmost window to the backmost.
        for entry in list {
            guard (entry[kCGWindowLayer] as? Int) == 0 else { continue }
            if (entry[kCGWindowNumber] as? Int) == windowNumber {
                passedMirror = true
            } else if passedMirror, (entry[kCGWindowOwnerPID] as? pid_t) != own {
                orderBack(nil)
                return
            }
        }
    }
}

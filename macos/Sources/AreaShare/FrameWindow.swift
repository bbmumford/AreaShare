import AppKit
import AreaShareCore

/// What the frame tells the user about the share.
enum ShareState: Equatable {
    case live
    case paused
    case needsPermission
    case stopped

    var color: NSColor {
        switch self {
        case .live: return NSColor(srgbRed: 0.86, green: 0.15, blue: 0.15, alpha: 1)
        // Anything but live is amber: the picture people see is not moving.
        case .paused, .needsPermission, .stopped: return NSColor(srgbRed: 0.85, green: 0.47, blue: 0.02, alpha: 1)
        }
    }
}

/// Receives what the pointer does to the frame.
@MainActor
protocol FrameViewDelegate: AnyObject {
    func frameDragMoved(to region: CGRect)
    func frameDragEnded()
    /// The tab was wiggled, the pointer passing through `path`: fit the
    /// region around the windows it passed over. Returns whether there were
    /// any.
    func frameSnapToWindows(along path: [CGPoint]) -> Bool
    /// Rectangles whose edges a dragged edge clicks onto, front to back.
    func frameAlignmentTargets() -> [CGRect]
    func frameContextMenu() -> NSMenu
    /// Every display's rectangle, in global points.
    var screenFrames: [CGRect] { get }
}

/// The outline around the region. The panel is see-through and covers the
/// whole display the region is on; the outline is drawn inside it. Moving or
/// resizing the region therefore only redraws: the panel itself changes only
/// when the region goes to another display, so the outline can never be out
/// of step with the size of its window.
///
/// Clicking it never activates the app, and everywhere it draws nothing the
/// window server passes clicks to whatever is underneath.
final class FrameWindow: NSPanel {
    let frameView = FrameView()

    init() {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        isFloatingPanel = true
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = true
        isMovable = false
        isReleasedWhenClosed = false
        isRestorable = false
        animationBehavior = .none
        acceptsMouseMovedEvents = true
        // Above ordinary windows, full-screen apps and the menu bar, on
        // every Space, and left alone by Mission Control.
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        contentView = frameView
        // The view sets the pointer itself, by zone; AppKit's cursor rects
        // would keep putting the arrow back.
        disableCursorRects()
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    /// Shows `layout` on the display whose rectangle is `screen`.
    func show(_ layout: FrameLayout, onScreen screen: CGRect) {
        if frame != screen {
            setFrame(screen, display: true)
        }
        frameView.layout = layout
    }
}

/// Draws the outline with layers and turns pointer movement into region
/// changes. Its bounds are the display; `layout` is in global coordinates.
final class FrameView: NSView {
    weak var delegate: FrameViewDelegate?
    let metrics = FrameMetrics()

    var layout: FrameLayout? { didSet { if layout != oldValue { refresh() } } }
    var state: ShareState = .live { didSet { if state != oldValue { refresh() } } }
    var label = "" { didSet { if label != oldValue { refresh() } } }

    private var drag: Drag?
    /// The zone under the pointer, drawn highlighted so it is plain what a
    /// press will grab.
    private var hover = Zone.none { didSet { if hover != oldValue { refresh() } } }
    private var tracking: NSTrackingArea?
    private var shake = ShakeDetector()
    /// What a dragged edge can click onto, read once when the drag starts.
    private var alignmentTargets: [CGRect] = []
    /// True from a snap until the button comes up, so the rest of that
    /// press does not drag the region off the window it just fitted.
    private var snapped = false
    /// True for a moment after a snap: the whole outline lights up.
    private var flashing = false

    /// The faint band that makes the whole border grabbable.
    private let halo = CAShapeLayer()
    /// The line, the grips and the tab.
    private let solid = CAShapeLayer()
    private let highlight = CAShapeLayer()
    private let text = CATextLayer()

    override init(frame: NSRect) {
        super.init(frame: frame)
        let root = CALayer()
        halo.fillRule = .evenOdd
        solid.fillRule = .nonZero
        text.font = NSFont.systemFont(ofSize: 12, weight: .semibold)
        text.fontSize = 12
        text.foregroundColor = NSColor.white.cgColor
        text.truncationMode = .end
        text.alignmentMode = .left
        for layer in [halo, solid, highlight, text] {
            // Nothing here animates: the outline must follow the pointer.
            layer.actions = ["path": NSNull(), "fillColor": NSNull(), "frame": NSNull(), "bounds": NSNull(),
                             "position": NSNull(), "contents": NSNull(), "string": NSNull(), "hidden": NSNull()]
            root.addSublayer(layer)
        }
        layer = root
        wantsLayer = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("FrameView is created in code") }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        text.contentsScale = window?.backingScaleFactor ?? 1
    }

    // MARK: Drawing

    /// Global rectangle to view coordinates.
    private func local(_ r: CGRect) -> CGRect {
        let origin = window?.frame.origin ?? .zero
        return r.offsetBy(dx: -origin.x, dy: -origin.y)
    }

    private func refresh() {
        guard let layout else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }

        let outer = local(layout.outer), inner = local(layout.region), tab = local(layout.tab)
        let band = metrics.border
        let cx = min(metrics.corner, outer.width / 3), cy = min(metrics.corner, outer.height / 3)

        let haloPath = CGMutablePath()
        haloPath.addRect(outer)
        haloPath.addRect(inner)
        halo.path = haloPath
        halo.fillColor = state.color.withAlphaComponent(0.3).cgColor

        let path = CGMutablePath()
        // The line hugging the region, as four strips.
        let line = metrics.line, lined = inner.insetBy(dx: -line, dy: -line)
        path.addRect(CGRect(x: lined.minX, y: lined.minY, width: lined.width, height: line))
        path.addRect(CGRect(x: lined.minX, y: inner.maxY, width: lined.width, height: line))
        path.addRect(CGRect(x: lined.minX, y: inner.minY, width: line, height: inner.height))
        path.addRect(CGRect(x: inner.maxX, y: inner.minY, width: line, height: inner.height))
        // Grips where the pointer resizes: an L at each corner, as long as
        // the diagonal zone, and a bar at the middle of each side.
        for zone in [Zone.topLeft, .topRight, .bottomLeft, .bottomRight] {
            for rect in rects(for: zone, outer: outer, tab: tab, cornerX: cx, cornerY: cy) { path.addRect(rect) }
        }
        if outer.width > 2 * cx + 2 * metrics.grip {
            for y in [outer.minY, outer.maxY - band] {
                path.addRect(CGRect(x: outer.midX - metrics.grip / 2, y: y, width: metrics.grip, height: band))
            }
        }
        if outer.height > 2 * cy + 2 * metrics.grip {
            for x in [outer.minX, outer.maxX - band] {
                path.addRect(CGRect(x: x, y: outer.midY - metrics.grip / 2, width: band, height: metrics.grip))
            }
        }
        // The tab, rounded on the corners that do not meet the outline.
        let radius = min(6, tab.height / 2, tab.width / 2)
        path.addRoundedRect(in: tab, cornerWidth: radius, cornerHeight: radius)
        switch layout.side {
        case .above:
            path.addRect(CGRect(x: tab.minX, y: tab.minY, width: tab.width, height: radius))
        case .below:
            path.addRect(CGRect(x: tab.minX, y: tab.maxY - radius, width: tab.width, height: radius))
        case .inside:
            path.addRect(CGRect(x: tab.minX, y: tab.minY, width: radius, height: tab.height))
            path.addRect(CGRect(x: tab.minX, y: tab.maxY - radius, width: tab.width, height: radius))
        }
        solid.path = path
        solid.fillColor = state.color.cgColor

        let lit = CGMutablePath()
        if flashing {
            lit.addRect(outer)
            lit.addRect(inner)
            lit.addRect(tab)
        } else {
            for rect in rects(for: hover, outer: outer, tab: tab, cornerX: cx, cornerY: cy) { lit.addRect(rect) }
        }
        highlight.fillRule = flashing ? .evenOdd : .nonZero
        highlight.path = lit
        highlight.fillColor = NSColor.white.withAlphaComponent(hover == .move && !flashing ? 0.22 : 0.85).cgColor

        let textHeight: CGFloat = 16
        let textRect = CGRect(x: tab.minX + 9, y: tab.midY - textHeight / 2, width: tab.width - 18, height: textHeight)
        text.isHidden = textRect.width < 12
        text.frame = textRect
        text.string = label
        text.contentsScale = window?.backingScaleFactor ?? 1

        updateTrackingAreas()
    }

    /// The part of the band (or the tab) that `zone` covers, in view
    /// coordinates.
    private func rects(for zone: Zone, outer: CGRect, tab: CGRect, cornerX cx: CGFloat, cornerY cy: CGFloat) -> [CGRect] {
        let band = metrics.border
        func corner(_ x: CGFloat, _ y: CGFloat, right: Bool, top: Bool) -> [CGRect] {
            [CGRect(x: right ? x - cx : x, y: top ? y - band : y, width: cx, height: band),
             CGRect(x: right ? x - band : x, y: top ? y - cy : y, width: band, height: cy)]
        }
        switch zone {
        case .none: return []
        case .move: return [tab]
        case .left: return [CGRect(x: outer.minX, y: outer.minY + cy, width: band, height: outer.height - 2 * cy)]
        case .right: return [CGRect(x: outer.maxX - band, y: outer.minY + cy, width: band, height: outer.height - 2 * cy)]
        case .bottom: return [CGRect(x: outer.minX + cx, y: outer.minY, width: outer.width - 2 * cx, height: band)]
        case .top: return [CGRect(x: outer.minX + cx, y: outer.maxY - band, width: outer.width - 2 * cx, height: band)]
        case .bottomLeft: return corner(outer.minX, outer.minY, right: false, top: false)
        case .bottomRight: return corner(outer.maxX, outer.minY, right: true, top: false)
        case .topLeft: return corner(outer.minX, outer.maxY, right: false, top: true)
        case .topRight: return corner(outer.maxX, outer.maxY, right: true, top: true)
        }
    }

    // MARK: Pointer

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// Pointer movement is followed only around the outline, not across the
    /// whole display the panel covers.
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        let wanted = layout.map { local($0.window).insetBy(dx: -4, dy: -4) } ?? .zero
        if let tracking, tracking.rect == wanted { return }
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: wanted, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        tracking = area
    }

    private func zone(at point: CGPoint) -> Zone {
        layout?.zone(at: point, metrics: metrics) ?? .none
    }

    /// Follows the pointer: highlights the zone it is over and sets the
    /// matching pointer shape. Away from the outline the pointer is put back
    /// to the arrow once and then left to the app underneath.
    private func track() {
        guard drag == nil else { return }
        let zone = zone(at: NSEvent.mouseLocation)
        if zone != .none {
            Self.cursor(for: zone).set()
        } else if hover != .none {
            NSCursor.arrow.set()
        }
        hover = zone
    }

    override func mouseMoved(with event: NSEvent) { track() }
    override func mouseEntered(with event: NSEvent) { track() }
    override func mouseExited(with event: NSEvent) { track() }

    override func mouseDown(with event: NSEvent) {
        guard let layout else { return }
        let point = NSEvent.mouseLocation
        let zone = zone(at: point)
        guard zone != .none else { return }
        drag = Drag(zone: zone, start: layout.region, anchor: point)
        shake = ShakeDetector()
        alignmentTargets = zone == .move ? [] : delegate?.frameAlignmentTargets() ?? []
        hover = zone
        if zone == .move { NSCursor.closedHand.set() }
    }

    override func mouseDragged(with event: NSEvent) {
        guard let drag, let delegate else { return }
        if drag.zone == .move, let path = shake.add(NSEvent.mouseLocation, at: event.timestamp),
           delegate.frameSnapToWindows(along: path) {
            self.drag = nil
            snapped = true
            hover = .none
            flash()
            return
        }
        let keepAspect = event.modifierFlags.contains(.shift)
        var region = drag.region(cursor: NSEvent.mouseLocation, screens: delegate.screenFrames, metrics: metrics,
                                 keepAspect: keepAspect)
        // A dragged edge clicks onto a window edge it comes close to. Not
        // while keeping the shape, where one edge cannot move alone, and
        // not with Command held, for placing an edge just beside another.
        if drag.zone != .move, !keepAspect, !event.modifierFlags.contains(.command),
           let screen = bestScreen(for: drag.start, in: delegate.screenFrames) {
            region = aligned(region, zone: drag.zone, toEdgesOf: alignmentTargets, within: screen, metrics: metrics)
        }
        delegate.frameDragMoved(to: region)
    }

    /// Lights the whole outline briefly to show it has taken a new shape.
    private func flash() {
        flashing = true
        refresh()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
            self?.flashing = false
            self?.refresh()
        }
    }

    override func mouseUp(with event: NSEvent) {
        guard drag != nil || snapped else { return }
        drag = nil
        snapped = false
        track()
        delegate?.frameDragEnded()
    }

    override func rightMouseDown(with event: NSEvent) {
        guard drag == nil, zone(at: NSEvent.mouseLocation) != .none, let menu = delegate?.frameContextMenu() else { return }
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }

    private static func cursor(for zone: Zone) -> NSCursor {
        if #available(macOS 15.0, *) {
            switch zone {
            case .left: return .frameResize(position: .left, directions: .all)
            case .right: return .frameResize(position: .right, directions: .all)
            case .top: return .frameResize(position: .top, directions: .all)
            case .bottom: return .frameResize(position: .bottom, directions: .all)
            case .topLeft: return .frameResize(position: .topLeft, directions: .all)
            case .topRight: return .frameResize(position: .topRight, directions: .all)
            case .bottomLeft: return .frameResize(position: .bottomLeft, directions: .all)
            case .bottomRight: return .frameResize(position: .bottomRight, directions: .all)
            case .move: return .openHand
            case .none: return .arrow
            }
        }
        switch zone {
        case .left, .right: return .resizeLeftRight
        case .top, .bottom: return .resizeUpDown
        case .topLeft, .topRight, .bottomLeft, .bottomRight: return .crosshair
        case .move: return .openHand
        case .none: return .arrow
        }
    }
}

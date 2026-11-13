import CoreGraphics

// All rectangles here are in AppKit's global screen space: points, origin at
// the bottom-left of the primary display, y increasing upwards. "Above"
// therefore means a larger y.

/// The frame's dimensions, in points.
public struct FrameMetrics: Equatable {
    /// Thickness of the band around the region that belongs to the frame:
    /// everything in it can be grabbed to resize.
    public var border: CGFloat = 12
    /// Thickness of the solid line drawn at the inner edge of the band. The
    /// rest of the band is a faint halo, with solid grips at the corners and
    /// the middle of each side.
    public var line: CGFloat = 4
    /// Length of the grip drawn at the middle of each side.
    public var grip: CGFloat = 48
    /// Preferred width of the grab tab.
    public var tabWidth: CGFloat = 250
    public var tabHeight: CGFloat = 24
    /// Length along each edge, from a corner, that resizes diagonally.
    public var corner: CGFloat = 30
    /// Smallest region a drag can produce.
    public var minSize = CGSize(width: 160, height: 120)

    public init() {}
}

/// Where the grab tab is attached to the ring.
public enum TabSide: Equatable {
    /// Outside the ring, above its top-left corner.
    case above
    /// Outside the ring, below its bottom-left corner.
    case below
    /// Inside the region's top-left corner.
    case inside
}

/// The part of the frame under the pointer.
public enum Zone: Equatable {
    case none, move
    case left, right, top, bottom
    case topLeft, topRight, bottomLeft, bottomRight

    var movesLeftEdge: Bool { self == .left || self == .topLeft || self == .bottomLeft }
    var movesRightEdge: Bool { self == .right || self == .topRight || self == .bottomRight }
    var movesTopEdge: Bool { self == .top || self == .topLeft || self == .topRight }
    var movesBottomEdge: Bool { self == .bottom || self == .bottomLeft || self == .bottomRight }
}

/// The frame window's geometry for one region. The ring is `outer` minus
/// `region`; the tab is a separate block.
public struct FrameLayout: Equatable {
    /// The shared area. Nothing of the frame is drawn here unless `side` is `.inside`.
    public let region: CGRect
    /// `region` grown by the border.
    public let outer: CGRect
    public let tab: CGRect
    /// Bounding box of ring and tab: the frame window's rectangle.
    public let window: CGRect
    public let side: TabSide

    /// Lays the frame out around `region`. The tab goes above the ring when
    /// `usable` (the display area not taken by the menu bar or Dock) has room
    /// there, otherwise below, and only inside the region when neither fits.
    public init(region: CGRect, usable: CGRect, metrics m: FrameMetrics) {
        self.region = region
        outer = region.insetBy(dx: -m.border, dy: -m.border)
        let width = min(m.tabWidth, outer.width)
        let above = CGRect(x: outer.minX, y: outer.maxY, width: width, height: m.tabHeight)
        let below = CGRect(x: outer.minX, y: outer.minY - m.tabHeight, width: width, height: m.tabHeight)
        if above.maxY <= usable.maxY {
            tab = above
            side = .above
        } else if below.minY >= usable.minY {
            tab = below
            side = .below
        } else {
            let w = min(m.tabWidth, region.width), h = min(m.tabHeight, region.height)
            tab = CGRect(x: region.minX, y: region.maxY - h, width: w, height: h)
            side = .inside
        }
        window = outer.union(tab)
    }

    /// The zone at global point `p`: the tab moves the region, the ring
    /// resizes it, and the ends of each ring edge resize diagonally.
    public func zone(at p: CGPoint, metrics m: FrameMetrics) -> Zone {
        if tab.contains(p) { return .move }
        guard outer.contains(p), !region.contains(p) else { return .none }
        let cx = min(m.corner, outer.width / 3), cy = min(m.corner, outer.height / 3)
        let left = p.x < outer.minX + cx, right = p.x >= outer.maxX - cx
        let bottom = p.y < outer.minY + cy, top = p.y >= outer.maxY - cy
        switch (top, bottom, left, right) {
        case (true, _, true, _): return .topLeft
        case (true, _, _, true): return .topRight
        case (_, true, true, _): return .bottomLeft
        case (_, true, _, true): return .bottomRight
        default: break
        }
        if p.x < region.minX { return .left }
        if p.x >= region.maxX { return .right }
        return p.y >= region.maxY ? .top : .bottom
    }
}

public extension CGRect {
    /// This rectangle moved, and shrunk only if it has to be, so that it
    /// lies inside `bounds`. The origin is kept where possible.
    func fitted(into bounds: CGRect) -> CGRect {
        let w = min(width, bounds.width), h = min(height, bounds.height)
        let x = max(bounds.minX, min(minX, bounds.maxX - w))
        let y = max(bounds.minY, min(minY, bounds.maxY - h))
        return CGRect(x: x, y: y, width: w, height: h)
    }

    /// A rectangle of `size` centred in this one, shrunk to it if larger.
    func centered(_ size: CGSize) -> CGRect {
        let w = min(size.width, width), h = min(size.height, height)
        return CGRect(x: (minX + (width - w) / 2).rounded(), y: (minY + (height - h) / 2).rounded(), width: w, height: h)
    }

    /// The same rectangle with every edge on a whole point, so the copied
    /// picture is never resampled.
    var snapped: CGRect {
        CGRect(x: minX.rounded(), y: minY.rounded(), width: width.rounded(), height: height.rounded())
    }

    fileprivate var area: CGFloat { isNull || isEmpty ? 0 : width * height }
    fileprivate var center: CGPoint { CGPoint(x: midX, y: midY) }
}

/// The display that shows most of `rect`, or the nearest one when `rect` is
/// entirely off screen. Returns nil only when there are no displays.
public func bestScreen(for rect: CGRect, in screens: [CGRect]) -> CGRect? {
    func distance(_ s: CGRect) -> CGFloat {
        let dx = s.center.x - rect.center.x, dy = s.center.y - rect.center.y
        return dx * dx + dy * dy
    }
    return screens.max { a, b in
        let areaA = a.intersection(rect).area, areaB = b.intersection(rect).area
        return areaA != areaB ? areaA < areaB : distance(a) > distance(b)
    }
}

/// A move or resize in progress: the zone that was grabbed, the region as it
/// was at that moment, and where the pointer was.
public struct Drag: Equatable {
    public let zone: Zone
    public let start: CGRect
    public let anchor: CGPoint

    public init(zone: Zone, start: CGRect, anchor: CGPoint) {
        self.zone = zone
        self.start = start
        self.anchor = anchor
    }

    /// The region for the pointer's current position. A region is captured
    /// from one display, so a move lands wholly on the display that shows
    /// most of it and a resize stops at the edges of the display it started
    /// on. With `keepAspect` a resize keeps the starting width-to-height
    /// ratio.
    public func region(cursor: CGPoint, screens: [CGRect], metrics m: FrameMetrics, keepAspect: Bool = false) -> CGRect {
        let dx = (cursor.x - anchor.x).rounded(), dy = (cursor.y - anchor.y).rounded()
        if zone == .none { return start }
        if zone == .move {
            let moved = start.offsetBy(dx: dx, dy: dy)
            guard let screen = bestScreen(for: moved, in: screens) else { return moved }
            return moved.fitted(into: screen)
        }
        let bounds = bestScreen(for: start, in: screens) ?? start
        let minW = min(m.minSize.width, start.width), minH = min(m.minSize.height, start.height)
        var minX = start.minX, maxX = start.maxX, minY = start.minY, maxY = start.maxY
        if zone.movesLeftEdge { minX = max(bounds.minX, min(minX + dx, maxX - minW)) }
        if zone.movesRightEdge { maxX = min(bounds.maxX, max(maxX + dx, minX + minW)) }
        if zone.movesBottomEdge { minY = max(bounds.minY, min(minY + dy, maxY - minH)) }
        if zone.movesTopEdge { maxY = min(bounds.maxY, max(maxY + dy, minY + minH)) }
        let free = CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
        return keepAspect ? constrained(free, bounds: bounds, metrics: m) : free
    }

    /// `free` adjusted to the starting aspect ratio. The edges the drag does
    /// not move stay where they are; an edge drag grows the other dimension
    /// away from the region's top-left corner.
    private func constrained(_ free: CGRect, bounds: CGRect, metrics m: FrameMetrics) -> CGRect {
        guard start.width > 0, start.height > 0 else { return free }
        let ratio = start.width / start.height
        let fixedRight = zone.movesLeftEdge, fixedBottom = zone.movesTopEdge
        let roomW = fixedRight ? free.maxX - bounds.minX : bounds.maxX - free.minX
        let roomH = fixedBottom ? bounds.maxY - free.minY : free.maxY - bounds.minY
        var width = (zone == .top || zone == .bottom) ? free.height * ratio : free.width
        width = max(width, m.minSize.width, m.minSize.height * ratio)
        width = min(width, roomW, roomH * ratio).rounded(.down)
        let height = (width / ratio).rounded()
        return CGRect(
            x: fixedRight ? free.maxX - width : free.minX,
            y: fixedBottom ? free.minY : free.maxY - height,
            width: width, height: height)
    }
}

/// `region` changed to `size` about its centre, kept inside `bounds`.
public func resized(_ region: CGRect, to size: CGSize, within bounds: CGRect) -> CGRect {
    CGRect(x: (region.midX - size.width / 2).rounded(), y: (region.midY - size.height / 2).rounded(),
           width: size.width, height: size.height).fitted(into: bounds)
}

/// `region` expressed the way the screen recorder wants it: relative to the
/// top-left corner of its display, y increasing downwards.
public func captureRect(for region: CGRect, onScreen screen: CGRect) -> CGRect {
    CGRect(x: region.minX - screen.minX, y: screen.maxY - region.maxY, width: region.width, height: region.height)
}

/// Recognises a wiggle: the pointer going quickly left and right several
/// times. Feed it every pointer position during a drag.
public struct ShakeDetector {
    /// How far the pointer must travel back before it counts as a change of
    /// direction, in points. Small enough for a wrist flick, large enough
    /// that a shaky hand on a slow drag does not count.
    public var minimumTravel: CGFloat = 14
    /// Changes of direction that make a wiggle.
    public var reversalsNeeded = 4
    /// All of them must happen within this many seconds.
    public var duration: Double = 0.9

    private var extreme: CGFloat?
    private var direction: CGFloat = 0
    private var reversals: [Double] = []

    public init() {}

    /// Records the pointer's x position at `time` (seconds, any epoch) and
    /// returns true when that completes a wiggle. The detector then starts
    /// afresh.
    public mutating func add(x: CGFloat, at time: Double) -> Bool {
        guard let from = extreme else {
            extreme = x
            return false
        }
        let delta = x - from
        if direction == 0 {
            if abs(delta) >= minimumTravel {
                direction = delta > 0 ? 1 : -1
                extreme = x
            }
            return false
        }
        if delta * direction > 0 {
            extreme = x
        } else if abs(delta) >= minimumTravel {
            direction = -direction
            extreme = x
            reversals.append(time)
            reversals.removeAll { time - $0 > duration }
            if reversals.count >= reversalsNeeded {
                self = ShakeDetector(like: self)
                return true
            }
        }
        return false
    }

    private init(like other: ShakeDetector) {
        minimumTravel = other.minimumTravel
        reversalsNeeded = other.reversalsNeeded
        duration = other.duration
    }
}

/// The frontmost of `windows` (listed front to back, in global points) that
/// is under `point` and large enough to be a region.
public func windowToSnap(at point: CGPoint, among windows: [CGRect], metrics: FrameMetrics) -> CGRect? {
    windows.first { $0.contains(point) && $0.width >= metrics.minSize.width && $0.height >= metrics.minSize.height }
}

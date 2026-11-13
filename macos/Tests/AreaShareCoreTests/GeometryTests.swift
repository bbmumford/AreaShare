import XCTest
@testable import AreaShareCore

final class GeometryTests: XCTestCase {
    let metrics = FrameMetrics()
    // A 57-inch super-ultrawide with a laptop panel to its right. The usable
    // area leaves out a 25-point menu bar.
    let wide = CGRect(x: 0, y: 0, width: 7680, height: 2160)
    let laptop = CGRect(x: 7680, y: 0, width: 1728, height: 1117)
    var usable: CGRect { CGRect(x: 0, y: 0, width: 7680, height: 2135) }

    func testFittedInto() {
        let bounds = CGRect(x: 0, y: 0, width: 1000, height: 800)
        XCTAssertEqual(CGRect(x: 10, y: 20, width: 100, height: 100).fitted(into: bounds), CGRect(x: 10, y: 20, width: 100, height: 100))
        XCTAssertEqual(CGRect(x: -50, y: -70, width: 100, height: 100).fitted(into: bounds), CGRect(x: 0, y: 0, width: 100, height: 100))
        XCTAssertEqual(CGRect(x: 950, y: 790, width: 100, height: 100).fitted(into: bounds), CGRect(x: 900, y: 700, width: 100, height: 100))
        XCTAssertEqual(CGRect(x: -10, y: -10, width: 3000, height: 3000).fitted(into: bounds), bounds)
    }

    func testBestScreen() {
        let screens = [wide, laptop]
        XCTAssertEqual(bestScreen(for: CGRect(x: 7000, y: 100, width: 1000, height: 500), in: screens), wide)
        XCTAssertEqual(bestScreen(for: CGRect(x: 7500, y: 100, width: 1000, height: 500), in: screens), laptop)
        XCTAssertEqual(bestScreen(for: CGRect(x: 20000, y: 0, width: 100, height: 100), in: screens), laptop)
        XCTAssertNil(bestScreen(for: wide, in: []))
    }

    func testTabPlacement() {
        let cases: [(CGRect, TabSide)] = [
            (CGRect(x: 1000, y: 500, width: 1920, height: 1080), .above),
            (CGRect(x: 1000, y: 1080, width: 1920, height: 1080), .below), // touches the top of the display
            (CGRect(x: 1000, y: 0, width: 1920, height: 2160), .inside), // full height
        ]
        for (region, side) in cases {
            let layout = FrameLayout(region: region, usable: usable, metrics: metrics)
            XCTAssertEqual(layout.side, side, "\(region)")
            XCTAssertEqual(layout.outer, region.insetBy(dx: -metrics.border, dy: -metrics.border))
            XCTAssertTrue(layout.window.contains(layout.outer) && layout.window.contains(layout.tab))
            if side == .inside {
                XCTAssertTrue(region.contains(layout.tab))
                XCTAssertEqual(layout.tab.maxY, region.maxY, "the inside tab hangs from the top edge")
            } else {
                XCTAssertFalse(layout.tab.intersects(region), "the tab must stay out of the shared area")
            }
        }
    }

    func testTabNarrowsWithTheRegion() {
        let layout = FrameLayout(region: CGRect(x: 500, y: 500, width: 100, height: 400), usable: usable, metrics: metrics)
        XCTAssertEqual(layout.tab.width, layout.outer.width)
    }

    func testZones() {
        let region = CGRect(x: 1000, y: 500, width: 1920, height: 1080)
        let layout = FrameLayout(region: region, usable: usable, metrics: metrics)
        let cases: [(CGPoint, Zone)] = [
            (CGPoint(x: region.midX, y: region.midY), .none),
            (CGPoint(x: 10, y: 10), .none),
            (CGPoint(x: layout.tab.midX, y: layout.tab.midY), .move),
            (CGPoint(x: region.minX - 1, y: region.midY), .left),
            (CGPoint(x: region.maxX + 1, y: region.midY), .right),
            (CGPoint(x: region.midX, y: region.maxY + 1), .top),
            (CGPoint(x: region.midX, y: region.minY - 1), .bottom),
            (CGPoint(x: layout.outer.minX, y: layout.outer.minY), .bottomLeft),
            (CGPoint(x: region.maxX - 2, y: region.maxY + 1), .topRight),
            (CGPoint(x: region.minX - 1, y: region.minY + 2), .bottomLeft),
            (CGPoint(x: region.maxX + 1, y: region.minY - 1), .bottomRight),
            (CGPoint(x: region.minX - 1, y: region.maxY - 2), .topLeft),
        ]
        for (point, zone) in cases {
            XCTAssertEqual(layout.zone(at: point, metrics: metrics), zone, "\(point)")
        }
    }

    func testInsideTabStillMoves() {
        let layout = FrameLayout(region: CGRect(x: 1000, y: 0, width: 1920, height: 2160), usable: usable, metrics: metrics)
        XCTAssertEqual(layout.zone(at: CGPoint(x: layout.tab.midX, y: layout.tab.midY), metrics: metrics), .move)
    }

    func testMoveStaysOnOneDisplay() {
        let start = CGRect(x: 1000, y: 500, width: 1920, height: 1080)
        let drag = Drag(zone: .move, start: start, anchor: CGPoint(x: 1100, y: 1600))
        let screens = [wide, laptop]
        XCTAssertEqual(drag.region(cursor: CGPoint(x: 1150, y: 1620), screens: screens, metrics: metrics),
                       start.offsetBy(dx: 50, dy: 20))
        XCTAssertEqual(drag.region(cursor: CGPoint(x: -9000, y: -9000), screens: screens, metrics: metrics),
                       CGRect(x: 0, y: 0, width: 1920, height: 1080))
        // Dragged mostly onto the smaller display, it lands wholly on it,
        // shrunk to fit.
        let onLaptop = drag.region(cursor: CGPoint(x: 1100 + 7400, y: 1100), screens: screens, metrics: metrics)
        XCTAssertTrue(laptop.contains(onLaptop), "\(onLaptop)")
    }

    func testResize() {
        let start = CGRect(x: 1000, y: 500, width: 1920, height: 1080)
        let screens = [wide]
        // In this space the top-right corner is at (maxX, maxY).
        let corner = Drag(zone: .topRight, start: start, anchor: CGPoint(x: start.maxX, y: start.maxY))
        XCTAssertEqual(corner.region(cursor: CGPoint(x: start.maxX + 80, y: start.maxY + 40), screens: screens, metrics: metrics),
                       CGRect(x: 1000, y: 500, width: 2000, height: 1120))
        let tiny = corner.region(cursor: CGPoint(x: -5000, y: -5000), screens: screens, metrics: metrics)
        XCTAssertEqual(tiny.size, metrics.minSize)
        XCTAssertEqual(tiny.origin, start.origin)
        let huge = corner.region(cursor: CGPoint(x: 90000, y: 90000), screens: screens, metrics: metrics)
        XCTAssertEqual(huge.maxX, wide.maxX)
        XCTAssertEqual(huge.maxY, wide.maxY)

        let left = Drag(zone: .left, start: start, anchor: CGPoint(x: start.minX, y: 900))
        XCTAssertEqual(left.region(cursor: CGPoint(x: start.minX - 100, y: 1300), screens: screens, metrics: metrics),
                       CGRect(x: 900, y: 500, width: 2020, height: 1080))
        let pushed = left.region(cursor: CGPoint(x: 90000, y: 0), screens: screens, metrics: metrics)
        XCTAssertEqual(pushed.maxX, start.maxX)
        XCTAssertEqual(pushed.width, metrics.minSize.width)
    }

    func testResizeKeepingAspect() {
        let start = CGRect(x: 1000, y: 500, width: 1920, height: 1080)
        let screens = [wide]
        let corner = Drag(zone: .bottomRight, start: start, anchor: CGPoint(x: start.maxX, y: start.minY))
        let grown = corner.region(cursor: CGPoint(x: start.maxX + 320, y: start.minY - 5), screens: screens, metrics: metrics, keepAspect: true)
        XCTAssertEqual(grown.size, CGSize(width: 2240, height: 1260))
        XCTAssertEqual(grown.minX, start.minX)
        XCTAssertEqual(grown.maxY, start.maxY, "the top-left corner stays put")

        // Pushed past the display, it stops at the edge without changing shape.
        let limited = corner.region(cursor: CGPoint(x: 90000, y: -90000), screens: screens, metrics: metrics, keepAspect: true)
        XCTAssertTrue(wide.contains(limited), "\(limited)")
        XCTAssertEqual(limited.width / limited.height, 16.0 / 9.0, accuracy: 0.01)

        let top = Drag(zone: .top, start: start, anchor: CGPoint(x: 1500, y: start.maxY))
        let taller = top.region(cursor: CGPoint(x: 1500, y: start.maxY + 90), screens: screens, metrics: metrics, keepAspect: true)
        XCTAssertEqual(taller.size, CGSize(width: 2080, height: 1170))
        XCTAssertEqual(taller.origin, start.origin)

        let small = corner.region(cursor: CGPoint(x: -90000, y: 90000), screens: screens, metrics: metrics, keepAspect: true)
        XCTAssertGreaterThanOrEqual(small.width, metrics.minSize.width)
        XCTAssertGreaterThanOrEqual(small.height, metrics.minSize.height)
    }

    func testResizedKeepsCentre() {
        let region = CGRect(x: 1000, y: 500, width: 1920, height: 1080)
        let smaller = resized(region, to: CGSize(width: 1280, height: 720), within: wide)
        XCTAssertEqual(smaller.size, CGSize(width: 1280, height: 720))
        XCTAssertEqual(smaller.midX, region.midX)
        XCTAssertEqual(smaller.midY, region.midY)
        XCTAssertEqual(resized(CGRect(x: 0, y: 0, width: 200, height: 200), to: CGSize(width: 1280, height: 720), within: wide),
                       CGRect(x: 0, y: 0, width: 1280, height: 720))
    }

    func testCaptureRectFlipsToTopLeftOrigin() {
        // A display to the right of, and standing higher than, the primary.
        let screen = CGRect(x: 7680, y: 400, width: 1728, height: 1117)
        let region = CGRect(x: 7780, y: 1000, width: 800, height: 450)
        XCTAssertEqual(captureRect(for: region, onScreen: screen), CGRect(x: 100, y: 67, width: 800, height: 450))
    }
}

final class SettingsTests: XCTestCase {
    private func scratchDefaults() -> UserDefaults {
        let name = "areashare.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        addTeardownBlock { defaults.removePersistentDomain(forName: name) }
        return defaults
    }

    func testFirstRunDefaults() {
        let settings = Settings(defaults: scratchDefaults())
        XCTAssertNil(settings.region)
        XCTAssertEqual(settings.frameRate, Settings.defaultFrameRate)
        XCTAssertTrue(settings.showCursor)
    }

    func testRoundTrip() {
        let defaults = scratchDefaults()
        var settings = Settings()
        settings.region = CGRect(x: -1920, y: 40, width: 1600, height: 900)
        settings.frameRate = 60
        settings.showCursor = false
        settings.save(to: defaults)
        XCTAssertEqual(Settings(defaults: defaults), settings)
    }

    func testRepairsValuesTheMenusCannotProduce() {
        let defaults = scratchDefaults()
        defaults.set(1000, forKey: "frameRate")
        defaults.set([1.0, 2.0, -5.0, 10.0], forKey: "region")
        let settings = Settings(defaults: defaults)
        XCTAssertEqual(settings.frameRate, Settings.defaultFrameRate)
        XCTAssertNil(settings.region)
    }

    func testStartRegion() {
        let metrics = FrameMetrics()
        let wide = CGRect(x: 0, y: 0, width: 7680, height: 2160)
        var settings = Settings()
        XCTAssertEqual(settings.startRegion(screens: [wide], metrics: metrics), wide.centered(CGSize(width: 1920, height: 1080)))
        XCTAssertEqual(settings.startRegion(screens: [CGRect(x: 0, y: 0, width: 1728, height: 1117)], metrics: metrics)?.size,
                       CGSize(width: 1280, height: 720))
        XCTAssertNil(settings.startRegion(screens: [], metrics: metrics))

        // A region saved on a display that has since gone is not restored
        // somewhere arbitrary.
        settings.region = CGRect(x: 9000, y: 100, width: 800, height: 600)
        XCTAssertEqual(settings.startRegion(screens: [wide], metrics: metrics), wide.centered(CGSize(width: 1920, height: 1080)))

        settings.region = CGRect(x: 7000, y: 100, width: 800, height: 600)
        XCTAssertEqual(settings.startRegion(screens: [wide], metrics: metrics), CGRect(x: 6880, y: 100, width: 800, height: 600))
    }
}

final class ShakeTests: XCTestCase {
    /// Feeds a zig-zag of `swings` strokes, each `width` points and `stroke` seconds long, sampled every 4 points.
    private func wiggle(_ detector: inout ShakeDetector, swings: Int, width: CGFloat, stroke: Double) -> Bool {
        var x: CGFloat = 500, time = 0.0, fired = false
        for swing in 0..<swings {
            let direction: CGFloat = swing.isMultiple(of: 2) ? 1 : -1
            let steps = Int(width / 4)
            for _ in 0..<steps {
                x += 4 * direction
                time += stroke / Double(steps)
                if detector.add(CGPoint(x: x, y: 300), at: time) != nil { fired = true }
            }
        }
        return fired
    }

    func testQuickWiggleFires() {
        var detector = ShakeDetector()
        XCTAssertTrue(wiggle(&detector, swings: 6, width: 60, stroke: 0.1))
    }

    func testStraightDragDoesNotFire() {
        var detector = ShakeDetector()
        XCTAssertFalse(wiggle(&detector, swings: 1, width: 2000, stroke: 1.0))
    }

    func testSlowBackAndForthDoesNotFire() {
        var detector = ShakeDetector()
        XCTAssertFalse(wiggle(&detector, swings: 8, width: 200, stroke: 0.6))
    }

    func testTremorDoesNotFire() {
        var detector = ShakeDetector()
        XCTAssertFalse(wiggle(&detector, swings: 20, width: 8, stroke: 0.03))
    }

    func testFiresOncePerWiggle() {
        var detector = ShakeDetector()
        XCTAssertTrue(wiggle(&detector, swings: 6, width: 60, stroke: 0.1))
        XCTAssertFalse(wiggle(&detector, swings: 2, width: 60, stroke: 0.1), "two more strokes are not a new wiggle")
    }

    func testWindowToSnapTakesTheFrontmostUnderThePointer() {
        let metrics = FrameMetrics()
        let palette = CGRect(x: 900, y: 900, width: 80, height: 40) // too small to share
        let front = CGRect(x: 800, y: 600, width: 1200, height: 700)
        let back = CGRect(x: 0, y: 0, width: 3000, height: 2000)
        let point = CGPoint(x: 920, y: 910)
        XCTAssertEqual(windowToSnap(at: point, among: [palette, front, back], metrics: metrics), front)
        XCTAssertEqual(windowToSnap(at: CGPoint(x: 100, y: 100), among: [palette, front, back], metrics: metrics), back)
        XCTAssertNil(windowToSnap(at: CGPoint(x: 5000, y: 100), among: [palette, front, back], metrics: metrics))
    }
}

final class MultiWindowAndAlignmentTests: XCTestCase {
    let metrics = FrameMetrics()
    let screen = CGRect(x: 0, y: 0, width: 7680, height: 2160)

    func testWiggleReportsWhereThePointerWent() {
        var detector = ShakeDetector()
        var path: [CGPoint]?
        var x: CGFloat = 500, time = 0.0
        for swing in 0..<6 {
            for _ in 0..<15 {
                x += swing.isMultiple(of: 2) ? 4 : -4
                time += 0.006
                if let fired = detector.add(CGPoint(x: x, y: 300), at: time) { path = fired }
            }
        }
        let xs = (path ?? []).map(\.x)
        XCTAssertGreaterThanOrEqual((xs.max() ?? 0) - (xs.min() ?? 0), 50, "the path covers the width of the wiggle")
    }

    func testWiggleAcrossTwoWindowsTakesBoth() {
        let left = CGRect(x: 100, y: 200, width: 900, height: 700)
        let right = CGRect(x: 1010, y: 300, width: 800, height: 900)
        let behind = CGRect(x: 0, y: 0, width: 4000, height: 2000)
        let windows = [left, right, behind]
        let across = [CGPoint(x: 980, y: 600), CGPoint(x: 1004, y: 600), CGPoint(x: 1030, y: 600)]
        XCTAssertEqual(windowsToSnap(along: across, among: windows, metrics: metrics), left.union(right).union(behind),
                       "the gap between the two shows the window behind, which the pointer also crossed")
        let touching = [CGPoint(x: 980, y: 600), CGPoint(x: 1030, y: 600)]
        XCTAssertEqual(windowsToSnap(along: touching, among: windows, metrics: metrics), left.union(right))
        XCTAssertEqual(windowsToSnap(along: [CGPoint(x: 500, y: 600)], among: windows, metrics: metrics), left)
        XCTAssertNil(windowsToSnap(along: [CGPoint(x: 6000, y: 2100)], among: windows, metrics: metrics))
    }

    func testDraggedEdgeClicksOntoANearbyWindowEdge() {
        let window = CGRect(x: 2000, y: 400, width: 1200, height: 800)
        let region = CGRect(x: 1000, y: 500, width: 994, height: 600) // right edge 6 short of the window's left
        let snapped = aligned(region, zone: .right, toEdgesOf: [window], within: screen, metrics: metrics)
        XCTAssertEqual(snapped, CGRect(x: 1000, y: 500, width: 1000, height: 600))
        // Too far away: left alone.
        let far = CGRect(x: 1000, y: 500, width: 960, height: 600)
        XCTAssertEqual(aligned(far, zone: .right, toEdgesOf: [window], within: screen, metrics: metrics), far)
        // Only the edge being dragged moves.
        XCTAssertEqual(aligned(region, zone: .left, toEdgesOf: [window], within: screen, metrics: metrics), region)
    }

    func testCornerDragAlignsBothEdges() {
        let window = CGRect(x: 2000, y: 400, width: 1200, height: 800)
        let region = CGRect(x: 2004, y: 300, width: 1190, height: 893) // top-right corner near the window's
        XCTAssertEqual(aligned(region, zone: .topRight, toEdgesOf: [window], within: screen, metrics: metrics),
                       CGRect(x: 2004, y: 300, width: 1196, height: 900))
    }

    func testDoesNotAlignToAnEdgeThatIsFarAlongOrCovered() {
        let window = CGRect(x: 2000, y: 400, width: 1200, height: 800)
        // Same x, but the window is nowhere near the region vertically.
        let elsewhere = CGRect(x: 1000, y: 1500, width: 994, height: 300)
        XCTAssertEqual(aligned(elsewhere, zone: .right, toEdgesOf: [window], within: screen, metrics: metrics), elsewhere)
        // The window's left edge is hidden behind a window in front of it.
        let cover = CGRect(x: 1500, y: 0, width: 1000, height: 2000)
        let region = CGRect(x: 1000, y: 500, width: 994, height: 600)
        XCTAssertEqual(aligned(region, zone: .right, toEdgesOf: [cover, window], within: screen, metrics: metrics), region)
    }

    func testAlignmentNeverLeavesTheDisplayOrGoesBelowTheMinimum() {
        let offscreen = CGRect(x: 7000, y: 0, width: 686, height: 900) // right edge 6 past the display
        let region = CGRect(x: 6000, y: 100, width: 1680, height: 600)
        XCTAssertEqual(aligned(region, zone: .right, toEdgesOf: [offscreen], within: screen, metrics: metrics), region)
        let narrow = CGRect(x: 1000, y: 500, width: 165, height: 600)
        let close = CGRect(x: 400, y: 400, width: 758, height: 800) // right edge at 1158, 7 from the region's right
        XCTAssertEqual(aligned(narrow, zone: .right, toEdgesOf: [close], within: screen, metrics: metrics), narrow)
    }
}

final class VersionTests: XCTestCase {
    func testParsing() {
        XCTAssertEqual(Version("v1.4.2")?.parts, [1, 4, 2])
        XCTAssertEqual(Version("2.0")?.description, "2.0")
        for bad in ["", "v", "1..2", "1.2-beta", "1.2.3.4.5", "one.two", "1.2 ", "-1.0", "٣.١"] {
            XCTAssertNil(Version(bad), bad)
        }
    }

    func testOrdering() {
        XCTAssertLessThan(Version("1.9.9")!, Version("1.10.0")!, "numbers compare as numbers, not as text")
        XCTAssertLessThan(Version("1.2")!, Version("1.2.1")!)
        XCTAssertEqual(Version("1.2")!, Version("v1.2.0")!)
        XCTAssertFalse(Version("2.0.0")! < Version("1.99.99")!)
    }
}

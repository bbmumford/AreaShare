import CoreGraphics
import Foundation

/// What AreaShare carries between runs, kept in the user's defaults.
public struct Settings: Equatable {
    /// Refresh rates offered in the menu, in frames per second.
    public static let frameRates = [15, 30, 60]
    public static let defaultFrameRate = 30

    /// Region sizes offered in the menu, in points.
    public static let sizePresets = [
        CGSize(width: 1280, height: 720),
        CGSize(width: 1600, height: 900),
        CGSize(width: 1920, height: 1080),
        CGSize(width: 2560, height: 1440),
        CGSize(width: 3840, height: 2160),
    ]

    /// The saved region in global screen points, or nil on a first run.
    public var region: CGRect?
    public var frameRate = Settings.defaultFrameRate
    public var showCursor = true

    public init() {}

    private enum Key {
        static let region = "region"
        static let frameRate = "frameRate"
        static let showCursor = "showCursor"
    }

    /// Reads the settings, replacing anything the menus could not have
    /// produced with its default.
    public init(defaults: UserDefaults) {
        if let numbers = defaults.array(forKey: Key.region) as? [Double], numbers.count == 4,
           numbers.allSatisfy(\.isFinite), numbers[2] > 0, numbers[3] > 0 {
            region = CGRect(x: numbers[0], y: numbers[1], width: numbers[2], height: numbers[3])
        }
        let rate = defaults.integer(forKey: Key.frameRate)
        frameRate = Settings.frameRates.contains(rate) ? rate : Settings.defaultFrameRate
        showCursor = defaults.object(forKey: Key.showCursor) as? Bool ?? true
    }

    public func save(to defaults: UserDefaults) {
        if let region {
            defaults.set([region.minX, region.minY, region.width, region.height].map(Double.init), forKey: Key.region)
        } else {
            defaults.removeObject(forKey: Key.region)
        }
        defaults.set(frameRate, forKey: Key.frameRate)
        defaults.set(showCursor, forKey: Key.showCursor)
    }

    /// The region to open with: the saved one if it is still on a display,
    /// otherwise a 16:9 region centred on the primary display (`screens`
    /// lists it first).
    public func startRegion(screens: [CGRect], metrics: FrameMetrics) -> CGRect? {
        if let region, let screen = bestScreen(for: region, in: screens), screen.intersects(region) {
            let fitted = region.fitted(into: screen).snapped
            if fitted.width >= metrics.minSize.width, fitted.height >= metrics.minSize.height {
                return fitted
            }
        }
        guard let primary = screens.first else { return nil }
        for size in [Settings.sizePresets[2], Settings.sizePresets[0]]
        where primary.width >= size.width * 1.25 && primary.height >= size.height * 1.25 {
            return primary.centered(size)
        }
        return primary.centered(CGSize(width: (primary.width * 2 / 3).rounded(), height: (primary.height * 2 / 3).rounded()))
    }
}

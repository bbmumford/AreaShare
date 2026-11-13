import AppKit
import AreaShareCore
import ScreenCaptureKit

/// Owns the region and keeps the frame, the mirror, the recorder and the
/// menus in step with it.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate, FrameViewDelegate {
    private var settings = Settings(defaults: .standard)
    private var region = CGRect.zero
    private var state = ShareState.live
    /// Why recording stopped, when `state` is `.stopped`.
    private var stopReason: String?

    private let frameWindow = FrameWindow()
    private var mirror: MirrorWindow?
    private let capture = CaptureEngine()
    private let updater = Updater()
    private var statusItem: NSStatusItem?
    private var housekeeping: Timer?

    private var metrics: FrameMetrics { frameWindow.frameView.metrics }

    // MARK: Launch

    func applicationDidFinishLaunching(_ notification: Notification) {
        if let id = Bundle.main.bundleIdentifier,
           NSRunningApplication.runningApplications(withBundleIdentifier: id)
               .contains(where: { $0 != .current && !$0.isTerminated }) {
            // A second copy would put a second frame and a second window
            // named AreaShare on screen.
            NSApp.terminate(nil)
            return
        }
        guard let start = settings.startRegion(screens: screenFrames, metrics: metrics) else {
            fail("No display was found.")
            return
        }
        region = start

        buildMenus()
        BackgroundCursor.enable()
        frameWindow.frameView.delegate = self
        let mirror = MirrorWindow(region: region)
        self.mirror = mirror

        capture.onFrame = { [weak self] surface in
            guard let self, self.state == .live else { return }
            self.mirror?.show(surface)
        }
        capture.onStopped = { [weak self] error in self?.captureStopped(error) }

        applyRegion()
        mirror.orderBack(nil)
        frameWindow.orderFrontRegardless()

        NotificationCenter.default.addObserver(self, selector: #selector(screensChanged),
                                               name: NSApplication.didChangeScreenParametersNotification, object: nil)
        housekeeping = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.keepHouse() }
        }

        updater.relaunch = { [weak self] in self?.relaunch() }
        updater.onChange = { [weak self] in self?.updateStatusIcon() }
        updater.start()

        if CGPreflightScreenCaptureAccess() {
            updateCapture()
        } else {
            setState(.needsPermission)
            // Shows the system's own request the first time it is called.
            CGRequestScreenCaptureAccess()
            DispatchQueue.main.async { self.explainPermission() }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationDidBecomeActive(_ notification: Notification) {
        mirror?.sinkIfRaised()
    }

    func applicationWillTerminate(_ notification: Notification) {
        saveSettings()
    }

    private func fail(_ message: String) {
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = "AreaShare could not start"
        alert.informativeText = message
        alert.runModal()
        NSApp.terminate(nil)
    }

    // MARK: Region

    var screenFrames: [CGRect] { NSScreen.screens.map(\.frame) }

    /// The display the region is captured from.
    private var regionScreen: NSScreen? {
        guard let frame = bestScreen(for: region, in: screenFrames) else { return nil }
        return NSScreen.screens.first { $0.frame == frame }
    }

    /// Makes both windows and the recorder match `region`.
    private func applyRegion() {
        guard let screen = regionScreen else { return }
        let layout = FrameLayout(region: region, usable: screen.visibleFrame, metrics: metrics)
        frameWindow.show(layout, onScreen: screen.frame)
        mirror?.setFrame(region, display: false)
        updateLabel()
        updateCapture()
    }

    private func setRegion(_ new: CGRect, save: Bool = true) {
        let snapped = new.snapped
        guard snapped != region else { return }
        region = snapped
        applyRegion()
        if save { saveSettings() }
    }

    private func saveSettings() {
        settings.region = region
        settings.save(to: .standard)
    }

    @objc private func screensChanged() {
        guard let screen = bestScreen(for: region, in: screenFrames) else { return }
        let fitted = region.fitted(into: screen).snapped
        if fitted == region {
            applyRegion()
        } else {
            setRegion(fitted)
        }
    }

    func frameDragMoved(to region: CGRect) {
        setRegion(region, save: false)
    }

    func frameDragEnded() {
        saveSettings()
    }

    /// Every ordinary window of other apps that is on screen, front to back,
    /// in global points.
    private func otherWindows() -> [CGRect] {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
                as? [[CFString: Any]],
              let primary = NSScreen.screens.first?.frame
        else { return [] }
        let own = ProcessInfo.processInfo.processIdentifier
        // The list gives rectangles measured from the top-left of the
        // primary display.
        return list.compactMap { entry in
            guard (entry[kCGWindowLayer] as? Int) == 0, (entry[kCGWindowOwnerPID] as? pid_t) != own,
                  (entry[kCGWindowAlpha] as? Double ?? 1) > 0,
                  let bounds = entry[kCGWindowBounds] as? NSDictionary,
                  let rect = CGRect(dictionaryRepresentation: bounds)
            else { return nil }
            return CGRect(x: rect.minX, y: primary.maxY - rect.maxY, width: rect.width, height: rect.height)
        }
    }

    /// Fits the region around the windows under `path`, as far as they are
    /// on one display.
    func frameSnapToWindows(along path: [CGPoint]) -> Bool {
        guard let windows = windowsToSnap(along: path, among: otherWindows(), metrics: metrics),
              let screen = bestScreen(for: windows, in: screenFrames)
        else { return false }
        setRegion(windows.intersection(screen))
        return true
    }

    /// Other apps' windows, then each display's area clear of the menu bar
    /// and Dock, so an edge also clicks onto those.
    func frameAlignmentTargets() -> [CGRect] {
        otherWindows() + NSScreen.screens.map(\.visibleFrame)
    }

    // MARK: Recording

    /// Records only while live. Pausing ends the stream, so the mirror keeps
    /// its last picture, and resuming starts a new one, which always opens
    /// with a fresh picture even if nothing on screen is changing.
    private func updateCapture() {
        guard state == .live, let screen = regionScreen,
              let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
        else {
            capture.set(nil)
            return
        }
        let scale = screen.backingScaleFactor
        capture.set(CaptureTarget(
            displayID: number.uint32Value,
            sourceRect: captureRect(for: region, onScreen: screen.frame),
            pixelSize: CGSize(width: region.width * scale, height: region.height * scale),
            frameRate: settings.frameRate,
            showCursor: settings.showCursor))
    }

    private func setState(_ new: ShareState) {
        state = new
        frameWindow.frameView.state = new
        updateLabel()
        updateStatusIcon()
        updateCapture()
    }

    private func captureStopped(_ error: Error) {
        let nsError = error as NSError
        if nsError.domain == SCStreamErrorDomain, nsError.code == SCStreamError.Code.userDeclined.rawValue {
            setState(.needsPermission)
            explainPermission()
            return
        }
        stopReason = nsError.domain == SCStreamErrorDomain && nsError.code == SCStreamError.Code.userStopped.rawValue
            ? "Recording was stopped from the menu bar."
            : error.localizedDescription
        setState(.stopped)
    }

    /// Runs every two seconds: keeps the mirror at the back and notices when
    /// permission arrives.
    private func keepHouse() {
        mirror?.sinkIfRaised()
        if state == .needsPermission, CGPreflightScreenCaptureAccess() {
            setState(.live)
        }
    }

    private func updateLabel() {
        let size = "\(Int(region.width)) × \(Int(region.height))"
        let scale = regionScreen?.backingScaleFactor ?? 1
        let detail = scale == 1 ? size : "\(size) @\(Int(scale))x"
        switch state {
        case .live: frameWindow.frameView.label = "AreaShare   \(detail)"
        case .paused: frameWindow.frameView.label = "Paused   \(detail)"
        case .needsPermission: frameWindow.frameView.label = "Needs Screen Recording permission"
        case .stopped: frameWindow.frameView.label = "Stopped   right-click to resume"
        }
    }

    // MARK: Permission

    private func explainPermission() {
        let alert = NSAlert()
        alert.messageText = "AreaShare needs permission to record the screen"
        alert.informativeText = """
            AreaShare copies the area inside its frame into a window you can share. macOS only allows that \
            once you turn AreaShare on under System Settings › Privacy & Security › Screen & System Audio \
            Recording.

            After turning it on, choose Relaunch.

            If AreaShare is already turned on there and you still see this message, the saved permission \
            belongs to a differently signed copy of AreaShare. Choose Reset Permission, then turn it on again.
            """
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "Relaunch")
        alert.addButton(withTitle: "Reset Permission")
        alert.addButton(withTitle: "Later")
        NSApp.activate(ignoringOtherApps: true)
        switch alert.runModal() {
        case .alertFirstButtonReturn: openPermissionSettings()
        case .alertSecondButtonReturn: relaunch()
        case .alertThirdButtonReturn: resetPermission()
        default: break
        }
    }

    /// Forgets the Screen Recording decision saved for this app and asks
    /// again. macOS keeps the decision with the signature it was made for, so
    /// after the app's signature changes the old entry still shows as turned
    /// on in System Settings but no longer applies; only removing it helps.
    @objc private func resetPermission() {
        guard let id = Bundle.main.bundleIdentifier else { return }
        let reset = Process()
        reset.executableURL = URL(fileURLWithPath: "/usr/bin/tccutil")
        reset.arguments = ["reset", "ScreenCapture", id]
        try? reset.run()
        reset.waitUntilExit()
        CGRequestScreenCaptureAccess()
        openPermissionSettings()
    }

    @objc private func openPermissionSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }

    /// Starts a fresh copy once this one has gone: a new permission is only
    /// seen by a new process, and so is an installed update. The helper
    /// waits for this process to exit, because a copy started while this one
    /// is still closing would see it and quit as a duplicate.
    @objc private func relaunch() {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = ["-c", "while kill -0 \"$1\" 2>/dev/null; do sleep 0.2; done; /usr/bin/open \"$0\"",
                          Bundle.main.bundlePath, String(ProcessInfo.processInfo.processIdentifier)]
        try? task.run()
        NSApp.terminate(nil)
    }

    // MARK: Menus

    private func buildMenus() {
        let main = NSMenu()

        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "About AreaShare", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide AreaShare", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit AreaShare", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        main.addItem(appItem)

        let regionItem = NSMenuItem()
        let regionMenu = NSMenu(title: "Region")
        regionMenu.delegate = self
        regionItem.submenu = regionMenu
        main.addItem(regionItem)
        NSApp.mainMenu = main

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
        statusItem = item
        updateStatusIcon()
    }

    private func updateStatusIcon() {
        // A badge on the icon is the only sign of a waiting update.
        let name = updater.available != nil ? "rectangle.badge.plus"
            : state == .live ? "rectangle.inset.filled" : "rectangle.dashed"
        let image = NSImage(systemSymbolName: name, accessibilityDescription: "AreaShare")
        image?.isTemplate = true
        statusItem?.button?.image = image
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        populate(menu)
    }

    func frameContextMenu() -> NSMenu {
        let menu = NSMenu()
        populate(menu)
        return menu
    }

    private func populate(_ menu: NSMenu) {
        func add(_ title: String, _ action: Selector, to target: NSMenu = menu, checked: Bool = false,
                 enabled: Bool = true, tag: Int = 0) {
            let item = NSMenuItem(title: title, action: enabled ? action : nil, keyEquivalent: "")
            item.target = self
            item.state = checked ? .on : .off
            item.tag = tag
            target.addItem(item)
        }
        menu.autoenablesItems = false

        if let update = updater.available {
            add("Install AreaShare \(update.version)…", #selector(installUpdate))
            menu.addItem(.separator())
        }

        switch state {
        case .live:
            add("Pause (Freeze the Shared Picture)", #selector(togglePause))
        case .paused:
            add("Resume", #selector(togglePause))
        case .stopped:
            if let stopReason {
                add(stopReason, #selector(togglePause), enabled: false)
            }
            add("Resume", #selector(resumeAfterStop))
        case .needsPermission:
            add("Allow Screen Recording…", #selector(openPermissionSettings))
            add("Reset the Screen Recording Permission", #selector(resetPermission))
            add("Relaunch AreaShare", #selector(relaunch))
        }
        menu.addItem(.separator())

        let screen = bestScreen(for: region, in: screenFrames) ?? .zero
        let sizes = NSMenu()
        sizes.autoenablesItems = false
        for (index, size) in Settings.sizePresets.enumerated() {
            add("\(Int(size.width)) × \(Int(size.height))", #selector(chooseSize(_:)), to: sizes,
                checked: region.size == size, enabled: size.width <= screen.width && size.height <= screen.height,
                tag: index)
        }
        let sizeItem = NSMenuItem(title: "Size", action: nil, keyEquivalent: "")
        sizeItem.submenu = sizes
        menu.addItem(sizeItem)

        let rates = NSMenu()
        for rate in Settings.frameRates {
            add("\(rate) Frames per Second", #selector(chooseFrameRate(_:)), to: rates,
                checked: settings.frameRate == rate, tag: rate)
        }
        let rateItem = NSMenuItem(title: "Refresh Rate", action: nil, keyEquivalent: "")
        rateItem.submenu = rates
        menu.addItem(rateItem)

        add("Show the Mouse Pointer", #selector(toggleCursor), checked: settings.showCursor)
        add("Centre on This Display", #selector(centre))

        if NSScreen.screens.count > 1 {
            let displays = NSMenu()
            for (index, candidate) in NSScreen.screens.enumerated() {
                add(candidate.localizedName, #selector(moveToDisplay(_:)), to: displays,
                    checked: candidate.frame == screen, tag: index)
            }
            let displayItem = NSMenuItem(title: "Move to Display", action: nil, keyEquivalent: "")
            displayItem.submenu = displays
            menu.addItem(displayItem)
        }

        menu.addItem(.separator())
        add("How to Share…", #selector(showHelp))
        add("Check for Updates…", #selector(checkForUpdates))
        add("Check for Updates Automatically", #selector(toggleAutomaticUpdates), checked: updater.checksAutomatically)
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit AreaShare", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "")
        menu.addItem(quit)
    }

    // MARK: Commands

    @objc private func togglePause() {
        setState(state == .paused ? .live : .paused)
    }

    @objc private func resumeAfterStop() {
        stopReason = nil
        setState(.live)
    }

    @objc private func chooseSize(_ sender: NSMenuItem) {
        guard Settings.sizePresets.indices.contains(sender.tag),
              let screen = bestScreen(for: region, in: screenFrames) else { return }
        setRegion(resized(region, to: Settings.sizePresets[sender.tag], within: screen))
    }

    @objc private func chooseFrameRate(_ sender: NSMenuItem) {
        guard Settings.frameRates.contains(sender.tag) else { return }
        settings.frameRate = sender.tag
        saveSettings()
        updateCapture()
    }

    @objc private func toggleCursor() {
        settings.showCursor.toggle()
        saveSettings()
        updateCapture()
    }

    @objc private func centre() {
        guard let screen = bestScreen(for: region, in: screenFrames) else { return }
        setRegion(screen.centered(region.size))
    }

    @objc private func moveToDisplay(_ sender: NSMenuItem) {
        guard NSScreen.screens.indices.contains(sender.tag) else { return }
        setRegion(NSScreen.screens[sender.tag].frame.centered(region.size))
    }

    @objc private func installUpdate() {
        if let update = updater.available { updater.offer(update) }
    }

    @objc private func checkForUpdates() {
        updater.checkNow()
    }

    @objc private func toggleAutomaticUpdates() {
        updater.checksAutomatically.toggle()
    }

    @objc private func showHelp() {
        let alert = NSAlert()
        alert.messageText = "Sharing an area of your screen"
        alert.informativeText = """
            1. Drag the tab on the red frame to move it. Drag the red outline to resize it; hold Shift to keep \
            its shape. An edge clicks onto a window edge it comes close to; hold Command to stop that. To fit the \
            frame to a window, drag the tab over it and wiggle; wiggle across several windows to take them all.

            2. In Teams, Zoom or Meet choose to share a window, and pick the one named AreaShare.

            People in the meeting see what is inside the frame, and nothing outside it. The frame itself is \
            never shown to them.

            Pause freezes what they see until you resume. The menu is also on the AreaShare icon in the menu bar.
            """
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }
}

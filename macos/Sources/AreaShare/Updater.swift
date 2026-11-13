import AppKit
import AreaShareCore
import Security

/// A published version newer than the one running.
struct AvailableUpdate: Equatable {
    let version: Version
    let notes: String
    /// The zipped app to download.
    let archive: URL
    /// The release's web page, for when the update cannot be installed here.
    let page: URL
}

enum UpdateError: LocalizedError {
    case server(Int)
    case unreadable
    case noArchive
    case unpack
    case wrongApp
    case notSignedByRelease
    case signature(OSStatus)

    var errorDescription: String? {
        switch self {
        case .server(let status): return "The update server answered with an error (\(status))."
        case .unreadable: return "The update information could not be read."
        case .noArchive: return "The latest release has no macOS download."
        case .unpack: return "The downloaded update could not be unpacked."
        case .wrongApp: return "The download is not the expected version of AreaShare."
        case .notSignedByRelease:
            return "This copy of AreaShare was built locally, so an update cannot be checked against it. "
                + "Download the new version from the release page instead."
        case .signature(let status):
            let reason = SecCopyErrorMessageString(status, nil) as String? ?? "error \(status)"
            return "The download is not signed with the same key as this copy of AreaShare (\(reason)), so it was "
                + "not installed. That is expected if this copy was built from source; download the release instead."
        }
    }
}

/// Finds new versions on the project's GitHub releases and installs them.
///
/// Trust comes from the code signature: an update is installed only if it
/// satisfies the designated requirement of the copy that is running, which
/// for a release build means "AreaShare, signed with the release key".
@MainActor
final class Updater {
    static let repository = "bbmumford/AreaShare"
    static let archiveName = "AreaShare-macos.zip"

    /// Called when `available` changes, so menus can offer the update.
    var onChange: (() -> Void)?
    /// Starts a fresh copy of the app once this one has quit.
    var relaunch: (() -> Void)?

    private(set) var available: AvailableUpdate? { didSet { if available != oldValue { onChange?() } } }
    private var working = false
    private var timer: Timer?
    private let defaults = UserDefaults.standard

    private enum Key {
        static let automatic = "checkForUpdates"
        static let lastCheck = "lastUpdateCheck"
        static let skipped = "skippedVersion"
    }

    var currentVersion: Version {
        Version(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "") ?? Version("0")!
    }

    var checksAutomatically: Bool {
        get { defaults.object(forKey: Key.automatic) as? Bool ?? true }
        set {
            defaults.set(newValue, forKey: Key.automatic)
            if newValue { checkQuietlyIfDue() }
        }
    }

    // MARK: Checking

    /// Looks for an update at start-up and then once a day. A quiet check
    /// never opens a window: it only makes the menus offer the update, so
    /// nothing appears on screen in the middle of a meeting.
    func start() {
        timer = Timer.scheduledTimer(withTimeInterval: 3600, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkQuietlyIfDue() }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in self?.checkQuietlyIfDue() }
    }

    private func checkQuietlyIfDue() {
        guard checksAutomatically, !working else { return }
        let last = defaults.object(forKey: Key.lastCheck) as? Date ?? .distantPast
        guard Date().timeIntervalSince(last) > 24 * 3600 else { return }
        Task {
            // A failed quiet check is simply tried again in an hour.
            guard let result = try? await self.latest() as AvailableUpdate?? else { return }
            self.defaults.set(Date(), forKey: Key.lastCheck)
            if let found = result, found.version.description != self.defaults.string(forKey: Key.skipped) {
                self.available = found
            }
        }
    }

    /// The menu command: checks now and says what it found.
    func checkNow() {
        guard !working else { return }
        Task {
            do {
                let found = try await self.latest()
                self.defaults.set(Date(), forKey: Key.lastCheck)
                if let found {
                    self.available = found
                    self.offer(found)
                } else {
                    self.inform("AreaShare is up to date", "Version \(self.currentVersion) is the newest version.")
                }
            } catch {
                self.inform("Could not check for updates", error.localizedDescription, style: .warning)
            }
        }
    }

    /// The newest published version, if it is newer than this one.
    func latest() async throws -> AvailableUpdate? {
        struct Release: Decodable {
            struct Asset: Decodable {
                let name: String
                let browser_download_url: URL
            }
            let tag_name: String
            let body: String?
            let html_url: URL
            let assets: [Asset]
        }
        var request = URLRequest(url: URL(string: "https://api.github.com/repos/\(Self.repository)/releases/latest")!)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 20
        request.cachePolicy = .reloadIgnoringLocalCacheData
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status == 404 { return nil } // nothing has been released yet
        guard status == 200 else { throw UpdateError.server(status) }
        guard let release = try? JSONDecoder().decode(Release.self, from: data),
              let version = Version(release.tag_name)
        else { throw UpdateError.unreadable }
        guard version > currentVersion else { return nil }
        guard let asset = release.assets.first(where: { $0.name == Self.archiveName }) else { throw UpdateError.noArchive }
        return AvailableUpdate(version: version, notes: release.body ?? "", archive: asset.browser_download_url,
                               page: release.html_url)
    }

    // MARK: Installing

    /// Asks whether to install `update`, and does.
    func offer(_ update: AvailableUpdate) {
        let alert = NSAlert()
        alert.messageText = "AreaShare \(update.version) is available"
        let notes = update.notes.trimmingCharacters(in: .whitespacesAndNewlines)
        alert.informativeText = "You have version \(currentVersion). Installing restarts AreaShare; a share in progress "
            + "stops until you pick the AreaShare window again."
            + (notes.isEmpty ? "" : "\n\n" + String(notes.prefix(900)))
        alert.addButton(withTitle: "Install and Relaunch")
        alert.addButton(withTitle: "Later")
        alert.addButton(withTitle: "Skip This Version")
        NSApp.activate(ignoringOtherApps: true)
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            install(update)
        case .alertThirdButtonReturn:
            defaults.set(update.version.description, forKey: Key.skipped)
            available = nil
        default:
            break
        }
    }

    private func install(_ update: AvailableUpdate) {
        guard !working else { return }
        working = true
        Task {
            do {
                try await self.downloadAndReplace(update)
                self.relaunch?()
            } catch {
                self.working = false
                let alert = NSAlert()
                alert.alertStyle = .warning
                alert.messageText = "The update was not installed"
                alert.informativeText = error.localizedDescription
                alert.addButton(withTitle: "Open the Release Page")
                alert.addButton(withTitle: "OK")
                NSApp.activate(ignoringOtherApps: true)
                if alert.runModal() == .alertFirstButtonReturn {
                    NSWorkspace.shared.open(update.page)
                }
            }
        }
    }

    private func downloadAndReplace(_ update: AvailableUpdate) async throws {
        let installed = Bundle.main.bundleURL
        // A folder on the same volume as the app, so the swap is a rename.
        let work = try FileManager.default.url(for: .itemReplacementDirectory, in: .userDomainMask,
                                               appropriateFor: installed, create: true)
        defer { try? FileManager.default.removeItem(at: work) }
        let fresh = try await Self.fetch(update, into: work)
        _ = try FileManager.default.replaceItemAt(installed, withItemAt: fresh)
    }

    /// Downloads and unpacks `update` into `folder` and returns the app
    /// inside, having checked that it is the promised version of this app
    /// and signed by the same publisher as the copy that is running.
    static func fetch(_ update: AvailableUpdate, into folder: URL) async throws -> URL {
        let (downloaded, response) = try await URLSession.shared.download(from: update.archive)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else { throw UpdateError.server(status) }
        let archive = folder.appendingPathComponent(archiveName)
        try FileManager.default.moveItem(at: downloaded, to: archive)

        let unzip = Process()
        unzip.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        unzip.arguments = ["-x", "-k", archive.path, folder.path]
        let unpacked: Bool = try await withCheckedThrowingContinuation { continuation in
            unzip.terminationHandler = { continuation.resume(returning: $0.terminationStatus == 0) }
            do { try unzip.run() } catch { continuation.resume(throwing: error) }
        }
        let app = folder.appendingPathComponent("AreaShare.app")
        guard unpacked, let bundle = Bundle(url: app) else { throw UpdateError.unpack }
        guard bundle.bundleIdentifier == Bundle.main.bundleIdentifier,
              let version = Version(bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""),
              version == update.version
        else { throw UpdateError.wrongApp }
        try verifySignature(of: app)
        return app
    }

    /// Throws unless the app at `url` is intact and satisfies the designated
    /// requirement of the running copy.
    static func verifySignature(of url: URL) throws {
        var running: SecCode?
        var runningStatic: SecStaticCode?
        var requirement: SecRequirement?
        guard SecCodeCopySelf([], &running) == errSecSuccess, let running,
              SecCodeCopyStaticCode(running, [], &runningStatic) == errSecSuccess, let runningStatic,
              SecCodeCopyDesignatedRequirement(runningStatic, [], &requirement) == errSecSuccess, let requirement
        else { throw UpdateError.notSignedByRelease }

        // An ad-hoc or unsigned copy has no publisher: its requirement names
        // one exact build, which no other build can satisfy.
        var text: CFString?
        SecRequirementCopyString(requirement, [], &text)
        guard let text = text as String?, text.contains("certificate") else { throw UpdateError.notSignedByRelease }

        var candidate: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &candidate) == errSecSuccess, let candidate else {
            throw UpdateError.unpack
        }
        let flags = SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSStrictValidate | kSecCSCheckNestedCode)
        let status = SecStaticCodeCheckValidity(candidate, flags, requirement)
        guard status == errSecSuccess else { throw UpdateError.signature(status) }
    }

    private func inform(_ title: String, _ text: String, style: NSAlert.Style = .informational) {
        let alert = NSAlert()
        alert.alertStyle = style
        alert.messageText = title
        alert.informativeText = text
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    // MARK: Diagnostics

    /// The command-line forms of the updater. `AreaShare --check-update`
    /// prints what a check finds and, if there is an update, downloads and
    /// verifies it without installing. `AreaShare --install-update` goes on
    /// to replace the app the command was run from; it does not start it.
    func runFromCommandLine(install: Bool) async -> Int32 {
        print("running version: \(currentVersion)")
        do {
            guard let update = try await latest() else {
                print("no newer release")
                return 0
            }
            print("newer release: \(update.version)  \(update.archive.absoluteString)")
            if install {
                try await downloadAndReplace(update)
                print("installed \(update.version) at \(Bundle.main.bundlePath)")
                return 0
            }
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent("areashare-update-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: folder) }
            _ = try await Self.fetch(update, into: folder)
            print("downloaded and verified: it would be installed")
            return 0
        } catch {
            print("failed: \(error.localizedDescription)")
            return 1
        }
    }
}

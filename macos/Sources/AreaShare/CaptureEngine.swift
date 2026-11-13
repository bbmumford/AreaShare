import CoreMedia
import IOSurface
import ScreenCaptureKit

/// What the recorder should be producing: one rectangle of one display.
struct CaptureTarget: Equatable {
    var displayID: CGDirectDisplayID
    /// The region relative to the display's top-left corner, in points.
    var sourceRect: CGRect
    /// The size of each delivered picture, in pixels.
    var pixelSize: CGSize
    var frameRate: Int
    var showCursor: Bool
}

enum CaptureError: LocalizedError {
    case displayNotFound

    var errorDescription: String? {
        "The display the region is on is not available for recording."
    }
}

/// Runs a ScreenCaptureKit stream of the region with every window of this app
/// left out of the picture, so neither the frame nor the mirror can appear in
/// the copy. Callers state the target they want with `set`; the engine brings
/// the stream to it, one change at a time, always heading for the latest.
@MainActor
final class CaptureEngine {
    /// Called on the main thread with each new picture.
    var onFrame: ((IOSurface) -> Void)?
    /// Called on the main thread when recording ends without being asked to,
    /// or cannot start. The engine is idle afterwards until `set` is called
    /// with a target again.
    var onStopped: ((Error) -> Void)?

    private var stream: SCStream?
    private var receiver: StreamReceiver?
    private var desired: CaptureTarget?
    private var applied: CaptureTarget?
    private var busy = false

    func set(_ target: CaptureTarget?) {
        desired = target
        pump()
    }

    private func pump() {
        guard !busy, desired != applied else { return }
        busy = true
        let target = desired
        Task { @MainActor in
            do {
                try await self.apply(target)
                self.applied = target
            } catch {
                await self.teardown()
                // Settle on idle so a failure is reported once, not once
                // per pointer movement while the region is being dragged.
                self.desired = nil
                self.applied = nil
                self.onStopped?(error)
            }
            self.busy = false
            self.pump()
        }
    }

    private func apply(_ target: CaptureTarget?) async throws {
        guard let target else {
            await teardown()
            return
        }
        let configuration = Self.configuration(for: target)
        if let stream, applied?.displayID == target.displayID {
            try await stream.updateConfiguration(configuration)
            return
        }
        await teardown()

        let filter = try await Self.filter(for: target.displayID)
        let receiver = StreamReceiver()
        let stream = SCStream(filter: filter, configuration: configuration, delegate: receiver)
        receiver.onFrame = { [weak self, weak stream] surface in
            guard let self, let stream, self.stream === stream else { return }
            self.onFrame?(surface)
        }
        receiver.onStop = { [weak self, weak stream] error in
            guard let self, let stream, self.stream === stream else { return }
            self.stream = nil
            self.receiver = nil
            self.desired = nil
            self.applied = nil
            self.onStopped?(error)
        }
        try stream.addStreamOutput(receiver, type: .screen, sampleHandlerQueue: receiver.queue)
        try await stream.startCapture()
        self.stream = stream
        self.receiver = receiver
    }

    private func teardown() async {
        guard let stream else { return }
        self.stream = nil
        receiver = nil
        try? await stream.stopCapture()
    }

    /// A filter for the whole display minus this app. The app only shows up
    /// in the shareable content once its windows are on screen, so a short
    /// wait covers a stream started in the same moment the windows open;
    /// without the exclusion the mirror would record itself.
    private static func filter(for displayID: CGDirectDisplayID) async throws -> SCContentFilter {
        let pid = ProcessInfo.processInfo.processIdentifier
        for attempt in 0..<6 {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
            guard let display = content.displays.first(where: { $0.displayID == displayID }) else {
                throw CaptureError.displayNotFound
            }
            let own = content.applications.filter { $0.processID == pid }
            if !own.isEmpty || attempt == 5 {
                return SCContentFilter(display: display, excludingApplications: own, exceptingWindows: [])
            }
            try await Task.sleep(nanoseconds: 300_000_000)
        }
        throw CaptureError.displayNotFound
    }

    private static func configuration(for target: CaptureTarget) -> SCStreamConfiguration {
        let configuration = SCStreamConfiguration()
        configuration.sourceRect = target.sourceRect
        configuration.width = max(1, Int(target.pixelSize.width))
        configuration.height = max(1, Int(target.pixelSize.height))
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(target.frameRate))
        configuration.showsCursor = target.showCursor
        configuration.pixelFormat = kCVPixelFormatType_32BGRA
        configuration.queueDepth = 4
        return configuration
    }
}

/// Receives the stream's callbacks on ScreenCaptureKit's queue and forwards
/// what matters to the main thread.
private final class StreamReceiver: NSObject, SCStreamOutput, SCStreamDelegate {
    let queue = DispatchQueue(label: "app.areashare.capture", qos: .userInteractive)
    var onFrame: ((IOSurface) -> Void)?
    var onStop: ((Error) -> Void)?

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        // The stream also delivers buffers that carry no new picture (the
        // screen did not change); only complete frames have pixels.
        guard type == .screen, sampleBuffer.isValid,
              let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false)
                as? [[SCStreamFrameInfo: Any]],
              let rawStatus = attachments.first?[.status] as? Int,
              SCFrameStatus(rawValue: rawStatus) == .complete,
              let pixels = sampleBuffer.imageBuffer,
              let surfaceRef = CVPixelBufferGetIOSurface(pixels)?.takeUnretainedValue()
        else { return }
        let surface = unsafeBitCast(surfaceRef, to: IOSurface.self)
        DispatchQueue.main.async { [weak self] in self?.onFrame?(surface) }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        DispatchQueue.main.async { [weak self] in self?.onStop?(error) }
    }
}

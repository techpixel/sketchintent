import CoreGraphics
import CoreMedia
import CoreVideo
import Foundation
import ScreenCaptureKit
import StreamProtocol

enum CaptureError: Error, CustomStringConvertible {
    case permissionDenied
    case noDisplay
    case stream(String)

    var description: String {
        switch self {
        case .permissionDenied:
            return """
            Screen Recording permission is off.
            Approve the system prompt, or enable this app in System Settings → Privacy & Security → Screen Recording.
            If you launched the server from a terminal or Cursor, enable that host app as well. Then run the server again.
            """
        case .noDisplay:
            return "No display is available to capture."
        case .stream(let message):
            return message
        }
    }
}

/// Captures the main display and encodes changed frames with VideoToolbox.
final class ScreenCapturer: NSObject, SCStreamDelegate, SCStreamOutput {
    var onVideo: ((VideoConfig?, VideoFrame) -> Void)?
    var onSize: ((Int, Int) -> Void)?

    private let captureQueue = DispatchQueue(label: "sketchintent.capture")
    private var stream: SCStream?
    private var encoder: H264Encoder?
    private let fps: Int

    init(fps: Int) {
        self.fps = fps
        super.init()
    }

    static func ensureAccess() throws {
        guard CGPreflightScreenCaptureAccess() || CGRequestScreenCaptureAccess() else {
            throw CaptureError.permissionDenied
        }
    }

    func requestKeyframe() {
        encoder?.requestKeyframe()
    }

    func start(bitrate: Int, maxWidth: Int, displayIndex: Int?) async throws -> (width: Int, height: Int) {
        try Self.ensureAccess()

        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        let display: SCDisplay?
        if let displayIndex {
            display = content.displays.indices.contains(displayIndex) ? content.displays[displayIndex] : nil
        } else {
            display = content.displays.first { $0.displayID == CGMainDisplayID() } ?? content.displays.first
        }
        guard let display else { throw CaptureError.noDisplay }

        let pixelWidth: Int
        let pixelHeight: Int
        if let mode = CGDisplayCopyDisplayMode(display.displayID) {
            pixelWidth = max(2, mode.pixelWidth)
            pixelHeight = max(2, mode.pixelHeight)
        } else {
            pixelWidth = max(2, Int(display.frame.width.rounded()))
            pixelHeight = max(2, Int(display.frame.height.rounded()))
        }
        let scale = min(1, Double(maxWidth) / Double(pixelWidth))
        let width = even(Int((Double(pixelWidth) * scale).rounded()))
        let height = even(Int((Double(pixelHeight) * scale).rounded()))

        let encoder = H264Encoder(fps: fps)
        encoder.onEncoded = { [weak self] config, frame in
            self?.onVideo?(config, frame)
        }
        try encoder.start(width: width, height: height, fps: fps, bitrate: bitrate)
        self.encoder = encoder

        let filter = SCContentFilter(display: display, excludingWindows: [])
        let configuration = SCStreamConfiguration()
        configuration.width = width
        configuration.height = height
        configuration.scalesToFit = true
        configuration.showsCursor = true
        configuration.pixelFormat = kCVPixelFormatType_32BGRA
        configuration.colorSpaceName = CGColorSpace.sRGB
        configuration.queueDepth = 2
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(max(1, fps)))

        let stream = SCStream(filter: filter, configuration: configuration, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: captureQueue)
        try await stream.startCapture()
        self.stream = stream
        onSize?(width, height)
        return (width, height)
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        fputs("[sketchintent] Capture stopped: \(error.localizedDescription)\n", stderr)
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, let pixelBuffer = sampleBuffer.imageBuffer else { return }
        if let status = frameStatus(sampleBuffer), status != .complete && status != .started {
            return
        }
        let time = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        let presentation = time.isValid ? time : CMClockGetTime(CMClockGetHostTimeClock())
        encoder?.encode(pixelBuffer, presentationTime: presentation)
    }

    private func frameStatus(_ sampleBuffer: CMSampleBuffer) -> SCFrameStatus? {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let raw = attachments.first?[.status] as? Int else {
            return nil
        }
        return SCFrameStatus(rawValue: raw)
    }

    private func even(_ value: Int) -> Int {
        max(2, value - (value % 2))
    }
}

import AVFoundation
import CoreImage
import CoreMedia
import SwiftUI
import UIKit
import VideoToolbox

/// Presents H.264 as soon as each access unit arrives. No jitter buffer.
final class SampleDisplayView: UIView {
    override class var layerClass: AnyClass { AVSampleBufferDisplayLayer.self }

    var videoLayer: AVSampleBufferDisplayLayer {
        layer as! AVSampleBufferDisplayLayer
    }

    /// After a flush the decoder has lost its references, so the next sample must be a keyframe.
    private var needsKeyframe = true
    /// readyForMoreMediaData can be false before the first enqueue. Only then does false mean a backlog.
    private var didEnqueue = false
    /// Display timestamps stay a millisecond apart so a burst cannot sit on a long PTS timeline.
    private var nextPresentation = CMTime.zero
    /// Compressed frames since the last keyframe, so a sketch can keep the picture it started on.
    private var groupOfPictures: [CMSampleBuffer] = []

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .black
        videoLayer.videoGravity = .resizeAspect
        videoLayer.backgroundColor = UIColor.black.cgColor
        isAccessibilityElement = true
        accessibilityLabel = "Mac screen"
        // A control timebase schedules frames by PTS and defeats DisplayImmediately.
        videoLayer.controlTimebase = nil
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func flush() {
        videoLayer.flushAndRemoveImage()
        needsKeyframe = true
        groupOfPictures = []
    }

    /// Keeps the decoder attached while the picture is covered. Blank canvas hides the
    /// layer; it does not tear down the stream, so a later unhide still has frames.
    func setPictureHidden(_ hidden: Bool) {
        isHidden = hidden
        alpha = hidden ? 0 : 1
        videoLayer.isHidden = hidden
        videoLayer.opacity = hidden ? 0 : 1
        isAccessibilityElement = !hidden
        accessibilityElementsHidden = hidden
    }

    /// Shows frames in decode order. A backlog is flushed back to the newest keyframe.
    @discardableResult
    func present(_ samples: [CMSampleBuffer], parameterSetsChanged: Bool) -> Bool {
        if parameterSetsChanged {
            flush()
        }
        var frames = samples
        if let keyIndex = frames.lastIndex(where: Self.isSync) {
            let holdingBacklog = didEnqueue && !videoLayer.isReadyForMoreMediaData
            if keyIndex > 0 || holdingBacklog {
                videoLayer.flush()
                needsKeyframe = true
                frames = Array(frames[keyIndex...])
            }
        }
        var showed = false
        for sample in frames where enqueue(sample) {
            showed = true
        }
        return showed
    }

    @discardableResult
    func enqueue(_ sampleBuffer: CMSampleBuffer) -> Bool {
        let keyframe = Self.isSync(sampleBuffer)
        if videoLayer.status == .failed {
            videoLayer.flush()
            needsKeyframe = true
        }
        if didEnqueue && !videoLayer.isReadyForMoreMediaData {
            videoLayer.flush()
            needsKeyframe = true
        }
        if needsKeyframe && !keyframe {
            return false
        }
        let immediate = retimedForImmediateDisplay(sampleBuffer, keyframe: keyframe)
        needsKeyframe = false
        didEnqueue = true
        videoLayer.enqueue(immediate)
        remember(sampleBuffer)
        return true
    }

    /// The picture currently on screen, decoded from the frames since the last keyframe.
    func capturedFrame() -> (image: UIImage, width: Int, height: Int)? {
        let frames = groupOfPictures
        guard let format = frames.first.flatMap({ CMSampleBufferGetFormatDescription($0) }) else { return nil }
        let decoded = DecodedFrame()
        var callback = VTDecompressionOutputCallbackRecord(
            decompressionOutputCallback: { refCon, _, status, _, imageBuffer, _, _ in
                guard status == noErr, let imageBuffer, let refCon else { return }
                Unmanaged<DecodedFrame>.fromOpaque(refCon).takeUnretainedValue().store(imageBuffer)
            },
            decompressionOutputRefCon: Unmanaged.passUnretained(decoded).toOpaque()
        )
        var session: VTDecompressionSession?
        let created = VTDecompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            formatDescription: format,
            decoderSpecification: nil,
            imageBufferAttributes: nil,
            outputCallback: &callback,
            decompressionSessionOut: &session
        )
        guard created == noErr, let session else { return nil }
        for frame in frames {
            var flags = VTDecodeInfoFlags()
            VTDecompressionSessionDecodeFrame(
                session,
                sampleBuffer: frame,
                flags: [._EnableAsynchronousDecompression],
                frameRefcon: nil,
                infoFlagsOut: &flags
            )
        }
        VTDecompressionSessionWaitForAsynchronousFrames(session)
        VTDecompressionSessionInvalidate(session)
        guard let image = decoded.image else { return nil }
        return (UIImage(cgImage: image), image.width, image.height)
    }

    private func remember(_ sample: CMSampleBuffer) {
        if Self.isSync(sample) || groupOfPictures.isEmpty {
            guard Self.isSync(sample) else { return }
            groupOfPictures = [sample]
        } else {
            groupOfPictures.append(sample)
            if groupOfPictures.count > 120 {
                groupOfPictures.removeFirst(groupOfPictures.count - 120)
            }
        }
    }

    /// Stamps a short, local timeline. Mac capture timestamps are a different clock and
    /// would schedule the frame in the future if the layer honors PTS.
    private func retimedForImmediateDisplay(_ sample: CMSampleBuffer, keyframe: Bool) -> CMSampleBuffer {
        let presentation = nextPresentation
        nextPresentation = CMTimeAdd(nextPresentation, CMTime(value: 1, timescale: 1000))
        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: 1000),
            presentationTimeStamp: presentation,
            decodeTimeStamp: .invalid
        )
        var copy: CMSampleBuffer?
        let status = CMSampleBufferCreateCopyWithNewTiming(
            allocator: kCFAllocatorDefault,
            sampleBuffer: sample,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleBufferOut: &copy
        )
        let result = (status == noErr ? copy : nil) ?? sample
        Self.markImmediate(result, keyframe: keyframe)
        return result
    }

    private static func isSync(_ sample: CMSampleBuffer) -> Bool {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[CFString: Any]],
              let first = attachments.first else {
            return true
        }
        return first[kCMSampleAttachmentKey_NotSync] == nil
    }

    private static func markImmediate(_ sample: CMSampleBuffer, keyframe: Bool) {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true) as? [NSMutableDictionary],
              let dictionary = attachments.first else { return }
        dictionary[kCMSampleAttachmentKey_DisplayImmediately as NSString] = true
        if keyframe {
            dictionary.removeObject(forKey: kCMSampleAttachmentKey_NotSync as NSString)
        } else {
            dictionary[kCMSampleAttachmentKey_NotSync as NSString] = true
        }
    }
}

enum H264Display {
    static func formatDescription(from config: VideoConfig) -> CMVideoFormatDescription? {
        guard !config.parameterSets.isEmpty else { return nil }
        var combined = Data()
        var ranges: [Range<Int>] = []
        for set in config.parameterSets {
            let start = combined.count
            combined.append(set)
            ranges.append(start..<combined.count)
        }

        var format: CMVideoFormatDescription?
        let status = combined.withUnsafeBytes { raw -> OSStatus in
            guard let base = raw.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return -1 }
            var pointers = ranges.map { UnsafePointer(base.advanced(by: $0.lowerBound)) }
            var sizes = ranges.map(\.count)
            return CMVideoFormatDescriptionCreateFromH264ParameterSets(
                allocator: kCFAllocatorDefault,
                parameterSetCount: pointers.count,
                parameterSetPointers: &pointers,
                parameterSetSizes: &sizes,
                nalUnitHeaderLength: Int32(config.nalUnitHeaderLength),
                formatDescriptionOut: &format
            )
        }
        guard status == noErr else { return nil }
        return format
    }

    static func sampleBuffer(from frame: VideoFrame, format: CMVideoFormatDescription) -> CMSampleBuffer? {
        var block: CMBlockBuffer?
        let length = frame.data.count
        var status = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: nil,
            blockLength: length,
            blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: length,
            flags: 0,
            blockBufferOut: &block
        )
        guard status == noErr, let block else { return nil }
        status = frame.data.withUnsafeBytes { raw in
            guard let source = raw.baseAddress else { return kCMBlockBufferBadCustomBlockSourceErr }
            return CMBlockBufferReplaceDataBytes(
                with: source,
                blockBuffer: block,
                offsetIntoDestination: 0,
                dataLength: length
            )
        }
        guard status == noErr else { return nil }

        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: 60),
            presentationTimeStamp: CMTime(value: CMTimeValue(frame.presentationMicros), timescale: 1_000_000),
            decodeTimeStamp: .invalid
        )
        var size = length
        var sample: CMSampleBuffer?
        status = CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault,
            dataBuffer: block,
            formatDescription: format,
            sampleCount: 1,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleSizeEntryCount: 1,
            sampleSizeArray: &size,
            sampleBufferOut: &sample
        )
        guard status == noErr, let sample else { return nil }
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true) as? [NSMutableDictionary],
           let dictionary = attachments.first {
            dictionary[kCMSampleAttachmentKey_DisplayImmediately as NSString] = true
            if !frame.isKeyframe {
                dictionary[kCMSampleAttachmentKey_NotSync as NSString] = true
            }
        }
        return sample
    }
}

/// The newest picture from one decode of the frames currently on screen.
private final class DecodedFrame {
    var image: CGImage?
    private let context = CIContext(options: [.cacheIntermediates: false])

    func store(_ buffer: CVPixelBuffer) {
        let source = CIImage(cvPixelBuffer: buffer)
        image = context.createCGImage(source, from: source.extent)
    }
}

/// One bounds rect for the live sample layer and the frozen still.
/// The still is a sibling of the sample view: hiding `AVSampleBufferDisplayLayer`
/// hides that view's subviews, so the still cannot live inside it.
/// Both children fill this view. The still uses `FrameCoordinates`, the same
/// aspect fit as the layer's `.resizeAspect` gravity and the ink mapping.
final class ScreenPictureView: UIView {
    let display = SampleDisplayView()
    private let stillView = UIImageView()
    private var showsPicture = true
    private var frozenWidth = 0
    private var frozenHeight = 0

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .black
        stillView.isHidden = true
        stillView.contentMode = .scaleToFill
        stillView.isUserInteractionEnabled = false
        stillView.isAccessibilityElement = false
        stillView.accessibilityElementsHidden = true
        addSubview(display)
        addSubview(stillView)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func setShowsPicture(_ shows: Bool) {
        showsPicture = shows
        applyPicture()
    }

    /// `width` and `height` are the captured pixel size, the same numbers ink maps against.
    func setFrozenImage(_ image: UIImage?, width: Int, height: Int) {
        frozenWidth = width
        frozenHeight = height
        if stillView.image !== image {
            stillView.image = image
        }
        applyPicture()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        display.frame = bounds
        placeStill()
    }

    /// The live sample view is the only hit target, matching the picture before the still existed.
    /// A frozen still and a blank canvas let touches through to the overlay.
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        guard showsPicture, !wantsStill else { return nil }
        return super.hitTest(point, with: event)
    }

    private var wantsStill: Bool {
        showsPicture && stillView.image != nil && frozenWidth > 0 && frozenHeight > 0
    }

    private func applyPicture() {
        display.setPictureHidden(!showsPicture || wantsStill)
        placeStill()
    }

    private func placeStill() {
        guard wantsStill,
              let picture = FrameCoordinates.pictureRect(
                viewWidth: Double(bounds.width),
                viewHeight: Double(bounds.height),
                frameWidth: frozenWidth,
                frameHeight: frozenHeight
              ),
              picture.width > 0, picture.height > 0
        else {
            stillView.isHidden = true
            return
        }
        stillView.isHidden = false
        stillView.frame = CGRect(x: picture.x, y: picture.y, width: picture.width, height: picture.height)
    }
}

struct ScreenDisplay: UIViewRepresentable {
    let client: StreamClient
    /// Blank canvas keeps the live layer and the still hidden.
    var showsPicture: Bool
    /// Nil while the livestream is the picture on screen.
    var frozenImage: UIImage?
    var frozenWidth: Int
    var frozenHeight: Int

    func makeUIView(context: Context) -> ScreenPictureView {
        let view = ScreenPictureView()
        view.setShowsPicture(showsPicture)
        view.setFrozenImage(frozenImage, width: frozenWidth, height: frozenHeight)
        client.attachDisplay(view.display)
        return view
    }

    func updateUIView(_ view: ScreenPictureView, context: Context) {
        view.setShowsPicture(showsPicture)
        view.setFrozenImage(frozenImage, width: frozenWidth, height: frozenHeight)
        client.attachDisplay(view.display)
    }
}

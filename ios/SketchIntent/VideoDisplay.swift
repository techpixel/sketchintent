import AVFoundation
import CoreMedia
import SwiftUI
import UIKit

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
        return true
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

struct ScreenDisplay: UIViewRepresentable {
    let client: StreamClient

    func makeUIView(context: Context) -> SampleDisplayView {
        let view = SampleDisplayView()
        client.attachDisplay(view)
        return view
    }

    func updateUIView(_ view: SampleDisplayView, context: Context) {
        client.attachDisplay(view)
    }
}

import CoreMedia
import CoreVideo
import Foundation
import StreamProtocol
import VideoToolbox

/// Hardware H.264 encoder tuned for screen mirroring: no B-frames, no frame delay.
final class H264Encoder {
    var onEncoded: ((VideoConfig?, VideoFrame) -> Void)?

    private var session: VTCompressionSession?
    private let lock = NSLock()
    private var forceNextKeyframe = true
    private let frameDuration: CMTime
    private var usingHardware = false

    init(fps: Int) {
        frameDuration = CMTime(value: 1, timescale: CMTimeScale(max(1, fps)))
    }

    func start(width: Int, height: Int, fps: Int, bitrate: Int) throws {
        let width = max(2, width - (width % 2))
        let height = max(2, height - (height % 2))
        let session: VTCompressionSession
        if let hardware = makeSession(width: width, height: height, requireHardware: true) {
            session = hardware
            usingHardware = true
        } else if let software = makeSession(width: width, height: height, requireHardware: false) {
            session = software
            usingHardware = false
        } else {
            throw CaptureError.stream("The H.264 encoder could not be created.")
        }
        configure(session, fps: fps, bitrate: bitrate)
        VTCompressionSessionPrepareToEncodeFrames(session)
        self.session = session
        print("[sketchintent] H.264 encoder is \(usingHardware ? "hardware" : "software").")
    }

    func requestKeyframe() {
        lock.lock()
        forceNextKeyframe = true
        lock.unlock()
    }

    func encode(_ pixelBuffer: CVPixelBuffer, presentationTime: CMTime) {
        guard let session else { return }
        tagScreenColor(pixelBuffer)
        let properties = takeFrameProperties()
        var flags = VTEncodeInfoFlags()
        let status = VTCompressionSessionEncodeFrame(
            session,
            imageBuffer: pixelBuffer,
            presentationTimeStamp: presentationTime,
            duration: frameDuration,
            frameProperties: properties,
            infoFlagsOut: &flags
        ) { [weak self] status, _, sampleBuffer in
            guard status == noErr, let sampleBuffer else { return }
            self?.handle(sampleBuffer)
        }
        if status != noErr {
            fputs("[sketchintent] Encode failed (\(status)).\n", stderr)
        }
    }

    private func makeSession(width: Int, height: Int, requireHardware: Bool) -> VTCompressionSession? {
        var session: VTCompressionSession?
        let specification: CFDictionary? = requireHardware
            ? [kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder: true] as CFDictionary
            : nil
        let status = VTCompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            width: Int32(width),
            height: Int32(height),
            codecType: kCMVideoCodecType_H264,
            encoderSpecification: specification,
            imageBufferAttributes: nil,
            compressedDataAllocator: nil,
            outputCallback: nil,
            refcon: nil,
            compressionSessionOut: &session
        )
        guard status == noErr else { return nil }
        return session
    }

    private func configure(_ session: VTCompressionSession, fps: Int, bitrate: Int) {
        set(session, kVTCompressionPropertyKey_RealTime, kCFBooleanTrue as Any)
        set(session, kVTCompressionPropertyKey_AllowFrameReordering, kCFBooleanFalse as Any)
        set(session, kVTCompressionPropertyKey_ProfileLevel, kVTProfileLevel_H264_High_AutoLevel)
        set(session, kVTCompressionPropertyKey_H264EntropyMode, kVTH264EntropyMode_CABAC)
        set(session, kVTCompressionPropertyKey_AverageBitRate, NSNumber(value: bitrate))
        set(session, kVTCompressionPropertyKey_ExpectedFrameRate, NSNumber(value: fps))
        // Half a second, and never every frame. A drop already asks for a keyframe
        // immediately; this is the backstop so recovery cannot take a full second.
        let keyframeInterval = max(2, fps / 2)
        set(session, kVTCompressionPropertyKey_MaxKeyFrameInterval, NSNumber(value: keyframeInterval))
        set(session, kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration, NSNumber(value: 0.5))
        // Zero frame delay is not supported by every hardware encoder. One frame is still realtime.
        let noDelay = VTSessionSetProperty(session, key: kVTCompressionPropertyKey_MaxFrameDelayCount, value: NSNumber(value: 0))
        if noDelay != noErr {
            _ = VTSessionSetProperty(session, key: kVTCompressionPropertyKey_MaxFrameDelayCount, value: NSNumber(value: 1))
        }
        let bytesPerSecond = max(1, bitrate / 8)
        set(
            session,
            kVTCompressionPropertyKey_DataRateLimits,
            [NSNumber(value: bytesPerSecond), NSNumber(value: 1)] as CFArray
        )
        set(session, kVTCompressionPropertyKey_ColorPrimaries, kCVImageBufferColorPrimaries_ITU_R_709_2)
        set(session, kVTCompressionPropertyKey_TransferFunction, kCVImageBufferTransferFunction_sRGB)
        set(session, kVTCompressionPropertyKey_YCbCrMatrix, kCVImageBufferYCbCrMatrix_ITU_R_709_2)
        // Full-range keeps UI black and white from being crushed into limited-range luma.
        // Hardware encoders that reject the flag keep their default range.
        _ = VTSessionSetProperty(session, key: kCMFormatDescriptionExtension_FullRangeVideo, value: kCFBooleanTrue)
    }

    /// Screen pixels are full-range sRGB. Attach that so the encoder can keep it if it accepts it.
    private func tagScreenColor(_ pixelBuffer: CVPixelBuffer) {
        CVBufferSetAttachment(pixelBuffer, kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_709_2, .shouldPropagate)
        CVBufferSetAttachment(pixelBuffer, kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_sRGB, .shouldPropagate)
        CVBufferSetAttachment(pixelBuffer, kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_709_2, .shouldPropagate)
        CVBufferSetAttachment(pixelBuffer, kCMFormatDescriptionExtension_FullRangeVideo, kCFBooleanTrue, .shouldPropagate)
    }

    private func set(_ session: VTCompressionSession, _ key: CFString, _ value: Any) {
        let status = VTSessionSetProperty(session, key: key, value: value as CFTypeRef)
        if status != noErr {
            print("[sketchintent] Encoder skipped \(key) (\(status)).")
        }
    }

    private func takeFrameProperties() -> CFDictionary? {
        lock.lock()
        let force = forceNextKeyframe
        forceNextKeyframe = false
        lock.unlock()
        guard force else { return nil }
        return [kVTEncodeFrameOptionKey_ForceKeyFrame: true] as CFDictionary
    }

    private func handle(_ sampleBuffer: CMSampleBuffer) {
        guard let format = sampleBuffer.formatDescription,
              let frameData = sampleBuffer.compressedData() else { return }
        let keyframe = sampleBuffer.isSyncSample
        let config = keyframe ? videoConfig(from: format) : nil
        let time = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        let micros = time.isValid ? UInt64(max(0, CMTimeGetSeconds(time)) * 1_000_000) : 0
        let frame = VideoFrame(isKeyframe: keyframe, presentationMicros: micros, data: frameData)
        onEncoded?(config, frame)
    }

    private func videoConfig(from format: CMFormatDescription) -> VideoConfig? {
        var count = 0
        var headerLength: Int32 = 4
        var pointer: UnsafePointer<UInt8>?
        var size = 0
        let first = CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
            format,
            parameterSetIndex: 0,
            parameterSetPointerOut: &pointer,
            parameterSetSizeOut: &size,
            parameterSetCountOut: &count,
            nalUnitHeaderLengthOut: &headerLength
        )
        guard first == noErr, count > 0, let pointer, size > 0 else { return nil }
        var sets = [Data(bytes: pointer, count: size)]
        if count > 1 {
            for index in 1..<count {
                var setPointer: UnsafePointer<UInt8>?
                var setSize = 0
                let status = CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
                    format,
                    parameterSetIndex: index,
                    parameterSetPointerOut: &setPointer,
                    parameterSetSizeOut: &setSize,
                    parameterSetCountOut: nil,
                    nalUnitHeaderLengthOut: nil
                )
                guard status == noErr, let setPointer, setSize > 0 else { continue }
                sets.append(Data(bytes: setPointer, count: setSize))
            }
        }
        let dimensions = CMVideoFormatDescriptionGetDimensions(format)
        return VideoConfig(
            width: Int(dimensions.width),
            height: Int(dimensions.height),
            nalUnitHeaderLength: Int(headerLength),
            parameterSets: sets
        )
    }
}

private extension CMSampleBuffer {
    var isSyncSample: Bool {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(self, createIfNecessary: false) as? [[CFString: Any]],
              let first = attachments.first else {
            return true
        }
        return first[kCMSampleAttachmentKey_NotSync] == nil
    }

    func compressedData() -> Data? {
        guard let block = dataBuffer else { return nil }
        let length = CMBlockBufferGetDataLength(block)
        guard length > 0 else { return nil }
        var data = Data(count: length)
        let status = data.withUnsafeMutableBytes { raw -> OSStatus in
            guard let destination = raw.baseAddress else { return kCMBlockBufferBadCustomBlockSourceErr }
            return CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: destination)
        }
        guard status == noErr else { return nil }
        return data
    }
}

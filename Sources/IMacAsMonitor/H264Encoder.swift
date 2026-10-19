import CoreMedia
import Foundation
import MAMCore
import VideoToolbox

final class H264Encoder: @unchecked Sendable {
    let width: Int
    let height: Int
    let framesPerSecond: Int

    private var session: VTCompressionSession?
    private var frameNumber: Int64 = 0
    private var lastConfiguration: H264Configuration?
    private let stateLock = NSLock()
    private var forceNextKeyframe = false

    var configurationProduced: ((H264Configuration) -> Void)?
    var frameProduced: ((_ data: Data, _ isKeyframe: Bool, _ ptsMicroseconds: UInt64) -> Void)?
    var failed: ((String) -> Void)?

    init(width: Int, height: Int, framesPerSecond: Int) {
        self.width = width
        self.height = height
        self.framesPerSecond = framesPerSecond
    }

    func start() throws {
        guard session == nil else { return }
        let specification = [
            kVTVideoEncoderSpecification_EnableHardwareAcceleratedVideoEncoder: true,
            kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder: true,
        ] as CFDictionary

        var createdSession: VTCompressionSession?
        let status = VTCompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            width: Int32(width),
            height: Int32(height),
            codecType: kCMVideoCodecType_H264,
            encoderSpecification: specification,
            imageBufferAttributes: nil,
            compressedDataAllocator: nil,
            outputCallback: h264CompressionOutputCallback,
            refcon: Unmanaged.passUnretained(self).toOpaque(),
            compressionSessionOut: &createdSession
        )
        guard status == noErr, let createdSession else {
            throw VideoPipelineError.operationFailed("VTCompressionSessionCreate", status)
        }
        session = createdSession

        try set(kVTCompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        try set(kVTCompressionPropertyKey_AllowFrameReordering, value: kCFBooleanFalse)
        try set(kVTCompressionPropertyKey_ProfileLevel, value: kVTProfileLevel_H264_High_AutoLevel)
        try set(kVTCompressionPropertyKey_ExpectedFrameRate, value: framesPerSecond as CFNumber)
        try set(kVTCompressionPropertyKey_MaxKeyFrameInterval, value: (framesPerSecond * 2) as CFNumber)
        let basePixelCount = 1440 * 900
        let scaledBitRate = 18_000_000 * width * height / basePixelCount
        let averageBitRate = min(60_000_000, max(18_000_000, scaledBitRate))
        try set(kVTCompressionPropertyKey_AverageBitRate, value: averageBitRate as CFNumber)
        let dataRateLimits = [averageBitRate * 5 / 4 / 8, 1] as CFArray
        try set(kVTCompressionPropertyKey_DataRateLimits, value: dataRateLimits)

        let prepareStatus = VTCompressionSessionPrepareToEncodeFrames(createdSession)
        guard prepareStatus == noErr else {
            throw VideoPipelineError.operationFailed("VTCompressionSessionPrepareToEncodeFrames", prepareStatus)
        }
    }

    func encode(_ pixelBuffer: CVPixelBuffer, capturePTS: CMTime) {
        guard let session else { return }
        let pts = CMTime(value: frameNumber, timescale: CMTimeScale(framesPerSecond))
        frameNumber += 1
        let duration = CMTime(value: 1, timescale: CMTimeScale(framesPerSecond))
        stateLock.lock()
        let shouldForceKeyframe = forceNextKeyframe
        forceNextKeyframe = false
        stateLock.unlock()
        let frameProperties: CFDictionary? = shouldForceKeyframe
            ? [kVTEncodeFrameOptionKey_ForceKeyFrame: true] as CFDictionary
            : nil
        let status = VTCompressionSessionEncodeFrame(
            session,
            imageBuffer: pixelBuffer,
            presentationTimeStamp: pts,
            duration: duration,
            frameProperties: frameProperties,
            sourceFrameRefcon: nil,
            infoFlagsOut: nil
        )
        if status != noErr {
            failed?("Encode failed with OSStatus \(status)")
        }
    }

    func requestKeyframe() {
        stateLock.lock()
        forceNextKeyframe = true
        stateLock.unlock()
    }

    func stop() {
        guard let session else { return }
        VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid)
        VTCompressionSessionInvalidate(session)
        self.session = nil
        frameNumber = 0
        lastConfiguration = nil
        stateLock.lock()
        forceNextKeyframe = false
        stateLock.unlock()
    }

    fileprivate func handle(status: OSStatus, sampleBuffer: CMSampleBuffer?) {
        guard status == noErr, let sampleBuffer, CMSampleBufferDataIsReady(sampleBuffer) else {
            failed?("Encoder callback failed with OSStatus \(status)")
            return
        }

        let isKeyframe: Bool = {
            guard
                let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false),
                let dictionaries = attachments as? [[CFString: Any]],
                let dictionary = dictionaries.first
            else { return true }
            return !(dictionary[kCMSampleAttachmentKey_NotSync] as? Bool ?? false)
        }()

        if isKeyframe, let format = CMSampleBufferGetFormatDescription(sampleBuffer) {
            do {
                let configuration = try configuration(from: format)
                if configuration != lastConfiguration {
                    lastConfiguration = configuration
                    configurationProduced?(configuration)
                } else {
                    // Repeat the configuration before every keyframe so a reconnect can recover quickly.
                    configurationProduced?(configuration)
                }
            } catch {
                failed?(error.localizedDescription)
                return
            }
        }

        guard let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { return }
        var totalLength = 0
        var dataPointer: UnsafeMutablePointer<Int8>?
        let dataStatus = CMBlockBufferGetDataPointer(
            blockBuffer,
            atOffset: 0,
            lengthAtOffsetOut: nil,
            totalLengthOut: &totalLength,
            dataPointerOut: &dataPointer
        )
        guard dataStatus == noErr, let dataPointer else {
            failed?("CMBlockBufferGetDataPointer failed with OSStatus \(dataStatus)")
            return
        }

        let data = Data(bytes: dataPointer, count: totalLength)
        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        let microseconds = UInt64(max(0, CMTimeConvertScale(pts, timescale: 1_000_000, method: .default).value))
        frameProduced?(data, isKeyframe, microseconds)
    }

    private func set(_ key: CFString, value: CFTypeRef) throws {
        guard let session else { return }
        let status = VTSessionSetProperty(session, key: key, value: value)
        guard status == noErr else {
            throw VideoPipelineError.operationFailed("VTSessionSetProperty \(key)", status)
        }
    }

    private func configuration(from format: CMFormatDescription) throws -> H264Configuration {
        var spsPointer: UnsafePointer<UInt8>?
        var spsSize = 0
        var parameterCount = 0
        var nalHeaderLength: Int32 = 0
        var status = CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
            format,
            parameterSetIndex: 0,
            parameterSetPointerOut: &spsPointer,
            parameterSetSizeOut: &spsSize,
            parameterSetCountOut: &parameterCount,
            nalUnitHeaderLengthOut: &nalHeaderLength
        )
        guard status == noErr, let spsPointer else {
            throw VideoPipelineError.operationFailed("Read H.264 SPS", status)
        }

        var ppsPointer: UnsafePointer<UInt8>?
        var ppsSize = 0
        status = CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
            format,
            parameterSetIndex: 1,
            parameterSetPointerOut: &ppsPointer,
            parameterSetSizeOut: &ppsSize,
            parameterSetCountOut: nil,
            nalUnitHeaderLengthOut: nil
        )
        guard status == noErr, let ppsPointer else {
            throw VideoPipelineError.operationFailed("Read H.264 PPS", status)
        }

        return H264Configuration(
            width: UInt32(width),
            height: UInt32(height),
            sps: Data(bytes: spsPointer, count: spsSize),
            pps: Data(bytes: ppsPointer, count: ppsSize)
        )
    }
}

private let h264CompressionOutputCallback: VTCompressionOutputCallback = {
    refcon, _, status, _, sampleBuffer in
    guard let refcon else { return }
    Unmanaged<H264Encoder>.fromOpaque(refcon).takeUnretainedValue().handle(
        status: status,
        sampleBuffer: sampleBuffer
    )
}

enum VideoPipelineError: LocalizedError {
    case operationFailed(String, OSStatus)
    case missingFormat

    var errorDescription: String? {
        switch self {
        case .operationFailed(let operation, let status):
            return "\(operation) failed with OSStatus \(status)"
        case .missingFormat:
            return "The stream did not provide a video format."
        }
    }
}

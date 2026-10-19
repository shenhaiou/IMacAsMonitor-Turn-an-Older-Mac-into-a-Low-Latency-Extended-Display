import CoreMedia
import CoreVideo
import Foundation
import MAMCore
import VideoToolbox

final class H264Decoder: @unchecked Sendable {
    private var formatDescription: CMVideoFormatDescription?
    private var session: VTDecompressionSession?
    private var currentConfiguration: H264Configuration?

    var frameDecoded: ((CVPixelBuffer) -> Void)?
    var failed: ((String) -> Void)?

    func configure(_ configuration: H264Configuration) throws {
        if configuration == currentConfiguration, session != nil { return }
        stop()
        var description: CMFormatDescription?
        let status = configuration.sps.withUnsafeBytes { spsBytes in
            configuration.pps.withUnsafeBytes { ppsBytes in
                let pointers: [UnsafePointer<UInt8>] = [
                    spsBytes.bindMemory(to: UInt8.self).baseAddress!,
                    ppsBytes.bindMemory(to: UInt8.self).baseAddress!,
                ]
                let sizes = [configuration.sps.count, configuration.pps.count]
                return CMVideoFormatDescriptionCreateFromH264ParameterSets(
                    allocator: kCFAllocatorDefault,
                    parameterSetCount: 2,
                    parameterSetPointers: pointers,
                    parameterSetSizes: sizes,
                    nalUnitHeaderLength: 4,
                    formatDescriptionOut: &description
                )
            }
        }
        guard status == noErr, let description else {
            throw VideoPipelineError.operationFailed("CMVideoFormatDescriptionCreateFromH264ParameterSets", status)
        }
        formatDescription = description

        let attributes = [
            kCVPixelBufferMetalCompatibilityKey: true,
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
        ] as CFDictionary
        var callback = VTDecompressionOutputCallbackRecord(
            decompressionOutputCallback: h264DecompressionOutputCallback,
            decompressionOutputRefCon: Unmanaged.passUnretained(self).toOpaque()
        )
        var createdSession: VTDecompressionSession?
        let createStatus = VTDecompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            formatDescription: description,
            decoderSpecification: nil,
            imageBufferAttributes: attributes,
            outputCallback: &callback,
            decompressionSessionOut: &createdSession
        )
        guard createStatus == noErr, let createdSession else {
            throw VideoPipelineError.operationFailed("VTDecompressionSessionCreate", createStatus)
        }
        session = createdSession
        currentConfiguration = configuration
    }

    func decode(_ data: Data, presentationTimeMicroseconds: UInt64) {
        guard let session, let formatDescription else { return }
        var blockBuffer: CMBlockBuffer?
        var status = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: nil,
            blockLength: data.count,
            blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: data.count,
            flags: 0,
            blockBufferOut: &blockBuffer
        )
        guard status == kCMBlockBufferNoErr, let blockBuffer else {
            failed?("Could not allocate compressed frame buffer: \(status)")
            return
        }
        status = data.withUnsafeBytes { bytes in
            CMBlockBufferReplaceDataBytes(
                with: bytes.baseAddress!,
                blockBuffer: blockBuffer,
                offsetIntoDestination: 0,
                dataLength: data.count
            )
        }
        guard status == kCMBlockBufferNoErr else {
            failed?("Could not copy compressed frame: \(status)")
            return
        }

        var timing = CMSampleTimingInfo(
            duration: .invalid,
            presentationTimeStamp: CMTime(value: CMTimeValue(presentationTimeMicroseconds), timescale: 1_000_000),
            decodeTimeStamp: .invalid
        )
        var sampleBuffer: CMSampleBuffer?
        var sampleSize = data.count
        status = CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault,
            dataBuffer: blockBuffer,
            formatDescription: formatDescription,
            sampleCount: 1,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleSizeEntryCount: 1,
            sampleSizeArray: &sampleSize,
            sampleBufferOut: &sampleBuffer
        )
        guard status == noErr, let sampleBuffer else {
            failed?("Could not create compressed sample: \(status)")
            return
        }

        var flagsOut = VTDecodeInfoFlags()
        status = VTDecompressionSessionDecodeFrame(
            session,
            sampleBuffer: sampleBuffer,
            flags: [._EnableAsynchronousDecompression, ._EnableTemporalProcessing],
            frameRefcon: nil,
            infoFlagsOut: &flagsOut
        )
        if status != noErr {
            failed?("Decode failed with OSStatus \(status)")
        }
    }

    func stop() {
        if let session {
            VTDecompressionSessionWaitForAsynchronousFrames(session)
            VTDecompressionSessionInvalidate(session)
        }
        session = nil
        formatDescription = nil
        currentConfiguration = nil
    }

    fileprivate func handle(status: OSStatus, imageBuffer: CVImageBuffer?) {
        guard status == noErr, let imageBuffer else {
            failed?("Decoder callback failed with OSStatus \(status)")
            return
        }
        frameDecoded?(imageBuffer)
    }
}

private let h264DecompressionOutputCallback: VTDecompressionOutputCallback = {
    refcon, _, status, _, imageBuffer, _, _ in
    guard let refcon else { return }
    Unmanaged<H264Decoder>.fromOpaque(refcon).takeUnretainedValue().handle(
        status: status,
        imageBuffer: imageBuffer
    )
}

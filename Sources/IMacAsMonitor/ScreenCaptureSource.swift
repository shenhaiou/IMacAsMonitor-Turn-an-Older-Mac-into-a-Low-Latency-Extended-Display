import CoreMedia
import CoreVideo
import Foundation
import ScreenCaptureKit

final class ScreenCaptureSource: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    private let encoder: H264Encoder
    private let targetDisplayID: CGDirectDisplayID?
    private let captureQueue = DispatchQueue(label: "com.haiou.imac-as-monitor.capture", qos: .userInteractive)
    private var stream: SCStream?

    var statusChanged: ((String) -> Void)?

    init(encoder: H264Encoder, targetDisplayID: CGDirectDisplayID? = nil) {
        self.encoder = encoder
        self.targetDisplayID = targetDisplayID
    }

    func start() async throws {
        try encoder.start()
        let desiredDisplayID = targetDisplayID ?? CGMainDisplayID()
        let display = try await waitForDisplay(desiredDisplayID)

        let filter = SCContentFilter(display: display, excludingWindows: [])
        let configuration = SCStreamConfiguration()
        configuration.width = encoder.width
        configuration.height = encoder.height
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(encoder.framesPerSecond))
        configuration.queueDepth = 3
        configuration.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        configuration.showsCursor = true
        configuration.colorSpaceName = CGColorSpace.sRGB

        let stream = SCStream(filter: filter, configuration: configuration, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: captureQueue)
        self.stream = stream
        try await stream.startCapture()
        statusChanged?(
            "Capturing \(display.width)×\(display.height) → " +
            "\(encoder.width)×\(encoder.height) at \(encoder.framesPerSecond) fps"
        )
    }

    private func waitForDisplay(_ displayID: CGDirectDisplayID) async throws -> SCDisplay {
        // WindowServer publishes a newly created virtual display asynchronously.
        // Give ScreenCaptureKit up to two seconds to observe it.
        for attempt in 0..<20 {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            if let display = content.displays.first(where: { $0.displayID == displayID }) {
                return display
            }
            if targetDisplayID == nil || attempt == 19 {
                break
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw CaptureError.noDisplay
    }

    func stop() async {
        if let stream {
            try? await stream.stopCapture()
        }
        stream = nil
        encoder.stop()
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of outputType: SCStreamOutputType) {
        guard outputType == .screen, sampleBuffer.isValid, let pixelBuffer = sampleBuffer.imageBuffer else { return }
        guard frameIsComplete(sampleBuffer) else { return }
        encoder.encode(pixelBuffer, capturePTS: sampleBuffer.presentationTimeStamp)
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        statusChanged?("Capture stopped: \(error.localizedDescription)")
    }

    private func frameIsComplete(_ sampleBuffer: CMSampleBuffer) -> Bool {
        guard
            let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
            let attachment = attachments.first,
            let rawStatus = attachment[.status] as? Int,
            let status = SCFrameStatus(rawValue: rawStatus)
        else { return false }
        return status == .complete
    }
}

enum CaptureError: LocalizedError {
    case noDisplay

    var errorDescription: String? {
        "No capturable display was found."
    }
}

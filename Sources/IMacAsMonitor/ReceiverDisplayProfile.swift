import CoreGraphics
import Foundation
import MAMCore

extension ReceiverDisplayProfile {
    static func currentBuiltInDisplay() -> ReceiverDisplayProfile {
        let displayID = builtInDisplayID() ?? CGMainDisplayID()
        guard let mode = CGDisplayCopyDisplayMode(displayID) else {
            return fallback
        }

        let refreshRate = mode.refreshRate > 1 ? mode.refreshRate : 60
        return ReceiverDisplayProfile(
            pixelWidth: clampedUInt32(mode.pixelWidth),
            pixelHeight: clampedUInt32(mode.pixelHeight),
            logicalWidth: clampedUInt32(mode.width),
            logicalHeight: clampedUInt32(mode.height),
            refreshRateMillihertz: clampedUInt32(Int((refreshRate * 1_000).rounded()))
        )
    }

    static let fallback = ReceiverDisplayProfile(
        pixelWidth: 1440,
        pixelHeight: 900,
        logicalWidth: 1440,
        logicalHeight: 900,
        refreshRateMillihertz: 60_000
    )

    private static func builtInDisplayID() -> CGDirectDisplayID? {
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &count) == .success, count > 0 else {
            return nil
        }
        var displays = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetActiveDisplayList(count, &displays, &count) == .success else {
            return nil
        }
        return displays.prefix(Int(count)).first(where: { CGDisplayIsBuiltin($0) != 0 })
    }

    private static func clampedUInt32<T: BinaryInteger>(_ value: T) -> UInt32 {
        UInt32(clamping: value)
    }
}

struct NegotiatedDisplayMode: Equatable {
    static let fallback = NegotiatedDisplayMode(
        logicalWidth: 1440,
        logicalHeight: 900,
        streamWidth: 1440,
        streamHeight: 900,
        framesPerSecond: 60
    )

    let logicalWidth: UInt32
    let logicalHeight: UInt32
    let streamWidth: Int
    let streamHeight: Int
    let framesPerSecond: Int

    init(profile: ReceiverDisplayProfile) {
        let safeLogicalWidth = Self.clampEven(Int(profile.logicalWidth), minimum: 640, maximum: 3_840)
        let safeLogicalHeight = Self.clampEven(Int(profile.logicalHeight), minimum: 480, maximum: 2_160)
        logicalWidth = UInt32(safeLogicalWidth)
        logicalHeight = UInt32(safeLogicalHeight)

        let requestedWidth = Self.clampEven(Int(profile.pixelWidth), minimum: 640, maximum: 4_096)
        let requestedHeight = Self.clampEven(Int(profile.pixelHeight), minimum: 480, maximum: 4_096)
        let maximumPixelArea = 3_840 * 2_160
        if requestedWidth * requestedHeight <= maximumPixelArea {
            streamWidth = requestedWidth
            streamHeight = requestedHeight
        } else {
            // H.264 hardware support on older Intel Macs is safer at 4K or below.
            streamWidth = safeLogicalWidth
            streamHeight = safeLogicalHeight
        }

        let requestedFPS = Int((Double(profile.refreshRateMillihertz) / 1_000).rounded())
        framesPerSecond = min(60, max(30, requestedFPS))
    }

    private init(
        logicalWidth: UInt32,
        logicalHeight: UInt32,
        streamWidth: Int,
        streamHeight: Int,
        framesPerSecond: Int
    ) {
        self.logicalWidth = logicalWidth
        self.logicalHeight = logicalHeight
        self.streamWidth = streamWidth
        self.streamHeight = streamHeight
        self.framesPerSecond = framesPerSecond
    }

    private static func clampEven(_ value: Int, minimum: Int, maximum: Int) -> Int {
        min(maximum, max(minimum, value)) & ~1
    }
}

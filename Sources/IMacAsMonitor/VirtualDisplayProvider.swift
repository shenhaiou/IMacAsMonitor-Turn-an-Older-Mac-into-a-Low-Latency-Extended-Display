import CoreGraphics
import CVirtualDisplay
import Foundation

final class VirtualDisplayProvider: @unchecked Sendable {
    let displayID: CGDirectDisplayID
    private var displayReference: UnsafeMutableRawPointer?

    init(logicalWidth: UInt32, logicalHeight: UInt32, refreshRate: Double) throws {
        guard MAMVirtualDisplayIsSupported() else {
            throw VirtualDisplayError.privateAPIUnavailable
        }
        var displayID: CGDirectDisplayID = 0
        guard let reference = MAMVirtualDisplayCreate(
            logicalWidth,
            logicalHeight,
            refreshRate,
            &displayID
        ), displayID != 0 else {
            throw VirtualDisplayError.creationFailed
        }
        self.displayID = displayID
        displayReference = reference
    }

    deinit {
        if let displayReference {
            MAMVirtualDisplayRelease(displayReference)
        }
    }
}

enum VirtualDisplayError: LocalizedError {
    case privateAPIUnavailable
    case creationFailed

    var errorDescription: String? {
        switch self {
        case .privateAPIUnavailable:
            return "This macOS version does not expose the virtual-display runtime classes."
        case .creationFailed:
            return "macOS rejected the virtual display configuration."
        }
    }
}

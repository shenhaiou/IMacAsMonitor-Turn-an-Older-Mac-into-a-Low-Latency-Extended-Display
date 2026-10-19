import CoreGraphics
import CVirtualDisplay
import Foundation
import XCTest

final class VirtualDisplaySmokeTests: XCTestCase {
    func testVirtualDisplayLifecycleWhenExplicitlyEnabled() throws {
        guard ProcessInfo.processInfo.environment["MAM_RUN_VIRTUAL_DISPLAY_TEST"] == "1" else {
            throw XCTSkip("Set MAM_RUN_VIRTUAL_DISPLAY_TEST=1 to exercise the private virtual-display API.")
        }

        XCTAssertTrue(MAMVirtualDisplayIsSupported())
        var displayID: CGDirectDisplayID = 0
        let reference = MAMVirtualDisplayCreate(1440, 900, 60, &displayID)
        XCTAssertNotNil(reference)
        XCTAssertNotEqual(displayID, 0)
        guard let reference else { return }
        defer { MAMVirtualDisplayRelease(reference) }

        XCTAssertNotEqual(CGDisplayBounds(displayID).width, 0)
        XCTAssertTrue(CGDisplayIsOnline(displayID) != 0)
    }
}

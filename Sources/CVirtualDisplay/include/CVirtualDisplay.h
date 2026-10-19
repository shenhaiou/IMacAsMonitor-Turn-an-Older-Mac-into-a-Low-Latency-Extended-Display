#ifndef C_VIRTUAL_DISPLAY_H
#define C_VIRTUAL_DISPLAY_H

#include <CoreGraphics/CoreGraphics.h>
#include <stdbool.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/// These functions dynamically resolve Apple's undocumented CGVirtualDisplay
/// Objective-C classes. No private class symbol is linked into the application.
bool MAMVirtualDisplayIsSupported(void);

/// Creates a HiDPI virtual display. width and height are logical point dimensions;
/// the backing framebuffer is twice as wide and high.
void *MAMVirtualDisplayCreate(
    uint32_t width,
    uint32_t height,
    double refreshRate,
    CGDirectDisplayID *displayIDOut
);

/// Releases the object that owns the virtual display, removing it from macOS.
void MAMVirtualDisplayRelease(void *displayReference);

#ifdef __cplusplus
}
#endif

#endif

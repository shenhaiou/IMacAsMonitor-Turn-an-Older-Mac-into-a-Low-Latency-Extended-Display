#import "CVirtualDisplay.h"

#import <AppKit/AppKit.h>
#import <Foundation/Foundation.h>

// The private interface declarations and setup sequence are based on DeskPad:
// https://github.com/Stengo/DeskPad (MIT licensed; see THIRD_PARTY_NOTICES.md).
// Keep their use isolated here so the rest of the app only sees a small C API.
@interface CGVirtualDisplayDescriptor : NSObject
@property(nonatomic, retain) NSString *name;
@property(nonatomic) unsigned int maxPixelsWide;
@property(nonatomic) unsigned int maxPixelsHigh;
@property(nonatomic) CGSize sizeInMillimeters;
@property(nonatomic) unsigned int vendorID;
@property(nonatomic) unsigned int productID;
@property(nonatomic) unsigned int serialNum;
- (void)setDispatchQueue:(dispatch_queue_t)queue;
@end

@interface CGVirtualDisplayMode : NSObject
- (instancetype)initWithWidth:(NSUInteger)width
                       height:(NSUInteger)height
                  refreshRate:(CGFloat)refreshRate;
@end

@interface CGVirtualDisplaySettings : NSObject
@property(nonatomic, retain) NSArray<CGVirtualDisplayMode *> *modes;
@property(nonatomic) unsigned int hiDPI;
@end

@interface CGVirtualDisplay : NSObject
@property(nonatomic, readonly) CGDirectDisplayID displayID;
- (instancetype)initWithDescriptor:(CGVirtualDisplayDescriptor *)descriptor;
- (BOOL)applySettings:(CGVirtualDisplaySettings *)settings;
@end

bool MAMVirtualDisplayIsSupported(void) {
    return NSClassFromString(@"CGVirtualDisplayDescriptor") != Nil &&
           NSClassFromString(@"CGVirtualDisplayMode") != Nil &&
           NSClassFromString(@"CGVirtualDisplaySettings") != Nil &&
           NSClassFromString(@"CGVirtualDisplay") != Nil;
}

void *MAMVirtualDisplayCreate(
    uint32_t width,
    uint32_t height,
    double refreshRate,
    CGDirectDisplayID *displayIDOut
) {
    if (!MAMVirtualDisplayIsSupported() || width == 0 || height == 0 || displayIDOut == NULL) {
        return NULL;
    }

    CGVirtualDisplayDescriptor *descriptor = [CGVirtualDisplayDescriptor new];
    descriptor.name = @"IMacAsMonitor Extended Display";
    descriptor.maxPixelsWide = width * 2;
    descriptor.maxPixelsHigh = height * 2;
    descriptor.sizeInMillimeters = CGSizeMake(331, 207);
    descriptor.vendorID = 0x4D41;
    descriptor.productID = 0x2017;
    descriptor.serialNum = 0x0001;
    [descriptor setDispatchQueue:dispatch_get_main_queue()];

    CGVirtualDisplayMode *mode = [[CGVirtualDisplayMode alloc]
        initWithWidth:(NSUInteger)width
                height:(NSUInteger)height
           refreshRate:(CGFloat)refreshRate];
    if (mode == nil) {
        NSLog(@"IMacAsMonitor: CGVirtualDisplayMode initialization failed");
        return NULL;
    }

    CGVirtualDisplaySettings *settings = [CGVirtualDisplaySettings new];
    settings.modes = @[mode];
    settings.hiDPI = 1;

    CGVirtualDisplay *display = [[CGVirtualDisplay alloc] initWithDescriptor:descriptor];
    if (display == nil) {
        NSLog(@"IMacAsMonitor: CGVirtualDisplay initialization failed");
        return NULL;
    }

    if (![display applySettings:settings]) {
        NSLog(@"IMacAsMonitor: CGVirtualDisplay applySettings failed");
        return NULL;
    }

    CGDirectDisplayID displayID = display.displayID;
    if (displayID == 0) {
        NSLog(@"IMacAsMonitor: CGVirtualDisplay returned display ID 0");
        return NULL;
    }

    *displayIDOut = displayID;
    return (__bridge_retained void *)display;
}

void MAMVirtualDisplayRelease(void *displayReference) {
    if (displayReference != NULL) {
        CFBridgingRelease(displayReference);
    }
}

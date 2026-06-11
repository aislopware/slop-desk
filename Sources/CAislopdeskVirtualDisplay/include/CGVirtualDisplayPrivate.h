// CGVirtualDisplayPrivate.h — private CoreGraphics virtual-display interface.
//
// These four classes live in the PUBLIC CoreGraphics.framework (no dlopen, no private
// sub-framework, no special entitlement); only their HEADERS are private. Declaring them here
// lets aislopdesk-videohostd create a HiDPI 2× virtual display so a remoted window renders at real
// Retina backing resolution (sharp text) instead of being captured at point resolution and
// upscaled on the client.
//
// Sources cross-checked (class-dumps + working OSS): KhaosT/CGVirtualDisplay,
// w0lfschild/macOS_headers (CoreGraphics 1336), huberdf/FreeDisplay, sammcj/force-hidpi,
// knightynite/HiDPIVirtualDisplay, Chromium virtual_display_mac_util.mm.
//
// ⚠️ PROPERTY-NAME DIVERGENCE: the original class-dump exposes `serialNum`; some later bridging
// headers use `serialNumber`. We declare `serialNum` (class-dump canonical) but the Swift wrapper
// sets the serial via GUARDED KVC (respondsToSelector) so a rename can never crash with an
// unrecognized selector — it just skips the cosmetic serial. vendorID/productID names are stable
// across every source.
//
// ⚠️ HANG/PERSISTENCE: `initWithDescriptor:` must run on the MAIN THREAD (synchronous WindowServer
// Mach IPC) and the process must keep a live run loop (NSApplication.run / CFRunLoopRun) or the
// display is torn down. The VD object must be RETAINED for its whole lifetime (ARC dealloc
// unregisters it). `applySettings:` blocks on WindowServer IPC — call it off the main thread.

#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>

NS_ASSUME_NONNULL_BEGIN

/// One display mode. width/height are POINT (logical) dimensions; with settings.hiDPI=1 the OS
/// doubles them to the pixel framebuffer (so a 1920×1080-point mode is backed by 3840×2160 px).
@interface CGVirtualDisplayMode : NSObject
@property (readonly, nonatomic) NSUInteger width;       // POINTS
@property (readonly, nonatomic) NSUInteger height;      // POINTS
@property (readonly, nonatomic) double      refreshRate;
- (instancetype)initWithWidth:(NSUInteger)width
                       height:(NSUInteger)height
                  refreshRate:(double)refreshRate;
@end

@interface CGVirtualDisplaySettings : NSObject
@property (nonatomic)         unsigned int  hiDPI;       // 0 = none, 1 = 2× Retina backing
@property (retain, nonatomic) NSArray<CGVirtualDisplayMode *> *modes;
@property (nonatomic)         unsigned int  rotation;    // 0/90/180/270
- (instancetype)init;
@end

@interface CGVirtualDisplayDescriptor : NSObject
@property (nonatomic) unsigned int  vendorID;           // MUST be non-zero (else initWithDescriptor: → nil)
@property (nonatomic) unsigned int  productID;
@property (nonatomic) unsigned int  serialNum;          // set via GUARDED KVC in Swift (see header note)
@property (copy,   nonatomic) NSString *name;
@property (nonatomic) CGSize        sizeInMillimeters;
@property (nonatomic) unsigned int  maxPixelsWide;      // PIXEL framebuffer width
@property (nonatomic) unsigned int  maxPixelsHigh;      // PIXEL framebuffer height
@property (nonatomic) CGPoint redPrimary;              // CIE xy, [0,1]
@property (nonatomic) CGPoint greenPrimary;
@property (nonatomic) CGPoint bluePrimary;
@property (nonatomic) CGPoint whitePoint;
@property (retain, nonatomic) dispatch_queue_t queue;   // terminationHandler delivery queue
@property (copy, nonatomic, nullable) void (^terminationHandler)(id _Nullable, id _Nullable);
- (instancetype)init;
@end

@interface CGVirtualDisplay : NSObject
@property (readonly, nonatomic) CGDirectDisplayID displayID;   // valid after applySettings: returns YES
@property (readonly, nonatomic) unsigned int      hiDPI;
@property (readonly, nonatomic) unsigned int      maxPixelsWide;
@property (readonly, nonatomic) unsigned int      maxPixelsHigh;
/// Returns nil on an invalid descriptor (e.g. vendorID=0) or if WindowServer cannot register it.
- (nullable instancetype)initWithDescriptor:(CGVirtualDisplayDescriptor *)descriptor;
/// Sends modes + hiDPI to WindowServer. Returns YES on success; can BLOCK for seconds on first
/// call — invoke off the main thread with a timeout guard.
- (BOOL)applySettings:(CGVirtualDisplaySettings *)settings;
@end

NS_ASSUME_NONNULL_END

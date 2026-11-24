// Mountain Lion's sheets: the sheet unrolls out of a slit under its parent's title bar, and rolls back into it. macOS 11
// dropped that for a detached window that fades and scales in.
//
// The effect is Mountain Lion's own. appkitd runs CoreGraphics' MetalSheetProgress, which warped the sheet and made and
// shaded the slit, against a stand-in window server (Guest/Renderer.m), and hands back what it did, frame by frame. Here
// that is played on the real windows at HIToolbox's timing: 0.2s, eased by (sin((2t - 1) * pi/2) + 1) / 2.
//
// AppKit is kept out of the way: opening skips AppKit's animation so the sheet is placed immediately (collapsed) and
// unrolls on a 120 Hz timer; closing runs inside AppKit's animation loop so AppKit keeps the sheet on screen until the
// effect finishes rolling it up and cleans up.

#import <AppKit/AppKit.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/message.h>
#import <objc/runtime.h>
#include <dlfcn.h>
#include <math.h>
#include <unistd.h>
#include "../Client/LionessClient.h"

// SkyLight is private, so these are looked up rather than linked.
static int SLSMainConnectionID(void) {
    static int (*fn)(void) = (int (*)(void))dlsym(RTLD_DEFAULT, "SLSMainConnectionID");
    return fn ? fn() : 0;
}
static CGError SLSSetWindowWarp(int cid, int wid, int width, int height, const float *mesh) {
    static CGError (*fn)(int, int, int, int, const float *) = (CGError (*)(int, int, int, int, const float *))dlsym(RTLD_DEFAULT, "SLSSetWindowWarp");
    return fn ? fn(cid, wid, width, height, mesh) : kCGErrorFailure;
}

static CGError SLSOrderWindow(int cid, int wid, int mode, int relative) {
    static CGError (*fn)(int, int, int, int) = (CGError (*)(int, int, int, int))dlsym(RTLD_DEFAULT, "SLSOrderWindow");
    return fn ? fn(cid, wid, mode, relative) : kCGErrorFailure;
}

namespace {

const int kFrames = 48;         // smooth at 120 Hz across Mountain Lion's ~0.35-0.52s duration

double Ease(double t) { return (sin((2.0 * t - 1.0) * M_PI_2) + 1.0) / 2.0; }

// Mountain Lion's -[NSMoveHelper(NSSheets) _startSheet]: [sheet animationResizeTime:zeroHeight] * 1.5.
double SheetDuration(NSWindow *sheet) {
    NSRect zero = sheet.frame;
    zero.size.height = 0;
    double d = [sheet animationResizeTime:zero] * 1.5;
    if (d < 0.2) d = 0.35;
    return d;
}

CGFloat ScreenTop(void) { return NSMaxY(NSScreen.screens.firstObject.frame); }

// Window server coordinates: points, from the top left of the main display.
CGRect ServerRect(NSRect r) { return CGRectMake(r.origin.x, ScreenTop() - NSMaxY(r), r.size.width, r.size.height); }
NSRect AppKitRect(CGRect r) { return NSMakeRect(r.origin.x, ScreenTop() - CGRectGetMaxY(r), r.size.width, r.size.height); }

void Unwarp(NSWindow *w) {
    if (w.windowNumber > 0) SLSSetWindowWarp(SLSMainConnectionID(), (int)w.windowNumber, 0, 0, NULL);
}

// AppKit has already marked a closing sheet as not visible, and a remote sheet (Save/Open) may order in late.
BOOL OnScreen(NSWindow *w) {
    if (w.windowNumber <= 0) return NO;
    CFArrayRef list = CGWindowListCopyWindowInfo(kCGWindowListOptionIncludingWindow, (CGWindowID)w.windowNumber);
    if (!list) return NO;
    NSDictionary *info = CFArrayGetCount(list) ? (__bridge NSDictionary *)CFArrayGetValueAtIndex(list, 0) : nil;
    BOOL on = [info[(__bridge NSString *)kCGWindowIsOnscreen] boolValue];
    CFRelease(list);
    return on;
}

// Rolled all the way up: the sheet's bottom edge squeezed to nothing along its top. Nothing of it shows.
void Collapse(NSWindow *w, CGRect server) {
    if (w.windowNumber <= 0) return;
    float x = (float)server.origin.x, y = (float)server.origin.y, W = (float)server.size.width, H = (float)server.size.height;
    float mesh[16] = {0, 0, x, y, W, 0, x + W, y, 0, H, x, y, W, H, x + W, y};
    SLSSetWindowWarp(SLSMainConnectionID(), (int)w.windowNumber, 2, 2, mesh);
}

// Frames for a sheet of this size, opening or closing. The effect works in the sheet's own position, so it is run once
// with the sheet at the origin and moved to where each sheet is.
NSMutableDictionary<NSString *, NSArray *> *gFrameCache;

NSArray *FramesFor(CGSize size, CGRect parentRelative, bool closing) {
    NSString *key = [NSString stringWithFormat:@"%.0fx%.0f/%.0f,%.0f,%.0fx%.0f/%d", size.width, size.height, parentRelative.origin.x,
                     parentRelative.origin.y, parentRelative.size.width, parentRelative.size.height, closing];
    if (!gFrameCache) gFrameCache = [NSMutableDictionary dictionary];
    if (NSArray *cached = gFrameCache[key]) return cached.count ? cached : nil;

    LionessSheetRequest r = {};
    r.sheet[2] = (float)size.width;
    r.sheet[3] = (float)size.height;
    r.parent[0] = (float)parentRelative.origin.x;
    r.parent[1] = (float)parentRelative.origin.y;
    r.parent[2] = (float)parentRelative.size.width;
    r.parent[3] = (float)parentRelative.size.height;
    r.leftEdge = (float)fmax(0.0, fmin(size.width, parentRelative.origin.x));
    r.rightEdge = (float)fmax(r.leftEdge, fmin(size.width, CGRectGetMaxX(parentRelative)));
    r.frames = kFrames;
    for (int i = 0; i < kFrames; i++) {
        double p = Ease((i + 1.0) / kFrames);
        r.progress[i] = (float)(closing ? 1.0 - p : p);
    }
    NSArray *frames = nil;
    if (CFDataRef data = LionessCopySheetFrames(&r)) {
        id list = [NSPropertyListSerialization propertyListWithData:(__bridge NSData *)data options:0 format:NULL error:NULL];
        CFRelease(data);
        if ([list isKindOfClass:NSArray.class] && [list count] == kFrames + 1) frames = list;
    }
    if (gFrameCache.count > 64) [gFrameCache removeAllObjects];
    gFrameCache[key] = frames ?: @[];   // asked once: a sheet that cannot have the effect appears as macOS has it
    return frames;
}

} // namespace

// One run of the effect on one sheet.
@interface LionessSheetEffect : NSObject
@property (nonatomic, strong) NSWindow *sheet;
@property (nonatomic, strong) NSWindow *parent;
@property (nonatomic, assign) CGPoint origin;   // the sheet's top left, window server coordinates
@property (nonatomic, assign) CGSize size;
@property (nonatomic, strong) NSArray *frames;
@property (nonatomic, assign) double duration;
@property (nonatomic, assign) BOOL closing;
@property (nonatomic, assign) CFTimeInterval queued;
@property (nonatomic, assign) CFTimeInterval start;
@property (nonatomic, assign) NSInteger applied;   // frames played so far
@property (nonatomic, strong) NSTimer *timer;
@property (nonatomic, copy) void (^done)(void);
@property (nonatomic, assign) BOOL finished;
@property (nonatomic, strong) NSMutableDictionary<NSNumber *, NSPanel *> *windows;   // the effect's own windows
@property (nonatomic, strong) NSMutableDictionary<NSNumber *, NSData *> *lastPixels;
@property (nonatomic, strong) NSMutableSet<NSNumber *> *ordered;
@end

@implementation LionessSheetEffect

- (NSRect)appKitRectFor:(NSDictionary *)op {
    return AppKitRect(CGRectMake([op[@"x"] doubleValue] + self.origin.x, [op[@"y"] doubleValue] + self.origin.y,
                                 [op[@"w"] doubleValue], [op[@"h"] doubleValue]));
}

- (NSInteger)windowNumberFor:(int)wid {
    if (wid == LIONESS_SHEET_WID) return self.sheet.windowNumber;
    if (wid == LIONESS_PARENT_WID) return self.parent.windowNumber;
    return self.windows[@(wid)].windowNumber;
}

// Off the screen now: AppKit's own -orderOut: only reaches the window server with its next display cycle.
- (void)dismiss:(NSPanel *)panel {
    if (!panel) return;
    if (panel.windowNumber > 0) SLSOrderWindow(SLSMainConnectionID(), (int)panel.windowNumber, 0, 0);
    [panel orderOut:nil];
}

- (void)play:(NSDictionary *)op {
    NSString *kind = op[@"op"];
    int wid = [op[@"wid"] intValue];
    NSWindow *sheet = self.sheet;
    NSPanel *panel = self.windows[@(wid)];

    if ([kind isEqualToString:@"warp"]) {
        NSWindow *target = (wid == LIONESS_SHEET_WID) ? sheet : panel;
        if (!target || target.windowNumber <= 0) return;
        int w = [op[@"w"] intValue], h = [op[@"h"] intValue];
        NSData *mesh = op[@"mesh"];
        if (w <= 0 || h <= 0 || mesh.length < (NSUInteger)w * h * 4 * sizeof(float)) {
            if (wid != LIONESS_SHEET_WID || !self.closing) Unwarp(target);   // closing sheet stays rolled up until AppKit takes it away
            return;
        }
        // macOS 27's SkyLight extrapolates the first quad for local.y < row0.local_y instead of clipping to the mesh.
        // Prepending a row at local.y = 0 with row 0's global position collapses the unrevealed top strip to a 0-height
        // line at the slit, clipping it atomically for both local windows and remote ViewBridge Save/Open panels.
        const float *src = (const float *)mesh.bytes;
        BOOL prependClip = (wid == LIONESS_SHEET_WID && w >= 2 && h >= 2 && src[1] > 0.5f);
        int outH = h + (prependClip ? 1 : 0);
        NSMutableData *moved = [NSMutableData dataWithLength:(NSUInteger)w * outH * 4 * sizeof(float)];
        float *v = (float *)moved.mutableBytes;
        int dstRow = 0;
        if (prependClip) {
            for (int x = 0; x < w; x++) {
                v[x * 4 + 0] = src[x * 4 + 0];
                v[x * 4 + 1] = 0.0f;
                v[x * 4 + 2] = src[x * 4 + 2] + (float)self.origin.x;
                v[x * 4 + 3] = src[x * 4 + 3] + (float)self.origin.y;
            }
            dstRow = 1;
        }
        for (int i = 0; i < w * h; i++) {   // {local x, local y, global x, global y}
            int d = dstRow * w + i;
            v[d * 4 + 0] = src[i * 4 + 0];
            v[d * 4 + 1] = src[i * 4 + 1];
            v[d * 4 + 2] = src[i * 4 + 2] + (float)self.origin.x;
            v[d * 4 + 3] = src[i * 4 + 3] + (float)self.origin.y;
        }
        SLSSetWindowWarp(SLSMainConnectionID(), (int)target.windowNumber, w, outH, (const float *)moved.bytes);
    } else if ([kind isEqualToString:@"new"]) {
        NSPanel *p = [[NSPanel alloc] initWithContentRect:[self appKitRectFor:op]
                                                styleMask:NSWindowStyleMaskBorderless | NSWindowStyleMaskNonactivatingPanel
                                                  backing:NSBackingStoreBuffered defer:NO];
        p.opaque = NO;
        p.backgroundColor = NSColor.clearColor;
        p.hasShadow = NO;
        p.ignoresMouseEvents = YES;
        p.animationBehavior = NSWindowAnimationBehaviorNone;
        p.releasedWhenClosed = NO;
        p.level = sheet.level;
        p.alphaValue = 0.0;
        p.contentView.wantsLayer = YES;
        p.contentView.layer.contentsGravity = kCAGravityResize;
        self.windows[@(wid)] = p;
    } else if ([kind isEqualToString:@"shape"]) {
        NSRect r = [self appKitRectFor:op];
        if (!NSEqualRects(panel.frame, r)) [panel setFrame:r display:NO];
    } else if ([kind isEqualToString:@"move"]) {
        NSRect f = panel.frame;
        CGRect r = CGRectMake([op[@"x"] doubleValue] + self.origin.x, [op[@"y"] doubleValue] + self.origin.y, f.size.width, f.size.height);
        NSPoint o = AppKitRect(r).origin;
        if (!NSEqualPoints(f.origin, o)) [panel setFrameOrigin:o];
    } else if ([kind isEqualToString:@"alpha"]) {
        double a = [op[@"alpha"] doubleValue];
        if (fabs(panel.alphaValue - a) > 1e-4) panel.alphaValue = a;
    } else if ([kind isEqualToString:@"order"]) {
        if (!panel) return;   // the sheet and its parent are AppKit's to order
        int mode = [op[@"mode"] intValue];
        if (mode == 0) { [panel orderOut:nil]; [self.ordered removeObject:@(wid)]; return; }
        if ([self.ordered containsObject:@(wid)]) return;
        int relWid = [op[@"relative"] intValue];
        NSWindowOrderingMode orderMode = mode < 0 ? NSWindowBelow : NSWindowAbove;
        NSInteger relative = [self windowNumberFor:relWid];
        // Ordering an NSPanel above parent puts it in front of the attached sheet; place it below the sheet instead.
        if (relWid == LIONESS_PARENT_WID && sheet.windowNumber > 0) {
            orderMode = NSWindowBelow;
            relative = sheet.windowNumber;
        } else if (relative <= 0) {
            relative = sheet.windowNumber;
        }
        [panel orderWindow:orderMode relativeTo:relative];
        [self.ordered addObject:@(wid)];
        [CATransaction flush];   // commit initial placement before any warp lands on this panel
    } else if ([kind isEqualToString:@"image"]) {
        NSData *pixels = op[@"pixels"];
        size_t pw = [op[@"pw"] unsignedLongValue], ph = [op[@"ph"] unsignedLongValue];
        if (!panel || !pw || !ph || pixels.length < pw * ph * 4) return;
        if ([self.lastPixels[@(wid)] isEqualToData:pixels]) return;
        self.lastPixels[@(wid)] = pixels;
        CGDataProviderRef provider = CGDataProviderCreateWithCFData((__bridge CFDataRef)pixels);
        CGColorSpaceRef space = CGColorSpaceCreateDeviceRGB();
        CGImageRef image = CGImageCreate(pw, ph, 8, 32, pw * 4, space, (CGBitmapInfo)kCGImageAlphaPremultipliedFirst | kCGBitmapByteOrder32Little,
                                         provider, NULL, false, kCGRenderingIntentDefault);
        CGColorSpaceRelease(space);
        CGDataProviderRelease(provider);
        [CATransaction begin];
        [CATransaction setDisableActions:YES];
        panel.contentView.layer.contents = (__bridge id)image;
        [CATransaction commit];
        CGImageRelease(image);
    } else if ([kind isEqualToString:@"release"]) {
        [self dismiss:panel];
        [self.windows removeObjectForKey:@(wid)];
        [self.lastPixels removeObjectForKey:@(wid)];
        [self.ordered removeObject:@(wid)];
    }
}

// Every frame, each at its time, then the release, on the main run loop: opening on its own timer, closing on AppKit's
// (see HookClose).
- (void)startClock {
    if (self.windows) return;
    self.windows = [NSMutableDictionary dictionary];
    self.lastPixels = [NSMutableDictionary dictionary];
    self.ordered = [NSMutableSet set];
    if (!self.closing && self.sheet) {
        CGRect sheetServer = ServerRect(self.sheet.frame);
        self.origin = sheetServer.origin;
        // Remote sheets (Save/Open panels) may resize to their expanded frame just before coming onscreen.
        if (self.parent && (fabs(sheetServer.size.width - self.size.width) > 1.0 || fabs(sheetServer.size.height - self.size.height) > 1.0)) {
            CGRect parentRelative = CGRectOffset(ServerRect(self.parent.frame), -sheetServer.origin.x, -sheetServer.origin.y);
            if (NSArray *refreshed = FramesFor(sheetServer.size, parentRelative, false)) {
                self.frames = refreshed;
                self.size = sheetServer.size;
                self.duration = SheetDuration(self.sheet);
            }
        }
    }
    self.start = CACurrentMediaTime();
}

- (void)runThen:(void (^)(void))done {
    self.done = done;
    self.queued = CACurrentMediaTime();
    __weak typeof(self) ws = self;
    self.timer = [NSTimer timerWithTimeInterval:1.0 / 120.0 repeats:YES block:^(NSTimer *t) {
        LionessSheetEffect *e = ws;
        if (!e) { [t invalidate]; return; }
        [e advance];
    }];
    [[NSRunLoop mainRunLoop] addTimer:self.timer forMode:NSRunLoopCommonModes];
}

- (void)advance {
    // Remote sheets (Save/Open panels) can order in after -openSheet returns; wait until the window is on screen.
    if (!self.windows && !self.closing && !OnScreen(self.sheet)) {
        if (CACurrentMediaTime() - self.queued < 1.5) return;
    }
    [self startClock];
    NSInteger due = (NSInteger)floor((CACurrentMediaTime() - self.start) / self.duration * kFrames) + 1;
    if (!self.sheet.sheetParent && !self.closing) due = kFrames;   // taken away while still opening
    [self playTo:MIN(due, (NSInteger)kFrames)];
    if (self.applied >= kFrames && self.timer) [self finish];
}

- (void)playTo:(NSInteger)frame {
    while (self.applied < frame && self.applied < (NSInteger)self.frames.count) {
        for (NSDictionary *op in self.frames[self.applied]) [self play:op];
        self.applied++;
    }
}

// To the end at once, from the timer or because AppKit needs the sheet settled now.
- (void)finish {
    if (self.finished) return;
    self.finished = YES;
    [self startClock];
    [self.timer invalidate];
    self.timer = nil;
    [self playTo:(NSInteger)self.frames.count];
    for (NSPanel *panel in self.windows.allValues) [self dismiss:panel];
    [self.windows removeAllObjects];
    void (^done)(void) = self.done;
    self.done = nil;
    if (done) done();
}

@end

static NSWindow *WindowIvar(id object, const char *name) {
    Ivar ivar = class_getInstanceVariable(object_getClass(object), name);
    return ivar ? object_getIvar(object, ivar) : nil;
}

static BOOL gEnabled;
static BOOL gForceSkip;   // while -openSheet runs with the effect in AppKit's place
static BOOL gForceAnimate;

static BOOL Wanted(NSWindow *sheet) {
    return gEnabled && sheet && !NSWorkspace.sharedWorkspace.accessibilityDisplayShouldReduceMotion && LionessIsReachable();
}

static LionessSheetEffect *EffectFor(NSWindow *sheet, NSWindow *parent, bool closing) {
    if (!sheet || !parent || sheet.windowNumber <= 0) return nil;
    NSRect frame = sheet.frame;
    if (frame.size.width < 1 || frame.size.height < 1) return nil;
    CGRect sheetServer = ServerRect(frame), parentServer = ServerRect(parent.frame);
    CGRect parentRelative = CGRectOffset(parentServer, -sheetServer.origin.x, -sheetServer.origin.y);
    NSArray *frames = FramesFor(sheetServer.size, parentRelative, closing);
    if (!frames) return nil;
    LionessSheetEffect *effect = [LionessSheetEffect new];
    effect.sheet = sheet;
    effect.parent = parent;
    effect.origin = sheetServer.origin;
    effect.size = sheetServer.size;
    effect.frames = frames;
    effect.duration = SheetDuration(sheet);
    effect.closing = closing;
    return effect;
}

static BOOL (*gOrigSkip)(id, SEL);
static BOOL HookSkip(id self, SEL _cmd) {
    if (gForceAnimate) return NO;
    return gForceSkip || gOrigSkip(self, _cmd);
}

static const void *kEffectKey = &kEffectKey;

static LionessSheetEffect *RunningEffect(id helper) { return objc_getAssociatedObject(helper, kEffectKey); }

// Straightened once it is off screen, so the window is whole if it is shown again some other way.
static void UnwarpWhenGone(NSWindow *sheet) {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.1 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (!OnScreen(sheet)) Unwarp(sheet);
    });
}

static void (*gOrigOpen)(id, SEL);
static void (*gOrigClose)(id, SEL);

// Every sheet goes in through here: -[NSWindow(NSSheets) _orderFrontRelativeToWindow:] calls -openSheet. Save and Open
// panels, alerts and -beginSheet: alike. Out through -closeSheet.
static void HookOpen(id self, SEL _cmd) {
    [RunningEffect(self) finish];   // still rolling away from last time: done with that first
    NSWindow *sheet = WindowIvar(self, "_sheet");
    if (!Wanted(sheet)) { gOrigOpen(self, _cmd); return; }

    // Rolled up before AppKit shows it, so it never appears whole before the effect starts.
    NSWindow *parent = WindowIvar(self, "_sheetParent") ?: sheet.sheetParent;
    NSSize size = sheet.frame.size;
    if (parent) Collapse(sheet, ServerRect(NSMakeRect(NSMidX(parent.frame) - size.width / 2, NSMaxY(parent.contentLayoutRect) + parent.frame.origin.y - size.height,
                                                      size.width, size.height)));
    BOOL saved = gForceSkip;
    gForceSkip = YES;
    gOrigOpen(self, _cmd);
    gForceSkip = saved;

    // Now in place, under the parent's toolbar.
    parent = WindowIvar(self, "_sheetParent") ?: sheet.sheetParent;
    LionessSheetEffect *effect = EffectFor(sheet, parent, false);
    if (!effect) { Unwarp(sheet); return; }
    Collapse(sheet, ServerRect(sheet.frame));
    objc_setAssociatedObject(self, kEffectKey, effect, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    __weak id helper = self;
    [effect runThen:^{
        Unwarp(sheet);
        if (helper && RunningEffect(helper) == effect) objc_setAssociatedObject(helper, kEffectKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }];
}

// Closing has to go through AppKit's animation: only while that runs does AppKit leave the sheet on screen after
// -closeSheet, and its end is where AppKit takes it away. Its steps are replaced by the effect's frames; the transform
// AppKit gives the sheet as it sets up is the open sheet's, and a warp takes precedence over it.
static void HookClose(id self, SEL _cmd) {
    [RunningEffect(self) finish];   // still unrolling: open first
    NSWindow *sheet = WindowIvar(self, "_sheet");
    NSWindow *parent = WindowIvar(self, "_sheetParent") ?: sheet.sheetParent;
    LionessSheetEffect *effect = (Wanted(sheet) && OnScreen(sheet)) ? EffectFor(sheet, parent, true) : nil;
    if (!effect) { gOrigClose(self, _cmd); return; }

    objc_setAssociatedObject(self, kEffectKey, effect, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    BOOL saved = gForceAnimate;
    gForceAnimate = YES;
    gOrigClose(self, _cmd);
    gForceAnimate = saved;
}

static LionessSheetEffect *ClosingEffect(id helper) {
    LionessSheetEffect *effect = RunningEffect(helper);
    return effect.closing ? effect : nil;
}

static double (*gOrigDuration)(id, SEL);
static double HookDuration(id self, SEL _cmd) {
    LionessSheetEffect *effect = ClosingEffect(self);
    return effect ? effect.duration : gOrigDuration(self, _cmd);
}

static void (*gOrigStep)(id, SEL, double);
static void HookStep(id self, SEL _cmd, double progress) {
    LionessSheetEffect *effect = ClosingEffect(self);
    if (!effect) { gOrigStep(self, _cmd, progress); return; }
    [effect advance];
}

static void (*gOrigCleanUp)(id, SEL);
static void HookCleanUp(id self, SEL _cmd) {
    LionessSheetEffect *effect = ClosingEffect(self);
    if (!effect) { gOrigCleanUp(self, _cmd); return; }
    [effect finish];
    NSWindow *sheet = effect.sheet;
    Collapse(sheet, ServerRect(sheet.frame));   // rolled away; AppKit takes it off screen from here
    objc_setAssociatedObject(self, kEffectKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    gOrigCleanUp(self, _cmd);
    UnwarpWhenGone(sheet);
}

template <typename F>
static void Hook(Class cls, const char *name, F replacement, F *original) {
    Method m = class_getInstanceMethod(cls, sel_registerName(name));
    if (!m) return;
    IMP previous = method_getImplementation(m);
    if (class_addMethod(cls, sel_registerName(name), (IMP)replacement, method_getTypeEncoding(m))) *original = (F)previous;
    else *original = (F)method_setImplementation(m, (IMP)replacement);
}

__attribute__((constructor)) static void LionessSheetsInit(void) {
    // On unless LionessSheetEffect is set to NO.
    id setting = [NSUserDefaults.standardUserDefaults objectForKey:@"LionessSheetEffect"];
    gEnabled = setting ? [setting boolValue] : YES;
    if (!gEnabled) return;
    Class helper = objc_getClass("NSSheetMoveHelper");
    if (!helper) return;
    Hook(helper, "shouldSkipAnimation", HookSkip, &gOrigSkip);
    Hook(helper, "openSheet", HookOpen, &gOrigOpen);
    Hook(helper, "closeSheet", HookClose, &gOrigClose);
    Hook(helper, "animationDuration", HookDuration, &gOrigDuration);
    Hook(helper, "animateStep:", HookStep, &gOrigStep);
    Hook(helper, "cleanUpAnimation", HookCleanUp, &gOrigCleanUp);
}

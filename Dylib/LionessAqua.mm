// Loaded into a modern AppKit app, this replaces AppKit's control drawing with Lion Aqua, drawn by Lion's
// own HIToolbox in appkitd. From tracing AppKit on macOS 27:
//
//  - +[_NSSwiftUICoreFeatureFlags isSolariumEnabled] decides everything else. While it is YES an NSButton
//    is a SwiftUI view that never reaches any cell or CoreUI drawing call. AppKit asks once and keeps
//    the answer, during NSAppearance setup, which is after this dylib's constructor.
//  - With it NO, AppKit gets its control pixels from NSAppearance, passing the same option dictionaries
//    CoreUI takes: -_createOrUpdateLayer:options: for layer-backed controls, and
//    -_drawInRect:context:options: for the ones drawn directly. Those are what is replaced here.
//
// A widget with no Lion mapping, or any request appkitd cannot answer, keeps AppKit's own drawing.
//
// Load it with DYLD_INSERT_LIBRARIES, or through Ammonia (LoadFunction). LIONESS_TRACE=1 logs each request.

#import <AppKit/AppKit.h>
#import <QuartzCore/QuartzCore.h>
#include "../Client/LionessClient.h"
#include <dobby.h>
#include <dlfcn.h>
#include <objc/message.h>
#include <objc/Runtime.h>
#include <os/log.h>
#include <stdio.h>
#include <stdlib.h>

static bool gTrace;
static bool gForceActive;   // for testing a window that can never become key
static bool gDump;          // LIONESS_DUMP=1: every request AppKit makes, on stderr, for finding what to map
#define TRACE(...) do { if (gTrace) os_log(OS_LOG_DEFAULT, "Lioness: " __VA_ARGS__); } while (0)

static void Dump(const char *entry, CGSize size, NSDictionary *options) {
    if (!gDump) return;
    fprintf(stderr, "REQ %s %.0fx%.0f %s\n", entry, size.width, size.height,
            [[options.description componentsSeparatedByCharactersInSet:NSCharacterSet.newlineCharacterSet] componentsJoinedByString:@" "].UTF8String);
}

// Modern names for widgets Lion knows by another.
static NSString *LionWidget(NSString *widget) {
    static NSDictionary<NSString *, NSString *> *names;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        names = [@{
            @"kCUIWidgetButtonSegmentedSliderToolbar": @"kCUIWidgetButtonSegmentedTextured",
            @"kCUIWidgetSliderModernToolbar":        @"slider",
            @"kCUIWidgetSliderThumbModernToolbar":   @"kCUIWidgetSliderThumb",
            @"kCUIWidgetButtonSegmentedToolbar":     @"kCUIWidgetButtonSegmentedTextured",
            @"kCUIWidgetButtonSegmentedSeparatedToolbar": @"kCUIWidgetButtonSegmentedTextured",
            @"kCUIWidgetButtonPopDownToolbar":       @"kCUIWidgetButtonPopDownTextured",
            @"kCUIWidgetButtonPopUpToolbar":         @"kCUIWidgetButtonPopUpTextured",
            @"kCUIWidgetTitleBarFullScreenEnter":    @"titlebarzoom",
            @"kCUIWidgetTitleBarFullScreenExit":     @"titlebarzoom",
            @"kCUIWidgetSliderModern":               @"slider",
            @"kCUIWidgetSliderThumbModern":          @"kCUIWidgetSliderThumb",
            @"kCUIWidgetTickMarkModern":             @"tickmark",
            @"kCUIWidgetButtonSegmentedSlider":      @"segmentedbutton",
            @"kCUIWidgetButtonSegmentedSmallSquare": @"segmentedbutton",
        } retain];
    });
    return names[widget] ?: widget;
}

// Lion only had blue and graphite. The modern Graphite accent still writes the same preference Lion read. Read once, so changing it
// takes a relaunch of the app.
static bool IsGraphite(void) {
    static bool graphite = [NSUserDefaults.standardUserDefaults integerForKey:@"AppleAquaColorVariant"] == 6;
    return graphite;
}

// What goes to Lion: AppKit's options, with what only makes sense on this side changed. Our bitmap is never
// flipped; a caller that is gets the picture flipped when it is drawn.
static NSDictionary *LionOptions(NSDictionary *options, bool isDefault) {
    NSMutableDictionary *o = [[options mutableCopy] autorelease];
    o[@"is.flipped"] = @NO;
    o[@"widget"] = LionWidget(options[@"widget"]);
    if (IsGraphite()) o[@"lioness.graphite"] = @YES;
    if (gForceActive) {
        if ([o[@"state"] isEqual:@"inactive"]) o[@"state"] = @"normal";
        if (o[@"kCUIPresentationStateKey"]) o[@"kCUIPresentationStateKey"] = @"kCUIPresentationStateActiveKey";
    }
    if (!o[@"state"]) o[@"state"] = @"normal";
    // Lion's splitter has a dimple; the rod is newer.
    if ([o[@"kCUIVariantKey"] hasPrefix:@"kCUIVariantDividerSplitterRod"]) o[@"kCUIVariantKey"] = @"kCUIVariantDividerSplitterDimple";
    if ([options[@"widget"] isEqual:@"listheader"]) [o removeObjectForKey:@"kCUIVariantKey"];
    // Lion has no such variant, and without it a toolbar search field draws as a square field.
    if ([o[@"kCUIVariantKey"] isEqual:@"kCUIVariantTextFieldRoundToolbar"]) {
        o[@"widget"] = @"textfieldround";
        [o removeObjectForKey:@"kCUIVariantKey"];
    }
    if (isDefault && [o[@"state"] isEqual:@"normal"] && ![o[@"kCUIPresentationStateKey"] isEqual:@"kCUIPresentationStateInactive"]) {
        o[@"state"] = @"pulsed";   // how Lion's NSButtonCell asks for the blue button (_kCUIStatePulsed)
        o[@"animationframe"] = @0;
    }
    return o;
}

static uint32_t ScaleOf(NSDictionary *options, CGFloat fallback) {
    double scale = [options[@"kCUIScaleKey"] doubleValue];
    if (scale < 1) scale = fallback;
    uint32_t s = (uint32_t)lround(scale);
    return s < 1 ? 1 : s > LIONESS_MAX_SCALE ? LIONESS_MAX_SCALE : s;
}

// Widgets with no counterpart in Lion, where Lion's answer is that the layer is empty.
static bool IsEmptyInLion(NSString *widget) {
    return [widget isEqual:@"kCUIWidgetVisualEffectView"] || [widget isEqual:@"kCUIWidgetWindowTitleBarSeparator"];
}

// The options do not say whether a push button is the default one, so that comes from the view.
static bool IsDefaultButton(CALayer *layer) {
    id delegate = layer.delegate;
    if (![delegate isKindOfClass:NSView.class]) return false;
    for (NSView *view = delegate; view; view = view.superview) {
        if (![view isKindOfClass:NSButton.class]) continue;
        NSButton *button = (NSButton *)view;
        return [button.keyEquivalent isEqualToString:@"\r"] || (button.window && button.window.defaultButtonCell == button.cell);
    }
    return false;
}

// Lion's bitmap on a canvas the size of the layer, with the control centred in it.
static CGImageRef CreateLayerContents(CGImageRef lion, CGSize canvas, uint32_t scale) {
    size_t width = (size_t)ceil(canvas.width * scale), height = (size_t)ceil(canvas.height * scale);
    if (!width || !height) return NULL;
    CGColorSpaceRef space = CGColorSpaceCreateDeviceRGB();
    CGContextRef cg = CGBitmapContextCreate(NULL, width, height, 8, 0, space, kCGImageAlphaPremultipliedFirst | kCGBitmapByteOrder32Little);
    CGColorSpaceRelease(space);
    if (!cg) return NULL;
    CGFloat w = CGImageGetWidth(lion), h = CGImageGetHeight(lion);
    CGContextDrawImage(cg, CGRectMake(floor(((CGFloat)width - w) / 2), floor(((CGFloat)height - h) / 2), w, h), lion);
    CGImageRef image = CGBitmapContextCreateImage(cg);
    CGContextRelease(cg);
    return image;
}

static void SetContents(CALayer *layer, CGImageRef contents, uint32_t scale, CGRect center) {
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    layer.contents = (__bridge id)contents;
    layer.contentsScale = scale;
    layer.contentsGravity = kCAGravityResize;
    layer.backgroundColor = NULL;
    layer.contentsCenter = center;
    layer.contentsRect = CGRectMake(0, 0, 1, 1);   // AppKit animates some of these as a sprite sheet
    [CATransaction commit];
}

static BOOL (*gOrigLayer)(id, SEL, id *, NSDictionary *);

static const void *const kOptionsKey = &kOptionsKey;

// Below 26 points the end caps of Lion's textured art collide, leaving dark ticks top and bottom. So it is
// drawn wider, and the middle taken out.
static CGImageRef CopyLionArt(NSDictionary *options, uint32_t width, uint32_t height, uint32_t scale) {
    if (width >= 26 || ![options[@"widget"] containsString:@"Textured"]) return LionessCopyDrawnImage((__bridge CFDictionaryRef)options, width, height, scale);
    CGImageRef wide = LionessCopyDrawnImage((__bridge CFDictionaryRef)options, 40, height, scale);
    if (!wide) return NULL;
    size_t w = (width + 2 * LIONESS_PADDING) * scale, h = CGImageGetHeight(wide), wideWidth = CGImageGetWidth(wide);
    CGColorSpaceRef space = CGColorSpaceCreateDeviceRGB();
    CGContextRef cg = CGBitmapContextCreate(NULL, w, h, 8, 0, space, kCGImageAlphaPremultipliedFirst | kCGBitmapByteOrder32Little);
    CGColorSpaceRelease(space);
    if (!cg) { CGImageRelease(wide); return NULL; }
    CGContextSaveGState(cg);
    CGContextClipToRect(cg, CGRectMake(0, 0, w / 2, h));
    CGContextDrawImage(cg, CGRectMake(0, 0, wideWidth, h), wide);
    CGContextRestoreGState(cg);
    CGContextClipToRect(cg, CGRectMake(w / 2, 0, w - w / 2, h));
    CGContextDrawImage(cg, CGRectMake((CGFloat)w - wideWidth, 0, wideWidth, h), wide);
    CGImageRef image = CGBitmapContextCreateImage(cg);
    CGContextRelease(cg);
    CGImageRelease(wide);
    return image;
}

// The window. Two layers ask for kCUIWidgetWindowFrame. The top-bar one sits above the traffic lights and the
// title, as a light overlay, so it goes empty. The other is the window's whole background, which gets Lion's
// window colour. Lion's title bar itself goes on NSTitlebarBackgroundView, which is beneath the lights and
// the title and resizes with the bar (UpdateTitlebarBackground).
static BOOL ApplyWindowFrame(CALayer *layer, NSDictionary *options, BOOL result) {
    for (CALayer *sub in layer.sublayers) sub.hidden = YES;
    layer.contents = nil;
    layer.backgroundColor = [options[@"kCUIWindowFrameTopBarOnlyKey"] boolValue] ? NULL : [NSColor colorWithSRGBRed:0.929 green:0.929 blue:0.929 alpha:1].CGColor;
    return YES;
}

static void UpdateTitlebarLine(NSView *view);

// Lion's bar art is 22 points high and speckled. Stretching it for a toolbar would smear the speckle into streaks, or lose it. So it is pulled apart: each row's
// average is the gradient, which stretches to the bar's height, and what is left over in a block of the art is the speckle, which tiles at its own size.
// Wide enough for any window, shared between windows, and anchored rather than scaled.
static constexpr uint32_t kBarWidthPoints = 2500;
static CGImageRef CreateSpeckledBar(CGImageRef art, uint32_t artPoints, uint32_t artHeight, uint32_t height, uint32_t scale) {
    size_t artWidth = CGImageGetWidth(art), artRows = CGImageGetHeight(art);
    uint8_t *source = (uint8_t *)malloc(artWidth * artRows * 4);
    if (!source) return NULL;
    CGColorSpaceRef space = CGColorSpaceCreateDeviceRGB();
    CGContextRef in = CGBitmapContextCreate(source, artWidth, artRows, 8, artWidth * 4, space, kCGImageAlphaPremultipliedFirst | kCGBitmapByteOrder32Little);
    CGContextDrawImage(in, CGRectMake(0, 0, artWidth, artRows), art);   // row 0 of this memory is the art's top
    CGContextRelease(in);
    size_t rows = artHeight * scale, firstRow = LIONESS_PADDING * scale, tile = 64 * scale, firstColumn = (artWidth - tile) / 2;
    size_t width = kBarWidthPoints * scale, high = height * scale;
    uint8_t *out = (uint8_t *)malloc(width * high * 4);
    float *mean = (float *)calloc(rows * 3, sizeof(float));
    if (!out || !mean) { free(source); free(out); free(mean); CGColorSpaceRelease(space); return NULL; }
    for (size_t y = 0; y < rows; y++)
        for (size_t x = 0; x < tile; x++)
            for (int c = 0; c < 3; c++) mean[y * 3 + c] += source[((firstRow + y) * artWidth + firstColumn + x) * 4 + c] / (float)tile;
    for (size_t y = 0; y < high; y++) {
        float at = high > 1 ? (float)y * (rows - 1) / (high - 1) : 0;
        size_t low = (size_t)at, up = MIN(low + 1, rows - 1);
        float mix = at - low;
        size_t tileRow = y % rows;
        for (size_t x = 0; x < width; x++) {
            size_t tileColumn = x % tile;
            const uint8_t *p = source + ((firstRow + tileRow) * artWidth + firstColumn + tileColumn) * 4;
            uint8_t *q = out + (y * width + x) * 4;
            for (int c = 0; c < 3; c++) {
                float gradient = mean[low * 3 + c] * (1 - mix) + mean[up * 3 + c] * mix;
                float value = gradient + (p[c] - mean[tileRow * 3 + c]);
                q[c] = (uint8_t)(value < 0 ? 0 : value > 255 ? 255 : value);
            }
            q[3] = 255;
        }
    }
    free(source);
    free(mean);
    CGContextRef result = CGBitmapContextCreate(out, width, high, 8, width * 4, space, kCGImageAlphaPremultipliedFirst | kCGBitmapByteOrder32Little);
    CGColorSpaceRelease(space);
    CGImageRef image = result ? CGBitmapContextCreateImage(result) : NULL;
    if (result) CGContextRelease(result);
    free(out);
    return image;
}

static void UpdateTitlebarBackground(NSView *view) {
    CALayer *layer = view.layer;
    NSWindow *window = view.window;
    if (!layer || !window) return;
    if (window.titlebarAppearsTransparent) { layer.contents = nil; return; }   // the app draws there itself
    LionessRequest r = {};
    r.kind = LionessWindowFrame;
    r.state = gForceActive || window.isKeyWindow || window.isMainWindow ? LionessStateActive : LionessStateInactive;
    r.width = 400;   // wide, because the left has Lion's empty widget wells: the centred crop misses them
    r.height = 22;   // Lion's art is this height whatever is asked for; taller bars stretch it (see below)
    r.scale = ScaleOf(@{}, window.backingScaleFactor);
    CGImageRef bar = LionessCopyCachedImage(&r, NULL);
    if (!bar) return;
    uint32_t height = (uint32_t)ceil(layer.bounds.size.height);
    if (!height || height > 400) return;
    static NSMutableDictionary *bars = [NSMutableDictionary new];
    NSString *key = [NSString stringWithFormat:@"%u %u %u", height, r.scale, r.state];
    id contents = bars[key];
    if (!contents) {
        CGImageRef built = CreateSpeckledBar(bar, r.width, r.height, height, r.scale);
        if (!built) return;
        contents = (__bridge id)built;
        bars[key] = contents;
        CGImageRelease(built);
    }
    for (CALayer *sub in layer.sublayers) sub.hidden = YES;   // the NSVisualEffectView
    // NSTitlebarView has a live blur of its own, beside this view, for content scrolling under the bar.
    for (CALayer *sub in layer.superlayer.sublayers) if ([NSStringFromClass(sub.class) containsString:@"Backdrop"]) sub.hidden = YES;
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    layer.contents = contents;
    layer.contentsScale = r.scale;
    layer.contentsGravity = kCAGravityTopLeft;
    layer.contentsCenter = CGRectMake(0, 0, 1, 1);
    layer.contentsRect = CGRectMake(0, 0, 1, 1);
    layer.backgroundColor = NULL;
    layer.masksToBounds = YES;
    [CATransaction commit];
    UpdateTitlebarLine(view);
}

// Bars at the foot of a split view item, such as Finder's path and status bars. Each sits in its own accessory clip
// view, and their material is an NSVisualEffectView, which is empty here: without this the rows scroll visibly
// underneath them. Accessories at the top are left alone, as Lion's bottom bar would be wrong there.
static const void *const kBottomBarKey = &kBottomBarKey;
// One colour out of a Lion picture, at a height from the top of the art, so lines match it. Results are kept: art does not change.
static NSColor *SampleLion(NSDictionary *options, uint32_t height, uint32_t fromTop) {
    static NSMutableDictionary *cache = [NSMutableDictionary new];
    NSString *key = [NSString stringWithFormat:@"%@ %u", options, fromTop];
    if (NSColor *known = cache[key]) return known;
    CGImageRef lion = LionessCopyDrawnImage((__bridge CFDictionaryRef)options, 64, height, 2);
    if (!lion) return nil;
    uint8_t pixel[4] = {};
    CGColorSpaceRef space = CGColorSpaceCreateDeviceRGB();
    CGContextRef one = CGBitmapContextCreate(pixel, 1, 1, 8, 4, space, kCGImageAlphaPremultipliedLast);
    CGColorSpaceRelease(space);
    CGFloat w = CGImageGetWidth(lion), h = CGImageGetHeight(lion);
    // The picture has LIONESS_PADDING points round it, at 2x. A 1x1 context shows the pixel placed at its origin.
    CGContextDrawImage(one, CGRectMake(-w / 2, -(h - 2.0 * LIONESS_PADDING - 2.0 * fromTop - 1), w, h), lion);
    CGContextRelease(one);
    CGImageRelease(lion);
    NSColor *color = [NSColor colorWithSRGBRed:pixel[0] / 255.0 green:pixel[1] / 255.0 blue:pixel[2] / 255.0 alpha:1];
    cache[key] = color;
    return color;
}
static NSDictionary *BottomBarOptions(bool active) {
    return active ? @{ @"widget": @"kCUIWidgetWindowBottomBar", @"state": @"normal", @"kCUIPresentationStateKey": @"kCUIPresentationStateActiveKey" }
                  : @{ @"widget": @"kCUIWidgetWindowBottomBar", @"state": @"inactive", @"kCUIPresentationStateKey": @"kCUIPresentationStateInactive" };
}
// Lion's divider colour: the dark line along the top of its own bottom bar art.
static NSColor *DividerColor(bool active) { return SampleLion(BottomBarOptions(active), 22, 0); }
static NSColor *SidebarColor(bool active) {
    NSMutableDictionary *o = [NSMutableDictionary dictionaryWithObjectsAndKeys:@"gradient", @"widget", @"kCUIVariantGradientSideBar", @"kCUIVariantKey", @"normal", @"state", nil];
    if (!active) o[@"kCUIPresentationStateKey"] = @"kCUIPresentationStateInactive";
    if (IsGraphite()) o[@"lioness.graphite"] = @YES;
    return SampleLion(o, 22, 10);
}

// Mountain Lion has no kCUIWidgetDividerSidebar. The layer AppKit asks for covers the gap between the sidebar and the content, so it gets
// the sidebar's colour with Lion's one-point line on the content side.
static NSHashTable *gSidebarDividers;
static bool WindowIsActive(NSWindow *window) { return gForceActive || window.isKeyWindow || window.isMainWindow; }
static void PaintSidebarDivider(CALayer *layer, bool rightToLeft) {
    id owner = layer.delegate;
    NSWindow *window = [owner isKindOfClass:NSView.class] ? ((NSView *)owner).window : nil;
    bool active = !window || WindowIsActive(window);
    NSColor *line = DividerColor(active), *sidebar = SidebarColor(active);
    if (!line || !sidebar) return;
    uint32_t scale = ScaleOf(@{}, window ? window.backingScaleFactor : layer.contentsScale);
    size_t width = (size_t)ceil(layer.bounds.size.width) * scale;
    if (!width) return;
    CGColorSpaceRef space = CGColorSpaceCreateDeviceRGB();
    CGContextRef cg = CGBitmapContextCreate(NULL, width, 1, 8, 0, space, kCGImageAlphaPremultipliedFirst | kCGBitmapByteOrder32Little);
    CGColorSpaceRelease(space);
    if (!cg) return;
    CGContextSetFillColorWithColor(cg, sidebar.CGColor);
    CGContextFillRect(cg, CGRectMake(0, 0, width, 1));
    CGContextSetFillColorWithColor(cg, line.CGColor);
    CGContextFillRect(cg, CGRectMake(rightToLeft ? 0 : width - scale, 0, scale, 1));
    CGImageRef contents = CGBitmapContextCreateImage(cg);
    CGContextRelease(cg);
    for (CALayer *sub in layer.sublayers) sub.hidden = YES;
    SetContents(layer, contents, scale, CGRectMake(0, 0, 1, 1));
    CGImageRelease(contents);
}

// A full-width line along the foot of the title bar, beneath the sidebar as well. NSTitlebarSeparatorView only spans the content, and
// stretching the bar's art blurs the one that is in it.
static NSString *const kTitlebarLineName = @"lioness.titlebarLine";
static void UpdateTitlebarLine(NSView *view) {
    CALayer *layer = view.layer;
    NSWindow *window = view.window;
    NSColor *color = window ? DividerColor(WindowIsActive(window)) : nil;
    if (!layer || !color) return;
    CALayer *line = nil;
    for (CALayer *sub in layer.sublayers) if ([sub.name isEqual:kTitlebarLineName]) line = sub;
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    if (!line) {
        line = [CALayer layer];
        line.name = kTitlebarLineName;
        [layer addSublayer:line];
    }
    line.hidden = NO;
    line.zPosition = 10;
    line.backgroundColor = color.CGColor;
    CGRect bounds = layer.bounds;
    line.frame = CGRectMake(0, layer.geometryFlipped ? bounds.size.height - 1 : 0, bounds.size.width, 1);
    [CATransaction commit];
}

// The divider beside a sidebar is an NSVibrantSplitDividerView, wider than the gap it sits in, which never asks CoreUI for anything: all
// it shows is its material, which is empty here, as a pale band. It becomes one line in the title bar line's colour, along the sidebar's edge,
// with the sidebar's colour up to it. Sits under the sidebar and over the content, so the rest stays clear.
static NSVisualEffectView *SidebarMaterial(NSView *view) {
    for (NSView *sub in view.subviews)
        if ([sub isKindOfClass:NSVisualEffectView.class] && ((NSVisualEffectView *)sub).material == NSVisualEffectMaterialSidebar) return (NSVisualEffectView *)sub;
    return nil;
}
static const void *const kVibrantDividerKey = &kVibrantDividerKey;
static void UpdateVibrantDivider(NSView *view) {
    NSWindow *window = view.window;
    if (!window || !view.layer) return;
    NSView *sidebar = nil;
    for (NSView *sibling in view.superview.subviews)
        if (sibling != view && SidebarMaterial(sibling)) sidebar = sibling;
    if (!sidebar) return;
    NSRect mine = view.frame, side = sidebar.frame;
    bool sidebarLeft = NSMidX(side) < NSMidX(mine);
    // The content's edge, where the gap ends.
    CGFloat edge = sidebarLeft ? CGFLOAT_MAX : -CGFLOAT_MAX;
    for (NSView *sibling in view.superview.subviews) {
        if (sibling == view || sibling == sidebar) continue;
        if (sidebarLeft && NSMinX(sibling.frame) >= NSMaxX(side) && NSMinX(sibling.frame) < edge) edge = NSMinX(sibling.frame);
        if (!sidebarLeft && NSMaxX(sibling.frame) <= NSMinX(side) && NSMaxX(sibling.frame) > edge) edge = NSMaxX(sibling.frame);
    }
    if (fabs(edge) == CGFLOAT_MAX) edge = sidebarLeft ? NSMaxX(side) + 1 : NSMinX(side) - 1;
    bool active = WindowIsActive(window);
    NSColor *line = DividerColor(active), *fill = SidebarColor(active);
    if (!line || !fill) return;
    uint32_t scale = ScaleOf(@{}, window.backingScaleFactor);
    size_t width = (size_t)ceil(mine.size.width) * scale;
    if (!width) return;
    NSString *drawn = [NSString stringWithFormat:@"%zu %.1f %d %d", width, edge - mine.origin.x, active, sidebarLeft];
    for (CALayer *sub in view.layer.sublayers) sub.hidden = YES;
    if ([objc_getAssociatedObject(view, kVibrantDividerKey) isEqual:drawn] && view.layer.contents) return;
    CGColorSpaceRef space = CGColorSpaceCreateDeviceRGB();
    CGContextRef cg = CGBitmapContextCreate(NULL, width, 1, 8, 0, space, kCGImageAlphaPremultipliedFirst | kCGBitmapByteOrder32Little);
    CGColorSpaceRelease(space);
    if (!cg) return;
    CGFloat at = (edge - mine.origin.x) * scale;   // pixels from the view's left
    CGContextSetFillColorWithColor(cg, fill.CGColor);
    CGContextFillRect(cg, sidebarLeft ? CGRectMake(0, 0, MAX(at - scale, 0), 1) : CGRectMake(at + scale, 0, width, 1));
    CGContextSetFillColorWithColor(cg, line.CGColor);
    CGContextFillRect(cg, CGRectMake(sidebarLeft ? at - scale : at, 0, scale, 1));
    CGImageRef contents = CGBitmapContextCreateImage(cg);
    CGContextRelease(cg);
    SetContents(view.layer, contents, scale, CGRectMake(0, 0, 1, 1));
    CGImageRelease(contents);
    objc_setAssociatedObject(view, kVibrantDividerKey, drawn, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

// SwiftUI toolbar buttons (Font Book, System Settings) are drawn by SwiftUI with no bezel: CoreUI is never asked. Lion's toolbar buttons have one,
// so its textured button goes beneath. Only a host with nothing in it but its focus ring and key proxy is a plain button; a slider or a group has more.
static void UpdateFieldBezel(NSView *field);
static const void *const kToolbarBezelKey = &kToolbarBezelKey;
static void UpdateToolbarBezel(NSView *viewer) {
    NSWindow *window = viewer.window;
    NSView *host = viewer.subviews.firstObject;
    // A plain field used as a search field (Console's token field) draws its own square frame. It goes without, over Lion's round one.
    if ([host isKindOfClass:NSTokenField.class]) {
        NSTextField *field = (NSTextField *)host;
        if (field.bezeled) field.bezeled = NO;
        if (field.bordered) field.bordered = NO;
        if (field.drawsBackground) field.drawsBackground = NO;
        UpdateFieldBezel(field);
        return;
    }
    if (!window || ![NSStringFromClass(host.class) hasPrefix:@"_TtGC7SwiftUI22ToolbarItemHostingView"] || host.subviews.count != 2) return;
    for (NSView *sub in host.subviews) {
        NSString *name = NSStringFromClass(sub.class);
        if (![name containsString:@"FocusRingView"] && ![name containsString:@"KeyViewProxy"]) return;
    }
    NSRect frame = host.frame;
    if (frame.size.width < 16 || frame.size.height < 16) return;
    bool active = WindowIsActive(window);
    uint32_t scale = ScaleOf(@{}, window.backingScaleFactor), width = (uint32_t)ceil(frame.size.width), height = (uint32_t)ceil(frame.size.height);
    CALayer *bezel = objc_getAssociatedObject(viewer, kToolbarBezelKey);
    NSString *drawn = [NSString stringWithFormat:@"%u %u %u %d", width, height, scale, active];
    if (![bezel.name isEqual:drawn]) {
        NSMutableDictionary *o = [NSMutableDictionary dictionaryWithObjectsAndKeys:@"kCUIWidgetButtonPushTextured", @"widget", active ? @"normal" : @"inactive", @"state", @"regular", @"size",
                                  active ? @"kCUIPresentationStateActiveKey" : @"kCUIPresentationStateInactive", @"kCUIPresentationStateKey", nil];
        if (IsGraphite()) o[@"lioness.graphite"] = @YES;
        CGImageRef lion = LionessCopyDrawnImage((__bridge CFDictionaryRef)o, width, height, scale);
        if (!lion) return;
        CGImageRef contents = CreateLayerContents(lion, CGSizeMake(width, height), scale);
        CGImageRelease(lion);
        if (!contents) return;
        if (!bezel) {
            bezel = [CALayer layer];
            viewer.wantsLayer = YES;
            [viewer.layer insertSublayer:bezel atIndex:0];
            objc_setAssociatedObject(viewer, kToolbarBezelKey, bezel, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
        SetContents(bezel, contents, scale, CGRectMake(0, 0, 1, 1));
        CGImageRelease(contents);
        bezel.name = drawn;
    }
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    bezel.frame = [viewer convertRect:host.bounds fromView:host];
    [CATransaction commit];
}

// Safari's address field paints itself, and only ever asks CoreUI for a mask, so unfocused it has no edge at all. Lion's round field goes behind it,
// in its container, where the focus ring it draws still shows over the top.
static const void *const kFieldBezelKey = &kFieldBezelKey;
static void UpdateFieldBezel(NSView *field) {
    NSView *container = field.superview;
    NSWindow *window = field.window;
    if (!window || !container.layer) return;
    NSRect frame = field.frame;
    if (frame.size.width < 40 || frame.size.height < 10) return;
    bool active = WindowIsActive(window);
    uint32_t scale = ScaleOf(@{}, window.backingScaleFactor), width = (uint32_t)ceil(frame.size.width), height = (uint32_t)ceil(frame.size.height);
    CALayer *bezel = objc_getAssociatedObject(field, kFieldBezelKey);
    NSString *drawn = [NSString stringWithFormat:@"%u %u %u %d", width, height, scale, active];
    if (![bezel.name isEqual:drawn]) {
        NSDictionary *o = @{ @"widget": @"textfieldround", @"state": active ? @"normal" : @"inactive", @"size": @"regular",
                             @"kCUIPresentationStateKey": active ? @"kCUIPresentationStateActiveKey" : @"kCUIPresentationStateInactive" };
        CGImageRef lion = LionessCopyDrawnImage((__bridge CFDictionaryRef)o, width, height, scale);
        if (!lion) return;
        CGImageRef contents = CreateLayerContents(lion, CGSizeMake(width, height), scale);
        CGImageRelease(lion);
        if (!contents) return;
        if (!bezel) {
            bezel = [CALayer layer];
            [container.layer insertSublayer:bezel atIndex:0];
            objc_setAssociatedObject(field, kFieldBezelKey, bezel, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
        SetContents(bezel, contents, scale, CGRectMake(0, 0, 1, 1));
        CGImageRelease(contents);
        bezel.name = drawn;
    }
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    bezel.frame = [container convertRect:field.bounds fromView:field];
    [CATransaction commit];
}

static void HideBackdrops(CALayer *layer) {
    for (CALayer *sub in layer.sublayers) {
        if ([NSStringFromClass(sub.class) containsString:@"Backdrop"]) sub.hidden = YES;
        else HideBackdrops(sub);
    }
}
static void UpdateBottomBar(NSView *view) {
    NSWindow *window = view.window;
    if (!window) return;
    NSRect frame = [view convertRect:view.bounds toView:nil];
    bool tabBar = [view isKindOfClass:objc_getClass("NSTabBar")];   // Lion had none. It is a flat live blur otherwise, so it matches the bars.
    if (frame.size.height < 1 || (!tabBar && NSMaxY(frame) > window.frame.size.height / 2)) return;
    if (tabBar) HideBackdrops(view.layer);
    bool active = gForceActive || window.isKeyWindow || window.isMainWindow;
    uint32_t height = (uint32_t)ceil(frame.size.height), scale = ScaleOf(@{}, window.backingScaleFactor);
    NSString *drawn = [NSString stringWithFormat:@"%u %u %d", height, scale, active];
    if ([objc_getAssociatedObject(view, kBottomBarKey) isEqual:drawn]) return;
    NSDictionary *options = @{ @"widget": @"kCUIWidgetWindowBottomBar", @"state": active ? @"normal" : @"inactive",
                               @"kCUIPresentationStateKey": active ? @"kCUIPresentationStateActiveKey" : @"kCUIPresentationStateInactive" };
    CGImageRef lion = LionessCopyDrawnImage((__bridge CFDictionaryRef)options, 64, height, scale);
    if (!lion) return;
    CGImageRef contents = CreateLayerContents(lion, CGSizeMake(64, height), scale);
    CGImageRelease(lion);
    if (!contents) return;
    view.wantsLayer = YES;
    SetContents(view.layer, contents, scale, CGRectMake(0.49, 0, 0.02, 1));   // only its width stretches
    CGImageRelease(contents);
    objc_setAssociatedObject(view, kBottomBarKey, drawn, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    if (gDump) fprintf(stderr, "BOTTOMBAR height=%u active=%d key=%d main=%d\n", height, active, window.isKeyWindow, window.isMainWindow);
}

static void UpdateTitlebarBackgrounds(CALayer *layer) {
    id owner = layer.delegate;
    if ([owner isKindOfClass:objc_getClass("NSTitlebarBackgroundView")]) { UpdateTitlebarBackground(owner); return; }
    for (CALayer *sub in layer.sublayers) UpdateTitlebarBackgrounds(sub);
}

// Lion's frames for a widget, played on the layer: animframe 0, step, 2 step... up to count.
static void AnimateFrames(CALayer *layer, NSDictionary *options, uint32_t width, uint32_t height, uint32_t scale, int count, int step, CFTimeInterval duration) {
    NSMutableArray *frames = [NSMutableArray array];
    for (int i = 0; i < count; i += step) {
        NSMutableDictionary *o = [[LionOptions(options, false) mutableCopy] autorelease];
        o[@"animframe"] = @(i);
        CGImageRef lion = LionessCopyDrawnImage((__bridge CFDictionaryRef)o, width, height, scale);
        if (!lion) return;
        CGImageRef frame = CreateLayerContents(lion, layer.bounds.size, scale);
        CGImageRelease(lion);
        if (!frame) return;
        [frames addObject:(__bridge id)frame];
        CGImageRelease(frame);
    }
    CAKeyframeAnimation *turn = [CAKeyframeAnimation animationWithKeyPath:@"contents"];
    turn.values = frames;
    turn.calculationMode = kCAAnimationDiscrete;
    turn.duration = duration;
    turn.repeatCount = HUGE_VALF;
    [layer removeAllAnimations];
    [layer addAnimation:turn forKey:@"lioness.spinner"];
}

// Lion's picture onto a layer AppKit asked about. `result` is what to answer if there is none.
// Two modern materials are Lion gradients: a list selection, which would otherwise be white text on nothing, and the
// sidebar. AppKit asks CoreUI for these on an inner layer of no size that it never sizes, so the view's own layer takes the
// picture. The selection's blue is the art called FinderSideBar; the art called SideBarSelection is only its grey form, which
// is also what FinderSideBar gives when inactive. Rounded selection masks are modern: Lion's runs edge to edge.
static const void *const kMaterialKey = &kMaterialKey;
static void UpdateMaterial(NSVisualEffectView *view) {
    NSWindow *window = view.window;
    if (!window) return;
    bool selection = view.material == NSVisualEffectMaterialSelection;
    if (!selection && view.material != NSVisualEffectMaterialSidebar) return;
    bool active = gForceActive || window.isKeyWindow || window.isMainWindow;
    if (selection) {
        NSView *parent = view.superview;
        if ([parent isKindOfClass:NSTableRowView.class]) active = gForceActive || ((NSTableRowView *)parent).emphasized;
    }
    uint32_t scale = ScaleOf(@{}, window.backingScaleFactor);
    NSString *drawn = [NSString stringWithFormat:@"%d %d %u", selection, active, scale];
    if ([objc_getAssociatedObject(view, kMaterialKey) isEqual:drawn] && view.layer.contents) return;
    NSMutableDictionary *o = [NSMutableDictionary dictionaryWithObjectsAndKeys:@"gradient", @"widget", selection ? @"variant.gradient.FinderSideBar" : @"kCUIVariantGradientSideBar", @"kCUIVariantKey", @"normal", @"state", nil];
    if (!active) o[@"kCUIPresentationStateKey"] = @"kCUIPresentationStateInactive";
    if (IsGraphite()) o[@"lioness.graphite"] = @YES;
    CGImageRef lion = LionessCopyDrawnImage((__bridge CFDictionaryRef)o, 64, 22, scale);
    if (!lion) return;
    CGImageRef contents = CreateLayerContents(lion, CGSizeMake(64, 22), scale);
    CGImageRelease(lion);
    if (!contents) return;
    if (selection && view.maskImage) view.maskImage = nil;
    view.wantsLayer = YES;
    for (CALayer *sub in view.layer.sublayers) if (![sub.delegate isKindOfClass:NSView.class]) sub.hidden = YES;   // the blur, not any content
    SetContents(view.layer, contents, scale, CGRectMake(0.49, 0, 0.02, 1));
    CGImageRelease(contents);
    objc_setAssociatedObject(view, kMaterialKey, drawn, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

static BOOL ApplyLion(CALayer *layer, NSDictionary *options, BOOL result) {
    NSString *widget = options[@"widget"];
    if ([widget isEqual:@"kCUIWidgetWindowFrame"]) return ApplyWindowFrame(layer, options, result);
    if ([widget isEqual:@"kCUIWidgetDividerSidebar"]) {
        if (!gSidebarDividers) gSidebarDividers = [[NSHashTable weakObjectsHashTable] retain];
        [gSidebarDividers addObject:layer];
        PaintSidebarDivider(layer, [options[@"kCUIUserInterfaceLayoutDirectionKey"] isEqual:@"kCUIUserInterfaceLayoutDirectionRightToLeft"]);
        return YES;
    }
    if (IsEmptyInLion(widget)) {
        for (CALayer *sub in layer.sublayers) sub.hidden = YES;
        layer.contents = nil;
        layer.backgroundColor = NULL;
        return YES;
    }
    CGSize bounds = layer.bounds.size;
    if ((bounds.width < 1 || bounds.height < 1) && [options[@"indiconly"] boolValue] && ([widget isEqual:@"scrollbar"] || [widget isEqual:@"kCUIWidgetOverlayScrollBar"])) {
        // A scroller knob: asked for once on a layer with no size, and AppKit sizes the layer itself as the
        // knob changes. So it is a picture long enough to have its ends, stretched across its middle.
        bool horizontal = [options[@"kCUIOrientationKey"] isEqual:@"kCUIOrientHorizontal"];
        CGFloat thickness = [widget isEqual:@"scrollbar"] ? 15 : 12;   // the layers AppKit ends up with
        bounds = horizontal ? CGSizeMake(64, thickness) : CGSizeMake(thickness, 64);
    }
    if (bounds.width < 1 || bounds.height < 1) return result;   // not laid out yet; AppKit asks again
    bool isDefault = [widget isEqual:@"pushbutton"] && IsDefaultButton(layer);
    uint32_t scale = ScaleOf(options, layer.contentsScale);
    uint32_t width = (uint32_t)ceil(bounds.width), height = (uint32_t)ceil(bounds.height);
    CGImageRef lion = CopyLionArt(LionOptions(options, isDefault), width, height, scale);
    if (!lion) { if (gDump) fprintf(stderr, "NATIVE layer %s\n", widget.UTF8String); return result; }

    // Some of these are trees of AppKit's own layers (the popup's pill and chevron), which would sit on
    // top of Lion's picture.
    for (CALayer *sub in layer.sublayers) sub.hidden = YES;
    CGImageRef contents = CreateLayerContents(lion, bounds, scale);
    CGImageRelease(lion);
    if (!contents) return result;

    if ([widget isEqual:@"widget.progressSpinner"]) AnimateFrames(layer, options, width, height, scale, 12, 1, 1.0);   // 12 frames a second
    if ([widget isEqual:@"kCUIWidgetIndeterminateBar"]) {
        // The barber pole. AppKit's animframe here is only a flag, 1 running and 0 stopped, and it asks again when that changes.
        // Mountain Lion's stripes repeat every 32 points, or 20 at small size, one phase per pixel. A frame per point at 16 points a second.
        int points = [options[@"size"] isEqual:@"small"] ? 20 : 32;
        if ([options[@"animframe"] intValue]) AnimateFrames(layer, options, width, height, scale, points * scale, scale, points / 16.0);
        else [layer removeAllAnimations];
    }

    // Bezels stretch across the middle when the view is resized before AppKit asks again. Art of one size must
    // not: a stretched spinner is two grey bars.
    static NSSet *fixedSize = [[NSSet setWithObjects:@"widget.progressSpinner", @"checkbox", @"radiobutton", @"titlebarclose", @"titlebarcollapse",
                                @"titlebarzoom", @"dial", @"kCUIWidgetDisclosureTriangle", @"kCUIWidgetButtonRoundHelp", @"littlearrows", nil] retain];
    SetContents(layer, contents, scale, [fixedSize containsObject:LionWidget(widget)] ? CGRectMake(0, 0, 1, 1) : CGRectMake(0.49, 0.49, 0.02, 0.02));
    CGImageRelease(contents);
    return YES;
}

static BOOL HookLayer(id self, SEL _cmd, id *layerOut, NSDictionary *options) {
    // AppKit's own result stays underneath: it makes the layer, and it is what shows if Lion cannot answer.
    BOOL result = gOrigLayer(self, _cmd, layerOut, options);
    CALayer *layer = layerOut ? *layerOut : nil;
    if (![layer isKindOfClass:CALayer.class]) return result;
    Dump("layer", layer.bounds.size, options);
    objc_setAssociatedObject(layer, kOptionsKey, options, OBJC_ASSOCIATION_COPY_NONATOMIC);
    return ApplyLion(layer, options, result);
}

static BOOL (*gOrigDraw)(id, SEL, CGRect, CGContextRef, NSDictionary *);

static BOOL HookDraw(id self, SEL _cmd, CGRect frame, CGContextRef cg, NSDictionary *options) {
    Dump("draw", frame.size, options);
    if (!cg || frame.size.width < 1 || frame.size.height < 1) return gOrigDraw(self, _cmd, frame, cg, options);
    CGFloat ctm = fabs(CGContextGetCTM(cg).a);
    uint32_t width = (uint32_t)ceil(frame.size.width), height = (uint32_t)ceil(frame.size.height);
    // Lion's list header art is one height; modern headers are taller. Drawn at Lion's height, then stretched.
    bool header = [options[@"widget"] isEqual:@"listheader"];
    uint32_t artHeight = header ? 17 : height;
    CGImageRef lion = CopyLionArt(LionOptions(options, false), width, artHeight, ScaleOf(options, ctm));
    if (!lion) {
        if (gDump) fprintf(stderr, "NATIVE draw %s %.0fx%.0f %s\n", [options[@"widget"] UTF8String], frame.size.width, frame.size.height, [[options[@"imagename"] description] UTF8String] ?: "");
        return gOrigDraw(self, _cmd, frame, cg, options);
    }

    CGFloat pad = LIONESS_PADDING, stretch = (CGFloat)height / artHeight;
    CGRect to = CGRectMake(frame.origin.x - pad, frame.origin.y - pad * stretch, width + 2 * pad, (artHeight + 2 * pad) * stretch);
    CGContextSaveGState(cg);
    if ([options[@"is.flipped"] boolValue]) {   // a CGImage draws bottom-up
        CGContextTranslateCTM(cg, 0, 2 * to.origin.y + to.size.height);
        CGContextScaleCTM(cg, 1, -1);
    }
    CGContextDrawImage(cg, to, lion);
    CGContextRestoreGState(cg);
    CGImageRelease(lion);
    return YES;
}

static BOOL ReturnNo(id, SEL) { return NO; }

// Overrides one method on exactly this class. class_getInstanceMethod finds inherited methods, and setting the implementation
// of one of those changes it for every class that shares it. If the class does not have its own, it gets one, and `original`
// is what it inherited.
template <typename F>
static bool Override(const char *className, SEL selector, IMP replacement, F *original) {
    Class cls = objc_getClass(className);
    Method inherited = cls ? class_getInstanceMethod(cls, selector) : NULL;
    if (!inherited) { os_log(OS_LOG_DEFAULT, "Lioness: %{public}s has no %{public}s", className, sel_getName(selector)); return false; }
    IMP before = method_getImplementation(inherited);
    if (class_addMethod(cls, selector, replacement, method_getTypeEncoding(inherited))) {
        if (original) *original = (F)before;
        return true;
    }
    IMP own = method_setImplementation(class_getInstanceMethod(cls, selector), replacement);
    if (original) *original = (F)own;
    return true;
}

static CGImageRef (*gOrigContents)(id, SEL, NSDictionary *, CGRect *);
static CGImageRef HookContents(id self, SEL _cmd, NSDictionary *options, CGRect *center) {
    CGImageRef image = gOrigContents(self, _cmd, options, center);
    Dump("contents", image ? CGSizeMake(CGImageGetWidth(image), CGImageGetHeight(image)) : CGSizeZero, options);
    return image;
}

// AppKit never asks for a bezel again when a button becomes the default one: the options do not mention
// it, so nothing it knows about has changed (needsDisplay does not help). This picture depends on it.
static void (*gOrigSetKeyEquivalent)(NSButton *, SEL, NSString *);
static void HookSetKeyEquivalent(NSButton *self, SEL _cmd, NSString *key) {
    gOrigSetKeyEquivalent(self, _cmd, key);
    // Through the layers: NSButton does not list its internal bezel view in -subviews.
    for (CALayer *layer in self.layer.sublayers) {
        NSDictionary *options = objc_getAssociatedObject(layer, kOptionsKey);
        if (options) ApplyLion(layer, options, NO);
    }
}

// NSBox fills itself from a layer colour or drawRect without asking CoreUI. Lion's is CoreUI's "group".
static void (*gOrigBoxDraw)(NSBox *, SEL, NSRect);
static void HookBoxDraw(NSBox *self, SEL _cmd, NSRect dirty) {
    if (self.boxType != NSBoxPrimary && self.boxType != NSBoxSecondary) { gOrigBoxDraw(self, _cmd, dirty); return; }
    CGContextRef cg = NSGraphicsContext.currentContext.CGContext;
    NSRect bounds = self.bounds;
    if (self.titlePosition == NSAtTop && self.title.length) bounds.size.height -= self.titleFont.pointSize + 4;
    uint32_t scale = ScaleOf(@{}, fabs(CGContextGetCTM(cg).a));
    NSDictionary *o = @{ @"widget": self.boxType == NSBoxSecondary ? @"groupsecondary" : @"group", @"state": @"normal", @"is.flipped": @NO };
    CGImageRef lion = LionessCopyDrawnImage((__bridge CFDictionaryRef)o, (uint32_t)ceil(bounds.size.width), (uint32_t)ceil(bounds.size.height), scale);
    if (!lion) { gOrigBoxDraw(self, _cmd, dirty); return; }
    CGFloat pad = LIONESS_PADDING;
    CGContextDrawImage(cg, CGRectMake(bounds.origin.x - pad, bounds.origin.y - pad, ceil(bounds.size.width) + 2 * pad, ceil(bounds.size.height) + 2 * pad), lion);
    CGImageRelease(lion);
    [self.titleCell drawWithFrame:self.titleRect inView:self];
}

static BOOL ReturnNoLayer(id, SEL) { return NO; }

// AppKit composes level indicators from parts, and Lion paints them in its NSLevelIndicatorCell, so
// the whole control goes across as its values. Asked to draw rather than update layers, it comes here.
static void (*gOrigLevelDraw)(NSLevelIndicator *, SEL, NSRect);
static void HookLevelDraw(NSLevelIndicator *self, SEL _cmd, NSRect dirty) {
    CGContextRef cg = NSGraphicsContext.currentContext.CGContext;
    NSLevelIndicatorCell *cell = self.cell;
    NSDictionary *o = @{ @"widget": @"lioness.levelindicator", @"style": @(cell.levelIndicatorStyle), @"value": @(cell.doubleValue),
                         @"min": @(cell.minValue), @"max": @(cell.maxValue), @"warning": @(cell.warningValue), @"critical": @(cell.criticalValue) };
    NSRect bounds = self.bounds;
    CGImageRef lion = LionessCopyDrawnImage((__bridge CFDictionaryRef)o, (uint32_t)ceil(bounds.size.width), (uint32_t)ceil(bounds.size.height), ScaleOf(@{}, fabs(CGContextGetCTM(cg).a)));
    if (!lion) { gOrigLevelDraw(self, _cmd, dirty); return; }
    for (CALayer *sub in self.layer.sublayers) sub.hidden = YES;
    CGFloat pad = LIONESS_PADDING;
    CGContextSaveGState(cg);
    if (self.isFlipped) {
        CGContextTranslateCTM(cg, 0, bounds.size.height);
        CGContextScaleCTM(cg, 1, -1);
    }
    CGContextDrawImage(cg, CGRectMake(-pad, -pad, ceil(bounds.size.width) + 2 * pad, ceil(bounds.size.height) + 2 * pad), lion);
    CGContextRestoreGState(cg);
    CGImageRelease(lion);
}

// Popup shape, shadow, placement and the submenu arrow follow Snow Leopard Menu Bar Tweak
// (MIT, Copyright (c) 2026 Snow Leopard Menu Bar Tweak contributors). The selection and background stay Lion's art.
static const CGFloat kMenuCornerRadius = 5, kMenuOverlap = 1;

static bool IsPopupMenuWindow(id window) { return [window isKindOfClass:objc_getClass("NSPopupMenuWindow")]; }

static char gIsSubmenuKey;

// A menu hanging from the menu bar, or from its parent menu, has a square top left corner.
static bool MenuHasSquareCorner(NSWindow *window) {
    NSScreen *screen = window.screen ?: NSScreen.mainScreen;
    if (screen && fabs(NSMaxY(window.frame) - NSMaxY(screen.visibleFrame)) <= kMenuOverlap + 1) return true;
    return [objc_getAssociatedObject(window, &gIsSubmenuKey) boolValue];
}

static NSImage *MenuCornerMask(bool squareCorner) {
    static NSImage *masks[2];
    if (masks[squareCorner]) return masks[squareCorner];
    CGFloat r = kMenuCornerRadius, side = 2 * r + 1;
    NSImage *mask = [[NSImage imageWithSize:NSMakeSize(side, side) flipped:NO drawingHandler:^BOOL(NSRect rect) {
        NSBezierPath *path = [NSBezierPath bezierPathWithRoundedRect:rect xRadius:r yRadius:r];
        if (squareCorner) [path appendBezierPathWithRect:NSMakeRect(0, r, r, side - r)];
        [NSColor.blackColor setFill];
        [path fill];
        return YES;
    }] retain];
    mask.capInsets = NSEdgeInsetsMake(r, r, r, r);
    mask.resizingMode = NSImageResizingModeStretch;
    return masks[squareCorner] = mask;
}

// The compositor's outline, which the window's shadow follows.
static id (*gOrigMenuCornerMask)(NSWindow *, SEL);
static id HookMenuCornerMask(NSWindow *self, SEL _cmd) { return MenuCornerMask(MenuHasSquareCorner(self)); }
static BOOL (*gOrigMenuMaskDefinesShadow)(NSWindow *, SEL);
static BOOL HookMenuMaskDefinesShadow(NSWindow *self, SEL _cmd) { return YES; }

static void (*gOrigMenuPresent)(id, SEL, id, BOOL);
static void HookMenuPresent(id self, SEL _cmd, id view, BOOL animated) { gOrigMenuPresent(self, _cmd, view, NO); }

static void TuneMenuShadow(NSWindow *window) {
    typedef CGError (*Setter)(uint32_t, CFDictionaryRef);
    static Setter setter = (Setter)dlsym(RTLD_DEFAULT, "SLSWindowSetShadowProperties");
    if (!setter || window.windowNumber <= 0) return;
    setter((uint32_t)window.windowNumber, (__bridge CFDictionaryRef)@{
        @"com.apple.WindowShadowDensity": @0.42, @"com.apple.WindowShadowRadius": @5.5,
        @"com.apple.WindowShadowVerticalOffset": @2.0, @"com.apple.WindowShadowRimDensity": @0.06 });
    [window invalidateShadow];
}

// Bar menus overlap the bar by a point, and a submenu overlaps its parent by a point.
static void PlaceMenu(NSWindow *window) {
    NSRect frame = window.frame;
    NSScreen *screen = window.screen ?: NSScreen.mainScreen;
    CGFloat barBottom = screen ? NSMaxY(screen.visibleFrame) : 0;
    if (screen && fabs(NSMaxY(frame) - barBottom) <= 1) frame.origin.y = barBottom + kMenuOverlap - frame.size.height;
    for (NSWindow *other in NSApp.windows) {
        if (other == window || !other.isVisible || !IsPopupMenuWindow(other) || NSMaxY(other.frame) < NSMinY(frame) || NSMinY(other.frame) > NSMaxY(frame)) continue;
        CGFloat right = NSMinX(frame) - NSMaxX(other.frame), left = NSMinX(other.frame) - NSMaxX(frame);
        if (fabs(right) > 12 && fabs(left) > 12) continue;
        frame.origin.x = fabs(right) <= 12 ? NSMaxX(other.frame) - kMenuOverlap : NSMinX(other.frame) - frame.size.width + kMenuOverlap;
        objc_setAssociatedObject(window, &gIsSubmenuKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    if (!NSEqualRects(frame, window.frame)) [window setFrame:frame display:NO];
}

static void StylePopupMenu(NSView *background) {
    NSWindow *window = background.window;
    if (!IsPopupMenuWindow(window)) return;
    static char shapedWindowKey;
    NSNumber *shaped = objc_getAssociatedObject(window, &shapedWindowKey);
    if (shaped.integerValue != window.windowNumber) {
        PlaceMenu(window);
        window.opaque = NO;
        window.backgroundColor = NSColor.clearColor;
        // The compositor took the outline before the window had its final place.
        if ([window respondsToSelector:sel_registerName("_cornerMaskChanged")]) ((void (*)(id, SEL))objc_msgSend)(window, sel_registerName("_cornerMaskChanged"));
        TuneMenuShadow(window);
        objc_setAssociatedObject(window, &shapedWindowKey, @(window.windowNumber), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    CALayer *frameLayer = background.superview.layer;
    frameLayer.backgroundColor = NULL;
    frameLayer.cornerRadius = 0;
    [frameLayer removeAllAnimations];
    CALayer *layer = background.layer;
    layer.cornerRadius = kMenuCornerRadius;
    layer.cornerCurve = kCACornerCurveCircular;
    layer.masksToBounds = YES;
    layer.maskedCorners = kCALayerMinXMinYCorner | kCALayerMaxXMinYCorner | kCALayerMaxXMaxYCorner | (MenuHasSquareCorner(window) ? 0 : kCALayerMinXMaxYCorner);
    [layer removeAllAnimations];
    [CATransaction commit];
}

static NSImage *SubmenuArrow(bool selected, bool enabled, bool rightToLeft) {
    static NSImage *images[2][3];
    int state = !enabled ? 2 : selected ? 1 : 0;
    NSImage *cached = images[rightToLeft][state];
    if (cached) return cached;
    NSColor *color = !enabled ? [NSColor colorWithCalibratedWhite:0.62 alpha:1] : selected ? NSColor.whiteColor : [NSColor colorWithCalibratedWhite:0.16 alpha:1];
    NSImage *image = [[NSImage imageWithSize:NSMakeSize(7, 10) flipped:NO drawingHandler:^BOOL(NSRect rect) {
        NSBezierPath *arrow = [NSBezierPath bezierPath];
        [arrow moveToPoint:NSMakePoint(rightToLeft ? 6.75 : 0.25, 0)];
        [arrow lineToPoint:NSMakePoint(rightToLeft ? 0.25 : 6.75, 5)];
        [arrow lineToPoint:NSMakePoint(rightToLeft ? 6.75 : 0.25, 10)];
        [arrow closePath];
        [color setFill];
        [arrow fill];
        return YES;
    }] retain];
    return images[rightToLeft][state] = image;
}

static void SetSubmenuArrow(NSTextField *field, NSImage *image) {
    NSAttributedString *old = field.attributedStringValue;
    id attachment = old.length == 1 ? [old attribute:NSAttachmentAttributeName atIndex:0 effectiveRange:NULL] : nil;
    if ([attachment isKindOfClass:NSTextAttachment.class] && ((NSTextAttachment *)attachment).image == image) return;
    NSTextAttachment *replacement = [[[NSTextAttachment alloc] init] autorelease];
    replacement.image = image;
    NSMutableDictionary *attributes = old.length ? [[[old attributesAtIndex:0 effectiveRange:NULL] mutableCopy] autorelease] : [NSMutableDictionary dictionary];
    attributes[NSAttachmentAttributeName] = replacement;
    field.attributedStringValue = [[[NSAttributedString alloc] initWithString:@"\uFFFC" attributes:attributes] autorelease];
    field.alignment = NSTextAlignmentCenter;
}

// Tracking highlights an item without selecting its table row.
static bool MenuRowIsHighlighted(NSTableRowView *row) {
    if (row.isSelected) return true;
    Class itemClass = objc_getClass("NSContextMenuItemView");
    for (NSView *view in row.subviews)
        if (itemClass && [view isKindOfClass:itemClass] && [view respondsToSelector:@selector(isHighlighted)] && ((BOOL (*)(id, SEL))objc_msgSend)(view, @selector(isHighlighted))) return true;
    return false;
}

// Lion's selection has white labels, and its shortcuts are the colour of the title rather than a pale secondary one.
static void DressMenuItem(NSTableRowView *row) {
    Class itemClass = objc_getClass("NSContextMenuItemView");
    for (NSView *view in row.subviews) {
        if (!itemClass || ![view isKindOfClass:itemClass] || ![view respondsToSelector:@selector(menuItem)]) continue;
        NSMenuItem *item = ((NSMenuItem *(*)(id, SEL))objc_msgSend)(view, @selector(menuItem));
        if (![item isKindOfClass:NSMenuItem.class] || item.isSeparatorItem) continue;
        bool selected = MenuRowIsHighlighted(row) && item.isEnabled;
        NSColor *color = !item.isEnabled ? NSColor.disabledControlTextColor : selected ? NSColor.whiteColor : NSColor.blackColor;
        Ivar arrowIvar = class_getInstanceVariable(itemClass, "_keyEquivalentTextField");
        id arrow = item.hasSubmenu && arrowIvar ? object_getIvar(view, arrowIvar) : nil;
        for (NSView *part in view.subviews) {
            if ([part isKindOfClass:NSTextField.class]) ((NSTextField *)part).textColor = color;
            else if ([part isKindOfClass:NSImageView.class] && ((NSImageView *)part).image.isTemplate) ((NSImageView *)part).contentTintColor = color;
        }
        if ([arrow isKindOfClass:NSTextField.class])
            SetSubmenuArrow(arrow, SubmenuArrow(selected, item.isEnabled, view.userInterfaceLayoutDirection == NSUserInterfaceLayoutDirectionRightToLeft));
    }
}

// Menus. The window's background is an NSVisualEffectView, and a selected item is a table row. Lion's are
// CoreUI's kCUIWidgetMenu and kCUIWidgetMenuItem.
static void (*gOrigMenuBackgroundLayout)(NSView *, SEL);
static void HookMenuBackgroundLayout(NSView *self, SEL _cmd) {
    gOrigMenuBackgroundLayout(self, _cmd);
    CALayer *layer = self.layer;
    if (!layer || !self.window || self.bounds.size.width < 1) return;
    StylePopupMenu(self);
    uint32_t scale = ScaleOf(@{}, self.window.backingScaleFactor);
    CGImageRef lion = LionessCopyDrawnImage((__bridge CFDictionaryRef)@{ @"widget": @"kCUIWidgetMenu", @"state": @"normal" }, 64, 64, scale);
    if (!lion) return;
    CGImageRef contents = CreateLayerContents(lion, CGSizeMake(64, 64), scale);
    CGImageRelease(lion);
    if (!contents) return;
    for (CALayer *sub in layer.sublayers) if (!sub.delegate) sub.hidden = YES;   // the material; views stay
    SetContents(layer, contents, scale, CGRectMake(0.49, 0.49, 0.02, 0.02));
    CGImageRelease(contents);
}

static void DressSidebarRow(NSTableRowView *row);
static void ApplyMenuRow(NSTableRowView *row) {
    if (![row.superview isKindOfClass:objc_getClass("NSTableViewBackedMenuRepresentation")]) return;
    CALayer *layer = row.layer;
    if (!layer) return;
    DressMenuItem(row);
    for (CALayer *sub in layer.sublayers) if (!sub.delegate) sub.hidden = YES;   // AppKit's rounded highlight
    if (!MenuRowIsHighlighted(row)) { layer.contents = nil; return; }
    uint32_t scale = ScaleOf(@{}, row.window.backingScaleFactor);
    CGImageRef lion = LionessCopyDrawnImage((__bridge CFDictionaryRef)@{ @"widget": @"kCUIWidgetMenuItem", @"state": @"pressed" }, 64, 22, scale);
    if (!lion) return;
    CGImageRef contents = CreateLayerContents(lion, CGSizeMake(64, 22), scale);
    CGImageRelease(lion);
    if (!contents) return;
    SetContents(layer, contents, scale, CGRectMake(0.49, 0, 0.02, 1));
    CGImageRelease(contents);
}
static void (*gOrigMenuSetHighlighted)(id, SEL, BOOL, NSView *);
static void HookMenuSetHighlighted(id self, SEL _cmd, BOOL highlighted, NSView *itemView) {
    gOrigMenuSetHighlighted(self, _cmd, highlighted, itemView);
    if ([itemView.superview isKindOfClass:NSTableRowView.class]) ApplyMenuRow((NSTableRowView *)itemView.superview);
}
static void (*gOrigRowSelected)(NSTableRowView *, SEL, BOOL);
static void HookRowSelected(NSTableRowView *self, SEL _cmd, BOOL selected) {
    gOrigRowSelected(self, _cmd, selected);
    ApplyMenuRow(self);
    DressSidebarRow(self);
}
static void (*gOrigRowLayout)(NSTableRowView *, SEL);
static void HookRowLayout(NSTableRowView *self, SEL _cmd) {
    gOrigRowLayout(self, _cmd);
    ApplyMenuRow(self);
    DressSidebarRow(self);
}

// Lion's selected tabs and its textured and capsule segments are dark, with white labels. AppKit's
// art is light, so it has to be told: an emphasized background style means a label on something dark.
static bool SegmentsAreDark(NSSegmentedCell *cell) {
    if (cell.segmentStyle == NSSegmentStyleCapsule) return true;
    for (NSView *view = cell.controlView; view; view = view.superview)   // toolbar segments draw as Lion's textured ones
        if ([NSStringFromClass(view.class) containsString:@"Toolbar"]) return true;
    return false;
}
// AppKit's own choice of how a segment's label and image render. Dark gives white on Lion's dark selection.
static id SegmentContentAppearance(id item, id original) {
    BOOL selected = ((BOOL (*)(id, SEL))objc_msgSend)(item, @selector(selected));
    NSSegmentedCell *cell = ((id (*)(id, SEL))objc_msgSend)(item, sel_registerName("parentCell"));
    if (![cell isKindOfClass:NSSegmentedCell.class]) return original;
    return [NSAppearance appearanceNamed:selected && SegmentsAreDark(cell) ? NSAppearanceNameDarkAqua : NSAppearanceNameAqua];
}

// In a focused window AppKit marks a selected segment's label and a default button's label as sitting on an
// accent colour, and turns them white. Lion's accents are light: only its dark surfaces have white labels.
static NSBackgroundStyle (*gOrigLabelStyle)(NSCell *, SEL);
static NSBackgroundStyle HookLabelStyle(NSCell *self, SEL _cmd) {
    id item = nil;
    for (NSView *view = self.controlView; view; view = view.superview) {
        if ([view isKindOfClass:objc_getClass("NSSegmentItemView")]) { item = view; break; }
    }
    if (!item) return gOrigLabelStyle(self, _cmd);
    BOOL selected = ((BOOL (*)(id, SEL))objc_msgSend)(item, @selector(selected));
    NSSegmentedCell *cell = ((id (*)(id, SEL))objc_msgSend)(item, sel_registerName("parentCell"));
    return selected && [cell isKindOfClass:NSSegmentedCell.class] && SegmentsAreDark(cell) ? NSBackgroundStyleEmphasized : NSBackgroundStyleNormal;
}
static NSBackgroundStyle ButtonLabelStyle(NSButtonCell *, SEL) { return NSBackgroundStyleNormal; }
// What makes round-rect and small-square segments' labels white when focused. Lion's are light, so never here.
static BOOL (*gOrigSegmentEmphasized)(id, SEL);
static BOOL HookSegmentEmphasized(id self, SEL _cmd) {
    NSSegmentedCell *cell = ((id (*)(id, SEL))objc_msgSend)(self, sel_registerName("parentCell"));
    return [cell isKindOfClass:NSSegmentedCell.class] && SegmentsAreDark(cell) && gOrigSegmentEmphasized(self, _cmd);
}

// Textured bezels dim their labels natively, because the bezel is translucent. Lion's are not.
static BOOL (*gOrigDisabledText)(NSButtonCell *, SEL);
static BOOL HookDisabledText(NSButtonCell *self, SEL _cmd) { return !self.isEnabled; }
static id (*gOrigSegmentLabelAppearance)(id, SEL, id);
static id HookSegmentLabelAppearance(id self, SEL _cmd, id view) { return SegmentContentAppearance(self, gOrigSegmentLabelAppearance(self, _cmd, view)); }
static id (*gOrigSegmentImageAppearance)(id, SEL, id);
static id HookSegmentImageAppearance(id self, SEL _cmd, id view) { return SegmentContentAppearance(self, gOrigSegmentImageAppearance(self, _cmd, view)); }
static NSBackgroundStyle (*gOrigTabStyle)(NSTabViewItem *, SEL);
static NSBackgroundStyle HookTabStyle(NSTabViewItem *self, SEL _cmd) {
    return self.tabState == NSSelectedTab ? NSBackgroundStyleEmphasized : gOrigTabStyle(self, _cmd);
}
static NSColor *(*gOrigTabLabelColor)(NSTabViewItem *, SEL);
static NSColor *HookTabLabelColor(NSTabViewItem *self, SEL _cmd) {
    return self.tabState == NSSelectedTab ? NSColor.whiteColor : gOrigTabLabelColor(self, _cmd);
}

// Lion's title bar goes on this view, from its own methods: they run when AppKit restyles it.
static void (*gOrigBackgroundLayout)(NSView *, SEL);
static void HookBackgroundLayout(NSView *self, SEL _cmd) {
    gOrigBackgroundLayout(self, _cmd);
    UpdateTitlebarBackground(self);
}
static void (*gOrigBackgroundMoved)(NSView *, SEL);
static void HookBackgroundMoved(NSView *self, SEL _cmd) {
    gOrigBackgroundMoved(self, _cmd);
    UpdateTitlebarBackground(self);
}
static void (*gOrigBackgroundUpdateLayer)(NSView *, SEL);
static void HookBackgroundUpdateLayer(NSView *self, SEL _cmd) {
    gOrigBackgroundUpdateLayer(self, _cmd);
    UpdateTitlebarBackground(self);
}

static void (*gOrigAccessoryLayout)(NSView *, SEL);
static void HookAccessoryLayout(NSView *self, SEL _cmd) {
    gOrigAccessoryLayout(self, _cmd);
    UpdateBottomBar(self);
}

// A split view keeps a 3 point gap beside a sidebar, by constraints, not by its dividerThickness. A selection stops at the sidebar's edge, so the
// content comes in until only the line's point is left. Widening the sidebar instead does not work: the constraints push the content along with it.
static void (*gOrigWrapperSetFrame)(NSView *, SEL, NSRect);
static void HookWrapperSetFrame(NSView *self, SEL _cmd, NSRect frame) {
    NSView *split = self.superview;
    if ([split isKindOfClass:NSSplitView.class] && !SidebarMaterial(self) && LionessIsReachable()) {
        for (NSView *sibling in split.subviews) {
            if (sibling == self || !SidebarMaterial(sibling) || sibling.frame.size.width < 1) continue;
            CGFloat left = frame.origin.x - NSMaxX(sibling.frame), right = sibling.frame.origin.x - NSMaxX(frame);
            if (left > 1 && left < 8) { frame.origin.x -= left - 1; frame.size.width += left - 1; }
            else if (right > 1 && right < 8) frame.size.width += right - 1;
        }
    }
    gOrigWrapperSetFrame(self, _cmd, frame);
}
static void (*gOrigVibrantDividerLayout)(NSView *, SEL);
static void HookVibrantDividerLayout(NSView *self, SEL _cmd) {
    gOrigVibrantDividerLayout(self, _cmd);
    UpdateVibrantDivider(self);
}
static void (*gOrigToolbarViewerLayout)(NSView *, SEL);
static void HookToolbarViewerLayout(NSView *self, SEL _cmd) {
    gOrigToolbarViewerLayout(self, _cmd);
    UpdateToolbarBezel(self);
}
static void (*gOrigFieldLayout)(NSView *, SEL);
static void HookFieldLayout(NSView *self, SEL _cmd) {
    gOrigFieldLayout(self, _cmd);
    UpdateFieldBezel(self);
}
// This builds a dictionary from an NSFont call that is sometimes nil, and the exception would end the app.
// Caught, that title just has no cached line until the menu bar is next laid out.
// AppKit frees the old line, then builds the new one from a dictionary that throws on a nil font, leaving what it freed in place for
// dealloc to free again. The function is objc_direct here, so it has no selector and takes only self. idealWidth is its usual way in.
static void ClearMenuBarLineCache(id self) {
    if (Ivar line = class_getInstanceVariable(object_getClass(self), "_cachedLine")) *(void **)((char *)self + ivar_getOffset(line)) = NULL;
}
static void (*gOrigEnsureLineCache)(id);
static void HookEnsureLineCache(id self) {
    @try { gOrigEnsureLineCache(self); }
    @catch (NSException *exception) {
        os_log(OS_LOG_DEFAULT, "Lioness: menu bar title skipped: %{public}@", exception.reason);
        ClearMenuBarLineCache(self);
    }
}
static double (*gOrigMenuBarIdealWidth)(id, SEL);
static double HookMenuBarIdealWidth(id self, SEL _cmd) {
    @try { return gOrigMenuBarIdealWidth(self, _cmd); }
    @catch (NSException *exception) {
        os_log(OS_LOG_DEFAULT, "Lioness: menu bar title not measured: %{public}@", exception.reason);
        ClearMenuBarLineCache(self);
        return 0;
    }
}
// Lion's toolbar items start 3 points in from each side. The modern layout keeps its own 5 and ignores _toolbarLeadingSpace and _toolbarTrailingSpace, so the view
// reaches 2 points past both edges instead.
static constexpr CGFloat kToolbarMarginTaken = 2;
static void (*gOrigToolbarSetFrame)(NSView *, SEL, NSRect);
static void HookToolbarSetFrame(NSView *self, SEL _cmd, NSRect frame) {
    if (frame.origin.x == 0 && self.superview && frame.size.width == self.superview.bounds.size.width) {
        frame.origin.x = -kToolbarMarginTaken;
        frame.size.width += 2 * kToolbarMarginTaken;
    }
    gOrigToolbarSetFrame(self, _cmd, frame);
}
static void (*gOrigTabBarLayout)(NSView *, SEL);
static void HookTabBarLayout(NSView *self, SEL _cmd) {
    gOrigTabBarLayout(self, _cmd);
    UpdateBottomBar(self);
}
static void (*gOrigMaterialLayout)(NSVisualEffectView *, SEL);
static void HookMaterialLayout(NSVisualEffectView *self, SEL _cmd) {
    gOrigMaterialLayout(self, _cmd);
    UpdateMaterial(self);
}
static void (*gOrigRowEmphasized)(NSTableRowView *, SEL, BOOL);
static void HookRowEmphasized(NSTableRowView *self, SEL _cmd, BOOL emphasized) {
    gOrigRowEmphasized(self, _cmd, emphasized);
    DressSidebarRow(self);
    for (NSView *sub in self.subviews) if ([sub isKindOfClass:NSVisualEffectView.class]) UpdateMaterial((NSVisualEffectView *)sub);
}

static void UpdateBottomBars(NSView *view) {
    if ([view isKindOfClass:objc_getClass("NSSplitViewItemAccessoryClipView")] || [view isKindOfClass:objc_getClass("NSTabBar")]) UpdateBottomBar(view);
    if ([view isKindOfClass:NSVisualEffectView.class]) UpdateMaterial((NSVisualEffectView *)view);
    if ([view isKindOfClass:objc_getClass("NSVibrantSplitDividerView")]) UpdateVibrantDivider(view);
    if ([view isKindOfClass:objc_getClass("NSToolbarItemViewer")]) UpdateToolbarBezel(view);
    if ([view isKindOfClass:objc_getClass("UnifiedField")]) UpdateFieldBezel(view);
    for (NSView *sub in view.subviews) UpdateBottomBars(sub);
}

// A window becoming or leaving main changes the bar, and nothing about that view changes for AppKit.
static void ObserveMainWindow(void) {
    for (NSString *name in @[ NSWindowDidBecomeMainNotification, NSWindowDidResignMainNotification, NSWindowDidBecomeKeyNotification, NSWindowDidResignKeyNotification ]) {
        [NSNotificationCenter.defaultCenter addObserverForName:name object:nil queue:nil usingBlock:^(NSNotification *note) {
            CALayer *root = ((NSWindow *)note.object).contentView.superview.layer;
            if (root) UpdateTitlebarBackgrounds(root);
            if (NSView *frame = ((NSWindow *)note.object).contentView.superview) UpdateBottomBars(frame);
            for (CALayer *divider in gSidebarDividers) {
                id owner = divider.delegate;
                PaintSidebarDivider(divider, [owner isKindOfClass:NSView.class] && ((NSView *)owner).userInterfaceLayoutDirection == NSUserInterfaceLayoutDirectionRightToLeft);
            }
        }];
    }
}

// Lion had no dark mode, and its controls are only right beside light-appearance text and backgrounds.
static NSAppearance *AquaAppearance(id, SEL) { return [NSAppearance appearanceNamed:NSAppearanceNameAqua]; }

// AppKit can draw a control's text through a CoreUI style preset, which ignores the text colour, so labels on Lion's art
// come out white or dim even when they say controlTextColor. Lion's labels are plain colours. Each class implementing
// this has its own method, so all of them are found.
static BOOL NoStyledText(id, SEL, id, NSBackgroundStyle) { return NO; }
static id NoContentStyle(id, SEL) { return nil; }   // what a segment sets on its own label
// A segment's label asks for alternateSelectedControlTextColor when selected, in its text attributes: white, for
// the modern solid accent. Lion's light selections want dark text, and only its dark ones keep white. Taking the
// colour out is not enough, so it is always stated.
static NSDictionary *(*gOrigLabelAttributes)(NSCell *, SEL);
static NSDictionary *HookLabelAttributes(NSCell *self, SEL _cmd) {
    NSDictionary *attributes = gOrigLabelAttributes(self, _cmd);
    if (!LionessIsReachable()) return attributes;   // AppKit's own art wants AppKit's own colours
    id item = nil;
    for (NSView *view = self.controlView; view && !item; view = view.superview)
        if ([view isKindOfClass:objc_getClass("NSSegmentItemView")]) item = view;
    if (!item) return attributes;
    BOOL selected = ((BOOL (*)(id, SEL))objc_msgSend)(item, @selector(selected));
    BOOL enabled = ((BOOL (*)(id, SEL))objc_msgSend)(item, @selector(enabled));
    NSSegmentedCell *cell = ((id (*)(id, SEL))objc_msgSend)(item, sel_registerName("parentCell"));
    bool dark = selected && [cell isKindOfClass:NSSegmentedCell.class] && SegmentsAreDark(cell);
    NSMutableDictionary *plain = [[attributes mutableCopy] autorelease];
    plain[NSForegroundColorAttributeName] = dark ? NSColor.whiteColor : enabled ? NSColor.controlTextColor : NSColor.disabledControlTextColor;
    return plain;
}
static void DisableStyledText(void) {
    SEL selector = sel_registerName("_shouldUseStyledTextInView:withBackgroundStyle:");
    unsigned classCount = 0;
    Class *classes = objc_copyClassList(&classCount);
    for (unsigned i = 0; i < classCount; i++) {
        const char *name = class_getName(classes[i]);
        if (strncmp(name, "NS", 2) != 0 && strncmp(name, "_NS", 3) != 0) continue;
        unsigned count = 0;
        Method *methods = class_copyMethodList(classes[i], &count);
        for (unsigned k = 0; k < count; k++) {
            if (method_getName(methods[k]) != selector) continue;
            method_setImplementation(methods[k], (IMP)NoStyledText);
            if (gDump) fprintf(stderr, "STYLED %s\n", name);
        }
        free(methods);
    }
    free(classes);
}

// Blend modes. AppKit composes text, images and bezels against translucent materials, which Lion's opaque art is
// not: a blended label comes out white on a light selection and dim on a light bezel. So everything draws
// normally. Getters all return an int and 0 is normal; those with out-parameters must still fill them in.
static int NoBlend(id, SEL) { return 0; }
static int NoBlendVibrancy3(id, SEL, id, int *bezel, int *title) {
    if (bezel) *bezel = 0;
    if (title) *title = 0;
    return 0;
}
static int NoBlendVibrancy4(id, SEL, id, int *bezel, int *title, int *image) {
    if (bezel) *bezel = 0;
    if (title) *title = 0;
    if (image) *image = 0;
    return 0;
}
static int NoBlendContextDrawing(id, SEL, id, BOOL *incompatible) {
    if (incompatible) *incompatible = NO;
    return 0;
}
// These report whether the button has that part at all, which is not ours to change.
static int (*gOrigTitleBlend)(id, SEL, id, BOOL *);
static int HookTitleBlend(id self, SEL _cmd, id appearance, BOOL *has) { gOrigTitleBlend(self, _cmd, appearance, has); return 0; }
static int (*gOrigImageBlend)(id, SEL, id, BOOL *);
static int HookImageBlend(id self, SEL _cmd, id appearance, BOOL *has) { gOrigImageBlend(self, _cmd, appearance, has); return 0; }
static int (*gOrigBezelBlend)(id, SEL, id, CGRect, BOOL *);
static int HookBezelBlend(id self, SEL _cmd, id appearance, CGRect bounds, BOOL *has) { gOrigBezelBlend(self, _cmd, appearance, bounds, has); return 0; }

// And on the layers themselves, where the getters' answers end up: plusD on toolbar images and search fields,
// and more. Only on AppKit's and SwiftUI's own view layers, and not destOut, which is a mask (the slider cuts its track with it),
// not a colour blend. An app's own layers keep their filters. Toolbar image views keep theirs too: AppKit tints
// template images pale on the assumption that plusD will darken them, and they go faint without it.
static void (*gOrigSetFilter)(CALayer *, SEL, id);
static void HookSetFilter(CALayer *self, SEL _cmd, id filter) {
    id delegate = self.delegate;
    bool ours = [delegate isKindOfClass:NSView.class] || [delegate isKindOfClass:objc_getClass("_SwiftUILayerDelegate")];   // SwiftUI lists: plusD, vibrant matrix
    if (filter && ours && ![delegate isKindOfClass:objc_getClass("NSToolbarImageView")]) {
        NSString *name = [filter description];
        if (![name containsString:@"destOut"] && ![name containsString:@"destIn"] && ![name containsString:@"sourceIn"] && ![name containsString:@"sourceOut"]) filter = nil;
    }
    gOrigSetFilter(self, _cmd, filter);
}

// Inside a visual effect view everything inherits VibrantLight, whatever the app's appearance, and that is what asks for
// plusD and translucent colours. No control sits on a live material here, so nothing should be vibrant.
static NSAppearance *(*gOrigEffectiveAppearance)(NSView *, SEL);
static NSAppearance *HookEffectiveAppearance(NSView *self, SEL _cmd) {
    NSAppearance *appearance = gOrigEffectiveAppearance(self, _cmd);
    static NSAppearance *aqua = [[NSAppearance appearanceNamed:NSAppearanceNameAqua] retain];
    return [appearance.name isEqualToString:NSAppearanceNameVibrantLight] ? aqua : appearance;
}
static BOOL NotVibrant(id, SEL) { return NO; }
static void DisableVibrancy(void) {
    unsigned classCount = 0, replaced = 0;
    Class *classes = objc_copyClassList(&classCount);
    for (unsigned i = 0; i < classCount; i++) {
        const char *name = class_getName(classes[i]);
        if (strncmp(name, "NS", 2) != 0 && strncmp(name, "_NS", 3) != 0) continue;
        unsigned count = 0;
        Method *methods = class_copyMethodList(classes[i], &count);
        for (unsigned k = 0; k < count; k++)
            if (method_getName(methods[k]) == @selector(allowsVibrancy)) { method_setImplementation(methods[k], (IMP)NotVibrant); replaced++; }
        free(methods);
    }
    free(classes);
    if (gDump) fprintf(stderr, "VIBRANCY replaced %u methods\n", replaced);
}

// Lion's system colours, read from its own NSColor under the engine. The modern ones are translucent, for vibrancy: labels are
// black at 85%, not black. Names with no Lion counterpart (secondaryLabelColor and so on) stay as they are. Lion's graphite values
// are unknown, so with Graphite on, the blue ones are left to the system.
static void UseLionColors(void) {
    static const struct { const char *name; CGFloat r, g, b; bool blue; } colors[] = {
        { "controlTextColor", 0, 0, 0 }, { "labelColor", 0, 0, 0 }, { "textColor", 0, 0, 0 }, { "headerTextColor", 0, 0, 0 },
        { "windowFrameTextColor", 0, 0, 0 }, { "selectedTextColor", 0, 0, 0 }, { "selectedControlTextColor", 0, 0, 0 },
        { "disabledControlTextColor", 0.5, 0.5, 0.5 },
        { "alternateSelectedControlTextColor", 1, 1, 1 }, { "selectedMenuItemTextColor", 1, 1, 1 },
        { "textBackgroundColor", 1, 1, 1 }, { "controlBackgroundColor", 1, 1, 1 },
        { "secondarySelectedControlColor", 0.831, 0.831, 0.831 }, { "unemphasizedSelectedContentBackgroundColor", 0.831, 0.831, 0.831 },
        { "unemphasizedSelectedTextBackgroundColor", 0.831, 0.831, 0.831 },
        { "gridColor", 0.8, 0.8, 0.8 },
        { "selectedTextBackgroundColor", 0.710, 0.835, 1, true }, { "selectedControlColor", 0.710, 0.835, 1, true },
        { "alternateSelectedControlColor", 0.220, 0.459, 0.843, true }, { "selectedContentBackgroundColor", 0.220, 0.459, 0.843, true },
        { "controlAccentColor", 0.220, 0.459, 0.843, true }, { "keyboardFocusIndicatorColor", 0.358, 0.614, 0.851, true },
    };
    for (const auto &c : colors) {
        if (c.blue && IsGraphite()) continue;
        Method method = class_getClassMethod(NSColor.class, sel_registerName(c.name));
        if (!method) continue;
        NSColor *color = [[NSColor colorWithSRGBRed:c.r green:c.g blue:c.b alpha:1] retain];
        method_setImplementation(method, imp_implementationWithBlock(^NSColor *(id) { return color; }));
    }
}

// Apps ask for SF Symbols, which Mountain Lion never had. Where it has an image for the same thing, appkitd draws that, at this screen's scale. Names with
// no counterpart keep the modern symbol (sidebar.leading, magnifyingglass, and most of the newer ones).
#define SIDEBAR(name) @"/System/Library/CoreServices/CoreTypes.bundle/Contents/Resources/Sidebar" name @".icns"
#define CORETYPES(name) @"/System/Library/CoreServices/CoreTypes.bundle/Contents/Resources/" name @".icns"
static NSString *const kLionTrashIcon = CORETYPES(@"TrashIcon");   // no sidebar form exists: Mountain Lion's sidebar had no Trash
static NSDictionary *GlyphSources(void) {
    static NSDictionary *sources = [@{
        @"plus": @"NSAddTemplate", @"minus": @"NSRemoveTemplate", @"gear": @"NSActionTemplate", @"gearshape": @"NSActionTemplate",
        @"square.and.arrow.up": @"NSShareTemplate", @"arrow.clockwise": @"NSRefreshTemplate", @"xmark": @"NSStopProgressTemplate",
        @"xmark.circle.fill": @"NSStopProgressFreestandingTemplate", @"eye": @"NSQuickLookTemplate", @"list.bullet": @"NSListViewTemplate",
        @"square.grid.2x2": @"NSIconViewTemplate", @"rectangle.split.3x1": @"NSColumnViewTemplate", @"squares.below.rectangle": @"NSFlowViewTemplate",
        @"chevron.backward": @"NSGoLeftTemplate", @"chevron.left": @"NSGoLeftTemplate", @"chevron.forward": @"NSGoRightTemplate", @"chevron.right": @"NSGoRightTemplate",
        @"chevron.forward.2": @"NSToolbarMoreTemplate", @"lock": @"NSLockLockedTemplate", @"lock.fill": @"NSLockLockedTemplate", @"lock.open": @"NSLockUnlockedTemplate",
        @"book": @"NSBookmarksTemplate", @"play.fill": @"NSPlayTemplate", @"pause.fill": @"NSPauseTemplate", @"arrowshape.turn.up.right": @"NSFollowLinkFreestandingTemplate",
        @"house": SIDEBAR(@"HomeFolder"), @"folder": SIDEBAR(@"GenericFolder"), @"document": SIDEBAR(@"GenericFile"), @"doc": SIDEBAR(@"GenericFile"), @"clock": SIDEBAR(@"Recents"),
        @"network": SIDEBAR(@"Network"), @"icloud": SIDEBAR(@"iCloud"), @"internaldrive": SIDEBAR(@"InternalDisk"), @"externaldrive": SIDEBAR(@"ExternalDisk"),
        @"laptopcomputer": SIDEBAR(@"Laptop"), @"display": SIDEBAR(@"Display"), @"desktopcomputer": SIDEBAR(@"iMac"),
        @"magnifyingglass": @"lioness:magnify", @"eject": @"lioness:eject", @"eject.fill": @"lioness:eject", @"sidebar.leading": @"lioness:sidebarleading", @"sidebar.left": @"lioness:sidebarleading",
        @"sidebar.trailing": @"lioness:sidebartrailing", @"sidebar.right": @"lioness:sidebartrailing", @"NSSidebarTemplate": @"lioness:sidebarleading", @"NSToolbarMore": @"NSToolbarMoreTemplate",
        @"gearshape.fill": @"NSActionTemplate", @"person": @"NSUser", @"person.2": @"NSUserGroup", @"info": @"lioness:info", @"info.circle": @"lioness:info", @"info.circle.fill": @"lioness:info",
        @"exclamationmark.triangle": @"NSCaution", @"record.circle.fill": @"NSRecordStartTemplate", @"stop.fill": @"NSRecordStopTemplate", @"forward.end.fill": @"NSSkipAheadTemplate",
        @"backward.end.fill": @"NSSkipBackTemplate", @"forward.fill": @"NSFastForwardTemplate", @"backward.fill": @"NSRewindTemplate", @"play.circle": @"NSPlayTemplate", @"pause.circle.fill": @"NSPauseTemplate",
        @"speaker.wave.1.fill": @"NSAudioOutputVolumeLowTemplate", @"speaker.wave.2": @"NSAudioOutputVolumeMedTemplate", @"speaker.wave.2.fill": @"NSAudioOutputVolumeMedTemplate", @"speaker.wave.3.fill": @"NSAudioOutputVolumeHighTemplate",
        @"speaker.slash": @"NSAudioOutputMuteTemplate", @"arrow.up.left.and.arrow.down.right.rectangle": @"NSEnterFullScreenTemplate", @"arrow.up.left.and.arrow.down.right": @"NSEnterFullScreenTemplate", @"arrow.down.right.and.arrow.up.left": @"NSExitFullScreenTemplate",
        @"list.bullet.indent": @"NSListViewTemplate", @"list.star": @"NSListViewTemplate", @"list.triangle": @"NSListViewTemplate", @"rectangle.grid.1x2": @"NSFlowViewTemplate", @"rectangle.grid.1x3": @"NSFlowViewTemplate", @"text.justify": @"NSListViewTemplate", @"line.3.horizontal.decrease": @"NSListViewTemplate",
        @"square.grid.3x3": @"NSIconViewTemplate", @"square.grid.3x2": @"NSIconViewTemplate", @"square.grid.4x3.fill": @"NSIconViewTemplate",
        @"xmark.circle": @"NSStopProgressFreestandingTemplate", @"xmark.square": @"NSStopProgressTemplate", @"arrow.clockwise.circle.fill": @"NSRefreshFreestandingTemplate", @"arrow.trianglehead.2.clockwise": @"NSRefreshTemplate", @"arrow.counterclockwise": @"NSRefreshTemplate",
        @"plus.circle": @"NSAddTemplate", @"plus.square": @"NSAddTemplate", @"plus.rectangle": @"NSAddTemplate", @"plus.rectangle.fill": @"NSAddTemplate", @"square.badge.plus": @"NSAddTemplate", @"plus.square.on.square": @"NSAddTemplate", @"plus.magnifyingglass": @"NSAddTemplate", @"minus.magnifyingglass": @"NSRemoveTemplate",
        @"book.badge.plus": @"NSAddBookmarkTemplate", @"star": CORETYPES(@"ToolbarFavoritesIcon"), @"tag": CORETYPES(@"ToolbarLabels"), @"trash": CORETYPES(@"ToolbarDeleteIcon"), @"document.on.trash": CORETYPES(@"ToolbarDeleteIcon"),
        @"wrench.and.screwdriver": CORETYPES(@"ToolbarAdvanced"), @"wrench.and.screwdriver.fill": CORETYPES(@"ToolbarAdvanced"), @"wrench.adjustable": CORETYPES(@"ToolbarAdvanced"), @"hammer": CORETYPES(@"ToolbarAdvanced"), @"slider.horizontal.3": CORETYPES(@"ToolbarAdvanced"),
        @"link": @"NSFollowLinkFreestandingTemplate", @"arrow.up.forward.square": @"NSFollowLinkFreestandingTemplate", @"arrow.up.forward.app": @"NSFollowLinkFreestandingTemplate", @"arrow.forward.folder": @"NSRevealFreestandingTemplate", @"arrow.up.folder": @"NSRevealFreestandingTemplate",
        @"folder.badge.plus": SIDEBAR(@"GenericFolder"), @"doc.on.doc": SIDEBAR(@"GenericFile"), @"document.on.document": SIDEBAR(@"GenericFile"), @"text.page": SIDEBAR(@"GenericFile"), @"book.pages": SIDEBAR(@"GenericFile"), @"macwindow": SIDEBAR(@"Display"), @"macwindow.on.rectangle": SIDEBAR(@"Display"), @"globe": SIDEBAR(@"Network"), @"hifispeaker.2": @"NSAudioOutputVolumeHighTemplate", @"externaldrive.badge.xmark": SIDEBAR(@"ExternalDisk"), @"square.stack.3d.up": SIDEBAR(@"GenericFolder"),
        @"NSActionTemplate": @"NSActionTemplate", @"NSAddTemplate": @"NSAddTemplate", @"NSRemoveTemplate": @"NSRemoveTemplate", @"NSShareTemplate": @"NSShareTemplate",
        @"NSRefreshTemplate": @"NSRefreshTemplate", @"NSStopProgressTemplate": @"NSStopProgressTemplate", @"NSListViewTemplate": @"NSListViewTemplate", @"NSIconViewTemplate": @"NSIconViewTemplate",
        @"NSColumnViewTemplate": @"NSColumnViewTemplate", @"NSFlowViewTemplate": @"NSFlowViewTemplate", @"NSGoLeftTemplate": @"NSGoLeftTemplate", @"NSGoRightTemplate": @"NSGoRightTemplate",
        @"NSToolbarMoreTemplate": @"NSToolbarMoreTemplate", @"NSQuickLookTemplate": @"NSQuickLookTemplate", @"NSHomeTemplate": @"NSHomeTemplate", @"NSLockLockedTemplate": @"NSLockLockedTemplate",
        @"NSLockUnlockedTemplate": @"NSLockUnlockedTemplate", @"NSBookmarksTemplate": @"NSBookmarksTemplate", @"NSPathTemplate": @"NSPathTemplate",
    } retain];
    return sources;
}

static const void *const kLionGlyphKey = &kLionGlyphKey;
static const void *const kLionGlyphSourceKey = &kLionGlyphSourceKey;
static NSImage *LionGlyph(NSString *source, NSSize size, bool selected) {
    static NSMutableDictionary *cache = [NSMutableDictionary new];
    if (size.width < 1 || size.height < 1) size = NSMakeSize(16, 16);
    uint32_t width = (uint32_t)ceil(size.width), height = (uint32_t)ceil(size.height), scale = ScaleOf(@{}, NSScreen.mainScreen.backingScaleFactor ?: 2);
    NSString *key = [NSString stringWithFormat:@"%@ %u %u %u %d", source, width, height, scale, selected];
    @synchronized (cache) { if (NSImage *known = cache[key]) return known; }
    NSDictionary *request = selected ? @{ @"widget": @"lioness.image", @"source": source, @"selected": @YES } : @{ @"widget": @"lioness.image", @"source": source };
    CGImageRef lion = LionessCopyDrawnImage((__bridge CFDictionaryRef)request, width, height, scale);
    if (!lion) return nil;
    CGImageRef cropped = CGImageCreateWithImageInRect(lion, CGRectMake(LIONESS_PADDING * scale, LIONESS_PADDING * scale, width * scale, height * scale));
    CGImageRelease(lion);
    if (!cropped) return nil;
    NSBitmapImageRep *rep = [[[NSBitmapImageRep alloc] initWithCGImage:cropped] autorelease];
    CGImageRelease(cropped);
    rep.size = NSMakeSize(width, height);
    NSImage *image = [[[NSImage alloc] initWithSize:NSMakeSize(width, height)] autorelease];
    [image addRepresentation:rep];
    [image setTemplate:[source hasSuffix:@"Template"] || [source hasPrefix:@"lioness:"]];   // the rest are shaded art; as templates they would flatten to black
    objc_setAssociatedObject(image, kLionGlyphKey, @(selected), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(image, kLionGlyphSourceKey, source, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    @synchronized (cache) { cache[key] = image; }
    return image;
}

static NSImage *(*gOrigSymbol)(id, SEL, NSString *, NSString *);
static NSImage *HookSymbol(id self, SEL _cmd, NSString *name, NSString *description) {
    NSImage *original = gOrigSymbol(self, _cmd, name, description);
    NSString *source = name ? GlyphSources()[name] : nil;
    NSImage *lion = source ? LionGlyph(source, original.size, false) : nil;
    if (!lion) return original;
    if (description) {
        lion = [[lion copy] autorelease];
        lion.accessibilityDescription = description;
        objc_setAssociatedObject(lion, kLionGlyphKey, @NO, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        objc_setAssociatedObject(lion, kLionGlyphSourceKey, source, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    return lion;
}
static NSImage *(*gOrigNamed)(id, SEL, NSString *);
static NSImage *HookNamed(id self, SEL _cmd, NSString *name) {
    NSImage *original = gOrigNamed(self, _cmd, name);
    NSString *source = name ? GlyphSources()[name] : nil;
    return (source ? LionGlyph(source, original.size, false) : nil) ?: original;
}
// Callers often mark what they got from a symbol name as a template. Shaded art flattens to a blob that way, and cached images are shared.
static void (*gOrigSetTemplate)(NSImage *, SEL, BOOL);
static void HookSetTemplate(NSImage *self, SEL _cmd, BOOL isTemplate) {
    NSString *source = objc_getAssociatedObject(self, kLionGlyphSourceKey);
    if (source && isTemplate && ![source hasSuffix:@"Template"] && ![source hasPrefix:@"lioness:"]) return;
    gOrigSetTemplate(self, _cmd, isTemplate);
}
// A symbol configuration means nothing to a bitmap, and the default answer of nil would lose the image.
static NSImage *(*gOrigWithConfiguration)(NSImage *, SEL, id);
static NSImage *HookWithConfiguration(NSImage *self, SEL _cmd, id configuration) {
    return objc_getAssociatedObject(self, kLionGlyphKey) ? self : gOrigWithConfiguration(self, _cmd, configuration);
}

// Finder's sidebar icons do not come through NSImage's names. Its outline's items are FINodes, which say what they are, in any language.
static NSString *SidebarSourceForFinderItem(id item, NSString *title) {
    NSString *description = [item description];
    if ([description containsString:@"cannedSearch"]) return SIDEBAR(@"Recents");
    // fileURL is empty on these. launchURL is a file reference.
    NSURL *reference = [item respondsToSelector:@selector(launchURL)] ? [item performSelector:@selector(launchURL)] : nil;
    NSURL *url = reference.filePathURL;
    NSString *path = url.URLByStandardizingPath.path;
    if (path) {
        NSString *home = NSHomeDirectory();
        NSDictionary *places = @{ @"/Applications": SIDEBAR(@"ApplicationsFolder"), home: SIDEBAR(@"HomeFolder"),
            [home stringByAppendingPathComponent:@"Desktop"]: SIDEBAR(@"DesktopFolder"), [home stringByAppendingPathComponent:@"Documents"]: SIDEBAR(@"DocumentsFolder"),
            [home stringByAppendingPathComponent:@"Downloads"]: SIDEBAR(@"DownloadsFolder"), [home stringByAppendingPathComponent:@"Movies"]: SIDEBAR(@"MoviesFolder"),
            [home stringByAppendingPathComponent:@"Music"]: SIDEBAR(@"MusicFolder"), [home stringByAppendingPathComponent:@"Pictures"]: SIDEBAR(@"PicturesFolder"),
            @"/Applications/Utilities": SIDEBAR(@"UtilitiesFolder"), @"/System/Applications/Utilities": SIDEBAR(@"UtilitiesFolder"), @"/System/Applications": SIDEBAR(@"ApplicationsFolder") };
        if (NSString *place = places[path]) return place;
        if ([path hasSuffix:@"/.Trash"]) return kLionTrashIcon;
        if ([path containsString:@"/Mobile Documents"]) return SIDEBAR(@"iCloud");
    }
    if (url) {
        NSNumber *volume = nil, *directory = nil, *internal = nil;
        [url getResourceValue:&volume forKey:NSURLIsVolumeKey error:NULL];
        [url getResourceValue:&directory forKey:NSURLIsDirectoryKey error:NULL];
        if (volume.boolValue) {
            [url getResourceValue:&internal forKey:NSURLVolumeIsInternalKey error:NULL];
            return internal.boolValue ? SIDEBAR(@"InternalDisk") : SIDEBAR(@"ExternalDisk");
        }
        return directory.boolValue ? SIDEBAR(@"GenericFolder") : SIDEBAR(@"GenericFile");
    }
    // These have no file behind them.
    NSDictionary *virtuals = @{ @"AirDrop": SIDEBAR(@"AirDrop"), @"Network": SIDEBAR(@"Network"), @"Trash": kLionTrashIcon, @"iCloud Drive": SIDEBAR(@"iCloud"), @"Shared": SIDEBAR(@"Network") };
    if (NSString *known = virtuals[title]) return known;
    if (getenv("LIONESS_DUMP")) fprintf(stderr, "SIDEBAR unknown %s: %s\n", title.UTF8String, description.UTF8String);
    return nil;
}
static void UpdateFinderSidebarCell(NSView *cell) {
    NSImageView *imageView = ((NSTableCellView *)cell).imageView;
    if (!imageView) for (NSView *sub in cell.subviews) if ([sub isKindOfClass:NSImageView.class]) imageView = (NSImageView *)sub;
    if (!imageView.image || objc_getAssociatedObject(imageView.image, kLionGlyphKey)) return;
    NSView *view = cell;
    while (view && ![view isKindOfClass:NSOutlineView.class]) view = view.superview;
    NSOutlineView *outline = (NSOutlineView *)view;
    NSInteger row = outline ? [outline rowForView:cell] : -1;
    id item = row >= 0 ? [outline itemAtRow:row] : nil;
    NSString *source = item ? SidebarSourceForFinderItem(item, ((NSTableCellView *)cell).textField.stringValue) : nil;
    NSImage *lion = source ? LionGlyph(source, NSMakeSize(16, 16), false) : nil;
    if (lion) imageView.image = lion;
}

// Sidebar rows: Lion's labels are etched, with a white shadow beneath, and a dark one when selected. The icons have theirs in the art, and swap to white when selected.
static bool IsInSidebar(NSView *view) {
    for (int depth = 0; view && depth < 14; view = view.superview, depth++)
        if ([view isKindOfClass:NSVisualEffectView.class] && ((NSVisualEffectView *)view).material == NSVisualEffectMaterialSidebar) return true;
    return false;
}
static void DressSidebarContent(NSView *view, bool selected) {
    if ([view isKindOfClass:NSImageView.class]) {
        NSImageView *imageView = (NSImageView *)view;
        NSString *source = objc_getAssociatedObject(imageView.image, kLionGlyphSourceKey);
        NSNumber *drawn = objc_getAssociatedObject(imageView.image, kLionGlyphKey);
        if ([source hasPrefix:@"/"] && drawn.boolValue != selected) {
            NSImage *swapped = LionGlyph(source, imageView.image.size, selected);
            if (swapped) imageView.image = swapped;
        }
        return;
    }
    if ([view isKindOfClass:NSTextField.class]) {
        view.wantsLayer = YES;
        CALayer *layer = view.layer;
        [CATransaction begin];
        [CATransaction setDisableActions:YES];
        layer.shadowColor = selected ? NSColor.blackColor.CGColor : NSColor.whiteColor.CGColor;
        layer.shadowOpacity = selected ? 0.45 : 0.9;
        layer.shadowRadius = 0;
        layer.shadowOffset = CGSizeMake(0, layer.geometryFlipped ? 1 : -1);
        [CATransaction commit];
        return;
    }
    for (NSView *sub in view.subviews) DressSidebarContent(sub, selected);
}
static void DressSidebarRow(NSTableRowView *row) {
    if (!LionessIsReachable() || !IsInSidebar(row)) return;
    bool selected = row.isSelected && row.isEmphasized;
    for (NSView *sub in row.subviews)
        if (![sub isKindOfClass:NSVisualEffectView.class]) DressSidebarContent(sub, selected);
}

static void (*gOrigSidebarCellLayout)(NSView *, SEL);
static void HookSidebarCellLayout(NSView *self, SEL _cmd) {
    gOrigSidebarCellLayout(self, _cmd);
    UpdateFinderSidebarCell(self);
}

// SwiftUI's Image(systemName:) goes straight to its own symbol renderer and never asks NSImage. Its String argument arrives as two registers.
static NSString *NSStringFromSwift(uint64_t countAndFlags, uint64_t object) {
    uint8_t top = object >> 56;
    if (top & 0x20) {   // small: the characters are in the registers themselves
        char bytes[16];
        memcpy(bytes, &countAndFlags, 8);
        memcpy(bytes + 8, &object, 8);
        return [[[NSString alloc] initWithBytes:bytes length:top & 0x0f encoding:NSUTF8StringEncoding] autorelease];
    }
    if (top & 0x50) return nil;   // bridged or foreign: not a symbol name written in code
    const char *bytes = (const char *)((object & 0x0fffffffffffffffull) + 32);
    return [[[NSString alloc] initWithBytes:bytes length:countAndFlags & 0xffffffffffffull encoding:NSUTF8StringEncoding] autorelease];
}
static void *(*gOrigImageSystemName)(uint64_t, uint64_t);
static void *(*gImageFromNSImage)(id);
static void *HookImageSystemName(uint64_t countAndFlags, uint64_t object) {
    @autoreleasepool {
        NSString *source = GlyphSources()[NSStringFromSwift(countAndFlags, object) ?: @""];
        NSImage *lion = source && gImageFromNSImage ? LionGlyph(source, NSMakeSize(16, 16), false) : nil;
        if (lion) return gImageFromNSImage([lion retain]);   // the initializer takes ownership
    }
    return gOrigImageSystemName(countAndFlags, object);
}

static void InstallGlyphs(void) {
    void *systemName = DobbySymbolResolver("SwiftUICore", "$s7SwiftUI5ImageV10systemNameACSS_tcfC");
    void *fromNSImage = dlsym(RTLD_DEFAULT, "$s7SwiftUI5ImageV02nsC0ACSo7NSImageC_tcfC");
    if (getenv("LIONESS_DUMP")) fprintf(stderr, "GLYPH Image(systemName:) %p Image(nsImage:) %p\n", systemName, fromNSImage);
    if (systemName && fromNSImage) {
        gImageFromNSImage = (void *(*)(id))fromNSImage;
        DobbyHook(systemName, (void *)HookImageSystemName, (void **)&gOrigImageSystemName);
        // Not Image(systemName:variableValue:) or Image(_systemName:colorPalette:): they are so short that the hook's patch would
        // overwrite the next function.
    }
    Class image = NSImage.class;
    Method symbol = class_getClassMethod(image, @selector(imageWithSystemSymbolName:accessibilityDescription:));
    if (symbol) gOrigSymbol = (NSImage *(*)(id, SEL, NSString *, NSString *))method_setImplementation(symbol, (IMP)HookSymbol);
    Method named = class_getClassMethod(image, @selector(imageNamed:));
    if (named) gOrigNamed = (NSImage *(*)(id, SEL, NSString *))method_setImplementation(named, (IMP)HookNamed);
    Override("NSImage", @selector(imageWithSymbolConfiguration:), (IMP)HookWithConfiguration, &gOrigWithConfiguration);
    Override("NSImage", @selector(setTemplate:), (IMP)HookSetTemplate, &gOrigSetTemplate);
    if (objc_getClass("TSidebarItemCell")) Override("TSidebarItemCell", @selector(layout), (IMP)HookSidebarCellLayout, &gOrigSidebarCellLayout);
}

static void DisableBlendModes(void) {
    unsigned classCount = 0, replaced = 0;
    Class *classes = objc_copyClassList(&classCount);
    for (unsigned i = 0; i < classCount; i++) {
        const char *name = class_getName(classes[i]);
        if (strncmp(name, "NS", 2) != 0 && strncmp(name, "_NS", 3) != 0) continue;
        unsigned count = 0;
        Method *methods = class_copyMethodList(classes[i], &count);
        for (unsigned k = 0; k < count; k++) {
            const char *selector = sel_getName(method_getName(methods[k]));
            const char *types = method_getTypeEncoding(methods[k]);
            if (!types || types[0] != 'i' || (!strcasestr(selector, "BlendMode") && !strcasestr(selector, "vibrancyBlend"))) continue;
            IMP replacement = (IMP)NoBlend;
            if (!strcmp(selector, "vibrancyBlendInAppearance:outBezelBlend:outTitleBlend:")) replacement = (IMP)NoBlendVibrancy3;
            else if (!strcmp(selector, "vibrancyBlendInAppearance:outBezelBlend:outTitleBlend:outImageBlend:")) replacement = (IMP)NoBlendVibrancy4;
            else if (strstr(selector, "outHasVibrancyIncompatability")) replacement = (IMP)NoBlendContextDrawing;
            else if (!strcmp(selector, "blendModeForTitleInAppearance:outHasTitle:")) { gOrigTitleBlend = (int (*)(id, SEL, id, BOOL *))method_getImplementation(methods[k]); replacement = (IMP)HookTitleBlend; }
            else if (!strcmp(selector, "blendModeForImageInAppearance:outHasImage:")) { gOrigImageBlend = (int (*)(id, SEL, id, BOOL *))method_getImplementation(methods[k]); replacement = (IMP)HookImageBlend; }
            else if (!strcmp(selector, "blendModeForBezelInAppearance:bounds:outHasBezel:")) { gOrigBezelBlend = (int (*)(id, SEL, id, CGRect, BOOL *))method_getImplementation(methods[k]); replacement = (IMP)HookBezelBlend; }
            method_setImplementation(methods[k], replacement);
            replaced++;
        }
        free(methods);
    }
    free(classes);
    if (gDump) fprintf(stderr, "BLEND replaced %u methods\n", replaced);
}

// The menu bar, in MenuBarAgent. Its windows have no background of their own, and titles and status items choose their colours
// for the wallpaper behind them. So the window takes Lion's bar, and a status item, which another process draws, is
// recoloured here. Selection is a layer of AppMenuItemContainerView holding a backdrop; AppKit is not asked about any of it.
static bool IsNamed(id object, const char *name) {
    for (Class c = object_getClass(object); c; c = class_getSuperclass(c)) if (strstr(class_getName(c), name)) return true;
    return false;
}

// Lightness inverted and hue kept: white goes black and black white, and a red icon stays red.
static NSArray *BrightnessInversion(void) {
    static NSArray *filters;
    if (filters) return filters;
    float m[20] = { 1 - .598f, -1.174f, -.228f, 0, 1,  -.598f, 1 - 1.174f, -.228f, 0, 1,  -.598f, -1.174f, 1 - .228f, 0, 1,  0, 0, 0, 1, 0 };
    id filter = ((id (*)(id, SEL, id))objc_msgSend)((id)objc_getClass("CAFilter"), sel_registerName("filterWithType:"), @"colorMatrix");
    if (!filter) return nil;
    [filter setValue:[NSValue value:m withObjCType:"{CAColorMatrix=ffffffffffffffffffff}"] forKey:@"inputColorMatrix"];
    return filters = [@[ filter ] retain];
}

static void SetInverted(CALayer *layer, bool inverted) {
    if (layer && (layer.filters.count > 0) != inverted) layer.filters = inverted ? BrightnessInversion() : nil;
}

static CGImageRef CreateBarArt(NSString *widget, NSString *state, CGFloat height, uint32_t scale) {
    CGImageRef lion = LionessCopyDrawnImage((__bridge CFDictionaryRef)@{ @"widget": widget, @"state": state, @"is.flipped": @NO }, 64, (uint32_t)ceil(height), scale);
    if (!lion) return NULL;
    CGImageRef contents = CreateLayerContents(lion, CGSizeMake(64, height), scale);
    CGImageRelease(lion);
    return contents;
}

static NSString *const kBarTitleLayer = @"lioness.barTitle";
static NSString *const kBarLayer = @"lioness.bar";

// A selection has no view behind it and is a title's height. Everything of its own goes, and Lion's art runs the full height of the bar.
static NSHashTable *gBarBackdrops;
static id (*gOrigBackdropInit)(id, SEL);
static id HookBackdropInit(id self, SEL _cmd) {
    id layer = gOrigBackdropInit(self, _cmd);
    ((CALayer *)layer).hidden = YES;   // or it shows until the selection it belongs to is found
    dispatch_async(dispatch_get_main_queue(), ^{
        if (!gBarBackdrops) gBarBackdrops = [[NSHashTable weakObjectsHashTable] retain];
        if (layer) [gBarBackdrops addObject:layer];
    });
    return layer;
}

static bool LooksLikeBarSelection(CALayer *layer) {
    if (layer.delegate || [layer.name hasPrefix:@"lioness."]) return false;
    const char *name = object_getClassName(layer);
    if (strstr(name, "BackingLayerContents") || strstr(name, "Scene")) return false;   // a title's text, and what another process draws
    CALayer *shown = layer.presentationLayer ?: layer;
    if (layer.hidden || shown.opacity < 0.01) return false;
    CGSize size = layer.bounds.size;
    return size.height >= 16 && size.height <= 34 && size.width >= 16 && size.width <= 400;
}

// The agent's selection is hidden rather than dressed, as it animates open and anything inside it would too. Lion's art goes
// beside it at its final size, and leaves when it does.
static NSMapTable *gBarSelections;   // selection -> Lion's layer

static void DressBarSelection(CALayer *selection, CALayer *barLayer, CGFloat barHeight, uint32_t scale) {
    if (!gBarSelections) gBarSelections = [[NSMapTable weakToStrongObjectsMapTable] retain];
    selection.hidden = YES;
    CALayer *parent = selection.superlayer;
    if (!parent || [gBarSelections objectForKey:selection]) return;
    // Kept: a round trip to appkitd here would hold up the frame the selection first appears in.
    static CGImageRef art;
    static CGFloat artKey;
    if (!art || artKey != barHeight * scale) {
        CGImageRef fresh = CreateBarArt(@"kCUIWidgetMenuTitle", @"pressed", barHeight, scale);
        if (!fresh) return;
        CGImageRelease(art);
        art = fresh;
        artKey = barHeight * scale;
    }
    CALayer *title = [CALayer layer];
    title.name = kBarTitleLayer;
    title.actions = @{ @"bounds": NSNull.null, @"position": NSNull.null, @"contents": NSNull.null, @"hidden": NSNull.null, @"opacity": NSNull.null, @"filters": NSNull.null };
    SetContents(title, art, scale, CGRectMake(0.49, 0, 0.02, 1));
    CGRect bar = [barLayer convertRect:barLayer.bounds toLayer:parent];
    id owner = parent.delegate;
    // The agent's own selection runs 14 points past each side of a title. A status item's container already has its margins.
    CGFloat x = 0, width = parent.bounds.size.width;
    if (IsNamed(owner, "AppMenuItemView")) { x = -14; width += 28; }
    else if (!IsNamed(owner, "SceneHostDisplayItemContainerView")) { x = selection.frame.origin.x; width = selection.frame.size.width; }
    title.frame = CGRectMake(x, bar.origin.y, width, bar.size.height);
    title.zPosition = -1;   // beneath the title
    [parent addSublayer:title];
    [gBarSelections setObject:title forKey:selection];
}

static void (*gOrigLayerRemove)(CALayer *, SEL);
static void DressMenuBars(void);
static void HookLayerRemove(CALayer *self, SEL _cmd) {
    CALayer *title = [gBarSelections objectForKey:self];
    if (title) {
        [CATransaction begin];
        [CATransaction setDisableActions:YES];
        gOrigLayerRemove(title, _cmd);
        [gBarSelections removeObjectForKey:self];
        [CATransaction commit];
        gOrigLayerRemove(self, _cmd);
        DressMenuBars();
        return;
    }
    gOrigLayerRemove(self, _cmd);
}

// Under the bar's own views, wherever it is, but not inside what another process or an image view draws.
static void FindBarSelections(CALayer *layer, CALayer *barLayer, CGFloat barHeight, uint32_t scale, int depth) {
    for (CALayer *sub in layer.sublayers) {
        if ([sub.name isEqual:kBarLayer]) continue;
        if (LooksLikeBarSelection(sub) && ![sub isKindOfClass:objc_getClass("CABackdropLayer")]) {
            DressBarSelection(sub, barLayer, barHeight, scale);
            continue;
        }
        id delegate = sub.delegate;
        if (depth < 8 && (!delegate || IsNamed(delegate, "AppMenuItem") || IsNamed(delegate, "MenuBarHitTestingView") || IsNamed(delegate, "SceneHostDisplayItemContainerView"))) FindBarSelections(sub, barLayer, barHeight, scale, depth + 1);
    }
}

static bool DressMenuBarWindow(NSWindow *window) {
    NSView *hit = window.contentView, *frame = hit.superview;
    if (!frame.layer || !IsNamed(hit, "MenuBarHitTestingView")) return false;
    CGFloat height = window.frame.size.height;
    uint32_t scale = ScaleOf(@{}, window.backingScaleFactor);
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    // Its own layer, as the frame view paints over contents set on its layer.
    CALayer *bar = nil;
    for (CALayer *sub in frame.layer.sublayers) if ([sub.name isEqual:kBarLayer]) bar = sub;
    if (!bar) {
        bar = [CALayer layer];
        bar.name = kBarLayer;
        bar.actions = @{ @"bounds": NSNull.null, @"position": NSNull.null, @"contents": NSNull.null };
        [frame.layer insertSublayer:bar atIndex:0];
    }
    bar.frame = frame.layer.bounds;
    static char barKey;
    NSNumber *dressed = objc_getAssociatedObject(window, &barKey);
    if (dressed.doubleValue != height * scale) {
        CGImageRef art = CreateBarArt(@"kCUIWidgetMenuBar", @"normal", height, scale);
        if (art) {
            SetContents(bar, art, scale, CGRectMake(0.49, 0, 0.02, 1));
            CGImageRelease(art);
            objc_setAssociatedObject(window, &barKey, @(height * scale), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
    }
    FindBarSelections(frame.layer, frame.layer, height, scale, 0);
    // A blur the agent made, in a place the search does not reach.
    for (CALayer *backdrop in gBarBackdrops.allObjects) {
        CALayer *parent = backdrop.superlayer;
        if (!parent || !LooksLikeBarSelection(parent)) continue;
        CALayer *root = parent;
        while (root.superlayer) root = root.superlayer;
        if (root == frame.layer || root == frame.layer.superlayer) DressBarSelection(parent, frame.layer, height, scale);
    }
    // A selection taken away by some other means than removeFromSuperlayer.
    for (CALayer *selection in gBarSelections.keyEnumerator.allObjects) {
        if (selection.superlayer) { selection.hidden = YES; continue; }
        gOrigLayerRemove([gBarSelections objectForKey:selection], @selector(removeFromSuperlayer));
        [gBarSelections removeObjectForKey:selection];
    }
    bool selecting = false;
    for (NSView *view in hit.subviews) {
        CALayer *title = nil;
        for (CALayer *sub in view.layer.sublayers) if ([sub.name isEqual:kBarTitleLayer]) title = sub;
        selecting |= title != nil;
        // The white label's inversion would take the blue with it, so the blue is inverted back.
        if (IsNamed(view, "AppMenuItemView")) { SetInverted(view.layer, title); SetInverted(title, title); }
        else if (IsNamed(view, "SceneHostDisplayItemContainerView")) SetInverted(view.layer, !title);
    }
    [CATransaction commit];
    return selecting;
}

// GCD, as this process does not run its main run loop in a way that fires an NSTimer.
static dispatch_source_t MainQueueTimer(double seconds, void (^block)(void)) {
    dispatch_source_t timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
    dispatch_source_set_timer(timer, dispatch_time(DISPATCH_TIME_NOW, 0), (uint64_t)(seconds * NSEC_PER_SEC), (uint64_t)(seconds * NSEC_PER_SEC / 10));
    dispatch_source_set_event_handler(timer, block);
    dispatch_resume(timer);
    return timer;
}

static dispatch_source_t gBarSelectionTimer;
static void DressMenuBars(void) {
    bool selecting = false;
    @try {
        for (NSWindow *window in NSApp.windows)
            if (window.frame.size.height <= 60 && IsNamed(window, "DisplayItemAppKitWindow")) selecting |= DressMenuBarWindow(window);
    } @catch (NSException *) {}
    if (!selecting && gBarSelectionTimer) { dispatch_source_cancel(gBarSelectionTimer); gBarSelectionTimer = NULL; }
    else if (selecting && !gBarSelectionTimer) gBarSelectionTimer = MainQueueTimer(1.0 / 30, ^{ DressMenuBars(); [CATransaction flush]; });
}

// Each selection is a new layer. Dressed here, in the transaction that adds it, it never reaches the screen as AppKit made it.
static void BarLayerGainedSublayer(CALayer *layer, CALayer *sublayer) {
    id delegate = layer.delegate;
    if (!delegate || !(IsNamed(delegate, "AppMenuItem") || IsNamed(delegate, "SceneHostDisplayItemContainerView"))) return;
    // Possibly not sized yet, in which case the blue takes its width when it is.
    if (sublayer.bounds.size.width > 0 ? !LooksLikeBarSelection(sublayer) : (sublayer.delegate || [sublayer.name hasPrefix:@"lioness."] || strstr(object_getClassName(sublayer), "Scene") || strstr(object_getClassName(sublayer), "BackingLayerContents"))) return;
    NSWindow *window = [delegate window];
    NSView *frame = window.contentView.superview;
    if (!frame.layer) return;
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    DressBarSelection(sublayer, frame.layer, window.frame.size.height, ScaleOf(@{}, window.backingScaleFactor));
    [CATransaction commit];
    DressMenuBars();
}
static void (*gOrigBarAddSublayer)(CALayer *, SEL, CALayer *);
static void HookBarAddSublayer(CALayer *self, SEL _cmd, CALayer *sublayer) {
    gOrigBarAddSublayer(self, _cmd, sublayer);
    BarLayerGainedSublayer(self, sublayer);
}
static void (*gOrigBarInsertSublayer)(CALayer *, SEL, CALayer *, unsigned);
static void HookBarInsertSublayer(CALayer *self, SEL _cmd, CALayer *sublayer, unsigned index) {
    gOrigBarInsertSublayer(self, _cmd, sublayer, index);
    BarLayerGainedSublayer(self, sublayer);
}

// The agent recolours every status item as if it were white, as the system's are. A skinned app's title is black, so it says otherwise.
static void (*gOrigStatusButtonTitle)(NSButton *, SEL, NSString *);
static void HookStatusButtonTitle(NSButton *self, SEL _cmd, NSString *title) {
    gOrigStatusButtonTitle(self, _cmd, title);
    if (title.length) self.attributedTitle = [[[NSAttributedString alloc] initWithString:title attributes:@{ NSForegroundColorAttributeName: NSColor.whiteColor, NSFontAttributeName: self.font ?: [NSFont menuBarFontOfSize:0] }] autorelease];
}

static void InstallMenuBar(void) {
    Override("NSStatusBarButton", @selector(setTitle:), (IMP)HookStatusButtonTitle, &gOrigStatusButtonTitle);
    if (strcmp(getprogname(), "MenuBarAgent")) return;
    Override("CABackdropLayer", @selector(init), (IMP)HookBackdropInit, &gOrigBackdropInit);
    Override("CALayer", @selector(removeFromSuperlayer), (IMP)HookLayerRemove, &gOrigLayerRemove);
    Override("NSViewBackingLayer", @selector(addSublayer:), (IMP)HookBarAddSublayer, &gOrigBarAddSublayer);
    Override("NSViewBackingLayer", @selector(insertSublayer:atIndex:), (IMP)HookBarInsertSublayer, &gOrigBarInsertSublayer);
    // The agent's windows come and go with Spaces and displays, and say nothing to AppKit that could be hooked.
    static dispatch_source_t timer;
    timer = MainQueueTimer(0.25, ^{ DressMenuBars(); [CATransaction flush]; });
}

static void Install(void) {
    static bool done;
    if (done) return;
    done = true;
    gTrace = getenv("LIONESS_TRACE") != NULL;
    gForceActive = getenv("LIONESS_FORCE_ACTIVE") != NULL;
    gDump = getenv("LIONESS_DUMP") != NULL;

    Class flags = objc_getClass("_NSSwiftUICoreFeatureFlags");
    Class appearance = objc_getClass("NSAppearance");
    if (!flags || !appearance) return;   // not AppKit, or an AppKit this was not read against

    // Solarium first: AppKit has to see NO the first time it asks.
    unsigned count = 0;
    Method *methods = class_copyMethodList(object_getClass(flags), &count);
    for (unsigned i = 0; i < count; i++)
        if (strstr(sel_getName(method_getName(methods[i])), "olarium"))
            method_setImplementation(methods[i], (IMP)ReturnNo);
    free(methods);

    Override("NSAppearance", sel_registerName("_createOrUpdateLayer:options:"), (IMP)HookLayer, &gOrigLayer);
    Override("NSAppearance", sel_registerName("_drawInRect:context:options:"), (IMP)HookDraw, &gOrigDraw);
    Override("NSAppearance", sel_registerName("_createLayerContents:contentsCenter:"), (IMP)HookContents, &gOrigContents);
    Override("NSButton", @selector(setKeyEquivalent:), (IMP)HookSetKeyEquivalent, &gOrigSetKeyEquivalent);
    Override("NSTitlebarBackgroundView", @selector(layout), (IMP)HookBackgroundLayout, &gOrigBackgroundLayout);
    Override("NSTitlebarBackgroundView", @selector(viewDidMoveToWindow), (IMP)HookBackgroundMoved, &gOrigBackgroundMoved);
    Override("NSTitlebarBackgroundView", @selector(updateLayer), (IMP)HookBackgroundUpdateLayer, &gOrigBackgroundUpdateLayer);
    Override("NSSplitViewItemAccessoryClipView", @selector(layout), (IMP)HookAccessoryLayout, &gOrigAccessoryLayout);
    Override("NSVisualEffectView", @selector(layout), (IMP)HookMaterialLayout, &gOrigMaterialLayout);
    Override("NSTabBar", @selector(layout), (IMP)HookTabBarLayout, &gOrigTabBarLayout);
    Override("_NSSplitViewItemViewWrapper", @selector(setFrame:), (IMP)HookWrapperSetFrame, &gOrigWrapperSetFrame);
    Override("NSVibrantSplitDividerView", @selector(layout), (IMP)HookVibrantDividerLayout, &gOrigVibrantDividerLayout);
    Override("NSToolbarItemViewer", @selector(layout), (IMP)HookToolbarViewerLayout, &gOrigToolbarViewerLayout);
    Override("NSToolbarView", @selector(setFrame:), (IMP)HookToolbarSetFrame, &gOrigToolbarSetFrame);
    Override("NSMenuBarItemView", sel_registerName("idealWidth"), (IMP)HookMenuBarIdealWidth, &gOrigMenuBarIdealWidth);
    if (void *ensure = DobbySymbolResolver("AppKit", "-[NSMenuBarItemView _ensureValidLineCache]")) DobbyHook(ensure, (void *)HookEnsureLineCache, (void **)&gOrigEnsureLineCache);
    else os_log(OS_LOG_DEFAULT, "Lioness: no _ensureValidLineCache symbol");
    if (objc_getClass("UnifiedField")) Override("UnifiedField", @selector(layout), (IMP)HookFieldLayout, &gOrigFieldLayout);
    Override("NSTableRowView", @selector(setEmphasized:), (IMP)HookRowEmphasized, &gOrigRowEmphasized);
    ObserveMainWindow();
    DisableStyledText();
    DisableBlendModes();
    Override("CALayer", @selector(setCompositingFilter:), (IMP)HookSetFilter, &gOrigSetFilter);
    Override("NSView", @selector(effectiveAppearance), (IMP)HookEffectiveAppearance, &gOrigEffectiveAppearance);
    DisableVibrancy();
    UseLionColors();
    InstallGlyphs();
    InstallMenuBar();

    // These fill themselves from layers without asking CoreUI. Asked to draw instead, they come here.
    Override("NSBox", @selector(drawRect:), (IMP)HookBoxDraw, &gOrigBoxDraw);
    Override("NSBox", @selector(wantsUpdateLayer), (IMP)ReturnNoLayer, (BOOL (**)(id, SEL))NULL);
    Override("NSLevelIndicator", @selector(drawRect:), (IMP)HookLevelDraw, &gOrigLevelDraw);
    Override("NSLevelIndicator", @selector(wantsUpdateLayer), (IMP)ReturnNoLayer, (BOOL (**)(id, SEL))NULL);

    Override("NSContextMenuImpl", sel_registerName("_setHighlighted:menuItemView:"), (IMP)HookMenuSetHighlighted, &gOrigMenuSetHighlighted);
    Override("NSPopupMenuWindow", sel_registerName("_cornerMask"), (IMP)HookMenuCornerMask, &gOrigMenuCornerMask);
    Override("NSPopupMenuWindow", sel_registerName("_cornerMaskShouldDefineShadow"), (IMP)HookMenuMaskDefinesShadow, &gOrigMenuMaskDefinesShadow);
    Override("NSPopupMenuWindow", sel_registerName("_commonPresentFromView:animated:"), (IMP)HookMenuPresent, &gOrigMenuPresent);
    Override("NSRootMenuWindowBackgroundView", @selector(layout), (IMP)HookMenuBackgroundLayout, &gOrigMenuBackgroundLayout);
    Override("NSTableRowView", @selector(setSelected:), (IMP)HookRowSelected, &gOrigRowSelected);
    Override("NSTableRowView", @selector(layout), (IMP)HookRowLayout, &gOrigRowLayout);
    Override("NSSegmentItemView", sel_registerName("_preferredAppearanceForSegmentLabelView:"), (IMP)HookSegmentLabelAppearance, &gOrigSegmentLabelAppearance);
    Override("NSSegmentItemView", sel_registerName("_preferredAppearanceForSegmentImageView:"), (IMP)HookSegmentImageAppearance, &gOrigSegmentImageAppearance);
    Override("NSSegmentItemView", sel_registerName("emphasized"), (IMP)HookSegmentEmphasized, &gOrigSegmentEmphasized);
    Override("NSSegmentItemLabelCell", sel_registerName("_textAttributes"), (IMP)HookLabelAttributes, &gOrigLabelAttributes);
    Override("NSSegmentItemLabelCell", sel_registerName("_contentStyleOverride"), (IMP)NoContentStyle, (id (**)(id, SEL))NULL);
    Override("NSSegmentItemLabelCell", sel_registerName("interiorBackgroundStyle"), (IMP)HookLabelStyle, &gOrigLabelStyle);
    Override("NSButtonCell", sel_registerName("interiorBackgroundStyle"), (IMP)ButtonLabelStyle, (NSBackgroundStyle (**)(NSButtonCell *, SEL))NULL);
    Override("NSButtonCell", sel_registerName("_shouldDrawTextWithDisabledAppearance"), (IMP)HookDisabledText, &gOrigDisabledText);
    Override("NSTabViewItem", sel_registerName("interiorBackgroundStyle"), (IMP)HookTabStyle, &gOrigTabStyle);
    Override("NSTabViewItem", sel_registerName("_labelColor"), (IMP)HookTabLabelColor, &gOrigTabLabelColor);

    Override("NSApplication", @selector(appearance), (IMP)AquaAppearance, (NSAppearance *(**)(id, SEL))NULL);
    Override("NSApplication", @selector(effectiveAppearance), (IMP)AquaAppearance, (NSAppearance *(**)(id, SEL))NULL);
    os_log(OS_LOG_DEFAULT, "Lioness: loaded into %{public}s", getprogname());
}

__attribute__((constructor)) static void LionessInit(void) { Install(); }

// Ammonia's entry point. The constructor has already done the work.
extern "C" __attribute__((visibility("default"))) void LoadFunction(void *) { Install(); }

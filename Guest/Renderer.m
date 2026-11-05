// The guest half of appkitd: x86-64, linked against Lion's frameworks, executed by the engine. It serves
// render requests itself; the host half checked in the Mach service and passes the receive right's name
// in LIONESS_PORT (a guest shares the host process's port namespace).

#import <AppKit/AppKit.h>
#include <ApplicationServices/ApplicationServices.h>
#include <Carbon/Carbon.h>
#include <dlfcn.h>
#include <mach/mach.h>
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "../Shared/Protocol.h"

// Lion's CoreUI. What Lion's AppKit calls for every control; not in any public header.
extern void *CUICreateRenderer(CFDictionaryRef properties);
extern void CUIDraw(void *renderer, CGRect frame, CGContextRef context, CFDictionaryRef options, CFDictionaryRef *results);
extern Boolean CUIExists(void *renderer, CFDictionaryRef options);
extern const CFStringRef kCUIScaleKey;
extern void CGContextSetBaseCTM(CGContextRef context, CGAffineTransform transform);

// CoreUI and HITheme pick 1x or 2x art from the context's default user space, its base CTM, which AppKit sets on a Retina window. A plain
// CGContextScaleCTM leaves that at 1, so they choose 1x art and the CTM doubles it.
static void SetBackingScale(CGContextRef cg, CGFloat scale) {
    CGContextSetBaseCTM(cg, CGAffineTransformMakeScale(scale, scale));
    CGContextScaleCTM(cg, scale, scale);
}

static void *gRenderer;

// CoreUI answers a request it has no art for with an error tile, not with nothing: orange "CUI" over red question
// marks on green, and CUIExists is only meaningful for named images. No control has red and orange together
// in any amount (a close button has red, a minimize button has orange, and they are separate pictures).
static bool IsErrorTile(const uint8_t *pixels, size_t size) {
    size_t red = 0, orange = 0, pixelsCount = size / 4;
    for (size_t i = 0; i + 4 <= size; i += 4) {
        uint8_t b = pixels[i], g = pixels[i + 1], r = pixels[i + 2], a = pixels[i + 3];
        if (a < 200) continue;
        if (r > 150 && g < 50 && b < 50) red++;
        else if (r > 170 && g > 110 && g < 200 && b < 70) orange++;
    }
    return red * 400 > pixelsCount && orange * 400 > pixelsCount;
}

// Blue or graphite. CoreUI holds this in CUIGetTheme's private gTheme (0 blue, 1 graphite, negative not read yet) and fills
// it once from the AppleAquaColorVariant preference, which this process has no reason to have. Apps may differ, so
// each request says. The distance is from Mountain Lion 10.8.5's CoreUI, md5 321891e887e4c674a4d1667fad9427f8, the only one this runs.
static void SelectTheme(CFDictionaryRef options) {
    static const ptrdiff_t kThemeFromCUIDraw = 0xd3580 - 0x32b17;
    *(int *)((char *)CUIDraw + kThemeFromCUIDraw) = CFDictionaryContainsKey(options, CFSTR("lioness.graphite")) ? 1 : 0;
}

// Flavours themes. A theme names 30-odd slots, each a stack of archived layers, top first: fills, strokes and shadows. They paint inside
// the shape of Lion's art for that control. Read here because Lion's own NSKeyedUnarchiver and NSColor can read them. One theme at a
// time, chosen by LionessSetup.sh; with no file here, this is all skipped.
@interface LionessFlavourLayer : NSObject <NSCoding> {
@public
    BOOL enabled, hasStroke, hasFill, hasInner, hasOuter, hasImage;
    double strokeWidth, blur, offsetX, offsetY, alpha;
    int fillType, anchor, scaling, imageType;
    NSColor *strokeColor, *solidColor, *glossColor, *shadowColor;
    NSArray *colors, *locations;
    NSString *inherits;
    NSData *image, *image2x;
    NSDictionary *info, *variants;   // when this is a whole Flavours 2 theme
}
@end
@implementation LionessFlavourLayer
// Themes hold numbers either inline or as archived objects, depending on their age.
static double FlavourNumber(NSCoder *c, NSString *key) {
    if (![c containsValueForKey:key]) return 0;
    @try { id o = [c decodeObjectForKey:key]; if ([o respondsToSelector:@selector(doubleValue)]) return [o doubleValue]; } @catch (NSException *e) {}
    @try { return [c decodeDoubleForKey:key]; } @catch (NSException *e) {}
    return 0;
}
- (id)initWithCoder:(NSCoder *)c {
    self = [super init];
    enabled = ![c containsValueForKey:@"Enabled"] || FlavourNumber(c, @"Enabled") != 0;
    if ([c containsValueForKey:@"Enabled"] && !enabled) @try { enabled = [c decodeBoolForKey:@"Enabled"]; } @catch (NSException *e) {}
    if ([c containsValueForKey:@"Variants"]) {
        info = [[c decodeObjectForKey:@"Info"] retain];
        variants = [[c decodeObjectForKey:@"Variants"] retain];
        return self;
    }
    if ((hasStroke = [c containsValueForKey:@"StrokeColor"])) {
        strokeColor = [[c decodeObjectForKey:@"StrokeColor"] retain];
        strokeWidth = FlavourNumber(c, @"StrokeWidth");
    }
    if ((hasFill = [c containsValueForKey:@"FillType"])) {
        fillType = (int)FlavourNumber(c, @"FillType");
        solidColor = [[c decodeObjectForKey:@"Solid Color"] retain];
        glossColor = [[c decodeObjectForKey:@"Gloss Color"] retain];
        colors = [[c decodeObjectForKey:@"Colors"] retain];
        locations = [[c decodeObjectForKey:@"Locations"] retain];
    }
    if ((hasInner = [c containsValueForKey:@"InnerShadowColor"])) {
        shadowColor = [[c decodeObjectForKey:@"InnerShadowColor"] retain];
        blur = FlavourNumber(c, @"InnerShadowBlurRadius");
        offsetX = FlavourNumber(c, @"InnerShadowOffsetWidth");
        offsetY = FlavourNumber(c, @"InnerShadowOffsetHeight");
    }
    if ((hasOuter = [c containsValueForKey:@"OutterShadowColor"])) {
        shadowColor = [[c decodeObjectForKey:@"OutterShadowColor"] retain];
        blur = FlavourNumber(c, @"OutterShadowBlurRadius");
        offsetX = FlavourNumber(c, @"OutterShadowOffsetWidth");
        offsetY = FlavourNumber(c, @"OutterShadowOffsetHeight");
    }
    if ((hasImage = [c containsValueForKey:@"ImageType"] || [c containsValueForKey:@"Image"])) {
        image = [[c decodeObjectForKey:@"Image"] retain];
        if ([c containsValueForKey:@"Image@2x"]) image2x = [[c decodeObjectForKey:@"Image@2x"] retain];
        anchor = (int)FlavourNumber(c, @"Anchor");
        scaling = (int)FlavourNumber(c, @"Scale");
        imageType = (int)FlavourNumber(c, @"ImageType");
        alpha = [c containsValueForKey:@"Alpha"] ? FlavourNumber(c, @"Alpha") : 1;
    }
    if ([c containsValueForKey:@"InheritURL"]) {
        id url = [c decodeObjectForKey:@"InheritURL"];
        inherits = [[url isKindOfClass:NSURL.class] ? [url absoluteString] : url retain];
    }
    return self;
}
- (void)encodeWithCoder:(NSCoder *)c {}
@end

// Every layer class in a theme decodes as the one above. The class names differ between theme versions.
@interface LionessFlavourDecoder : NSObject <NSKeyedUnarchiverDelegate>
@end
@implementation LionessFlavourDecoder
- (Class)unarchiver:(NSKeyedUnarchiver *)u cannotDecodeObjectOfClassName:(NSString *)name originalClasses:(NSArray *)classes {
    return LionessFlavourLayer.class;
}
@end

static NSDictionary *gFlavour;
static NSMutableDictionary *gFlavourSlots;

static LionessFlavourDecoder *FlavourDecoder(void) {
    static LionessFlavourDecoder *decoder;
    if (!decoder) decoder = [LionessFlavourDecoder new];
    return decoder;
}

static id FlavourUnarchive(NSData *data) {
    id root = nil;
    NSKeyedUnarchiver *u = nil;
    @try {
        u = [[NSKeyedUnarchiver alloc] initForReadingWithData:data];
        u.delegate = FlavourDecoder();
        root = [[u decodeObjectForKey:@"root"] retain];
        [u finishDecoding];
    } @catch (NSException *e) { root = nil; }
    [u release];
    return [root autorelease];
}

// Flavours 1 themes are a plist. Flavours 2 themes are an archive of the same layers in variants, one of them the default.
static void LoadFlavour(void) {
    gFlavourSlots = [NSMutableDictionary new];
    NSData *data = [NSData dataWithContentsOfFile:@"/usr/share/lioness/flavour.theme"];
    id layers = nil;
    if (data) {
        id plist = [NSPropertyListSerialization propertyListWithData:data options:0 format:NULL error:NULL];
        if ([plist isKindOfClass:NSDictionary.class] && plist[@"$objects"]) {
            LionessFlavourLayer *theme = FlavourUnarchive(data);
            if ([theme isKindOfClass:LionessFlavourLayer.class]) {
                NSString *key = theme->info[@"DefaultVariant"];
                id variant = key ? theme->variants[key] : theme->variants.allValues.firstObject;
                layers = variant[@"Layers"];
            }
        } else if ([plist isKindOfClass:NSDictionary.class]) layers = plist[@"Layers"];
    }
    gFlavour = [layers isKindOfClass:NSDictionary.class] ? [layers retain] : nil;
    fprintf(stderr, "renderer: flavour %s\n", gFlavour ? "loaded" : "none");
}

// Top first. A smart layer stands for the stack of the slot it names.
static NSArray *FlavourSlot(NSString *path, int depth) {
    NSArray *known = gFlavourSlots[path];
    if (known) return known;
    NSMutableArray *result = [NSMutableArray array];
    id node = gFlavour;
    for (NSString *part in [path componentsSeparatedByString:@"/"]) node = [node isKindOfClass:NSDictionary.class] ? node[part] : nil;
    if ([node isKindOfClass:NSArray.class] && depth < 6) {
        for (id item in node) {
            id layer = [item isKindOfClass:NSData.class] ? FlavourUnarchive(item) : item;
            if (![layer isKindOfClass:LionessFlavourLayer.class]) continue;
            LionessFlavourLayer *l = layer;
            if (l->inherits.length) {
                if ([l->inherits hasPrefix:@"style://"] && l->enabled) [result addObjectsFromArray:FlavourSlot([l->inherits substringFromIndex:8], depth + 1)];
            } else if (l->enabled) [result addObject:l];
        }
    }
    gFlavourSlots[path] = result;
    return result;
}

static CGColorRef FlavourColor(NSColor *color) {
    // Calibrated colours are gamma 1.8 and this bitmap is sRGB, near enough 2.2: taken as they are, they come out too dark.
    bool calibrated = [color.colorSpaceName hasPrefix:@"NSCalibrated"];
    NSColor *rgb = [color colorUsingColorSpaceName:calibrated ? NSCalibratedRGBColorSpace : NSDeviceRGBColorSpace];
    if (!rgb) return NULL;
    CGColorSpaceRef space = CGColorSpaceCreateDeviceRGB();
    CGFloat c[4] = { rgb.redComponent, rgb.greenComponent, rgb.blueComponent, rgb.alphaComponent };
    if (calibrated) for (int i = 0; i < 3; i++) c[i] = pow(c[i], 1.8 / 2.2);
    CGColorRef result = CGColorCreate(space, c);
    CGColorSpaceRelease(space);
    return result;
}

// Image layers: PNG or JPEG 2000, anchored on a 3 by 3 grid counted from the top left, as a tile or scaled.
static void DrawFlavourImage(LionessFlavourLayer *l, CGContextRef cg, CGRect area, uint32_t scale, CGColorSpaceRef space) {
    NSData *data = scale > 1 && l->image2x.length ? l->image2x : l->image;
    if (![data isKindOfClass:NSData.class] || !data.length) return;
    CGImageSourceRef source = CGImageSourceCreateWithData((CFDataRef)data, NULL);
    CGImageRef tagged = source ? CGImageSourceCreateImageAtIndex(source, 0, NULL) : NULL;
    if (source) CFRelease(source);
    if (!tagged) return;
    // Its profile would be matched to this untagged bitmap, and come out too dark. The numbers are what Flavours showed.
    CGImageRef image = CGImageCreateCopyWithColorSpace(tagged, space) ?: CGImageRetain(tagged);
    CGImageRelease(tagged);
    CGFloat density = data == l->image2x ? 1 : scale;   // an image for 1x is doubled on a 2x bitmap
    CGFloat w = CGImageGetWidth(image) * density, h = CGImageGetHeight(image) * density;
    CGContextSaveGState(cg);
    CGContextSetAlpha(cg, l->alpha);
    if (l->imageType == 1) {
        for (CGFloat y = CGRectGetMaxY(area) - h; y > area.origin.y - h; y -= h)
            for (CGFloat x = area.origin.x; x < CGRectGetMaxX(area); x += w) CGContextDrawImage(cg, CGRectMake(x, y, w, h), image);
    } else if (l->scaling == 2) {
        CGContextDrawImage(cg, area, image);
    } else {
        if (l->scaling == 1) { CGFloat fit = MIN(area.size.width / w, area.size.height / h); w *= fit; h *= fit; }
        CGFloat x = area.origin.x + (l->anchor % 3) * (area.size.width - w) / 2, y = area.origin.y + (2 - l->anchor / 3) * (area.size.height - h) / 2;
        CGContextDrawImage(cg, CGRectMake(x, y, w, h), image);
    }
    CGContextRestoreGState(cg);
    CGImageRelease(image);
}

static CGImageRef GrayMask(const uint8_t *alpha, size_t width, size_t height) {
    CGColorSpaceRef gray = CGColorSpaceCreateDeviceGray();
    CFDataRef data = CFDataCreate(NULL, alpha, width * height);
    CGDataProviderRef provider = CGDataProviderCreateWithCFData(data);
    CGImageRef image = CGImageCreate(width, height, 8, 8, width, gray, kCGImageAlphaNone, provider, NULL, false, kCGRenderingIntentDefault);
    CGDataProviderRelease(provider);
    CFRelease(data);
    CGColorSpaceRelease(gray);
    return image;
}

// Lion's art gives the shape. With keepDetail its marks survive too, as light and dark over the theme's colour.
static void PaintFlavour(NSString *slot, bool keepDetail, void *pixels, uint32_t width, uint32_t height, uint32_t rowBytes, uint32_t scale, CGColorSpaceRef space) {
    if (!gFlavour) return;
    NSArray *layers = FlavourSlot(slot, 0);
    if (!layers.count) return;
    uint8_t *p = pixels;
    uint8_t *shape = malloc((size_t)width * height), *outside = malloc((size_t)width * height);
    uint8_t *art = malloc((size_t)rowBytes * height);
    if (!shape || !outside || !art) { free(shape); free(outside); free(art); return; }
    memcpy(art, p, (size_t)rowBytes * height);
    int top = -1, bottom = -1, left = (int)width, right = -1;
    for (uint32_t y = 0; y < height; y++) for (uint32_t x = 0; x < width; x++) {
        uint8_t a = p[y * rowBytes + x * 4 + 3];
        shape[y * width + x] = a;
        outside[y * width + x] = 255 - a;
        if (a > 8) { if (top < 0) top = (int)y; bottom = (int)y; if ((int)x < left) left = (int)x; if ((int)x > right) right = (int)x; }
    }
    if (top < 0) { free(shape); free(outside); free(art); return; }
    CGImageRef shapeImage = GrayMask(shape, width, height), outsideImage = GrayMask(outside, width, height);
    CGContextRef cg = CGBitmapContextCreate(pixels, width, height, 8, rowBytes, space, kCGImageAlphaPremultipliedFirst | kCGBitmapByteOrder32Little);
    CGDataProviderRef artProvider = CGDataProviderCreateWithData(NULL, art, (size_t)rowBytes * height, NULL);
    CGImageRef artImage = CGImageCreate(width, height, 8, 32, rowBytes, space, kCGImageAlphaPremultipliedFirst | kCGBitmapByteOrder32Little, artProvider, NULL, false, kCGRenderingIntentDefault);
    CGRect all = CGRectMake(0, 0, width, height);
    CGRect area = CGRectMake(left, height - bottom - 1, right - left + 1, bottom - top + 1);
    CGContextClearRect(cg, all);
    for (LionessFlavourLayer *l in layers) if (l->hasOuter) {
        CGColorRef color = FlavourColor(l->shadowColor);
        CGContextSaveGState(cg);
        CGContextSetShadowWithColor(cg, CGSizeMake(l->offsetX * scale, -l->offsetY * scale), l->blur * scale, color);
        CGContextDrawImage(cg, all, artImage);
        CGContextRestoreGState(cg);
        if (color) CGColorRelease(color);
    }
    CGContextSaveGState(cg);
    CGContextClipToMask(cg, all, shapeImage);
    for (LionessFlavourLayer *l in layers.reverseObjectEnumerator) {
        if (l->hasImage) {
            DrawFlavourImage(l, cg, area, scale, space);
        } else if (l->hasFill) {
            if (l->fillType == 2 && l->colors.count >= 2) {
                NSMutableArray *cgColors = [NSMutableArray array];
                CGFloat *stops = calloc(l->colors.count, sizeof(CGFloat));
                for (NSUInteger i = 0; i < l->colors.count; i++) {
                    CGColorRef c = FlavourColor(l->colors[i]);
                    if (c) { [cgColors addObject:(id)c]; CGColorRelease(c); }
                    stops[i] = i < l->locations.count ? [l->locations[i] doubleValue] : (CGFloat)i / (l->colors.count - 1);
                }
                CGGradientRef gradient = CGGradientCreateWithColors(space, (CFArrayRef)cgColors, stops);
                // Row 0 is the top of the bitmap, which is the largest y here.
                CGContextDrawLinearGradient(cg, gradient, CGPointMake(0, height - top), CGPointMake(0, height - bottom - 1), kCGGradientDrawsBeforeStartLocation | kCGGradientDrawsAfterEndLocation);
                CGGradientRelease(gradient);
                free(stops);
            } else if (l->solidColor) {
                CGColorRef c = FlavourColor(l->solidColor);
                CGContextSetFillColorWithColor(cg, c);
                CGContextFillRect(cg, all);
                if (c) CGColorRelease(c);
                // Glossy: the upper half lit.
                if (l->fillType == 1 && l->glossColor) {
                    CGColorRef gloss = FlavourColor([l->glossColor colorWithAlphaComponent:0.35]);
                    CGContextSetFillColorWithColor(cg, gloss);
                    CGContextFillRect(cg, CGRectMake(0, height - top - (bottom - top + 1) / 2, width, (bottom - top + 1) / 2));
                    if (gloss) CGColorRelease(gloss);
                }
            }
        } else if (l->hasInner) {
            CGColorRef color = FlavourColor(l->shadowColor);
            CGContextSaveGState(cg);
            CGContextSetShadowWithColor(cg, CGSizeMake(l->offsetX * scale, -l->offsetY * scale), l->blur * scale, color);
            CGContextBeginTransparencyLayer(cg, NULL);
            CGContextClipToMask(cg, all, outsideImage);
            CGContextSetGrayFillColor(cg, 0, 1);
            CGContextFillRect(cg, all);
            CGContextEndTransparencyLayer(cg);
            CGContextRestoreGState(cg);
            if (color) CGColorRelease(color);
        } else if (l->hasStroke && l->strokeWidth > 0) {
            CGColorRef color = FlavourColor(l->strokeColor);
            CGFloat w = l->strokeWidth * scale;
            CGSize offsets[4] = { { w, 0 }, { -w, 0 }, { 0, w }, { 0, -w } };
            for (int i = 0; i < 4; i++) {
                CGContextSaveGState(cg);
                CGContextClipToMask(cg, CGRectOffset(all, offsets[i].width, offsets[i].height), outsideImage);
                CGContextSetFillColorWithColor(cg, color);
                CGContextFillRect(cg, all);
                CGContextRestoreGState(cg);
            }
            if (color) CGColorRelease(color);
        }
    }
    if (keepDetail) {
        CGContextSetBlendMode(cg, kCGBlendModeLuminosity);
        CGContextDrawImage(cg, all, artImage);
    }
    CGContextRestoreGState(cg);
    CGContextFlush(cg);
    CGImageRelease(artImage);
    CGDataProviderRelease(artProvider);
    CGImageRelease(shapeImage);
    CGImageRelease(outsideImage);
    CGContextRelease(cg);
    free(shape);
    free(outside);
    free(art);
}

static bool IsInactive(CFDictionaryRef options) {
    CFStringRef state = CFDictionaryGetValue(options, CFSTR("state")), presentation = CFDictionaryGetValue(options, CFSTR("kCUIPresentationStateKey"));
    return (state && CFEqual(state, CFSTR("inactive"))) || (presentation && CFEqual(presentation, CFSTR("kCUIPresentationStateInactive")));
}

// Which slot paints a widget, and whether it has marks of its own to keep.
static NSString *FlavourSlotForOptions(CFDictionaryRef options, bool *keepDetail) {
    NSString *widget = (NSString *)CFDictionaryGetValue(options, CFSTR("widget"));
    NSString *state = (NSString *)CFDictionaryGetValue(options, CFSTR("state"));
    *keepDetail = false;
    if ([widget isEqual:@"kCUIWidgetMenuBar"]) return @"Menu/MenuBar/MenuBar";
    if ([widget isEqual:@"kCUIWidgetMenuTitle"]) return @"Menu/MenuBar/MenuSelection";
    if ([widget isEqual:@"kCUIWidgetMenu"]) return @"Menu/MenuItems/MenuBackground";
    if ([widget isEqual:@"kCUIWidgetMenuItem"]) return @"Menu/MenuItems/MenuSelection";
    // Flavours 2's own slots: the window's content, the sidebar and tabs. Flavours 1 themes do not have them, and these then stay as they are.
    if ([widget isEqual:@"gradient"]) {
        NSString *variant = (NSString *)CFDictionaryGetValue(options, CFSTR("kCUIVariantKey"));
        if ([variant rangeOfString:@"FinderSideBar"].length) return @"Window/Sidebar/Selection";
        if ([variant rangeOfString:@"Sid"].length) return @"Window/Sidebar/Background";
        return nil;
    }
    if ([widget isEqual:@"kCUIWidgetWindowBottomBar"]) return IsInactive(options) ? @"Window/BottomBar/BottomBarInactive" : @"Window/BottomBar/BottomBar";
    NSDictionary *lights = @{ @"titlebarclose": @"Close", @"titlebarcollapse": @"Min", @"titlebarzoom": @"Max" };
    if (lights[widget]) {
        NSString *light = [state isEqual:@"pressed"] ? @"Pressed" : [state isEqual:@"rollover"] ? @"Hover" : IsInactive(options) ? @"Inactive" : @"Active";
        *keepDetail = [light isEqual:@"Hover"];   // the glyph inside
        return [NSString stringWithFormat:@"Window/TitleBar%@Button/%@", lights[widget], light];
    }
    static NSSet *plain, *detailed;
    if (!plain) {
        plain = [[NSSet setWithObjects:@"pushbutton", @"pushbutton.inlay", @"pushbutton.scopeselector", @"bevelbutton", @"bevelbuttonround", @"bevelbuttoninset", nil] retain];
        detailed = [[NSSet setWithObjects:@"checkbox", @"radiobutton", @"popupbutton", @"popdownbutton", @"roundbutton", @"segmentedbutton", @"kCUIWidgetButtonSegmentedSCurve", @"kCUIWidgetButtonSegmentedInset", @"littlearrows", @"disclosurebutton", @"kCUIWidgetSliderThumb", @"kCUIWidgetButtonRoundHelp", @"tab", nil] retain];
    }
    bool textured = [widget rangeOfString:@"Textured"].length > 0;
    if (!textured && ![plain containsObject:widget] && ![detailed containsObject:widget]) return nil;
    *keepDetail = textured || [detailed containsObject:widget];
    NSString *group = textured ? @"Controls/Metal" : @"Controls/Aqua";
    if ([state isEqual:@"pressed"]) return [group stringByAppendingString:@"/Pressed"];
    if ([state isEqual:@"pulsed"] || [(NSNumber *)CFDictionaryGetValue(options, CFSTR("value")) intValue] == 1) return [group stringByAppendingString:@"/Active"];
    return [group stringByAppendingString:@"/Normal"];
}

// Modern AppKit asks for things Lion never had (large toolbar sizes, newer variants), so a tile gets retried in
// Lion's terms. If there is still no art the bitmap is left empty, and AppKit's own drawing stays.
static void DrawInLionsTerms(CFDictionaryRef options, CGContextRef cg, void *pixels, uint32_t width, uint32_t height, uint32_t rowBytes, uint32_t scale, CGRect frame, CGColorSpaceRef space) {
    SelectTheme(options);
    CFStringRef widget = CFDictionaryGetValue(options, CFSTR("widget"));
    // A kCUIWidget name this CoreUI does not export makes CUIDraw fault, parsing it as a number and using the NULL that gives. Lion
    // only declined these. Left empty, so AppKit keeps its own drawing.
    if (widget && CFStringHasPrefix(widget, CFSTR("kCUIWidget"))) {
        char symbol[128];
        // This one's value is not its symbol's name, which is kCUIWidgetProgressIndeterminateBar.
        if (!CFEqual(widget, CFSTR("kCUIWidgetIndeterminateBar")) &&
            (!CFStringGetCString(widget, symbol, sizeof symbol, kCFStringEncodingUTF8) || !dlsym(RTLD_DEFAULT, symbol))) return;
    }
    if (widget && CFEqual(widget, CFSTR("image"))) {
        CFMutableDictionaryRef o = CFDictionaryCreateMutableCopy(NULL, 0, options);
        CFDictionaryRemoveValue(o, kCUIScaleKey);
        if (CUIExists(gRenderer, o)) CUIDraw(gRenderer, frame, cg, o, NULL);
        CFRelease(o);
        return;
    }
    static const struct { bool regular, noVariant; } tries[] = { { false, false }, { true, false }, { false, true }, { true, true } };
    for (size_t i = 0; i < sizeof tries / sizeof *tries; i++) {
        CFMutableDictionaryRef o = CFDictionaryCreateMutableCopy(NULL, 0, options);
        if (tries[i].regular) CFDictionarySetValue(o, CFSTR("size"), CFSTR("regular"));
        if (tries[i].noVariant) CFDictionaryRemoveValue(o, CFSTR("kCUIVariantKey"));
        // With this key present CoreUI skips its own choice of scale, which comes from the context's base CTM (SetBackingScale).
        CFDictionaryRemoveValue(o, kCUIScaleKey);
        memset(pixels, 0, (size_t)rowBytes * height);
        CUIDraw(gRenderer, frame, cg, o, NULL);
        CGContextFlush(cg);
        CFRelease(o);
        if (!IsErrorTile(pixels, (size_t)rowBytes * height)) return;
    }
    memset(pixels, 0, (size_t)rowBytes * height);
}

static double NumberFor(CFDictionaryRef options, CFStringRef key) {
    double value = 0;
    CFNumberRef number = CFDictionaryGetValue(options, key);
    if (number && CFGetTypeID(number) == CFNumberGetTypeID()) CFNumberGetValue(number, kCFNumberDoubleType, &value);
    return value;
}

// Capacity level indicators are not CoreUI widgets in Lion: its NSLevelIndicatorCell paints them. So this one
// is Lion's AppKit itself, with a graphics context on our bitmap and no application around it.
static void DrawLevelIndicator(CFDictionaryRef options, CGContextRef cg, CGRect frame) {
    NSAutoreleasePool *pool = [NSAutoreleasePool new];
    NSLevelIndicatorCell *cell = [[NSLevelIndicatorCell alloc] initWithLevelIndicatorStyle:(NSLevelIndicatorStyle)NumberFor(options, CFSTR("style"))];
    cell.minValue = NumberFor(options, CFSTR("min"));
    cell.maxValue = NumberFor(options, CFSTR("max"));
    cell.warningValue = NumberFor(options, CFSTR("warning"));
    cell.criticalValue = NumberFor(options, CFSTR("critical"));
    cell.doubleValue = NumberFor(options, CFSTR("value"));
    NSGraphicsContext *context = [NSGraphicsContext graphicsContextWithGraphicsPort:cg flipped:NO];
    [NSGraphicsContext saveGraphicsState];
    [NSGraphicsContext setCurrentContext:context];
    [cell drawWithFrame:NSRectFromCGRect(frame) inView:nil];
    [NSGraphicsContext restoreGraphicsState];
    [cell release];
    [pool drain];
}

// Decoding an .icns takes over a second under the engine, longer than a client waits, so they are all decoded at startup.
static NSMutableDictionary *gImages;
// The sidebar icons hold two sets. The top level is near black; `sbpp`, a whole icon family nested inside, is the tinted and embossed art Finder shows.
static NSImage *SidebarImage(NSString *path) {
    NSData *file = [NSData dataWithContentsOfFile:path];
    const uint8_t *bytes = file.bytes;
    size_t size = file.length;
    for (size_t at = 8; file && at + 8 <= size;) {
        uint32_t length = OSSwapBigToHostInt32(*(const uint32_t *)(bytes + at + 4));
        if (length < 8 || at + length > size) break;
        if (!memcmp(bytes + at, "sbpp", 4)) {
            NSMutableData *family = [NSMutableData dataWithBytes:"icns" length:4];
            uint32_t total = OSSwapHostToBigInt32(length);
            [family appendBytes:&total length:4];
            [family appendBytes:bytes + at + 8 length:length - 8];
            NSImage *image = [[[NSImage alloc] initWithData:family] autorelease];
            if (image) return image;
            break;
        }
        at += length;
    }
    return [[[NSImage alloc] initWithContentsOfFile:path] autorelease];
}
static NSImage *LoadedImage(NSString *source) {
    if (!source) return nil;
    if (!gImages) gImages = [[NSMutableDictionary alloc] init];
    NSImage *image = [gImages objectForKey:source];
    if (image) return image;
    image = [source hasPrefix:@"/"] ? SidebarImage(source) : [NSImage imageNamed:source];
    if (image) [gImages setObject:image forKey:source];
    return image;
}
static void PreloadSidebarImages(CGColorSpaceRef space) {
    NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
    NSString *folder = @"/System/Library/CoreServices/CoreTypes.bundle/Contents/Resources";
    CGContextRef cg = CGBitmapContextCreate(NULL, 64, 64, 8, 0, space, kCGImageAlphaPremultipliedFirst | kCGBitmapByteOrder32Little);
    CGContextSetBaseCTM(cg, CGAffineTransformMakeScale(2, 2));
    CGContextScaleCTM(cg, 2, 2);
    NSGraphicsContext *context = [NSGraphicsContext graphicsContextWithGraphicsPort:cg flipped:NO];
    [NSGraphicsContext saveGraphicsState];
    [NSGraphicsContext setCurrentContext:context];
    for (NSString *file in [[NSFileManager defaultManager] contentsOfDirectoryAtPath:folder error:NULL]) {
        if (!([file hasPrefix:@"Sidebar"] || [file hasPrefix:@"Toolbar"] || [file isEqualToString:@"TrashIcon.icns"]) || ![file hasSuffix:@".icns"]) continue;
        NSImage *image = LoadedImage([folder stringByAppendingPathComponent:file]);
        [image drawInRect:NSMakeRect(0, 0, 16, 16) fromRect:NSZeroRect operation:NSCompositeSourceOver fraction:1];
    }
    for (NSString *name in [NSArray arrayWithObjects:@"NSUser", @"NSUserGroup", @"NSCaution", nil])
        [LoadedImage(name) drawInRect:NSMakeRect(0, 0, 16, 16) fromRect:NSZeroRect operation:NSCompositeSourceOver fraction:1];
    [NSGraphicsContext restoreGraphicsState];
    CGContextRelease(cg);
    [pool drain];
}

// A few things apps ask for that no Mountain Lion file holds, drawn the way its templates are: solid shapes, heavy lines.
static void DrawHandGlyph(NSString *name, CGRect frame) {
    [[NSColor blackColor] set];
    CGFloat side = MIN(frame.size.width, frame.size.height), line = MAX(1.5, side / 9);
    NSRect box = NSMakeRect(frame.origin.x + (frame.size.width - side) / 2, frame.origin.y + (frame.size.height - side) / 2, side, side);
    if ([name isEqualToString:@"lioness:magnify"]) {
        NSRect ring = NSMakeRect(NSMinX(box) + side * 0.12, NSMinY(box) + side * 0.34, side * 0.54, side * 0.54);
        NSBezierPath *circle = [NSBezierPath bezierPathWithOvalInRect:ring];
        [circle setLineWidth:line];
        [circle stroke];
        NSBezierPath *handle = [NSBezierPath bezierPath];
        [handle moveToPoint:NSMakePoint(NSMinX(box) + side * 0.60, NSMinY(box) + side * 0.40)];
        [handle lineToPoint:NSMakePoint(NSMinX(box) + side * 0.90, NSMinY(box) + side * 0.10)];
        [handle setLineWidth:line * 1.4];
        [handle setLineCapStyle:NSRoundLineCapStyle];
        [handle stroke];
    } else if ([name isEqualToString:@"lioness:info"]) {
        NSBezierPath *circle = [NSBezierPath bezierPathWithOvalInRect:NSInsetRect(box, side * 0.10, side * 0.10)];
        [circle setLineWidth:line];
        [circle stroke];
        CGFloat stem = MAX(1.5, side * 0.12);
        NSRectFill(NSMakeRect(NSMidX(box) - stem / 2, NSMinY(box) + side * 0.26, stem, side * 0.30));
        [[NSBezierPath bezierPathWithOvalInRect:NSMakeRect(NSMidX(box) - stem * 0.6, NSMinY(box) + side * 0.62, stem * 1.2, stem * 1.2)] fill];
    } else if ([name isEqualToString:@"lioness:eject"]) {
        NSBezierPath *triangle = [NSBezierPath bezierPath];
        [triangle moveToPoint:NSMakePoint(NSMidX(box), NSMinY(box) + side * 0.86)];
        [triangle lineToPoint:NSMakePoint(NSMinX(box) + side * 0.14, NSMinY(box) + side * 0.36)];
        [triangle lineToPoint:NSMakePoint(NSMinX(box) + side * 0.86, NSMinY(box) + side * 0.36)];
        [triangle closePath];
        [triangle fill];
        NSRectFill(NSMakeRect(NSMinX(box) + side * 0.14, NSMinY(box) + side * 0.14, side * 0.72, side * 0.14));
    } else {   // lioness:sidebarleading, lioness:sidebartrailing
        NSRect outer = NSMakeRect(NSMinX(box) + 1, NSMinY(box) + side * 0.18, side - 2, side * 0.64);
        NSBezierPath *frameShape = [NSBezierPath bezierPathWithRoundedRect:outer xRadius:2 yRadius:2];
        [frameShape setLineWidth:line * 0.8];
        [frameShape stroke];
        CGFloat column = side * 0.32;
        bool leading = [name isEqualToString:@"lioness:sidebarleading"];
        NSRectFill(NSMakeRect(leading ? NSMinX(outer) : NSMaxX(outer) - column, NSMinY(outer), column, outer.size.height));
    }
}

// One of Mountain Lion's own images, by NSImage name or by path. At its natural size if it fits, so its pixels land on pixels, and centred.
static void DrawNamedImage(CFDictionaryRef options, CGContextRef cg, CGRect frame) {
    NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
    NSString *wanted = (NSString *)CFDictionaryGetValue(options, CFSTR("source"));
    if ([wanted hasPrefix:@"lioness:"]) {
        NSGraphicsContext *context = [NSGraphicsContext graphicsContextWithGraphicsPort:cg flipped:NO];
        [NSGraphicsContext saveGraphicsState];
        [NSGraphicsContext setCurrentContext:context];
        DrawHandGlyph(wanted, frame);
        [NSGraphicsContext restoreGraphicsState];
        [pool drain];
        return;
    }
    NSImage *image = LoadedImage(wanted);
    NSSize natural = image.size;
    if (image && natural.width > 0 && natural.height > 0) {
        CGFloat fit = MIN(1, MIN(frame.size.width / natural.width, frame.size.height / natural.height));
        NSSize size = NSMakeSize(round(natural.width * fit), round(natural.height * fit));
        NSRect target = NSMakeRect(floor(frame.origin.x + (frame.size.width - size.width) / 2), floor(frame.origin.y + (frame.size.height - size.height) / 2), size.width, size.height);
        NSGraphicsContext *context = [NSGraphicsContext graphicsContextWithGraphicsPort:cg flipped:NO];
        [NSGraphicsContext saveGraphicsState];
        [NSGraphicsContext setCurrentContext:context];
        [image setTemplate:NO];
        [image drawInRect:target fromRect:NSZeroRect operation:NSCompositeSourceOver fraction:1];
        // On a selected row the same shape is white, as in Finder.
        if (CFDictionaryContainsKey(options, CFSTR("selected"))) {
            [[NSColor whiteColor] set];
            NSRectFillUsingOperation(NSInsetRect(frame, -16, -16), NSCompositeSourceIn);
        }
        [NSGraphicsContext restoreGraphicsState];
    }
    [pool drain];
}

static OSStatus DrawOptions(const LionessDrawMessage *m, void *pixels, uint32_t width, uint32_t height, uint32_t rowBytes, CGColorSpaceRef space) {
    if (!gRenderer) gRenderer = CUICreateRenderer(NULL);
    CFDataRef data = CFDataCreateWithBytesNoCopy(NULL, m->options, m->length, kCFAllocatorNull);
    CFPropertyListRef options = CFPropertyListCreateWithData(NULL, data, kCFPropertyListImmutable, NULL, NULL);
    CFRelease(data);
    if (!options || CFGetTypeID(options) != CFDictionaryGetTypeID()) return paramErr;
    CGContextRef cg = CGBitmapContextCreate(pixels, width, height, 8, rowBytes, space,
                                            kCGImageAlphaPremultipliedFirst | kCGBitmapByteOrder32Little);
    if (!cg) { CFRelease(options); return -1; }
    SetBackingScale(cg, m->scale);
    CGRect frame = CGRectMake(LIONESS_PADDING, LIONESS_PADDING, m->width, m->height);
    if (CFEqual(CFDictionaryGetValue(options, CFSTR("widget")) ?: CFSTR(""), CFSTR("lioness.image"))) DrawNamedImage(options, cg, frame);
    else if (CFEqual(CFDictionaryGetValue(options, CFSTR("widget")) ?: CFSTR(""), CFSTR("lioness.levelindicator"))) DrawLevelIndicator(options, cg, frame);
    else if (CFEqual(CFDictionaryGetValue(options, CFSTR("widget")) ?: CFSTR(""), CFSTR("lioness.slot"))) {
        // A theme's slot by name, for the surfaces Lion has no widget for. With no theme, or no such slot, this stays empty.
        NSString *slot = (NSString *)CFDictionaryGetValue(options, CFSTR("lioness.path"));
        if (gFlavour && FlavourSlot(slot, 0).count) {
            CGContextSetGrayFillColor(cg, 1, 1);
            CGContextFillRect(cg, frame);
            CGContextFlush(cg);
            PaintFlavour(slot, false, pixels, width, height, rowBytes, m->scale, space);
        }
    }
    else DrawInLionsTerms(options, cg, pixels, width, height, rowBytes, m->scale, frame, space);
    CGContextFlush(cg);
    CGContextRelease(cg);
    if (gFlavour) {
        bool keepDetail = false;
        NSString *slot = FlavourSlotForOptions(options, &keepDetail);
        if (slot) PaintFlavour(slot, keepDetail, pixels, width, height, rowBytes, m->scale, space);
    }
    CFRelease(options);
    return noErr;
}

static uint32_t IsBlank(const void *pixels, size_t size) {
    const uint64_t *w = pixels;
    for (size_t i = 0; i < size / 8; i++) if (w[i]) return 0;
    return 1;
}

static ThemeDrawState DrawState(uint32_t state) {
    switch (state) {
        case LionessStatePressed:  return kThemeStatePressed;
        case LionessStateInactive: return kThemeStateInactive;
        case LionessStateDisabled: return kThemeStateUnavailable;
        default:                   return kThemeStateActive;
    }
}

static OSStatus DrawButton(const LionessRequest *r, CGContextRef cg, HIRect bounds, ThemeButtonKind kind) {
    HIThemeButtonDrawInfo info;
    memset(&info, 0, sizeof info);
    info.state = DrawState(r->state);
    info.kind = kind;
    info.value = r->value == LionessValueOn ? kThemeButtonOn : r->value == LionessValueMixed ? kThemeButtonMixed : kThemeButtonOff;
    info.adornment = (r->isDefault ? kThemeAdornmentDefault : kThemeAdornmentNone) | (r->focused ? kThemeAdornmentFocus : 0);
    HIRect label;
    return HIThemeDrawButton(&bounds, &info, cg, kHIThemeOrientationInverted, &label);
}

static OSStatus DrawWidget(const LionessRequest *r, CGContextRef cg, HIRect bounds, ThemeTitleBarWidget widget) {
    HIThemeWindowWidgetDrawInfo info;
    memset(&info, 0, sizeof info);
    info.widgetState = DrawState(r->state);
    info.widgetType = widget;
    info.windowState = r->state == LionessStateInactive ? kThemeStateInactive : kThemeStateActive;
    info.windowType = kThemeDocumentWindow;
    info.attributes = kThemeWindowHasTitleText | kThemeWindowHasCloseBox | kThemeWindowHasCollapseBox | kThemeWindowHasFullZoom;
    info.titleHeight = 22;
    info.titleWidth = 100;

    // The rect passed in is the window's content, and the widget lands in the title bar above it. So
    // ask Lion where it would put this widget for a sample window, and move the drawing to our bounds.
    HIThemeWindowDrawInfo window;
    memset(&window, 0, sizeof window);
    window.state = info.windowState;
    window.windowType = info.windowType;
    window.attributes = info.attributes;
    window.titleHeight = info.titleHeight;
    window.titleWidth = info.titleWidth;
    HIRect content = CGRectMake(0, 0, 200, 100);
    WindowRegionCode region = widget == kThemeWidgetCloseBox ? kWindowCloseBoxRgn :
                              widget == kThemeWidgetZoomBox ? kWindowZoomBoxRgn : kWindowCollapseBoxRgn;
    HIShapeRef shape = NULL;
    OSStatus status = HIThemeGetWindowShape(&content, &window, region, &shape);
    if (status != noErr || !shape) return status ? status : paramErr;
    HIRect at;
    HIShapeGetBounds(shape, &at);
    CFRelease(shape);
    CGContextSaveGState(cg);
    // The shape is in y-down coordinates with the content at the origin, so the title bar has negative y.
    // This context has y going up, where that same spot is above the content's top edge.
    CGFloat atYUp = CGRectGetMaxY(content) + (-at.origin.y - at.size.height);
    CGContextTranslateCTM(cg, bounds.origin.x - at.origin.x, bounds.origin.y - atYUp);
    status = HIThemeDrawTitleBarWidget(&content, &info, cg, kHIThemeOrientationInverted);
    CGContextRestoreGState(cg);
    return status;
}

static OSStatus DrawFrame(const LionessRequest *r, CGContextRef cg, HIRect bounds) {
    HIThemeWindowDrawInfo info;
    memset(&info, 0, sizeof info);
    info.state = r->state == LionessStateInactive ? kThemeStateInactive : kThemeStateActive;
    info.windowType = kThemeDocumentWindow;
    // No widgets in this picture: AppKit has its own view for each, and asks for them one at a time. The
    // request is for the title bar alone, so the content below it has no height.
    info.attributes = kThemeWindowHasTitleText;
    info.titleHeight = bounds.size.height;
    info.titleWidth = bounds.size.width;
    // This context has y going up, and Lion puts the title bar above the content.
    HIRect content = bounds;
    content.size.height = 0;
    HIRect title;
    return HIThemeDrawWindowFrame(&content, &info, cg, kHIThemeOrientationInverted, &title);
}

static OSStatus DrawScroller(const LionessRequest *r, CGContextRef cg, HIRect bounds) {
    HIThemeTrackDrawInfo info;
    memset(&info, 0, sizeof info);
    info.kind = kThemeScrollBarMedium;
    info.bounds = bounds;
    info.min = 0;
    info.max = 100;
    info.value = 30;
    info.attributes = kThemeTrackShowThumb | (bounds.size.width > bounds.size.height ? kThemeTrackHorizontal : 0);
    info.enableState = r->state == LionessStateDisabled ? kThemeTrackDisabled :
                       r->state == LionessStateInactive ? kThemeTrackInactive : kThemeTrackActive;
    info.trackInfo.scrollbar.viewsize = 40;
    return HIThemeDrawTrack(&info, NULL, cg, kHIThemeOrientationInverted);
}

static OSStatus Render(const LionessRequest *r, void *pixels, uint32_t width, uint32_t height, uint32_t rowBytes, CGColorSpaceRef space) {
    CGContextRef cg = CGBitmapContextCreate(pixels, width, height, 8, rowBytes, space,
                                            kCGImageAlphaPremultipliedFirst | kCGBitmapByteOrder32Little);
    if (!cg) return -1;
    SetBackingScale(cg, r->scale);
    HIRect bounds = CGRectMake(LIONESS_PADDING, LIONESS_PADDING, r->width, r->height);
    OSStatus status;
    switch (r->kind) {
        case LionessPushButton:     status = DrawButton(r, cg, bounds, kThemePushButton); break;
        case LionessCheckBox:       status = DrawButton(r, cg, bounds, kThemeCheckBox); break;
        case LionessRadioButton:    status = DrawButton(r, cg, bounds, kThemeRadioButton); break;
        case LionessPopupButton:    status = DrawButton(r, cg, bounds, kThemePopupButton); break;
        case LionessCloseWidget:    status = DrawWidget(r, cg, bounds, kThemeWidgetCloseBox); break;
        case LionessMinimizeWidget: status = DrawWidget(r, cg, bounds, kThemeWidgetCollapseBox); break;
        case LionessZoomWidget:     status = DrawWidget(r, cg, bounds, kThemeWidgetZoomBox); break;
        case LionessWindowFrame:    status = DrawFrame(r, cg, bounds); break;
        case LionessScrollerTrack:  status = DrawScroller(r, cg, bounds); break;
        default:                    status = paramErr; break;
    }
    CGContextFlush(cg);
    CGContextRelease(cg);
    if (!status && gFlavour) {
        NSString *slot = nil;
        bool inactive = r->state == LionessStateInactive;
        NSString *widgetState = r->state == LionessStatePressed ? @"Pressed" : inactive ? @"Inactive" : @"Active";
        switch (r->kind) {
            case LionessWindowFrame:    slot = inactive ? @"Window/TitleBar/TitleBarInactive" : @"Window/TitleBar/TitleBar"; break;
            case LionessCloseWidget:    slot = [@"Window/TitleBarCloseButton/" stringByAppendingString:widgetState]; break;
            case LionessMinimizeWidget: slot = [@"Window/TitleBarMinButton/" stringByAppendingString:widgetState]; break;
            case LionessZoomWidget:     slot = [@"Window/TitleBarMaxButton/" stringByAppendingString:widgetState]; break;
            default: break;
        }
        if (slot) PaintFlavour(slot, false, pixels, width, height, rowBytes, r->scale, space);
    }
    return status;
}

int main(void) {
    const char *portText = getenv("LIONESS_PORT");
    if (!portText) { fprintf(stderr, "renderer: no LIONESS_PORT\n"); return 1; }
    mach_port_t port = (mach_port_t)strtoul(portText, NULL, 0);
    CGColorSpaceRef space = CGColorSpaceCreateDeviceRGB();
    LoadFlavour();
    PreloadSidebarImages(space);
    fprintf(stderr, "renderer: serving on port %#x\n", port);

    for (;;) {
        union {
            LionessRequestMessage request;
            LionessDrawMessage draw;
            LionessReplyMessage reply;
            char room[sizeof(LionessDrawMessage) + 128];
        } m;
        kern_return_t kr = mach_msg(&m.request.header, MACH_RCV_MSG, 0, sizeof m, port, MACH_MSG_TIMEOUT_NONE, MACH_PORT_NULL);
        if (kr != KERN_SUCCESS) {
            fprintf(stderr, "renderer: receive failed: %#x\n", kr);
            continue;
        }
        mach_port_t replyPort = m.request.header.msgh_remote_port;
        int id = m.request.header.msgh_id;
        if ((id != LIONESS_MSG_RENDER && id != LIONESS_MSG_DRAW) || !replyPort) {
            mach_msg_destroy(&m.request.header);
            continue;
        }
        LionessRequest r = m.request.request;
        LionessImageInfo info;
        memset(&info, 0, sizeof info);
        void *pixels = NULL;
        size_t size = 0;
        if (id == LIONESS_MSG_DRAW) {
            const LionessDrawMessage *d = &m.draw;
            if (d->scale < 1 || d->scale > LIONESS_MAX_SCALE || !d->width || !d->height || d->width > LIONESS_MAX_POINTS ||
                d->height > LIONESS_MAX_POINTS || d->length > LIONESS_MAX_OPTIONS) {
                info.status = (uint32_t)paramErr;
            } else {
                info.padding = LIONESS_PADDING;
                info.pixelWidth = (d->width + 2 * LIONESS_PADDING) * d->scale;
                info.pixelHeight = (d->height + 2 * LIONESS_PADDING) * d->scale;
                info.rowBytes = info.pixelWidth * 4;
                size = (size_t)info.rowBytes * info.pixelHeight;
                pixels = calloc(size, 1);
                info.status = pixels ? (uint32_t)DrawOptions(d, pixels, info.pixelWidth, info.pixelHeight, info.rowBytes, space) : (uint32_t)memFullErr;
                if (pixels && !info.status) info.blank = IsBlank(pixels, size);
            }
        } else if (r.scale < 1 || r.scale > LIONESS_MAX_SCALE || !r.width || !r.height || r.width > LIONESS_MAX_POINTS || r.height > LIONESS_MAX_POINTS) {
            info.status = (uint32_t)paramErr;
        } else {
            info.padding = LIONESS_PADDING;
            info.pixelWidth = (r.width + 2 * LIONESS_PADDING) * r.scale;
            info.pixelHeight = (r.height + 2 * LIONESS_PADDING) * r.scale;
            info.rowBytes = info.pixelWidth * 4;
            size = (size_t)info.rowBytes * info.pixelHeight;
            pixels = calloc(size, 1);
            info.status = pixels ? (uint32_t)Render(&r, pixels, info.pixelWidth, info.pixelHeight, info.rowBytes, space) : (uint32_t)memFullErr;
        }

        memset(&m.reply, 0, sizeof m.reply);
        m.reply.header.msgh_bits = MACH_MSGH_BITS_COMPLEX | MACH_MSGH_BITS(MACH_MSG_TYPE_MOVE_SEND_ONCE, 0);
        m.reply.header.msgh_size = sizeof m.reply;
        m.reply.header.msgh_remote_port = replyPort;
        m.reply.header.msgh_id = id + 100;
        m.reply.body.msgh_descriptor_count = 1;
        m.reply.pixels.address = pixels;
        m.reply.pixels.size = (mach_msg_size_t)(pixels ? size : 0);
        m.reply.pixels.deallocate = FALSE;
        m.reply.pixels.copy = MACH_MSG_VIRTUAL_COPY;
        m.reply.pixels.type = MACH_MSG_OOL_DESCRIPTOR;
        m.reply.info = info;
        kr = mach_msg(&m.reply.header, MACH_SEND_MSG, sizeof m.reply, 0, MACH_PORT_NULL, MACH_MSG_TIMEOUT_NONE, MACH_PORT_NULL);
        if (kr != KERN_SUCCESS) fprintf(stderr, "renderer: reply failed: %#x\n", kr);
        free(pixels);
    }
}

// Mountain Lion Dock fixes (com.apple.dock only):
// 1. Dock icon hover label (DOCKLabelLayer): dark translucent capsule pill with pointer triangle & bold white shadowed text.
// 2. Dock grid stack (DOCKStackGridLayer + DOCKStackGridItemLayer): dark translucent charcoal panel with crisp 1pt light
//    border, bottom pointer triangle, and white item/title labels.
// 3. Dock fan stack (DOCKStackFanItemLayer): dark translucent capsule pills behind white item labels.

#import <AppKit/AppKit.h>
#import <CoreText/CoreText.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/message.h>
#import <objc/runtime.h>

namespace {

// -----------------------------------------------------------------------------
// Helpers
// -----------------------------------------------------------------------------

template <typename F>
void Hook(Class cls, const char *name, F replacement, F *original) {
    SEL sel = sel_registerName(name);
    Method m = class_getInstanceMethod(cls, sel);
    if (!m) return;
    IMP previous = method_getImplementation(m);
    if (class_addMethod(cls, sel, (IMP)replacement, method_getTypeEncoding(m))) *original = (F)previous;
    else *original = (F)method_setImplementation(m, (IMP)replacement);
}

template <typename F>
void HookClassMethod(Class cls, const char *name, F replacement, F *original) {
    Class meta = object_getClass((id)cls);
    if (!meta) return;
    Hook(meta, name, replacement, original);
}

CTFontRef CachedLucidaBold(CGFloat size) {
    static NSMutableDictionary<NSNumber *, id> *cache;
    if (!cache) cache = [NSMutableDictionary dictionary];
    NSNumber *key = @(round(size * 2.0));
    id existing = cache[key];
    if (existing) return (__bridge CTFontRef)existing;
    CTFontRef font = CTFontCreateWithName(CFSTR("LucidaGrande-Bold"), size > 0 ? size : 12.0, NULL);
    if (font) {
        cache[key] = (__bridge id)font;
        CFRelease(font);
        return (__bridge CTFontRef)cache[key];
    }
    return NULL;
}

id GetIvarObject(id obj, const char *name) {
    if (!obj) return nil;
    Ivar iv = class_getInstanceVariable(object_getClass(obj), name);
    return iv ? object_getIvar(obj, iv) : nil;
}

BOOL LayerContainsDescendant(CALayer *root, CALayer *target) {
    if (!root || !target) return NO;
    if (root == target) return YES;
    for (CALayer *sub in root.sublayers) {
        if (LayerContainsDescendant(sub, target)) return YES;
    }
    return NO;
}

enum DockEdge { kEdgeBottom, kEdgeLeft, kEdgeRight };

DockEdge CurrentDockEdge(void) {
    NSString *o = [NSUserDefaults.standardUserDefaults stringForKey:@"orientation"];
    if ([o isEqualToString:@"left"]) return kEdgeLeft;
    if ([o isEqualToString:@"right"]) return kEdgeRight;
    return kEdgeBottom;
}

// Forces a CATextLayer / ECTextLayer / _ECVibrantTextLayer (and any nested text sublayers) to crisp white.
void MakeTextLayerWhite(CALayer *layer, CGFloat alpha) {
    if (!layer) return;
    layer.compositingFilter = nil;
    layer.filters = nil;
    CGColorRef white = CGColorCreateGenericRGB(1.0, 1.0, 1.0, alpha);
    if ([layer respondsToSelector:@selector(setForegroundColor:)]) {
        ((void (*)(id, SEL, CGColorRef))objc_msgSend)(layer, @selector(setForegroundColor:), white);
    }
    if ([layer respondsToSelector:@selector(fontSize)] && [layer respondsToSelector:@selector(setFont:)]) {
        CGFloat fsz = ((CGFloat (*)(id, SEL))objc_msgSend)(layer, @selector(fontSize));
        if (fsz > 1.0) {
            CTFontRef lf = CachedLucidaBold(fsz);
            if (lf) ((void (*)(id, SEL, CFTypeRef))objc_msgSend)(layer, @selector(setFont:), lf);
        }
    }
    if ([layer respondsToSelector:@selector(string)] && [layer respondsToSelector:@selector(setString:)]) {
        id str = ((id (*)(id, SEL))objc_msgSend)(layer, @selector(string));
        if ([str isKindOfClass:NSAttributedString.class]) {
            NSMutableAttributedString *m = [(NSAttributedString *)str mutableCopy];
            if (m.length > 0) {
                NSColor *col = [NSColor colorWithCalibratedWhite:1.0 alpha:alpha];
                [m addAttribute:NSForegroundColorAttributeName value:col range:NSMakeRange(0, m.length)];
                [m addAttribute:(__bridge NSString *)kCTForegroundColorAttributeName value:(__bridge id)white range:NSMakeRange(0, m.length)];
                [m enumerateAttribute:NSFontAttributeName inRange:NSMakeRange(0, m.length) options:0
                           usingBlock:^(id val, NSRange rng, BOOL *stop) {
                    (void)stop;
                    CGFloat sz = [val isKindOfClass:NSFont.class] ? [(NSFont *)val pointSize] : 12.0;
                    CTFontRef lf = CachedLucidaBold(sz);
                    if (lf) {
                        [m addAttribute:NSFontAttributeName value:(__bridge NSFont *)lf range:rng];
                        [m addAttribute:(__bridge NSString *)kCTFontAttributeName value:(__bridge id)lf range:rng];
                    }
                }];
                ((void (*)(id, SEL, id))objc_msgSend)(layer, @selector(setString:), m);
            }
        }
    }
    CGColorRelease(white);

    // Subtle dark shadow for crisp legibility on dark translucent backgrounds.
    CGColorRef shadow = CGColorCreateGenericRGB(0.0, 0.0, 0.0, 0.75);
    layer.shadowColor = shadow;
    layer.shadowOpacity = 1.0;
    layer.shadowRadius = 1.0;
    layer.shadowOffset = CGSizeMake(0.0, -1.0);
    CGColorRelease(shadow);

    for (CALayer *sub in layer.sublayers) {
        MakeTextLayerWhite(sub, alpha);
    }
}

// -----------------------------------------------------------------------------
// 1. Mountain Lion Dock Hover Label (DOCKLabelLayer)
// -----------------------------------------------------------------------------

NSString *const kLabelOverlayName = @"LionessDockLabel";

NSString *LabelStringForLayer(id labelLayer) {
    id src = nil;
    if ([labelLayer respondsToSelector:@selector(source)]) {
        src = ((id (*)(id, SEL))objc_msgSend)(labelLayer, @selector(source));
    }
    if (!src) src = GetIvarObject(labelLayer, "_source");
    if (!src) return nil;

    static SEL const kLabelSels[] = { @selector(label), @selector(title), @selector(displayName) };
    for (SEL s : kLabelSels) {
        if ([src respondsToSelector:s]) {
            id v = ((id (*)(id, SEL))objc_msgSend)(src, s);
            if ([v isKindOfClass:NSString.class] && [(NSString *)v length] > 0) return v;
        }
    }
    id iv = GetIvarObject(src, "_label");
    if ([iv isKindOfClass:NSString.class] && [(NSString *)iv length] > 0) return iv;
    return nil;
}

CGImageRef CreateDockLabelImage(NSString *text, DockEdge edge, CGFloat scale, CGSize *outSize) {
    if (scale < 1.0) scale = 2.0;

    NSFont *font = [NSFont fontWithName:@"LucidaGrande-Bold" size:13.5]
                ?: [NSFont boldSystemFontOfSize:13.5];

    NSShadow *textShadow = [NSShadow new];
    textShadow.shadowColor = [NSColor colorWithCalibratedWhite:0.0 alpha:0.80];
    textShadow.shadowOffset = NSMakeSize(0.0, -1.0);
    textShadow.shadowBlurRadius = 1.5;

    NSDictionary *attrs = @{
        NSFontAttributeName: font,
        NSForegroundColorAttributeName: NSColor.whiteColor,
        NSShadowAttributeName: textShadow,
    };
    NSAttributedString *attrStr = [[NSAttributedString alloc] initWithString:text attributes:attrs];
    NSSize textSize = [attrStr size];

    const CGFloat padX = 13.0;
    const CGFloat pillH = MAX(24.0, ceil(textSize.height) + 7.0);
    const CGFloat pillW = MAX(pillH, ceil(textSize.width) + padX * 2.0);
    const CGFloat triW = 12.0;
    const CGFloat triH = 6.0;
    const CGFloat margin = 4.0;

    CGFloat totalW = pillW + margin * 2.0 + (edge != kEdgeBottom ? triH : 0.0);
    CGFloat totalH = pillH + margin * 2.0 + (edge == kEdgeBottom ? triH : 0.0);
    if (outSize) *outSize = CGSizeMake(totalW, totalH);

    size_t pw = (size_t)ceil(totalW * scale);
    size_t ph = (size_t)ceil(totalH * scale);
    CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
    CGContextRef ctx = CGBitmapContextCreate(NULL, pw, ph, 8, pw * 4, cs,
                                             (CGBitmapInfo)kCGImageAlphaPremultipliedFirst | kCGBitmapByteOrder32Little);
    CGColorSpaceRelease(cs);
    if (!ctx) return NULL;

    CGContextScaleCTM(ctx, scale, scale);

    CGFloat px = margin + (edge == kEdgeLeft ? triH : 0.0);
    CGFloat py = margin + (edge == kEdgeBottom ? triH : 0.0);
    CGRect pill = CGRectMake(px, py, pillW, pillH);
    CGFloat r = pillH * 0.5;

    CGMutablePathRef path = CGPathCreateMutable();
    CGFloat midX = CGRectGetMidX(pill), midY = CGRectGetMidY(pill);
    CGFloat minX = CGRectGetMinX(pill), maxX = CGRectGetMaxX(pill);
    CGFloat minY = CGRectGetMinY(pill), maxY = CGRectGetMaxY(pill);

    if (edge == kEdgeBottom) {
        CGPathMoveToPoint(path, NULL, minX + r, maxY);
        CGPathAddLineToPoint(path, NULL, maxX - r, maxY);
        CGPathAddArc(path, NULL, maxX - r, midY, r, M_PI_2, -M_PI_2, true);
        CGPathAddLineToPoint(path, NULL, midX + triW * 0.5, minY);
        CGPathAddLineToPoint(path, NULL, midX, minY - triH);
        CGPathAddLineToPoint(path, NULL, midX - triW * 0.5, minY);
        CGPathAddLineToPoint(path, NULL, minX + r, minY);
        CGPathAddArc(path, NULL, minX + r, midY, r, -M_PI_2, M_PI_2, true);
        CGPathCloseSubpath(path);
    } else if (edge == kEdgeLeft) {
        CGPathMoveToPoint(path, NULL, minX + r, maxY);
        CGPathAddLineToPoint(path, NULL, maxX - r, maxY);
        CGPathAddArc(path, NULL, maxX - r, midY, r, M_PI_2, -M_PI_2, true);
        CGPathAddLineToPoint(path, NULL, minX + r, minY);
        CGPathAddArc(path, NULL, minX + r, midY, r, -M_PI_2, M_PI_2, true);
        CGPathCloseSubpath(path);
        CGPathMoveToPoint(path, NULL, minX + 1.0, midY + triW * 0.5);
        CGPathAddLineToPoint(path, NULL, minX - triH, midY);
        CGPathAddLineToPoint(path, NULL, minX + 1.0, midY - triW * 0.5);
        CGPathCloseSubpath(path);
    } else {
        CGPathMoveToPoint(path, NULL, minX + r, maxY);
        CGPathAddLineToPoint(path, NULL, maxX - r, maxY);
        CGPathAddArc(path, NULL, maxX - r, midY, r, M_PI_2, -M_PI_2, true);
        CGPathAddLineToPoint(path, NULL, minX + r, minY);
        CGPathAddArc(path, NULL, minX + r, midY, r, -M_PI_2, M_PI_2, true);
        CGPathCloseSubpath(path);
        CGPathMoveToPoint(path, NULL, maxX - 1.0, midY + triW * 0.5);
        CGPathAddLineToPoint(path, NULL, maxX + triH, midY);
        CGPathAddLineToPoint(path, NULL, maxX - 1.0, midY - triW * 0.5);
        CGPathCloseSubpath(path);
    }

    CGContextSaveGState(ctx);
    CGColorRef shadowCol = CGColorCreateGenericRGB(0.0, 0.0, 0.0, 0.38);
    CGContextSetShadowWithColor(ctx, CGSizeMake(0.0, -1.0), 2.5, shadowCol);
    CGColorRelease(shadowCol);
    CGContextSetRGBFillColor(ctx, 0.0, 0.0, 0.0, 0.68);
    CGContextAddPath(ctx, path);
    CGContextFillPath(ctx);
    CGContextRestoreGState(ctx);
    CGPathRelease(path);

    NSGraphicsContext *gc = [NSGraphicsContext graphicsContextWithCGContext:ctx flipped:NO];
    [NSGraphicsContext saveGraphicsState];
    [NSGraphicsContext setCurrentContext:gc];
    CGFloat tx = px + (pillW - textSize.width) * 0.5;
    CGFloat ty = py + (pillH - textSize.height) * 0.5 + 0.5;
    [attrStr drawAtPoint:NSMakePoint(floor(tx), floor(ty))];
    [NSGraphicsContext restoreGraphicsState];

    CGImageRef image = CGBitmapContextCreateImage(ctx);
    CGContextRelease(ctx);
    return image;
}

void ApplyMountainLionLabel(CALayer *labelLayer) {
    NSString *text = LabelStringForLayer(labelLayer);
    if (!text.length) return;

    [CATransaction begin];
    [CATransaction setDisableActions:YES];

    CALayer *overlay = nil;
    for (CALayer *sub in labelLayer.sublayers) {
        if ([sub.name isEqualToString:kLabelOverlayName]) {
            overlay = sub;
        } else {
            sub.hidden = YES;
            sub.opacity = 0.0;
        }
    }
    if (!overlay) {
        overlay = [CALayer layer];
        overlay.name = kLabelOverlayName;
        [labelLayer addSublayer:overlay];
    }

    labelLayer.contents = nil;
    labelLayer.backgroundColor = NULL;
    labelLayer.borderWidth = 0.0;
    labelLayer.shadowOpacity = 0.0;
    labelLayer.masksToBounds = NO;

    CGFloat scale = labelLayer.contentsScale >= 1.0 ? labelLayer.contentsScale : 2.0;
    CGSize sz = CGSizeZero;
    CGImageRef img = CreateDockLabelImage(text, CurrentDockEdge(), scale, &sz);
    if (img) {
        overlay.hidden = NO;
        overlay.opacity = 1.0;
        overlay.contentsScale = scale;
        overlay.contents = (__bridge id)img;
        CGImageRelease(img);
        overlay.bounds = CGRectMake(0, 0, sz.width, sz.height);
        CGRect b = labelLayer.bounds;
        overlay.position = CGPointMake(CGRectGetMidX(b), CGRectGetMidY(b));
    }

    [CATransaction commit];
}

void (*gOrigLabelUpdate)(id, SEL);
void HookLabelUpdate(id self, SEL _cmd) {
    gOrigLabelUpdate(self, _cmd);
    ApplyMountainLionLabel((CALayer *)self);
}

void (*gOrigLabelUpdateBg)(id, SEL);
void HookLabelUpdateBg(id self, SEL _cmd) {
    gOrigLabelUpdateBg(self, _cmd);
    ApplyMountainLionLabel((CALayer *)self);
}

void (*gOrigLabelUpdateImg)(id, SEL, float, long long);
void HookLabelUpdateImg(id self, SEL _cmd, float scale, long long orientation) {
    gOrigLabelUpdateImg(self, _cmd, scale, orientation);
    ApplyMountainLionLabel((CALayer *)self);
}

// -----------------------------------------------------------------------------
// 2. Mountain Lion Grid Stack Panel (DOCKStackGridLayer + DOCKStackGridItemLayer)
//    Dark translucent charcoal rounded rect, crisp 1pt light border, bottom pointer
//    triangle, and crisp white labels.
// -----------------------------------------------------------------------------

NSString *const kGridBgLayerName = @"LionessGridStackBg";

// Renders the Mountain Lion dark translucent grid stack box with 1pt border and bottom pointer triangle.
// Returned image extends below the box by triH (for bottom dock) so the triangle points to the stack tile.
CGImageRef CreateGridStackBgImage(CGSize boxSize, CGFloat pointerCenter, DockEdge edge, CGFloat scale, CGRect *outFrame) {
    if (boxSize.width < 20.0 || boxSize.height < 20.0) return NULL;
    if (scale < 1.0) scale = 2.0;

    const CGFloat r = 11.0;
    const CGFloat triW = 22.0;
    const CGFloat triH = 11.0;
    const CGFloat pad = 2.0;

    CGFloat extraL = (edge == kEdgeLeft) ? triH : 0.0;
    CGFloat extraR = (edge == kEdgeRight) ? triH : 0.0;
    CGFloat extraB = (edge == kEdgeBottom) ? triH : 0.0;

    CGFloat totalW = boxSize.width + pad * 2.0 + extraL + extraR;
    CGFloat totalH = boxSize.height + pad * 2.0 + extraB;
    if (outFrame) *outFrame = CGRectMake(-pad - extraL, -pad - extraB, totalW, totalH);

    size_t pw = (size_t)ceil(totalW * scale);
    size_t ph = (size_t)ceil(totalH * scale);
    if (pw > 8192 || ph > 8192) return NULL;

    CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
    CGContextRef ctx = CGBitmapContextCreate(NULL, pw, ph, 8, pw * 4, cs,
                                             (CGBitmapInfo)kCGImageAlphaPremultipliedFirst | kCGBitmapByteOrder32Little);
    CGColorSpaceRelease(cs);
    if (!ctx) return NULL;

    CGContextScaleCTM(ctx, scale, scale);

    // Inset by 0.5pt so the 1pt stroke lands cleanly on pixel boundaries.
    CGRect box = CGRectMake(pad + extraL + 0.5, pad + extraB + 0.5, boxSize.width - 1.0, boxSize.height - 1.0);
    CGFloat minX = CGRectGetMinX(box), maxX = CGRectGetMaxX(box);
    CGFloat minY = CGRectGetMinY(box), maxY = CGRectGetMaxY(box);

    CGMutablePathRef path = CGPathCreateMutable();
    if (edge == kEdgeBottom) {
        CGFloat cx = pointerCenter > 0.0 ? (pad + extraL + pointerCenter) : CGRectGetMidX(box);
        cx = fmax(minX + r + triW * 0.5 + 4.0, fmin(maxX - r - triW * 0.5 - 4.0, cx));
        CGPathMoveToPoint(path, NULL, minX + r, maxY);
        CGPathAddLineToPoint(path, NULL, maxX - r, maxY);
        CGPathAddArc(path, NULL, maxX - r, maxY - r, r, M_PI_2, 0.0, true);
        CGPathAddLineToPoint(path, NULL, maxX, minY + r);
        CGPathAddArc(path, NULL, maxX - r, minY + r, r, 0.0, -M_PI_2, true);
        CGPathAddLineToPoint(path, NULL, cx + triW * 0.5, minY);
        CGPathAddLineToPoint(path, NULL, cx, minY - triH);
        CGPathAddLineToPoint(path, NULL, cx - triW * 0.5, minY);
        CGPathAddLineToPoint(path, NULL, minX + r, minY);
        CGPathAddArc(path, NULL, minX + r, minY + r, r, -M_PI_2, -M_PI, true);
        CGPathAddLineToPoint(path, NULL, minX, maxY - r);
        CGPathAddArc(path, NULL, minX + r, maxY - r, r, M_PI, M_PI_2, true);
        CGPathCloseSubpath(path);
    } else if (edge == kEdgeLeft) {
        CGFloat cy = pointerCenter > 0.0 ? (pad + extraB + pointerCenter) : CGRectGetMidY(box);
        cy = fmax(minY + r + triW * 0.5 + 4.0, fmin(maxY - r - triW * 0.5 - 4.0, cy));
        CGPathMoveToPoint(path, NULL, minX + r, maxY);
        CGPathAddLineToPoint(path, NULL, maxX - r, maxY);
        CGPathAddArc(path, NULL, maxX - r, maxY - r, r, M_PI_2, 0.0, true);
        CGPathAddLineToPoint(path, NULL, maxX, minY + r);
        CGPathAddArc(path, NULL, maxX - r, minY + r, r, 0.0, -M_PI_2, true);
        CGPathAddLineToPoint(path, NULL, minX + r, minY);
        CGPathAddArc(path, NULL, minX + r, minY + r, r, -M_PI_2, -M_PI, true);
        CGPathAddLineToPoint(path, NULL, minX, cy - triW * 0.5);
        CGPathAddLineToPoint(path, NULL, minX - triH, cy);
        CGPathAddLineToPoint(path, NULL, minX, cy + triW * 0.5);
        CGPathAddLineToPoint(path, NULL, minX, maxY - r);
        CGPathAddArc(path, NULL, minX + r, maxY - r, r, M_PI, M_PI_2, true);
        CGPathCloseSubpath(path);
    } else {
        CGFloat cy = pointerCenter > 0.0 ? (pad + extraB + pointerCenter) : CGRectGetMidY(box);
        cy = fmax(minY + r + triW * 0.5 + 4.0, fmin(maxY - r - triW * 0.5 - 4.0, cy));
        CGPathMoveToPoint(path, NULL, minX + r, maxY);
        CGPathAddLineToPoint(path, NULL, maxX - r, maxY);
        CGPathAddArc(path, NULL, maxX - r, maxY - r, r, M_PI_2, 0.0, true);
        CGPathAddLineToPoint(path, NULL, maxX, cy + triW * 0.5);
        CGPathAddLineToPoint(path, NULL, maxX + triH, cy);
        CGPathAddLineToPoint(path, NULL, maxX, cy - triW * 0.5);
        CGPathAddLineToPoint(path, NULL, maxX, minY + r);
        CGPathAddArc(path, NULL, maxX - r, minY + r, r, 0.0, -M_PI_2, true);
        CGPathAddLineToPoint(path, NULL, minX + r, minY);
        CGPathAddArc(path, NULL, minX + r, minY + r, r, -M_PI_2, -M_PI, true);
        CGPathAddLineToPoint(path, NULL, minX, maxY - r);
        CGPathAddArc(path, NULL, minX + r, maxY - r, r, M_PI, M_PI_2, true);
        CGPathCloseSubpath(path);
    }

    // Dark translucent neutral black fill matching the reference photo.
    CGContextSetRGBFillColor(ctx, 0.0, 0.0, 0.0, 0.72);
    CGContextAddPath(ctx, path);
    CGContextFillPath(ctx);

    // Crisp 1pt light translucent border around both box and pointer triangle.
    CGContextSetRGBStrokeColor(ctx, 1.0, 1.0, 1.0, 0.45);
    CGContextSetLineWidth(ctx, 1.0);
    CGContextAddPath(ctx, path);
    CGContextStrokePath(ctx);

    CGPathRelease(path);
    CGImageRef out = CGBitmapContextCreateImage(ctx);
    CGContextRelease(ctx);
    return out;
}

void StyleGridStackBackground(CALayer *bgLayer, CALayer *contentLayer, CGFloat pointerCenter) {
    if (!bgLayer) return;
    CGRect b = bgLayer.bounds;
    if (b.size.width < 20.0 || b.size.height < 20.0) return;

    [CATransaction begin];
    [CATransaction setDisableActions:YES];

    bgLayer.backgroundColor = NULL;
    bgLayer.masksToBounds = NO;
    CALayer *bgImgLayer = nil;
    for (CALayer *sub in bgLayer.sublayers) {
        if ([sub.name isEqualToString:kGridBgLayerName]) {
            bgImgLayer = sub;
            continue;
        }
        if (contentLayer && LayerContainsDescendant(sub, contentLayer)) continue;
        sub.hidden = YES;
        sub.opacity = 0.0;
    }

    if (!bgImgLayer) {
        bgImgLayer = [CALayer layer];
        bgImgLayer.name = kGridBgLayerName;
        bgImgLayer.zPosition = -10.0;
        [bgLayer insertSublayer:bgImgLayer atIndex:0];
    }

    CGFloat scale = bgLayer.contentsScale >= 1.0 ? bgLayer.contentsScale : 2.0;
    DockEdge edge = CurrentDockEdge();
    CGRect frame = CGRectZero;
    CGImageRef img = CreateGridStackBgImage(b.size, pointerCenter, edge, scale, &frame);
    if (img) {
        bgImgLayer.frame = frame;
        bgImgLayer.contentsScale = scale;
        bgImgLayer.contents = (__bridge id)img;
        CGImageRelease(img);
    }

    [CATransaction commit];
}

void StyleGridStack(CALayer *gridLayer) {
    id bgCtrl = GetIvarObject(gridLayer, "_backgroundController");
    CALayer *bgLayer = nil;
    CALayer *contentLayer = nil;
    CGFloat center = 0.0;
    if (bgCtrl) {
        if ([bgCtrl respondsToSelector:@selector(layer)]) {
            id l = ((id (*)(id, SEL))objc_msgSend)(bgCtrl, @selector(layer));
            if ([l isKindOfClass:CALayer.class]) bgLayer = (CALayer *)l;
        }
        if ([bgCtrl respondsToSelector:@selector(contentLayer)]) {
            id l = ((id (*)(id, SEL))objc_msgSend)(bgCtrl, @selector(contentLayer));
            if ([l isKindOfClass:CALayer.class]) contentLayer = (CALayer *)l;
        }
        if ([bgCtrl respondsToSelector:@selector(center)]) {
            center = ((double (*)(id, SEL))objc_msgSend)(bgCtrl, @selector(center));
        }
    }

    StyleGridStackBackground(bgLayer ?: gridLayer, contentLayer, center);

    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    id titleLayer = GetIvarObject(gridLayer, "_titleTextLayer");
    if ([titleLayer isKindOfClass:CALayer.class]) MakeTextLayerWhite((CALayer *)titleLayer, 0.92);
    id titleHover = GetIvarObject(gridLayer, "_titleHoverTextLayer");
    if ([titleHover isKindOfClass:CALayer.class]) MakeTextLayerWhite((CALayer *)titleHover, 1.0);
    if ([gridLayer respondsToSelector:@selector(axTitleTextLayer)]) {
        id axTitle = ((id (*)(id, SEL))objc_msgSend)(gridLayer, @selector(axTitleTextLayer));
        if ([axTitle isKindOfClass:CALayer.class]) MakeTextLayerWhite((CALayer *)axTitle, 0.92);
    }
    [CATransaction commit];
}

id (*gOrigGridInit)(id, SEL, id, id);
id HookGridInit(id self, SEL _cmd, id stack, id source) {
    id r = gOrigGridInit(self, _cmd, stack, source);
    if (r) StyleGridStack((CALayer *)r);
    return r;
}

void (*gOrigGridLayout)(id, SEL);
void HookGridLayout(id self, SEL _cmd) {
    gOrigGridLayout(self, _cmd);
    StyleGridStack((CALayer *)self);
}

void (*gOrigGridReposition)(id, SEL, CGRect, double);
void HookGridReposition(id self, SEL _cmd, CGRect stage, double edge) {
    gOrigGridReposition(self, _cmd, stage, edge);
    StyleGridStack((CALayer *)self);
}

void (*gOrigGridSetTitle)(id, SEL, id);
void HookGridSetTitle(id self, SEL _cmd, id title) {
    gOrigGridSetTitle(self, _cmd, title);
    StyleGridStack((CALayer *)self);
}

void (*gOrigGridLayoutSublayers)(id, SEL);
void HookGridLayoutSublayers(id self, SEL _cmd) {
    gOrigGridLayoutSublayers(self, _cmd);
    StyleGridStack((CALayer *)self);
}

void KeepGridStyleOnCartouche(id ctrl) {
    if (![ctrl respondsToSelector:@selector(layer)]) return;
    id l = ((id (*)(id, SEL))objc_msgSend)(ctrl, @selector(layer));
    if (![l isKindOfClass:CALayer.class]) return;
    CALayer *bgLayer = (CALayer *)l;
    BOOL ours = NO;
    for (CALayer *sub in bgLayer.sublayers) {
        if ([sub.name isEqualToString:kGridBgLayerName]) { ours = YES; break; }
    }
    if (!ours) return;

    CALayer *contentLayer = nil;
    if ([ctrl respondsToSelector:@selector(contentLayer)]) {
        id cl = ((id (*)(id, SEL))objc_msgSend)(ctrl, @selector(contentLayer));
        if ([cl isKindOfClass:CALayer.class]) contentLayer = (CALayer *)cl;
    }
    CGFloat center = 0.0;
    if ([ctrl respondsToSelector:@selector(center)]) {
        center = ((double (*)(id, SEL))objc_msgSend)(ctrl, @selector(center));
    }
    StyleGridStackBackground(bgLayer, contentLayer, center);
}

void (*gOrigGlassLayout)(id, SEL);
void HookGlassLayout(id self, SEL _cmd) {
    gOrigGlassLayout(self, _cmd);
    KeepGridStyleOnCartouche(self);
}

void (*gOrigBackdropLayout)(id, SEL);
void HookBackdropLayout(id self, SEL _cmd) {
    gOrigBackdropLayout(self, _cmd);
    KeepGridStyleOnCartouche(self);
}

// -----------------------------------------------------------------------------
// 3. Grid & Fan Stack Item Labels (white text + dark capsule pill for fan items)
// -----------------------------------------------------------------------------

NSString *const kFanPillName = @"LionessFanPill";

void StyleStackItemText(id itemLayer) {
    if (![itemLayer respondsToSelector:@selector(textLayer)]) return;
    id tl = ((id (*)(id, SEL))objc_msgSend)(itemLayer, @selector(textLayer));
    if ([tl isKindOfClass:CALayer.class]) {
        [CATransaction begin];
        [CATransaction setDisableActions:YES];
        MakeTextLayerWhite((CALayer *)tl, 1.0);
        [CATransaction commit];
    }
}

void StyleFanItemPill(id fanItemLayer) {
    StyleStackItemText(fanItemLayer);
    if (![fanItemLayer isKindOfClass:CALayer.class]) return;
    CALayer *item = (CALayer *)fanItemLayer;

    [CATransaction begin];
    [CATransaction setDisableActions:YES];

    CALayer *textLayer = nil;
    if ([fanItemLayer respondsToSelector:@selector(textLayer)]) {
        id tl = ((id (*)(id, SEL))objc_msgSend)(fanItemLayer, @selector(textLayer));
        if ([tl isKindOfClass:CALayer.class]) textLayer = (CALayer *)tl;
    }

    // textBackgroundLayer is the pill behind the fan item's label (backdropLayerController is the icon's own backdrop).
    CALayer *textBg = nil;
    if ([fanItemLayer respondsToSelector:@selector(textBackgroundLayer)]) {
        id tb = ((id (*)(id, SEL))objc_msgSend)(fanItemLayer, @selector(textBackgroundLayer));
        if ([tb isKindOfClass:CALayer.class]) textBg = (CALayer *)tb;
    }

    if (textBg && !CGRectIsEmpty(textBg.bounds)) {
        textBg.hidden = NO;
        textBg.opacity = 1.0;
        textBg.contents = nil;
        textBg.compositingFilter = nil;
        textBg.filters = nil;
        textBg.backgroundFilters = nil;
        textBg.borderWidth = 0.0;
        CGColorRef fill = CGColorCreateGenericRGB(0.0, 0.0, 0.0, 0.68);
        textBg.backgroundColor = fill;
        CGColorRelease(fill);
        textBg.cornerRadius = textBg.bounds.size.height * 0.5;
        CGColorRef shadow = CGColorCreateGenericRGB(0.0, 0.0, 0.0, 0.35);
        textBg.shadowColor = shadow;
        textBg.shadowOpacity = 1.0;
        textBg.shadowRadius = 2.0;
        textBg.shadowOffset = CGSizeMake(0.0, -1.0);
        CGColorRelease(shadow);
        for (CALayer *sub in textBg.sublayers) {
            if (textLayer && LayerContainsDescendant(sub, textLayer)) continue;
            sub.hidden = YES;
            sub.opacity = 0.0;
        }
    } else if (textLayer && !CGRectIsEmpty(textLayer.frame)) {
        CGRect pillFrame = CGRectInset(textLayer.frame, -10.0, -2.5);
        CALayer *host = textLayer.superlayer ?: item;
        CALayer *pill = nil;
        for (CALayer *sub in host.sublayers) {
            if ([sub.name isEqualToString:kFanPillName]) { pill = sub; break; }
        }
        if (!pill) {
            pill = [CALayer layer];
            pill.name = kFanPillName;
            CGColorRef fill = CGColorCreateGenericRGB(0.0, 0.0, 0.0, 0.68);
            pill.backgroundColor = fill;
            CGColorRelease(fill);
            CGColorRef shadow = CGColorCreateGenericRGB(0.0, 0.0, 0.0, 0.35);
            pill.shadowColor = shadow;
            pill.shadowOpacity = 1.0;
            pill.shadowRadius = 2.0;
            pill.shadowOffset = CGSizeMake(0.0, -1.0);
            CGColorRelease(shadow);
            [host insertSublayer:pill below:textLayer];
        }
        pill.hidden = NO;
        pill.opacity = 1.0;
        pill.frame = pillFrame;
        pill.cornerRadius = pillFrame.size.height * 0.5;
        pill.zPosition = textLayer.zPosition - 0.1;
    }

    [CATransaction commit];
}

void (*gOrigExpandedSetText)(id, SEL, id);
void HookExpandedSetText(id self, SEL _cmd, id text) {
    gOrigExpandedSetText(self, _cmd, text);
    StyleStackItemText(self);
}

void (*gOrigGridItemLayout)(id, SEL);
void HookGridItemLayout(id self, SEL _cmd) {
    gOrigGridItemLayout(self, _cmd);
    StyleStackItemText(self);
}

void (*gOrigFanItemLayout)(id, SEL);
void HookFanItemLayout(id self, SEL _cmd) {
    gOrigFanItemLayout(self, _cmd);
    StyleFanItemPill(self);
}

void (*gOrigFanSetText)(id, SEL, id);
void HookFanSetText(id self, SEL _cmd, id text) {
    gOrigFanSetText(self, _cmd, text);
    StyleFanItemPill(self);
}

CTFontRef (*gOrigGridTitleFont)(id, SEL);
CTFontRef HookGridTitleFont(id self, SEL _cmd) {
    CTFontRef orig = gOrigGridTitleFont(self, _cmd);
    CGFloat sz = orig ? CTFontGetSize(orig) : 13.0;
    return CachedLucidaBold(sz) ?: orig;
}

CTFontRef (*gOrigItemFont)(id, SEL);
CTFontRef HookItemFont(id self, SEL _cmd) {
    CTFontRef orig = gOrigItemFont(self, _cmd);
    CGFloat sz = orig ? CTFontGetSize(orig) : 12.0;
    return CachedLucidaBold(sz) ?: orig;
}

} // namespace

__attribute__((constructor)) static void DockFixesInit(void) {
    if (![[NSBundle mainBundle].bundleIdentifier isEqualToString:@"com.apple.dock"]) return;

    if (Class labelCls = objc_getClass("DOCKLabelLayer")) {
        Hook(labelCls, "update", HookLabelUpdate, &gOrigLabelUpdate);
        Hook(labelCls, "updateBackground", HookLabelUpdateBg, &gOrigLabelUpdateBg);
        Hook(labelCls, "_updateLabelImage:orientation:", HookLabelUpdateImg, &gOrigLabelUpdateImg);
    }

    if (Class gridCls = objc_getClass("DOCKStackGridLayer")) {
        HookClassMethod(gridCls, "titleFont", HookGridTitleFont, &gOrigGridTitleFont);
        Hook(gridCls, "initWithStack:usingLayerSource:", HookGridInit, &gOrigGridInit);
        Hook(gridCls, "setTitle:", HookGridSetTitle, &gOrigGridSetTitle);
        Hook(gridCls, "layout", HookGridLayout, &gOrigGridLayout);
        Hook(gridCls, "repositionForStage:withEdge:", HookGridReposition, &gOrigGridReposition);
        Hook(gridCls, "layoutSublayers", HookGridLayoutSublayers, &gOrigGridLayoutSublayers);
    }
    if (Class glassCls = objc_getClass("ECCartoucheGlassLayerController")) {
        Hook(glassCls, "layout", HookGlassLayout, &gOrigGlassLayout);
    }
    if (Class backdropCls = objc_getClass("ECCartoucheBackdropLayerController")) {
        Hook(backdropCls, "layout", HookBackdropLayout, &gOrigBackdropLayout);
    }

    if (Class expItemCls = objc_getClass("DOCKStackExpandedItemLayer")) {
        HookClassMethod(expItemCls, "itemFont", HookItemFont, &gOrigItemFont);
        Hook(expItemCls, "_setText:", HookExpandedSetText, &gOrigExpandedSetText);
    }
    if (Class gridItemCls = objc_getClass("DOCKStackGridItemLayer")) {
        Hook(gridItemCls, "layoutSublayers", HookGridItemLayout, &gOrigGridItemLayout);
    }
    if (Class fanItemCls = objc_getClass("DOCKStackFanItemLayer")) {
        Hook(fanItemCls, "layoutSublayers", HookFanItemLayout, &gOrigFanItemLayout);
        Hook(fanItemCls, "_setText:", HookFanSetText, &gOrigFanSetText);
    }
}

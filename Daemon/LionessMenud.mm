// lionessmenud: Aqua LaunchAgent that draws and tracks Mountain Lion menus for every app
// (context menus, menu bar menus, pop-up menus, the Dock's dark bubble menus). Apps reach it
// through libLionessMenus.dylib; LionessSpotlight uses it for its contextual menu.
//
// Every metric and colour here is measured from the Mountain Lion screenshots in MenuRefs
// (all 2x): image-1/2/3 for light menus, image.webp for the Dock bubble.

#import <Cocoa/Cocoa.h>
#import <CoreText/CoreText.h>
#import <QuartzCore/QuartzCore.h>
#import "../Shared/MenuProtocol.h"

#include <bootstrap.h>
#include <mach/mach.h>
#include <servers/bootstrap.h>
#include <signal.h>
#include <spawn.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/wait.h>
#include <unistd.h>

extern "C" char *sandbox_extension_issue_mach(const char *extension_class, const char *name, uint32_t flags);
extern char **environ;

// ---------------------------------------------------------------------------
// 1. Fonts, colours, metrics
// ---------------------------------------------------------------------------

static NSString *gMLRoot = @"/Library/Lioness/ml-root";
static NSFont *gMenuFont = nil;       // Lucida Grande 14, Mountain Lion's menu font
static NSFont *gMenuFontSmall = nil;  // section headers

static void RegisterMountainLionFonts(void) {
    NSString *ttc = [gMLRoot stringByAppendingPathComponent:@"System/Library/Fonts/LucidaGrande.ttc"];
    if ([[NSFileManager defaultManager] fileExistsAtPath:ttc]) {
        CTFontManagerRegisterFontsForURL((__bridge CFURLRef)[NSURL fileURLWithPath:ttc], kCTFontManagerScopeProcess, NULL);
    }
    gMenuFont      = [NSFont fontWithName:@"LucidaGrande" size:14.0] ?: [NSFont menuFontOfSize:14.0];
    gMenuFontSmall = [NSFont fontWithName:@"LucidaGrande" size:11.0] ?: [NSFont systemFontOfSize:11.0];
}

static NSColor *RGB(CGFloat r, CGFloat g, CGFloat b, CGFloat a = 1.0) {
    return [NSColor colorWithSRGBRed:r / 255.0 green:g / 255.0 blue:b / 255.0 alpha:a];
}

// Light menus: rows 19pt, separators 12pt with one 1pt line, 4pt above the first row and below
// the last, titles at 21pt, shortcuts end 11pt from the right edge, arrows 10pt.
static const CGFloat kRowH          = 19.0;
static const CGFloat kSepH          = 12.0;
static const CGFloat kPadV          = 4.0;
static const CGFloat kTextX         = 21.0;
static const CGFloat kShortcutRight = 11.0;
static const CGFloat kShortcutGap   = 20.0;
static const CGFloat kArrowRight    = 10.0;
static const CGFloat kArrowW        = 8.0;
static const CGFloat kArrowH        = 9.0;
static const CGFloat kCorner        = 5.0;
static const CGFloat kIconSize      = 16.0;
static const CGFloat kIconGap       = 5.0;
static const CGFloat kFinderTagsH   = 52.0;
static const CGFloat kSectionHdrH   = 17.0;

// Dock bubble: 2pt blue-grey rim, 8pt corners, titles at 24pt, 6pt from the outer edge to the
// first row, and a 26pt-wide, 13pt-deep pointer.
static const CGFloat kDockCorner    = 8.0;
static const CGFloat kDockPadV      = 6.0;
static const CGFloat kDockTextX     = 24.0;
static const CGFloat kDockArrowRight = 12.0;
static const CGFloat kDockTailHalf  = 13.0;
static const CGFloat kDockTailH     = 13.0;
static const CGFloat kDockSelInset  = 3.0;

static NSArray<NSColor *> *FinderLabelColors(void) {
    static NSArray<NSColor *> *colors;
    if (!colors) colors = @[ RGB(250, 99, 95), RGB(250, 172, 75), RGB(247, 225, 90), RGB(175, 222, 90),
                             RGB(102, 178, 252), RGB(198, 141, 226), RGB(170, 170, 172) ];
    return colors;
}

// The selection bar: a 0.5pt (96,120,230) top line, a (107,131,240) to (49,85,237) gradient and
// a 0.5pt (34,71,227) bottom line, sampled from the Dock menu and Spotlight's Top Hit row.
static void DrawSelection(NSRect r) {
    static NSGradient *grad;
    if (!grad) grad = [[NSGradient alloc] initWithStartingColor:RGB(107, 131, 240) endingColor:RGB(49, 85, 237)];
    [grad drawInRect:r angle:90.0];   // flipped view: 90° runs top to bottom
    [RGB(96, 120, 230) setFill];
    NSRectFill(NSMakeRect(NSMinX(r), NSMinY(r), NSWidth(r), 0.5));
    [RGB(34, 71, 227) setFill];
    NSRectFill(NSMakeRect(NSMinX(r), NSMaxY(r) - 0.5, NSWidth(r), 0.5));
}

typedef NS_ENUM(NSInteger, LionessMenuVisualStyle) {
    LionessVisualContext = 0,  // light, 4 rounded corners
    LionessVisualMenuBar = 1,  // light, square top corners under the menu bar
    LionessVisualPopup   = 2,  // light, 4 rounded corners
    LionessVisualDock    = 3,  // dark bubble with a pointer
    LionessVisualDockSub = 4,  // dark bubble, no pointer
};

typedef NS_ENUM(NSInteger, LionessTailEdge) {
    LionessTailNone   = 0,
    LionessTailBottom = 1,
    LionessTailLeft   = 2,
    LionessTailRight  = 3,
};

static BOOL StyleIsDock(LionessMenuVisualStyle s) { return s == LionessVisualDock || s == LionessVisualDockSub; }

static BOOL ItemHasSubmenu(NSDictionary *item) {
    NSArray *sub = item[@"submenu"];
    return [sub isKindOfClass:NSArray.class] && sub.count > 0;
}

static CGFloat RowHeightForItem(NSDictionary *item) {
    if ([item[@"hidden"] boolValue]) return 0.0;
    if ([item[@"separator"] boolValue]) return kSepH;
    if ([item[@"sectionHeader"] boolValue]) return kSectionHdrH;
    NSString *ck = item[@"customViewKind"];
    if ([ck isEqualToString:@"finderTags"]) return kFinderTagsH;
    if ([ck isEqualToString:@"snapshot"]) {
        CGFloat h = [item[@"customViewHeight"] doubleValue];
        return (h >= 8.0 && h <= 400.0) ? h : kRowH;
    }
    return kRowH;
}

static BOOL ItemIsSelectable(NSDictionary *item) {
    if (!item || [item[@"hidden"] boolValue] || [item[@"separator"] boolValue] || [item[@"sectionHeader"] boolValue]) return NO;
    if ([item[@"customViewKind"] length]) return YES;
    return [item[@"enabled"] boolValue];
}

static NSString *ShortcutMods(NSDictionary *item) { return item[@"shortcutMods"] ?: @""; }
static NSString *ShortcutKey(NSDictionary *item)  { return item[@"shortcutKey"] ?: item[@"shortcut"] ?: @""; }

static CGFloat TextWidth(NSString *s, NSFont *f) {
    if (!s.length) return 0.0;
    return ceil([s sizeWithAttributes:@{ NSFontAttributeName: f }].width);
}

// Layout shared by measuring and drawing.
typedef struct {
    CGFloat width;
    CGFloat contentHeight;
    CGFloat textX;
    CGFloat keyColW;     // widest shortcut key
    BOOL anyIcon;
    NSInteger baseIndent; // the smallest indent in the menu: macOS 27 indents every item one level
} MenuLayout;

static MenuLayout MeasureMenu(NSArray<NSDictionary *> *items, BOOL isDock, CGFloat minWidth, NSMutableArray<NSValue *> *rowRects) {
    MenuLayout L = {};
    CGFloat maxTitle = 0.0, maxMods = 0.0, maxKey = 0.0, minW = isDock ? 150.0 : 120.0;
    BOOL anySub = NO;
    L.baseIndent = NSIntegerMax;
    for (NSDictionary *it in items) {
        if ([it[@"hidden"] boolValue] || [it[@"separator"] boolValue] || [it[@"customViewKind"] length]) continue;
        L.baseIndent = MIN(L.baseIndent, [it[@"indent"] integerValue]);
    }
    if (L.baseIndent == NSIntegerMax) L.baseIndent = 0;
    for (NSDictionary *it in items) {
        if ([it[@"hidden"] boolValue] || [it[@"separator"] boolValue]) continue;
        if (it[@"iconPNG"]) L.anyIcon = YES;
        if (ItemHasSubmenu(it)) anySub = YES;
        NSString *ck = it[@"customViewKind"];
        if ([ck isEqualToString:@"finderTags"]) { minW = MAX(minW, 216.0); continue; }
        if ([ck isEqualToString:@"snapshot"]) { minW = MAX(minW, [it[@"customViewWidth"] doubleValue]); continue; }
        NSFont *f = [it[@"sectionHeader"] boolValue] ? gMenuFontSmall : gMenuFont;
        maxTitle = MAX(maxTitle, TextWidth(it[@"title"], f) + MAX(0, [it[@"indent"] integerValue] - L.baseIndent) * 14.0);
        maxMods = MAX(maxMods, TextWidth(ShortcutMods(it), gMenuFont));
        maxKey = MAX(maxKey, TextWidth(ShortcutKey(it), gMenuFont));
    }
    L.textX = (isDock ? kDockTextX : kTextX) + (L.anyIcon ? kIconSize + kIconGap : 0.0);
    L.keyColW = maxKey;
    CGFloat right;
    if (maxKey > 0.0) right = kShortcutGap + maxMods + maxKey + kShortcutRight;
    else if (anySub) right = 20.0 + kArrowW + (isDock ? kDockArrowRight : kArrowRight);
    else right = isDock ? 22.0 : 20.0;
    L.width = ceil(MIN(MAX(MAX(minW, minWidth), L.textX + maxTitle + right), 640.0));

    CGFloat pad = isDock ? kDockPadV : kPadV;
    CGFloat y = pad;
    [rowRects removeAllObjects];
    for (NSDictionary *it in items) {
        CGFloat h = RowHeightForItem(it);
        [rowRects addObject:[NSValue valueWithRect:NSMakeRect(0, y, L.width, h)]];
        y += h;
    }
    L.contentHeight = y + pad;
    return L;
}

// Outline in a flipped view. `box` is the menu body; the tail sticks out of it.
static NSBezierPath *MenuOutline(NSRect box, CGFloat rTop, CGFloat rBot, LionessTailEdge tail, CGFloat tailPos) {
    CGFloat x0 = NSMinX(box), x1 = NSMaxX(box), y0 = NSMinY(box), y1 = NSMaxY(box);   // y0 is the top
    NSBezierPath *p = [NSBezierPath bezierPath];
    [p moveToPoint:NSMakePoint(x0 + rTop, y0)];
    [p lineToPoint:NSMakePoint(x1 - rTop, y0)];
    if (rTop > 0) [p appendBezierPathWithArcFromPoint:NSMakePoint(x1, y0) toPoint:NSMakePoint(x1, y0 + rTop) radius:rTop];
    if (tail == LionessTailRight) {
        CGFloat ty = MAX(y0 + rTop + kDockTailHalf, MIN(y1 - rBot - kDockTailHalf, tailPos));
        [p lineToPoint:NSMakePoint(x1, ty - kDockTailHalf)];
        [p lineToPoint:NSMakePoint(x1 + kDockTailH, ty)];
        [p lineToPoint:NSMakePoint(x1, ty + kDockTailHalf)];
    }
    [p lineToPoint:NSMakePoint(x1, y1 - rBot)];
    if (rBot > 0) [p appendBezierPathWithArcFromPoint:NSMakePoint(x1, y1) toPoint:NSMakePoint(x1 - rBot, y1) radius:rBot];
    if (tail == LionessTailBottom) {
        CGFloat tx = MAX(x0 + rBot + kDockTailHalf, MIN(x1 - rBot - kDockTailHalf, tailPos));
        [p lineToPoint:NSMakePoint(tx + kDockTailHalf, y1)];
        [p lineToPoint:NSMakePoint(tx, y1 + kDockTailH)];
        [p lineToPoint:NSMakePoint(tx - kDockTailHalf, y1)];
    }
    [p lineToPoint:NSMakePoint(x0 + rBot, y1)];
    if (rBot > 0) [p appendBezierPathWithArcFromPoint:NSMakePoint(x0, y1) toPoint:NSMakePoint(x0, y1 - rBot) radius:rBot];
    if (tail == LionessTailLeft) {
        CGFloat ty = MAX(y0 + rTop + kDockTailHalf, MIN(y1 - rBot - kDockTailHalf, tailPos));
        [p lineToPoint:NSMakePoint(x0, ty + kDockTailHalf)];
        [p lineToPoint:NSMakePoint(x0 - kDockTailH, ty)];
        [p lineToPoint:NSMakePoint(x0, ty - kDockTailHalf)];
    }
    [p lineToPoint:NSMakePoint(x0, y0 + rTop)];
    if (rTop > 0) [p appendBezierPathWithArcFromPoint:NSMakePoint(x0, y0) toPoint:NSMakePoint(x0 + rTop, y0) radius:rTop];
    [p closePath];
    return p;
}

// ---------------------------------------------------------------------------
// 2. Menu view and panel
// ---------------------------------------------------------------------------

@class LionessMenuSession;
@class LionessMenuPanel;

@interface LionessMenuView : NSView
@property (nonatomic, weak) LionessMenuPanel *ownerPanel;
@property (nonatomic, strong) NSArray<NSDictionary *> *items;
@property (nonatomic, assign) LionessMenuVisualStyle visualStyle;
@property (nonatomic, assign) LionessTailEdge tailEdge;
@property (nonatomic, assign) CGFloat tailPos;          // along the tail's edge, view coords
@property (nonatomic, assign) MenuLayout menuLayout;
@property (nonatomic, assign) NSInteger highlightedIndex;
@property (nonatomic, assign) NSInteger hoveredTagIndex; // -1 none, 0 clear, 1..7 colours
@property (nonatomic, assign) CGFloat scrollOffset;
@property (nonatomic, assign) NSRect menuBoxRect;       // menu body in view coords (flipped)
@property (nonatomic, strong) NSMutableArray<NSValue *> *rowRects; // content coords, y down
@property (nonatomic, strong) NSMutableDictionary<NSNumber *, NSImage *> *imageCache;
@end

@interface LionessMenuPanel : NSPanel
@property (nonatomic, weak) LionessMenuSession *session;
@property (nonatomic, assign) NSInteger depth;
@property (nonatomic, assign) NSInteger parentRowIndex;
@property (nonatomic, strong) LionessMenuView *menuView;
@property (nonatomic, assign) BOOL takesKeyboard;
@end

@interface LionessMenuSession : NSObject
- (void)pointerMovedTo:(NSPoint)screenPt;
@end

@implementation LionessMenuView

- (BOOL)isFlipped { return YES; }
- (BOOL)isOpaque  { return NO; }
- (BOOL)acceptsFirstMouse:(NSEvent *)event { (void)event; return YES; }

- (void)updateTrackingAreas {
    [super updateTrackingAreas];
    for (NSTrackingArea *a in self.trackingAreas) [self removeTrackingArea:a];
    [self addTrackingArea:[[NSTrackingArea alloc] initWithRect:NSZeroRect
                                                       options:NSTrackingMouseMoved | NSTrackingActiveAlways |
                                                               NSTrackingInVisibleRect | NSTrackingEnabledDuringMouseDrag |
                                                               NSTrackingMouseEnteredAndExited
                                                         owner:self userInfo:nil]];
}

- (void)mouseMoved:(NSEvent *)event { (void)event; [self.ownerPanel.session pointerMovedTo:NSEvent.mouseLocation]; }
- (void)mouseExited:(NSEvent *)event { (void)event; [self.ownerPanel.session pointerMovedTo:NSEvent.mouseLocation]; }

- (CGFloat)visibleContentHeight { return NSHeight(self.menuBoxRect); }
- (CGFloat)maxScroll { return MAX(0.0, self.menuLayout.contentHeight - NSHeight(self.menuBoxRect)); }

- (NSImage *)imageForIndex:(NSInteger)idx data:(NSData *)data {
    if (![data isKindOfClass:NSData.class]) return nil;
    if (!self.imageCache) self.imageCache = [NSMutableDictionary dictionary];
    NSImage *img = self.imageCache[@(idx)];
    if (!img && (img = [[NSImage alloc] initWithData:data])) self.imageCache[@(idx)] = img;
    return img;
}

// Row rect in view coordinates.
- (NSRect)viewRectForRowIndex:(NSInteger)idx {
    if (idx < 0 || idx >= (NSInteger)self.rowRects.count) return NSZeroRect;
    NSRect r = [self.rowRects[idx] rectValue];
    return NSMakeRect(NSMinX(self.menuBoxRect), NSMinY(self.menuBoxRect) + r.origin.y - self.scrollOffset, NSWidth(self.menuBoxRect), r.size.height);
}

- (NSInteger)rowIndexAtViewPoint:(NSPoint)pt {
    if (!NSPointInRect(pt, self.menuBoxRect)) return -1;
    CGFloat cy = pt.y - NSMinY(self.menuBoxRect) + self.scrollOffset;
    for (NSInteger i = 0; i < (NSInteger)self.rowRects.count; i++) {
        NSRect r = [self.rowRects[i] rectValue];
        if (r.size.height > 0 && cy >= NSMinY(r) && cy < NSMaxY(r)) return i;
    }
    return -1;
}

// Finder's label row (image-3): 'x' centred 29pt in, colour squares centred from 51.5pt, 18pt
// apart, 29.5pt below the row's top.
- (NSRect)tagRectAtIndex:(NSInteger)k inRow:(NSRect)row {
    CGFloat cx = NSMinX(row) + (k == 0 ? 29.0 : 51.5 + (k - 1) * 18.0);
    CGFloat cy = NSMinY(row) + 29.5;
    return NSMakeRect(cx - 7.0, cy - 7.0, 14.0, 14.0);
}

- (NSInteger)finderTagIndexAtViewPoint:(NSPoint)pt inRowRect:(NSRect)row {
    for (NSInteger k = 0; k < 8; k++) {
        if (NSPointInRect(pt, NSInsetRect([self tagRectAtIndex:k inRow:row], -2.0, -3.0))) return k;
    }
    return -1;
}

- (void)drawArrowInRow:(NSRect)row color:(NSColor *)color dock:(BOOL)dock {
    CGFloat right = NSMaxX(row) - (dock ? kDockArrowRight : kArrowRight);
    CGFloat h = dock ? 8.0 : kArrowH, w = dock ? 7.0 : kArrowW;
    CGFloat cy = floor(NSMidY(row)) + 0.5;
    NSBezierPath *tri = [NSBezierPath bezierPath];
    [tri moveToPoint:NSMakePoint(right - w, cy - h / 2)];
    [tri lineToPoint:NSMakePoint(right, cy)];
    [tri lineToPoint:NSMakePoint(right - w, cy + h / 2)];
    [tri closePath];
    [color setFill];
    [tri fill];
}

- (void)drawFinderTagsInRow:(NSRect)row item:(NSDictionary *)item {
    NSString *cap = [item[@"title"] length] ? item[@"title"] : @"Label:";
    [cap drawAtPoint:NSMakePoint(NSMinX(row) + kTextX, NSMinY(row) + 1.0)
      withAttributes:@{ NSFontAttributeName: gMenuFont, NSForegroundColorAttributeName: RGB(145, 146, 146) }];

    NSArray *selected = [item[@"selectedTags"] isKindOfClass:NSArray.class] ? item[@"selectedTags"] : @[];
    for (NSInteger k = 0; k < 8; k++) {
        NSRect cell = [self tagRectAtIndex:k inRow:row];
        BOOL hover = (self.hoveredTagIndex == k);
        BOOL on = k > 0 && [selected containsObject:@(k)];
        if (hover || on) {
            NSBezierPath *ring = [NSBezierPath bezierPathWithRoundedRect:NSInsetRect(cell, -2.0, -2.0) xRadius:3 yRadius:3];
            [[NSColor colorWithWhite:0.0 alpha:on ? 0.12 : 0.07] setFill];
            [ring fill];
            [[NSColor colorWithWhite:0.45 alpha:0.8] setStroke];
            ring.lineWidth = 1.0;
            [ring stroke];
        }
        if (k == 0) {
            NSBezierPath *x = [NSBezierPath bezierPath];
            NSRect g = NSInsetRect(cell, 3.5, 3.5);
            [x moveToPoint:g.origin]; [x lineToPoint:NSMakePoint(NSMaxX(g), NSMaxY(g))];
            [x moveToPoint:NSMakePoint(NSMaxX(g), NSMinY(g))]; [x lineToPoint:NSMakePoint(NSMinX(g), NSMaxY(g))];
            x.lineWidth = 1.5;
            [RGB(120, 120, 122) setStroke];
            [x stroke];
            continue;
        }
        NSColor *base = FinderLabelColors()[k - 1];
        NSRect sq = NSInsetRect(cell, 3.0, 3.0);
        NSBezierPath *sp = [NSBezierPath bezierPathWithRoundedRect:sq xRadius:1.5 yRadius:1.5];
        NSGradient *g = [[NSGradient alloc] initWithStartingColor:[base blendedColorWithFraction:0.45 ofColor:NSColor.whiteColor]
                                                      endingColor:base];
        [g drawInBezierPath:sp angle:90.0];
        [[base blendedColorWithFraction:0.35 ofColor:NSColor.blackColor] setStroke];
        sp.lineWidth = 0.5;
        [sp stroke];
    }
}

- (void)drawRect:(NSRect)dirtyRect {
    (void)dirtyRect;
    BOOL dock = StyleIsDock(self.visualStyle);
    NSRect box = self.menuBoxRect;
    CGFloat rTop = dock ? kDockCorner : (self.visualStyle == LionessVisualMenuBar ? 0.0 : kCorner);
    CGFloat rBot = dock ? kDockCorner : kCorner;
    NSBezierPath *outline = MenuOutline(box, rTop, rBot, self.tailEdge, self.tailPos);

    // Body. Light: white at 95% (243 over image-1's dark sky). Dock: (31,33,35).
    [(dock ? RGB(31, 33, 35, 0.96) : [NSColor colorWithWhite:1.0 alpha:0.95]) setFill];
    [outline fill];

    [NSGraphicsContext saveGraphicsState];
    [outline addClip];
    NSRectClip(box);

    MenuLayout L = self.menuLayout;
    NSColor *textColor     = dock ? NSColor.whiteColor : NSColor.blackColor;
    NSColor *disabledColor = dock ? [NSColor colorWithWhite:1.0 alpha:0.4] : RGB(145, 146, 146);
    NSMutableParagraphStyle *ps = [[NSMutableParagraphStyle alloc] init];
    ps.lineBreakMode = NSLineBreakByTruncatingTail;
    CGFloat textTop = floor((kRowH - (gMenuFont.ascender - gMenuFont.descender)) / 2.0);

    for (NSInteger i = 0; i < (NSInteger)self.items.count; i++) {
        NSDictionary *item = self.items[i];
        if ([item[@"hidden"] boolValue]) continue;
        NSRect row = [self viewRectForRowIndex:i];
        if (NSMaxY(row) < NSMinY(box) || NSMinY(row) > NSMaxY(box)) continue;

        if ([item[@"separator"] boolValue]) {
            // NSRectFill copies, alpha and all, so only opaque colours go through it.
            CGFloat ly = NSMinY(row) + floor(kSepH / 2.0) - 1.0;
            if (dock) {
                // image.webp: a 1pt (27,29,30) line over a 1pt (75,76,78) one, 4pt in from the edge.
                NSRect line = NSMakeRect(NSMinX(box) + 4.0, ly, NSWidth(box) - 8.0, 1.0);
                [RGB(27, 29, 30) setFill];
                NSRectFill(line);
                [RGB(75, 76, 78) setFill];
                NSRectFill(NSOffsetRect(line, 0.0, 1.0));
            } else {
                [RGB(217, 218, 219) setFill];
                NSRectFill(NSMakeRect(NSMinX(box), ly + 0.5, NSWidth(box), 1.0));
            }
            continue;
        }

        NSString *ck = item[@"customViewKind"];
        if ([ck isEqualToString:@"finderTags"]) { [self drawFinderTagsInRow:row item:item]; continue; }
        if ([ck isEqualToString:@"snapshot"]) {
            NSImage *snap = [self imageForIndex:i + 100000 data:item[@"customViewPNG"]];
            CGFloat sw = [item[@"customViewWidth"] doubleValue], sh = [item[@"customViewHeight"] doubleValue];
            if (snap) [snap drawInRect:NSMakeRect(NSMinX(row), NSMinY(row), sw, sh) fromRect:NSZeroRect
                             operation:NSCompositingOperationSourceOver fraction:1.0 respectFlipped:YES hints:nil];
            continue;
        }

        BOOL header = [item[@"sectionHeader"] boolValue];
        BOOL enabled = [item[@"enabled"] boolValue] && !header;
        BOOL selected = (i == self.highlightedIndex) && enabled;
        if (selected) {
            NSRect sel = dock ? NSMakeRect(NSMinX(box) + kDockSelInset, NSMinY(row), NSWidth(box) - 2 * kDockSelInset, NSHeight(row)) : row;
            DrawSelection(sel);
        }
        NSColor *fg = selected ? NSColor.whiteColor : (enabled ? textColor : disabledColor);
        if (header) fg = dock ? [NSColor colorWithWhite:1.0 alpha:0.55] : RGB(120, 121, 122);

        NSInteger state = [item[@"state"] integerValue];
        if (state != 0) {
            NSString *mark = state > 0 ? @"✓" : @"–";
            [mark drawAtPoint:NSMakePoint(NSMinX(row) + (dock ? 8.0 : 6.0), NSMinY(row) + textTop)
               withAttributes:@{ NSFontAttributeName: gMenuFont, NSForegroundColorAttributeName: fg }];
        }

        CGFloat x = NSMinX(row) + (dock ? kDockTextX : kTextX);
        NSImage *icon = [self imageForIndex:i data:item[@"iconPNG"]];
        if (icon) {
            [icon drawInRect:NSMakeRect(x, NSMinY(row) + floor((NSHeight(row) - kIconSize) / 2.0), kIconSize, kIconSize)
                    fromRect:NSZeroRect operation:NSCompositingOperationSourceOver fraction:enabled ? 1.0 : 0.5
              respectFlipped:YES hints:nil];
        }
        x = NSMinX(row) + L.textX + MAX(0, [item[@"indent"] integerValue] - L.baseIndent) * 14.0;

        NSString *mods = ShortcutMods(item), *key = ShortcutKey(item);
        CGFloat keyX = NSMaxX(row) - kShortcutRight - L.keyColW;
        CGFloat titleRight = NSMaxX(row) - 12.0;
        if (key.length) {
            CGFloat modsX = keyX - TextWidth(mods, gMenuFont);
            titleRight = modsX - 8.0;
            NSDictionary *sa = @{ NSFontAttributeName: gMenuFont, NSForegroundColorAttributeName: fg };
            if (mods.length) [mods drawAtPoint:NSMakePoint(modsX, NSMinY(row) + textTop) withAttributes:sa];
            [key drawAtPoint:NSMakePoint(keyX, NSMinY(row) + textTop) withAttributes:sa];
        } else if (ItemHasSubmenu(item)) {
            NSColor *ac = selected ? NSColor.whiteColor : (dock ? NSColor.whiteColor : (enabled ? RGB(64, 64, 64) : disabledColor));
            [self drawArrowInRow:row color:ac dock:dock];
            titleRight = NSMaxX(row) - 30.0;
        }

        NSFont *font = header ? gMenuFontSmall : gMenuFont;
        NSDictionary *ta = @{ NSFontAttributeName: font, NSForegroundColorAttributeName: fg, NSParagraphStyleAttributeName: ps };
        CGFloat ty = header ? NSMinY(row) + 2.0 : NSMinY(row) + textTop;
        [(item[@"title"] ?: @"") drawInRect:NSMakeRect(x, ty, MAX(10.0, titleRight - x), NSHeight(row)) withAttributes:ta];
    }

    // Scroll arrows when the menu is taller than the screen.
    NSColor *stripColor = dock ? RGB(31, 33, 35) : RGB(243, 244, 244);
    NSColor *arrowColor = dock ? NSColor.whiteColor : RGB(64, 64, 64);
    if (self.scrollOffset > 0.5) {
        NSRect strip = NSMakeRect(NSMinX(box), NSMinY(box), NSWidth(box), kRowH);
        [stripColor setFill]; NSRectFill(strip);
        NSBezierPath *t = [NSBezierPath bezierPath];
        [t moveToPoint:NSMakePoint(NSMidX(box) - 5, NSMinY(box) + 13)];
        [t lineToPoint:NSMakePoint(NSMidX(box), NSMinY(box) + 6)];
        [t lineToPoint:NSMakePoint(NSMidX(box) + 5, NSMinY(box) + 13)];
        [arrowColor setFill]; [t fill];
    }
    if (self.scrollOffset < self.maxScroll - 0.5) {
        NSRect strip = NSMakeRect(NSMinX(box), NSMaxY(box) - kRowH, NSWidth(box), kRowH);
        [stripColor setFill]; NSRectFill(strip);
        NSBezierPath *t = [NSBezierPath bezierPath];
        [t moveToPoint:NSMakePoint(NSMidX(box) - 5, NSMaxY(box) - 13)];
        [t lineToPoint:NSMakePoint(NSMidX(box), NSMaxY(box) - 6)];
        [t lineToPoint:NSMakePoint(NSMidX(box) + 5, NSMaxY(box) - 13)];
        [arrowColor setFill]; [t fill];
    }
    [NSGraphicsContext restoreGraphicsState];

    if (dock) {
        // Rim: 2pt of translucent blue-grey ((67,80,96) over the sky), a dark hairline inside it.
        NSBezierPath *rim = MenuOutline(NSInsetRect(box, 1.0, 1.0), kDockCorner - 1, kDockCorner - 1, self.tailEdge, self.tailPos);
        rim.lineWidth = 2.0;
        [RGB(150, 170, 195, 0.42) setStroke];
        [rim stroke];
        NSBezierPath *inner = MenuOutline(NSInsetRect(box, 2.25, 2.25), kDockCorner - 2, kDockCorner - 2, self.tailEdge, self.tailPos);
        inner.lineWidth = 0.5;
        [RGB(0, 0, 0, 0.6) setStroke];
        [inner stroke];
    }
}

@end

@implementation LionessMenuPanel
- (BOOL)canBecomeKeyWindow  { return self.takesKeyboard; }
- (BOOL)canBecomeMainWindow { return NO; }
@end

// ---------------------------------------------------------------------------
// 3. Session: one open menu (and its submenus) for one client request
// ---------------------------------------------------------------------------

@interface LionessMenuSession ()
@property (nonatomic, assign) mach_port_t replyPort;
@property (nonatomic, strong) dispatch_source_t replyDeadSource;
@property (nonatomic, strong) NSDictionary *request;
@property (nonatomic, strong) NSMutableArray<LionessMenuPanel *> *panels;
@property (nonatomic, strong) id globalMonitor;
@property (nonatomic, strong) id localMonitor;
@property (nonatomic, strong) NSTimer *submenuTimer;
@property (nonatomic, strong) NSTimer *scrollTimer;
@property (nonatomic, assign) NSInteger pendingSubmenuDepth;
@property (nonatomic, assign) NSInteger pendingSubmenuRow;
@property (nonatomic, assign) CFAbsoluteTime openedAt;
@property (nonatomic, assign) BOOL mouseMovedSinceOpen;
@property (nonatomic, assign) BOOL mouseDownInMenu;
@property (nonatomic, assign) NSPoint openMouseLocation;
@property (nonatomic, copy) NSString *typeAhead;
@property (nonatomic, assign) CFAbsoluteTime lastTypeAt;
@property (nonatomic, assign) BOOL finished;
@property (nonatomic, strong) NSArray<NSDictionary *> *menuBarTitles;
@property (nonatomic, assign) NSInteger activeMenuBarIndex;
@property (nonatomic, assign) NSRect anchorRect;
@property (nonatomic, assign) BOOL isDockMenu;
@end

static LionessMenuSession *gActiveSession = nil;
// menuBarTitleIndexAt: answers. Title -1 is the Apple menu, so "none" can't be negative one.
static const NSInteger kNotInBar = NSNotFound;
static const NSInteger kNoTitle = NSIntegerMin;
// Panels of a menu bar menu the user just scrubbed away from. They stay up until the next
// title's menu is on screen, so scrubbing never shows an empty gap.
static NSMutableArray<LionessMenuPanel *> *gLingeringPanels = nil;

static void CloseLingeringPanels(void) {
    for (LionessMenuPanel *p in gLingeringPanels) [p orderOut:nil];
    [gLingeringPanels removeAllObjects];
}

static void SendMachReply(mach_port_t replyPort, NSDictionary *dict) {
    if (replyPort == MACH_PORT_NULL) return;
    NSData *data = [NSPropertyListSerialization dataWithPropertyList:(dict ?: @{ @"result": @(LIONESS_MENU_RESULT_CANCELLED) })
                                                              format:NSPropertyListBinaryFormat_v1_0 options:0 error:nil];
    LionessMenuMachMessage reply = {};
    reply.header.msgh_bits = MACH_MSGH_BITS_COMPLEX | MACH_MSGH_BITS(MACH_MSG_TYPE_MOVE_SEND_ONCE, 0);
    reply.header.msgh_size = sizeof(reply);
    reply.header.msgh_remote_port = replyPort;
    reply.header.msgh_id = LIONESS_MENU_MSG_PRESENT + 100;
    reply.body.msgh_descriptor_count = 1;
    reply.payload.address = (void *)data.bytes;
    reply.payload.size = (mach_msg_size_t)data.length;
    reply.payload.copy = MACH_MSG_VIRTUAL_COPY;
    reply.payload.type = MACH_MSG_OOL_DESCRIPTOR;
    if (mach_msg(&reply.header, MACH_SEND_MSG | MACH_SEND_TIMEOUT, sizeof(reply), 0, MACH_PORT_NULL, 1000, MACH_PORT_NULL) != KERN_SUCCESS) {
        mach_port_deallocate(mach_task_self(), replyPort);
    }
}

static NSScreen *ScreenForPoint(NSPoint pt) {
    for (NSScreen *s in NSScreen.screens) if (NSPointInRect(pt, s.frame)) return s;
    NSScreen *best = nil;
    CGFloat bestD = CGFLOAT_MAX;
    for (NSScreen *s in NSScreen.screens) {
        NSRect f = s.frame;
        CGFloat dx = MAX(0.0, MAX(NSMinX(f) - pt.x, pt.x - NSMaxX(f)));
        CGFloat dy = MAX(0.0, MAX(NSMinY(f) - pt.y, pt.y - NSMaxY(f)));
        if (dx + dy < bestD) { bestD = dx + dy; best = s; }
    }
    return best ?: NSScreen.mainScreen;
}

// The usable area: below the menu bar, the full height elsewhere. Lioness's menu bar is
// Mountain Lion's 24pt, even where macOS reserves 37pt for a notch, so visibleFrame's top is
// only used to tell whether this screen has a menu bar at all.
static NSRect MenuArea(NSScreen *s) {
    NSRect f = s.frame, v = s.visibleFrame;
    CGFloat top = NSMaxY(v) < NSMaxY(f) - 1.0 ? NSMaxY(f) - 24.0 : NSMaxY(f);
    return NSMakeRect(NSMinX(f), NSMinY(f), NSWidth(f), top - NSMinY(f));
}

@implementation LionessMenuSession

- (instancetype)initWithRequest:(NSDictionary *)req replyPort:(mach_port_t)port {
    if ((self = [super init])) {
        _request = req;
        _replyPort = port;
        _panels = [NSMutableArray array];
        _openedAt = CFAbsoluteTimeGetCurrent();
        _openMouseLocation = NSEvent.mouseLocation;
        _pendingSubmenuDepth = -1;
        _pendingSubmenuRow = -1;
        _menuBarTitles = [req[@"menuBarTitles"] isKindOfClass:NSArray.class] ? req[@"menuBarTitles"] : nil;
        _activeMenuBarIndex = req[@"activeMenuBarIndex"] ? [req[@"activeMenuBarIndex"] integerValue] : kNoTitle;
        _isDockMenu = [req[@"style"] isEqualToString:@"dock"];
        _anchorRect = NSMakeRect([req[@"anchorX"] doubleValue], [req[@"anchorY"] doubleValue],
                                 [req[@"anchorW"] doubleValue], [req[@"anchorH"] doubleValue]);
        if (port != MACH_PORT_NULL) {
            // The client died or gave up: its send-once right dies with it.
            dispatch_source_t src = dispatch_source_create(DISPATCH_SOURCE_TYPE_MACH_SEND, port, DISPATCH_MACH_SEND_DEAD, dispatch_get_main_queue());
            __weak typeof(self) ws = self;
            dispatch_source_set_event_handler(src, ^{ [ws cancelAndCloseImmediately]; });
            dispatch_resume(src);
            _replyDeadSource = src;
        }
    }
    return self;
}

- (LionessMenuPanel *)createPanelForItems:(NSArray<NSDictionary *> *)items
                                    style:(LionessMenuVisualStyle)style
                               anchorRect:(NSRect)anchor
                            preferredEdge:(NSInteger)preferredEdge
                                    depth:(NSInteger)depth
                           parentRowIndex:(NSInteger)parentRowIndex {
    BOOL dock = StyleIsDock(style);
    NSMutableArray<NSValue *> *rowRects = [NSMutableArray array];
    CGFloat minWidth = (style == LionessVisualPopup && depth == 0) ? [self.request[@"minWidth"] doubleValue] : 0.0;
    MenuLayout L = MeasureMenu(items, dock, minWidth, rowRects);

    NSScreen *scr = ScreenForPoint(NSMakePoint(NSMidX(anchor), NSMidY(anchor)));
    NSRect area = MenuArea(scr);
    CGFloat boxW = L.width;
    CGFloat boxH = MIN(L.contentHeight, NSHeight(area) - 8.0);
    CGFloat boxX = 0.0, boxTop = 0.0;   // AppKit screen coords: boxTop is the top edge
    LionessTailEdge tail = LionessTailNone;
    CGFloat tailAt = 0.0;               // screen coordinate the tail points at
    CGFloat scrollOffset = 0.0;

    if (style == LionessVisualMenuBar) {
        // Flush under the title, left edges aligned (image-1, image-2, image-3).
        boxX = NSMinX(anchor);
        boxTop = MIN(NSMinY(anchor), NSMaxY(area));
        boxH = MIN(L.contentHeight, boxTop - NSMinY(area) - 4.0);
        boxX = MAX(NSMinX(area), MIN(boxX, NSMaxX(area) - boxW));
    } else if (style == LionessVisualDock) {
        if (preferredEdge == NSRectEdgeMaxX || preferredEdge == NSRectEdgeMinX) {
            BOOL right = (preferredEdge == NSRectEdgeMaxX);
            tail = right ? LionessTailLeft : LionessTailRight;
            boxX = right ? NSMaxX(anchor) + kDockTailH + 2.0 : NSMinX(anchor) - kDockTailH - 2.0 - boxW;
            tailAt = NSMidY(anchor);
            boxTop = MAX(NSMinY(area) + boxH + 4.0, MIN(NSMaxY(area) - 4.0, tailAt + boxH / 2.0));
        } else {
            tail = LionessTailBottom;
            tailAt = NSMidX(anchor);
            boxX = MAX(NSMinX(area) + 4.0, MIN(NSMaxX(area) - boxW - 4.0, tailAt - boxW / 2.0));
            CGFloat bottom = NSMaxY(anchor) + kDockTailH + 2.0;
            boxTop = MIN(NSMaxY(area) - 4.0, bottom + boxH);
        }
    } else if (depth > 0) {
        // Submenus overlap the parent by 1pt; the first row lines up with the parent row.
        CGFloat pad = dock ? kDockPadV : kPadV;
        boxX = NSMaxX(anchor) - 1.0;
        if (boxX + boxW > NSMaxX(area)) boxX = NSMinX(anchor) - boxW + 1.0;
        boxTop = NSMaxY(anchor) + pad;
        if (boxTop - boxH < NSMinY(area) + 4.0) boxTop = NSMinY(area) + 4.0 + boxH;
        boxTop = MIN(boxTop, NSMaxY(area));
    } else if (style == LionessVisualPopup) {
        // The selected item sits on the anchor point, its title over the control's title.
        NSInteger sel = [self.request[@"selectedIndex"] integerValue];
        CGFloat selTop = (self.request[@"selectedIndex"] && sel >= 0 && sel < (NSInteger)rowRects.count)
            ? NSMinY([rowRects[sel] rectValue]) : kPadV;
        // The whole menu would sit at idealTop; clip it to the screen and scroll what's cut off at
        // the top, so the selected row stays over the control however long the menu is.
        boxX = NSMinX(anchor) - L.textX + [self.request[@"titleInset"] doubleValue];
        CGFloat idealTop = NSMaxY(anchor) + selTop;
        CGFloat idealBottom = idealTop - L.contentHeight;
        CGFloat top = MIN(idealTop, NSMaxY(area));
        CGFloat bottom = MAX(idealBottom, NSMinY(area) + 4.0);
        if (top - bottom < 3 * kRowH) {   // too close to an edge to be usable: slide it on screen
            top = MIN(NSMaxY(area), MAX(top, NSMinY(area) + 4.0 + MIN(L.contentHeight, NSHeight(area) - 8.0)));
            bottom = MAX(NSMinY(area) + 4.0, top - L.contentHeight);
            idealTop = top;
        }
        boxTop = top;
        boxH = top - bottom;
        scrollOffset = idealTop - top;
        boxX = MAX(NSMinX(area), MIN(boxX, NSMaxX(area) - boxW));
    } else {
        // Context menu: top-left corner at the click; flip up or left near the screen edges.
        boxX = NSMinX(anchor) + 1.0;
        boxTop = NSMinY(anchor) - 1.0;
        if (boxX + boxW > NSMaxX(area)) boxX = NSMinX(anchor) - boxW - 1.0;
        if (boxTop - boxH < NSMinY(area)) boxTop = (NSMinY(anchor) + boxH <= NSMaxY(area)) ? NSMinY(anchor) + boxH : NSMinY(area) + boxH;
        boxTop = MIN(boxTop, NSMaxY(area));
        boxX = MAX(NSMinX(area), boxX);
    }

    boxX = round(boxX);
    boxTop = round(boxTop);
    boxH = ceil(boxH);
    CGFloat padL = tail == LionessTailLeft ? kDockTailH : 0.0;
    CGFloat padR = tail == LionessTailRight ? kDockTailH : 0.0;
    CGFloat padB = tail == LionessTailBottom ? kDockTailH : 0.0;
    NSRect winFrame = NSMakeRect(boxX - padL, boxTop - boxH - padB, boxW + padL + padR, boxH + padB);

    LionessMenuPanel *panel = [[LionessMenuPanel alloc] initWithContentRect:winFrame
                                                                  styleMask:NSWindowStyleMaskBorderless | NSWindowStyleMaskNonactivatingPanel
                                                                    backing:NSBackingStoreBuffered
                                                                      defer:YES];
    panel.opaque = NO;
    panel.backgroundColor = NSColor.clearColor;
    panel.hasShadow = YES;
    panel.level = kCGPopUpMenuWindowLevel;
    panel.animationBehavior = NSWindowAnimationBehaviorNone;
    panel.collectionBehavior = NSWindowCollectionBehaviorCanJoinAllSpaces | NSWindowCollectionBehaviorFullScreenAuxiliary |
                               NSWindowCollectionBehaviorTransient | NSWindowCollectionBehaviorIgnoresCycle;
    panel.acceptsMouseMovedEvents = YES;
    panel.releasedWhenClosed = NO;
    panel.hidesOnDeactivate = NO;
    panel.session = self;
    panel.depth = depth;
    panel.parentRowIndex = parentRowIndex;

    LionessMenuView *view = [[LionessMenuView alloc] initWithFrame:NSMakeRect(0, 0, NSWidth(winFrame), NSHeight(winFrame))];
    view.ownerPanel = panel;
    view.items = items;
    view.visualStyle = style;
    view.tailEdge = tail;
    view.menuLayout = L;
    view.highlightedIndex = -1;
    view.hoveredTagIndex = -1;
    view.rowRects = rowRects;
    view.menuBoxRect = NSMakeRect(padL, 0.0, boxW, boxH);   // flipped: the tail hangs below
    view.scrollOffset = MAX(0.0, MIN(scrollOffset, view.maxScroll));
    if (tail == LionessTailBottom) view.tailPos = tailAt - NSMinX(winFrame);
    else if (tail != LionessTailNone) view.tailPos = (NSMaxY(winFrame) - tailAt);   // flipped y

    if (depth == 0 && self.request[@"debugHighlight"]) view.highlightedIndex = [self.request[@"debugHighlight"] integerValue];
    if (depth == 0 && style == LionessVisualPopup && self.request[@"selectedIndex"]) {
        NSInteger si = [self.request[@"selectedIndex"] integerValue];
        if (si >= 0 && si < (NSInteger)items.count && ItemIsSelectable(items[si])) view.highlightedIndex = si;
    }

    panel.menuView = view;
    panel.contentView = view;
    // Draw before ordering in, so the first frame on screen is the finished menu.
    [view displayIfNeeded];
    [panel orderFrontRegardless];
    [panel invalidateShadow];
    return panel;
}

- (void)closeSubmenusDeeperThan:(NSInteger)depth {
    while ((NSInteger)self.panels.count > depth + 1) {
        [self.panels.lastObject orderOut:nil];
        [self.panels removeLastObject];
    }
}

- (void)openSubmenuAtDepth:(NSInteger)depth row:(NSInteger)row {
    if (depth < 0 || depth >= (NSInteger)self.panels.count) return;
    LionessMenuPanel *parent = self.panels[depth];
    if (row < 0 || row >= (NSInteger)parent.menuView.items.count) return;
    NSDictionary *item = parent.menuView.items[row];
    if (!ItemHasSubmenu(item) || ![item[@"enabled"] boolValue]) { [self closeSubmenusDeeperThan:depth]; return; }
    if ((NSInteger)self.panels.count > depth + 1 && self.panels[depth + 1].parentRowIndex == row) return;
    [self closeSubmenusDeeperThan:depth];

    NSRect rowInView = [parent.menuView viewRectForRowIndex:row];
    NSRect rowOnScreen = [parent convertRectToScreen:[parent.menuView convertRect:rowInView toView:nil]];
    LionessMenuPanel *sub = [self createPanelForItems:item[@"submenu"]
                                                style:self.isDockMenu ? LionessVisualDockSub : LionessVisualContext
                                           anchorRect:rowOnScreen
                                        preferredEdge:0
                                                depth:depth + 1
                                       parentRowIndex:row];
    [self.panels addObject:sub];
}

- (void)scheduleSubmenuAtDepth:(NSInteger)depth row:(NSInteger)row {
    if (self.pendingSubmenuDepth == depth && self.pendingSubmenuRow == row && self.submenuTimer.valid) return;
    [self.submenuTimer invalidate];
    self.pendingSubmenuDepth = depth;
    self.pendingSubmenuRow = row;
    __weak typeof(self) ws = self;
    self.submenuTimer = [NSTimer scheduledTimerWithTimeInterval:0.1 repeats:NO block:^(NSTimer *t) {
        (void)t;
        LionessMenuSession *ss = ws;
        if (!ss || ss.finished) return;
        if (ss.pendingSubmenuDepth == depth && ss.pendingSubmenuRow == row) [ss openSubmenuAtDepth:depth row:row];
    }];
    [[NSRunLoop currentRunLoop] addTimer:self.submenuTimer forMode:NSRunLoopCommonModes];
}

- (void)teardownMonitors {
    [self.submenuTimer invalidate]; self.submenuTimer = nil;
    [self.scrollTimer invalidate]; self.scrollTimer = nil;
    if (self.globalMonitor) { [NSEvent removeMonitor:self.globalMonitor]; self.globalMonitor = nil; }
    if (self.localMonitor)  { [NSEvent removeMonitor:self.localMonitor];  self.localMonitor = nil; }
    if (self.replyDeadSource) { dispatch_source_cancel(self.replyDeadSource); self.replyDeadSource = nil; }
}

- (void)finishWithReply:(NSDictionary *)reply {
    if (self.finished) return;
    fprintf(stderr, "lionessmenud: close %s result %ld\n", [self.request[@"style"] UTF8String], (long)[reply[@"result"] integerValue]);
    self.finished = YES;
    [self teardownMonitors];
    if ([reply[@"result"] integerValue] == LIONESS_MENU_RESULT_SWITCH_BAR) {
        // Keep this menu up until the next title's menu is drawn (or briefly, if none comes).
        if (!gLingeringPanels) gLingeringPanels = [NSMutableArray array];
        CloseLingeringPanels();
        [gLingeringPanels addObjectsFromArray:self.panels];
        NSArray *mine = [self.panels copy];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.35 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            for (LionessMenuPanel *p in mine) {
                if ([gLingeringPanels containsObject:p]) { [p orderOut:nil]; [gLingeringPanels removeObject:p]; }
            }
        });
    } else {
        for (LionessMenuPanel *p in self.panels) [p orderOut:nil];
    }
    [self.panels removeAllObjects];
    mach_port_t rp = self.replyPort;
    self.replyPort = MACH_PORT_NULL;
    if (gActiveSession == self) gActiveSession = nil;
    SendMachReply(rp, reply);
}

- (void)cancelAndCloseImmediately {
    CloseLingeringPanels();
    [self finishWithReply:@{ @"result": @(LIONESS_MENU_RESULT_CANCELLED) }];
}

- (void)activateItemAtDepth:(NSInteger)depth row:(NSInteger)row clickPointInView:(NSPoint)viewPt fromKeyboard:(BOOL)kb {
    if (depth < 0 || depth >= (NSInteger)self.panels.count) return;
    LionessMenuPanel *panel = self.panels[depth];
    if (row < 0 || row >= (NSInteger)panel.menuView.items.count) return;
    NSDictionary *item = panel.menuView.items[row];
    if (!ItemIsSelectable(item)) return;

    NSString *ck = item[@"customViewKind"];
    if ([ck isEqualToString:@"finderTags"]) {
        if (kb) return;
        NSInteger tagIdx = [panel.menuView finderTagIndexAtViewPoint:viewPt inRowRect:[panel.menuView viewRectForRowIndex:row]];
        if (tagIdx < 0) return;
        [self finishWithReply:@{ @"result": @(LIONESS_MENU_RESULT_SELECTED), @"itemId": item[@"id"] ?: @(-1), @"customSubIndex": @(tagIdx) }];
        return;
    }
    if (ItemHasSubmenu(item)) { [self openSubmenuAtDepth:depth row:row]; return; }

    // Mountain Lion blinks the chosen item once before the menu goes away.
    NSMutableDictionary *reply = [@{ @"result": @(LIONESS_MENU_RESULT_SELECTED), @"itemId": item[@"id"] ?: @(-1) } mutableCopy];
    if ([ck isEqualToString:@"snapshot"] && !kb) {
        NSRect rr = [panel.menuView viewRectForRowIndex:row];
        reply[@"clickX"] = @(viewPt.x - NSMinX(rr));
        reply[@"clickY"] = @(NSMaxY(rr) - viewPt.y);   // the custom view is unflipped
    }
    [self teardownMonitors];
    LionessMenuView *v = panel.menuView;
    v.highlightedIndex = -1; [v display];
    __weak typeof(self) ws = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.06 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        v.highlightedIndex = row; [v display];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.06 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            [ws finishWithReply:reply];
        });
    });
}

- (NSInteger)menuBarTitleIndexAt:(NSPoint)pt {
    if (!self.menuBarTitles.count) return kNotInBar;
    NSScreen *scr = ScreenForPoint(pt);
    CGFloat barH = NSHeight(self.anchorRect) > 0 ? NSHeight(self.anchorRect) : 24.0;
    if (pt.y < NSMaxY(scr.frame) - barH || pt.y > NSMaxY(scr.frame) + 1.0) return kNotInBar;
    for (NSDictionary *e in self.menuBarTitles) {
        CGFloat x = [e[@"x"] doubleValue], w = [e[@"w"] doubleValue];
        if (pt.x >= x && pt.x < x + w) return [e[@"index"] integerValue];
    }
    return kNoTitle;
}

- (void)pointerMovedTo:(NSPoint)screenPt {
    if (self.finished) return;
    if (hypot(screenPt.x - self.openMouseLocation.x, screenPt.y - self.openMouseLocation.y) > 3.0) self.mouseMovedSinceOpen = YES;

    // Scrubbing across the menu bar opens the title under the pointer.
    NSInteger title = [self menuBarTitleIndexAt:screenPt];
    if (title != kNotInBar && title != kNoTitle && title != self.activeMenuBarIndex && self.mouseMovedSinceOpen) {
        [self finishWithReply:@{ @"result": @(LIONESS_MENU_RESULT_SWITCH_BAR), @"switchMenuBarIndex": @(title) }];
        return;
    }

    for (NSInteger d = (NSInteger)self.panels.count - 1; d >= 0; d--) {
        LionessMenuPanel *panel = self.panels[d];
        LionessMenuView *v = panel.menuView;
        NSPoint lp = [v convertPoint:[panel convertPointFromScreen:screenPt] fromView:nil];
        if (!NSPointInRect(lp, v.menuBoxRect)) continue;
        [self updateAutoscrollForView:v point:lp];
        NSInteger row = [v rowIndexAtViewPoint:lp];
        NSDictionary *item = row >= 0 ? v.items[row] : nil;
        NSInteger newHi = (item && ItemIsSelectable(item)) ? row : -1;
        NSInteger newTag = -1;
        if (item && [item[@"customViewKind"] isEqualToString:@"finderTags"]) {
            newTag = [v finderTagIndexAtViewPoint:lp inRowRect:[v viewRectForRowIndex:row]];
            newHi = -1;
        }
        // Keep the parent row of an open submenu lit while the pointer is in that submenu.
        if (v.highlightedIndex != newHi || v.hoveredTagIndex != newTag) {
            v.highlightedIndex = newHi;
            v.hoveredTagIndex = newTag;
            [v setNeedsDisplay:YES];
        }
        if (newHi >= 0 && ItemHasSubmenu(item)) {
            [self scheduleSubmenuAtDepth:d row:newHi];
        } else {
            [self.submenuTimer invalidate];
            self.pendingSubmenuRow = -1;
            // Leave a submenu open briefly so a diagonal move towards it doesn't close it.
            if ((NSInteger)self.panels.count > d + 1) {
                __weak typeof(self) ws = self;
                NSInteger hiAtSchedule = newHi;
                self.submenuTimer = [NSTimer scheduledTimerWithTimeInterval:0.15 repeats:NO block:^(NSTimer *t) {
                    (void)t;
                    LionessMenuSession *ss = ws;
                    if (!ss || ss.finished || d >= (NSInteger)ss.panels.count) return;
                    if (ss.panels[d].menuView.highlightedIndex == hiAtSchedule) [ss closeSubmenusDeeperThan:d];
                }];
                [[NSRunLoop currentRunLoop] addTimer:self.submenuTimer forMode:NSRunLoopCommonModes];
            }
        }
        return;
    }

    // Outside every menu: unlight the deepest one unless its row owns an open submenu.
    LionessMenuPanel *top = self.panels.lastObject;
    if (top && (top.menuView.highlightedIndex != -1 || top.menuView.hoveredTagIndex != -1)) {
        NSInteger hi = top.menuView.highlightedIndex;
        BOOL ownsSub = hi >= 0 && ItemHasSubmenu(top.menuView.items[hi]);
        if (!ownsSub) {
            top.menuView.highlightedIndex = -1;
            top.menuView.hoveredTagIndex = -1;
            [top.menuView setNeedsDisplay:YES];
        }
    }
    [self.scrollTimer invalidate]; self.scrollTimer = nil;
}

- (void)updateAutoscrollForView:(LionessMenuView *)v point:(NSPoint)lp {
    CGFloat dir = 0.0;
    if (v.scrollOffset > 0.5 && lp.y < NSMinY(v.menuBoxRect) + kRowH) dir = -1.0;
    else if (v.scrollOffset < v.maxScroll - 0.5 && lp.y > NSMaxY(v.menuBoxRect) - kRowH) dir = 1.0;
    if (dir == 0.0) { [self.scrollTimer invalidate]; self.scrollTimer = nil; return; }
    if (self.scrollTimer.valid) return;
    __weak LionessMenuView *wv = v;
    self.scrollTimer = [NSTimer scheduledTimerWithTimeInterval:1.0 / 30.0 repeats:YES block:^(NSTimer *t) {
        LionessMenuView *sv = wv;
        if (!sv) { [t invalidate]; return; }
        CGFloat next = MAX(0.0, MIN(sv.maxScroll, sv.scrollOffset + dir * 6.0));
        if (next == sv.scrollOffset) { [t invalidate]; return; }
        sv.scrollOffset = next;
        [sv setNeedsDisplay:YES];
    }];
    [[NSRunLoop currentRunLoop] addTimer:self.scrollTimer forMode:NSRunLoopCommonModes];
}

- (void)handleScrollEvent:(NSEvent *)event {
    NSPoint screenPt = NSEvent.mouseLocation;
    for (NSInteger d = (NSInteger)self.panels.count - 1; d >= 0; d--) {
        LionessMenuView *v = self.panels[d].menuView;
        NSPoint lp = [v convertPoint:[self.panels[d] convertPointFromScreen:screenPt] fromView:nil];
        if (!NSPointInRect(lp, v.menuBoxRect)) continue;
        if (v.maxScroll > 0.5) {
            CGFloat delta = event.hasPreciseScrollingDeltas ? event.scrollingDeltaY : event.scrollingDeltaY * 12.0;
            v.scrollOffset = MAX(0.0, MIN(v.maxScroll, v.scrollOffset - delta));
            [v setNeedsDisplay:YES];
        }
        return;
    }
}

- (void)moveHighlightBy:(NSInteger)delta {
    LionessMenuPanel *panel = self.panels.lastObject;
    LionessMenuView *v = panel.menuView;
    NSInteger count = (NSInteger)v.items.count;
    if (!count) return;
    NSInteger cur = v.highlightedIndex;
    for (NSInteger step = 0; step < count; step++) {
        cur = cur < 0 ? (delta > 0 ? 0 : count - 1) : (cur + delta + count) % count;
        NSDictionary *it = v.items[cur];
        if (ItemIsSelectable(it) && ![it[@"customViewKind"] length]) {
            v.highlightedIndex = cur;
            NSRect r = [v.rowRects[cur] rectValue];
            CGFloat vis = NSHeight(v.menuBoxRect);
            if (NSMinY(r) - (v.scrollOffset > 0 ? kRowH : 0) < v.scrollOffset) v.scrollOffset = MAX(0.0, NSMinY(r) - kRowH);
            else if (NSMaxY(r) + kRowH > v.scrollOffset + vis && v.maxScroll > 0) v.scrollOffset = MIN(v.maxScroll, NSMaxY(r) + kRowH - vis);
            [v setNeedsDisplay:YES];
            return;
        }
    }
}

- (void)handleKeyCode:(unsigned short)kc character:(unichar)ch modifiers:(NSEventModifierFlags)mods {
    if (self.finished) return;
    LionessMenuPanel *top = self.panels.lastObject;
    switch (kc) {
        case 53: [self cancelAndCloseImmediately]; return;   // Escape
        case 125: [self moveHighlightBy:+1]; return;          // Down
        case 126: [self moveHighlightBy:-1]; return;          // Up
        case 124: {                                            // Right
            NSInteger hi = top.menuView.highlightedIndex;
            if (hi >= 0 && ItemHasSubmenu(top.menuView.items[hi])) {
                [self openSubmenuAtDepth:top.depth row:hi];
                [self moveHighlightBy:+1];
                return;
            }
            if (self.menuBarTitles.count > 1 && self.activeMenuBarIndex != kNoTitle) [self switchMenuBarBy:+1];
            return;
        }
        case 123:                                              // Left
            if (self.panels.count > 1) { [self closeSubmenusDeeperThan:(NSInteger)self.panels.count - 2]; return; }
            if (self.menuBarTitles.count > 1 && self.activeMenuBarIndex != kNoTitle) [self switchMenuBarBy:-1];
            return;
        case 36: case 76: case 49: {                           // Return, Enter, Space
            NSInteger hi = top.menuView.highlightedIndex;
            if (hi >= 0) [self activateItemAtDepth:top.depth row:hi clickPointInView:NSZeroPoint fromKeyboard:YES];
            else [self cancelAndCloseImmediately];
            return;
        }
        default: break;
    }
    if (!ch || (mods & (NSEventModifierFlagCommand | NSEventModifierFlagControl | NSEventModifierFlagOption))) return;
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    if (now - self.lastTypeAt > 0.8) self.typeAhead = @"";
    self.lastTypeAt = now;
    self.typeAhead = [(self.typeAhead ?: @"") stringByAppendingString:[[NSString stringWithCharacters:&ch length:1] lowercaseString]];
    for (NSInteger i = 0; i < (NSInteger)top.menuView.items.count; i++) {
        NSDictionary *it = top.menuView.items[i];
        if (ItemIsSelectable(it) && [[it[@"title"] ?: @"" lowercaseString] hasPrefix:self.typeAhead]) {
            top.menuView.highlightedIndex = i;
            [top.menuView setNeedsDisplay:YES];
            break;
        }
    }
}

- (void)switchMenuBarBy:(NSInteger)delta {
    NSInteger n = (NSInteger)self.menuBarTitles.count, pos = -1;
    for (NSInteger i = 0; i < n; i++) if ([self.menuBarTitles[i][@"index"] integerValue] == self.activeMenuBarIndex) pos = i;
    if (pos < 0) return;
    NSInteger next = [self.menuBarTitles[(pos + delta + n) % n][@"index"] integerValue];
    [self finishWithReply:@{ @"result": @(LIONESS_MENU_RESULT_SWITCH_BAR), @"switchMenuBarIndex": @(next) }];
}

- (BOOL)handleMouseDown:(NSPoint)screenPt {
    for (NSInteger d = (NSInteger)self.panels.count - 1; d >= 0; d--) {
        LionessMenuPanel *panel = self.panels[d];
        LionessMenuView *v = panel.menuView;
        NSPoint lp = [v convertPoint:[panel convertPointFromScreen:screenPt] fromView:nil];
        if (!NSPointInRect(lp, v.menuBoxRect)) continue;
        self.mouseDownInMenu = YES;
        [self pointerMovedTo:screenPt];
        NSInteger row = [v rowIndexAtViewPoint:lp];
        if (row >= 0 && ItemIsSelectable(v.items[row]) && ItemHasSubmenu(v.items[row])) {
            [self openSubmenuAtDepth:d row:row];
        }
        return YES;   // wait for mouse-up to fire the item
    }
    NSInteger title = [self menuBarTitleIndexAt:screenPt];
    if (title != kNotInBar && title != kNoTitle && title != self.activeMenuBarIndex) {
        [self finishWithReply:@{ @"result": @(LIONESS_MENU_RESULT_SWITCH_BAR), @"switchMenuBarIndex": @(title) }];
        return YES;
    }
    [self cancelAndCloseImmediately];
    return NO;
}

- (void)handleMouseUp:(NSPoint)screenPt {
    // Press, drag, release (classic menu tracking): choose on release if the button was pressed
    // inside the menu, or once the pointer has moved / the button was held since open. A quick
    // click that opened the menu just leaves it open.
    BOOL fromInside = self.mouseDownInMenu;
    self.mouseDownInMenu = NO;
    BOOL heldLong = (CFAbsoluteTimeGetCurrent() - self.openedAt) > 0.3;
    if (!fromInside && !self.mouseMovedSinceOpen && !heldLong) return;
    for (NSInteger d = (NSInteger)self.panels.count - 1; d >= 0; d--) {
        LionessMenuPanel *panel = self.panels[d];
        LionessMenuView *v = panel.menuView;
        NSPoint lp = [v convertPoint:[panel convertPointFromScreen:screenPt] fromView:nil];
        if (!NSPointInRect(lp, v.menuBoxRect)) continue;
        NSInteger row = [v rowIndexAtViewPoint:lp];
        if (row >= 0 && ItemIsSelectable(v.items[row]) && !ItemHasSubmenu(v.items[row])) {
            [self activateItemAtDepth:d row:row clickPointInView:lp fromKeyboard:NO];
        }
        return;
    }
    if (fromInside) [self cancelAndCloseImmediately];
}

- (void)handleEvent:(NSEvent *)event {
    if (self.finished) return;
    NSPoint pt = NSEvent.mouseLocation;
    switch (event.type) {
        case NSEventTypeMouseMoved:
        case NSEventTypeLeftMouseDragged:
        case NSEventTypeRightMouseDragged:
            [self pointerMovedTo:pt];
            break;
        case NSEventTypeScrollWheel:
            [self handleScrollEvent:event];
            break;
        case NSEventTypeLeftMouseDown:
        case NSEventTypeRightMouseDown:
        case NSEventTypeOtherMouseDown:
            [self handleMouseDown:pt];
            break;
        case NSEventTypeLeftMouseUp:
        case NSEventTypeRightMouseUp:
            [self handleMouseUp:pt];
            break;
        case NSEventTypeKeyDown: {
            NSString *c = event.charactersIgnoringModifiers;
            [self handleKeyCode:event.keyCode character:c.length ? [c characterAtIndex:0] : 0 modifiers:event.modifierFlags];
            break;
        }
        default:
            break;
    }
}

- (void)start {
    NSString *styleStr = self.request[@"style"] ?: @"context";
    LionessMenuVisualStyle style = LionessVisualContext;
    if ([styleStr isEqualToString:@"menubar"]) style = LionessVisualMenuBar;
    else if ([styleStr isEqualToString:@"popup"]) style = LionessVisualPopup;
    else if ([styleStr isEqualToString:@"dock"]) style = LionessVisualDock;

    fprintf(stderr, "lionessmenud: open %s at %.0f,%.0f %.0fx%.0f\n", styleStr.UTF8String, NSMinX(self.anchorRect), NSMinY(self.anchorRect), NSWidth(self.anchorRect), NSHeight(self.anchorRect));
    NSArray<NSDictionary *> *items = self.request[@"items"];
    if (![items isKindOfClass:NSArray.class] || items.count == 0) {
        [self finishWithReply:@{ @"result": @(LIONESS_MENU_RESULT_CANCELLED) }];
        return;
    }

    LionessMenuPanel *root = [self createPanelForItems:items style:style anchorRect:self.anchorRect
                                         preferredEdge:[self.request[@"preferredEdge"] integerValue]
                                                 depth:0 parentRowIndex:-1];
    [self.panels addObject:root];
    CloseLingeringPanels();
    // Keys go to the frontmost app, which forwards them while its own menu is open. The Dock is
    // never frontmost, so its menu takes the keyboard itself (a non-activating panel can be key
    // without activating menud).
    if (self.isDockMenu) {
        root.takesKeyboard = YES;
        [root makeKeyWindow];
    }

    NSEventMask mask = NSEventMaskMouseMoved | NSEventMaskLeftMouseDown | NSEventMaskLeftMouseUp |
                       NSEventMaskLeftMouseDragged | NSEventMaskRightMouseDown | NSEventMaskRightMouseUp |
                       NSEventMaskRightMouseDragged | NSEventMaskOtherMouseDown | NSEventMaskScrollWheel;
    __weak typeof(self) ws = self;
    // Keys come from the client as LIONESS_MENU_MSG_KEY: other apps' keys aren't visible here.
    self.globalMonitor = [NSEvent addGlobalMonitorForEventsMatchingMask:mask handler:^(NSEvent *e) { [ws handleEvent:e]; }];
    self.localMonitor = [NSEvent addLocalMonitorForEventsMatchingMask:mask | NSEventMaskKeyDown handler:^NSEvent *(NSEvent *e) {
        [ws handleEvent:e];
        return (e.type == NSEventTypeMouseMoved) ? e : nil;
    }];
    [self pointerMovedTo:NSEvent.mouseLocation];
}

@end

// ---------------------------------------------------------------------------
// 4. LionessSpotlight, the sandbox token, and the Mach server
// ---------------------------------------------------------------------------

static const char *kSpotlightPath = "/Library/Lioness/LionessSpotlight";
static pid_t gSpotlightPid = 0;
static CFAbsoluteTime gSpotlightLastSpawn = 0;
static void SpawnSpotlight(const char *mode);

static BOOL SpotlightRunning(void) {
    if (gSpotlightPid > 0 && kill(gSpotlightPid, 0) == 0) return YES;
    for (NSRunningApplication *app in NSWorkspace.sharedWorkspace.runningApplications) {
        if ([app.executableURL.lastPathComponent isEqualToString:@"LionessSpotlight"]) return YES;
    }
    return NO;
}

// LionessSpotlight lives as long as menud, so Spotlight opens with no launch delay.
static void WatchSpotlight(pid_t pid) {
    dispatch_source_t src = dispatch_source_create(DISPATCH_SOURCE_TYPE_PROC, (uintptr_t)pid, DISPATCH_PROC_EXIT, dispatch_get_main_queue());
    dispatch_source_set_event_handler(src, ^{
        dispatch_source_cancel(src);
        int status = 0;
        waitpid(pid, &status, WNOHANG);
        if (gSpotlightPid == pid) gSpotlightPid = 0;
        double wait = (CFAbsoluteTimeGetCurrent() - gSpotlightLastSpawn) < 10.0 ? 10.0 : 1.0;   // don't spin on a crash loop
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(wait * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            if (!SpotlightRunning()) SpawnSpotlight("--daemon");
        });
    });
    dispatch_resume(src);
}

static void SpawnSpotlight(const char *mode) {
    if (access(kSpotlightPath, X_OK) != 0) return;
    pid_t pid = 0;
    char *argv[] = { (char *)kSpotlightPath, (char *)mode, NULL };
    if (posix_spawn(&pid, kSpotlightPath, NULL, NULL, argv, environ) == 0) {
        gSpotlightPid = pid;
        gSpotlightLastSpawn = CFAbsoluteTimeGetCurrent();
        WatchSpotlight(pid);
    }
}

static void TriggerSpotlight(uint32_t action) {
    BOOL running = SpotlightRunning();
    if (action == 3) {   // ensure running: the caller already posted the toggle itself
        if (!running) SpawnSpotlight("--show");
        return;
    }
    if (!running) {
        if (action != 2) SpawnSpotlight("--show");
        return;
    }
    NSString *name = action == 1 ? @LIONESS_SPOTLIGHT_SHOW_NOTE : action == 2 ? @LIONESS_SPOTLIGHT_DISMISS_NOTE : @LIONESS_SPOTLIGHT_TOGGLE_NOTE;
    [[NSDistributedNotificationCenter defaultCenter] postNotificationName:name object:nil userInfo:nil deliverImmediately:YES];
}

static void PublishMenuSandboxToken(void) {
    char *token = sandbox_extension_issue_mach(LIONESS_MENU_TOKEN_CLASS, LIONESS_MENU_SERVICE, 0);
    if (!token) { fprintf(stderr, "lionessmenud: failed to issue sandbox token\n"); return; }
    char tmp[256];
    snprintf(tmp, sizeof(tmp), "%s.new", LIONESS_MENU_TOKEN_PATH);
    FILE *f = fopen(tmp, "w");
    if (f) {
        fputs(token, f);
        fclose(f);
        chmod(tmp, 0644);
        if (rename(tmp, LIONESS_MENU_TOKEN_PATH) != 0) {
            unlink(tmp);
            if ((f = fopen(LIONESS_MENU_TOKEN_PATH, "w"))) { fputs(token, f); fclose(f); }
        }
    } else if ((f = fopen(LIONESS_MENU_TOKEN_PATH, "w"))) {
        fputs(token, f);
        fclose(f);
    }
    free(token);
}

static void HandleIncomingMachPort(mach_port_t port) {
    for (;;) {
        struct {
            union {
                LionessMenuMachMessage present;
                LionessMenuSimpleMessage simple;
                LionessMenuKeyMessage key;
            } m;
            mach_msg_trailer_t trailer;
        } buf;
        memset(&buf, 0, sizeof(buf));
        if (mach_msg(&buf.m.present.header, MACH_RCV_MSG | MACH_RCV_TIMEOUT, 0, sizeof(buf), port, 0, MACH_PORT_NULL) != KERN_SUCCESS) break;

        mach_msg_header_t *hdr = &buf.m.present.header;
        mach_port_t replyPort = hdr->msgh_remote_port;
        switch (hdr->msgh_id) {
            case LIONESS_MENU_MSG_PING: {
                LionessMenuSimpleMessage rep = {};
                rep.header.msgh_bits = MACH_MSGH_BITS(MACH_MSG_TYPE_MOVE_SEND_ONCE, 0);
                rep.header.msgh_size = sizeof(rep);
                rep.header.msgh_remote_port = replyPort;
                rep.header.msgh_id = LIONESS_MENU_MSG_PING + 100;
                if (mach_msg(&rep.header, MACH_SEND_MSG | MACH_SEND_TIMEOUT, sizeof(rep), 0, MACH_PORT_NULL, 250, MACH_PORT_NULL) != KERN_SUCCESS)
                    mach_msg_destroy(hdr);
                break;
            }
            case LIONESS_MENU_MSG_DISMISS:
                [gActiveSession cancelAndCloseImmediately];
                mach_msg_destroy(hdr);
                break;
            case LIONESS_MENU_MSG_KEY:
                [gActiveSession handleKeyCode:(unsigned short)buf.m.key.keyCode character:(unichar)buf.m.key.character
                                    modifiers:(NSEventModifierFlags)buf.m.key.modifiers];
                mach_msg_destroy(hdr);
                break;
            case LIONESS_MENU_MSG_SPOTLIGHT: {
                uint32_t action = buf.m.simple.flags;
                if (action != 3) [gActiveSession cancelAndCloseImmediately];
                TriggerSpotlight(action);
                mach_msg_destroy(hdr);
                break;
            }
            case LIONESS_MENU_MSG_PRESENT: {
                NSDictionary *req = nil;
                if ((hdr->msgh_bits & MACH_MSGH_BITS_COMPLEX) && buf.m.present.payload.address && buf.m.present.payload.size > 0) {
                    NSData *data = [NSData dataWithBytes:buf.m.present.payload.address length:buf.m.present.payload.size];
                    vm_deallocate(mach_task_self(), (vm_address_t)buf.m.present.payload.address, buf.m.present.payload.size);
                    id obj = [NSPropertyListSerialization propertyListWithData:data options:NSPropertyListImmutable format:NULL error:nil];
                    if ([obj isKindOfClass:NSDictionary.class]) req = obj;
                }
                if (!req) { SendMachReply(replyPort, nil); break; }
                // A new menu replaces any open one; a scrubbed-from menu bar menu lingers until it's drawn.
                LionessMenuSession *old = gActiveSession;
                if (old) {
                    if ([req[@"style"] isEqualToString:@"menubar"]) [old finishWithReply:@{ @"result": @(LIONESS_MENU_RESULT_SWITCH_BAR), @"switchMenuBarIndex": @(kNoTitle) }];
                    else [old cancelAndCloseImmediately];
                }
                gActiveSession = [[LionessMenuSession alloc] initWithRequest:req replyPort:replyPort];
                [gActiveSession start];
                break;
            }
            default:
                mach_msg_destroy(hdr);
                break;
        }
    }
}

int main(int argc, const char **argv) {
    @autoreleasepool {
        if (argc >= 2 && argv[1] && argv[1][0] == '/') gMLRoot = [NSString stringWithUTF8String:argv[1]];
        signal(SIGPIPE, SIG_IGN);

        NSApplication *app = [NSApplication sharedApplication];
        [app setActivationPolicy:NSApplicationActivationPolicyAccessory];
        RegisterMountainLionFonts();

        mach_port_t servicePort = MACH_PORT_NULL;
        kern_return_t kr = bootstrap_check_in(bootstrap_port, LIONESS_MENU_SERVICE, &servicePort);
        if (kr != KERN_SUCCESS) {
            mach_port_allocate(mach_task_self(), MACH_PORT_RIGHT_RECEIVE, &servicePort);
            mach_port_insert_right(mach_task_self(), servicePort, servicePort, MACH_MSG_TYPE_MAKE_SEND);
            kr = bootstrap_register(bootstrap_port, (char *)LIONESS_MENU_SERVICE, servicePort);
            if (kr != KERN_SUCCESS) {
                fprintf(stderr, "lionessmenud: cannot check in/register %s: %s\n", LIONESS_MENU_SERVICE, bootstrap_strerror(kr));
                return 1;
            }
        }
        PublishMenuSandboxToken();

        dispatch_source_t src = dispatch_source_create(DISPATCH_SOURCE_TYPE_MACH_RECV, servicePort, 0, dispatch_get_main_queue());
        dispatch_source_set_event_handler(src, ^{ @autoreleasepool { HandleIncomingMachPort(servicePort); } });
        dispatch_resume(src);

        if (!SpotlightRunning()) SpawnSpotlight("--daemon");

        fprintf(stderr, "lionessmenud: serving %s\n", LIONESS_MENU_SERVICE);
        [app run];
    }
    return 0;
}

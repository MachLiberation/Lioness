// LionessSpotlight: Authentic OS X 10.8 Mountain Lion Spotlight dropdown replacement
// (matched to MenuRefs/image-4.webp):
// - Anchored flush beneath the 24pt menu bar on the right side
// - Mountain Lion glossy blue header bar ("Spotlight" + white pill search input)
// - Live NSMetadataQuery search + Calculator + Dictionary ("Look Up") + Web Searches
// - Two-column Mountain Lion results layout with right-aligned gray category column & blue glossy Top Hit
// - Right-click contextual menus routed through lionessmenud (com.lioness.menud)

#import <Cocoa/Cocoa.h>
#import <CoreServices/CoreServices.h>
#import <CoreText/CoreText.h>
#import "../Client/LionessMenuClient.h"
#import "../Shared/MenuProtocol.h"

static NSFont *gSLRegular = nil;
static NSFont *gSLBold = nil;
static NSFont *gSLCategory = nil;

static void LoadMountainLionSpotlightFonts(void) {
    NSString *ttc = @"/Library/Lioness/ml-root/System/Library/Fonts/LucidaGrande.ttc";
    if ([[NSFileManager defaultManager] fileExistsAtPath:ttc]) {
        CTFontManagerRegisterFontsForURL((__bridge CFURLRef)[NSURL fileURLWithPath:ttc], kCTFontManagerScopeProcess, NULL);
    }
    gSLRegular  = [NSFont fontWithName:@"LucidaGrande" size:13.0] ?: [NSFont systemFontOfSize:13.0];
    gSLBold     = [NSFont fontWithName:@"LucidaGrande-Bold" size:13.0] ?: [NSFont boldSystemFontOfSize:13.0];
    gSLCategory = [NSFont fontWithName:@"LucidaGrande" size:12.0] ?: [NSFont systemFontOfSize:12.0];
}

static NSColor *RGB(CGFloat r, CGFloat g, CGFloat b, CGFloat a = 1.0) {
    return [NSColor colorWithSRGBRed:r / 255.0 green:g / 255.0 blue:b / 255.0 alpha:a];
}

// Mountain Lion's selection bar, sampled from the Top Hit row of MenuRefs/image-4 (flipped view).
static void DrawSelection(NSRect r) {
    NSGradient *g = [[NSGradient alloc] initWithStartingColor:RGB(107, 131, 240) endingColor:RGB(49, 85, 237)];
    [g drawInRect:r angle:90.0];
    [RGB(96, 120, 230) setFill];
    NSRectFill(NSMakeRect(NSMinX(r), NSMinY(r), NSWidth(r), 0.5));
    [RGB(34, 71, 227) setFill];
    NSRectFill(NSMakeRect(NSMinX(r), NSMaxY(r) - 0.5, NSWidth(r), 0.5));
}

typedef NS_ENUM(NSInteger, SLRowKind) {
    SLRowShowAllInFinder = 0,
    SLRowFile            = 1,
    SLRowCalculator      = 2,
    SLRowDictionary      = 3,
    SLRowWebSearch       = 4,
    SLRowWikiSearch      = 5,
    SLRowPreferences     = 6,
    SLRowSeparator       = 7,
};

@interface SLResultRow : NSObject
@property (nonatomic, assign) SLRowKind kind;
@property (nonatomic, copy) NSString *category; // shown only on first row of each category
@property (nonatomic, copy) NSString *title;
@property (nonatomic, copy) NSString *path;
@property (nonatomic, strong) NSImage *icon;
@end

@implementation SLResultRow
@end

static BOOL SpotlightMenuOpen = NO;

// Custom search field whose right-click contextual menu routes directly through lionessmenud!
@interface SLSearchField : NSTextField
@end

@implementation SLSearchField
- (void)rightMouseDown:(NSEvent *)event {
    NSString *sel = self.stringValue ?: @"";
    NSText *editor = self.currentEditor;
    NSString *selectedText = sel;
    if (editor && editor.selectedRange.length > 0 && NSMaxRange(editor.selectedRange) <= editor.string.length) {
        selectedText = [editor.string substringWithRange:editor.selectedRange];
    }
    NSMutableArray *items = [NSMutableArray array];
    if (selectedText.length > 0) {
        [items addObject:@{ @"id": @1, @"title": [NSString stringWithFormat:@"Look Up “%@”", selectedText], @"enabled": @YES }];
        [items addObject:@{ @"id": @2, @"title": @"Search with Google", @"enabled": @YES }];
        [items addObject:@{ @"id": @3, @"separator": @YES }];
    }
    BOOL hasSel = (selectedText.length > 0);
    BOOL hasPaste = ([[NSPasteboard generalPasteboard] stringForType:NSPasteboardTypeString].length > 0);
    [items addObject:@{ @"id": @4, @"title": @"Cut", @"enabled": @(hasSel) }];
    [items addObject:@{ @"id": @5, @"title": @"Copy", @"enabled": @(hasSel) }];
    [items addObject:@{ @"id": @6, @"title": @"Paste", @"enabled": @(hasPaste) }];
    [items addObject:@{ @"id": @7, @"separator": @YES }];
    [items addObject:@{ @"id": @8, @"title": @"Select All", @"enabled": @(sel.length > 0) }];

    NSPoint scr = NSEvent.mouseLocation;
    SpotlightMenuOpen = YES;
    NSDictionary *reply = LionessMenuPresent(@{
        @"style": @"context",
        @"anchorX": @(scr.x),
        @"anchorY": @(scr.y),
        @"anchorW": @1,
        @"anchorH": @1,
        @"items": items,
    });
    SpotlightMenuOpen = NO;
    [self.window makeKeyWindow];
    if (!reply || [reply[@"result"] integerValue] != LIONESS_MENU_RESULT_SELECTED) return;
    NSInteger chosen = [reply[@"itemId"] integerValue];
    if (chosen == 1 && selectedText.length > 0) {
        NSString *enc = [selectedText stringByAddingPercentEncodingWithAllowedCharacters:NSCharacterSet.URLPathAllowedCharacterSet];
        [[NSWorkspace sharedWorkspace] openURL:[NSURL URLWithString:[NSString stringWithFormat:@"dict://%@", enc]]];
    } else if (chosen == 2 && selectedText.length > 0) {
        NSString *enc = [selectedText stringByAddingPercentEncodingWithAllowedCharacters:NSCharacterSet.URLQueryAllowedCharacterSet];
        [[NSWorkspace sharedWorkspace] openURL:[NSURL URLWithString:[NSString stringWithFormat:@"https://www.google.com/search?q=%@", enc]]];
    } else if (chosen == 4) {
        [NSApp sendAction:@selector(cut:) to:nil from:self];
    } else if (chosen == 5) {
        [NSApp sendAction:@selector(copy:) to:nil from:self];
    } else if (chosen == 6) {
        [NSApp sendAction:@selector(paste:) to:nil from:self];
    } else if (chosen == 8) {
        [NSApp sendAction:@selector(selectAll:) to:nil from:self];
    }
}
@end

@class SpotlightController;

@interface SpotlightCanvasView : NSView
@property (nonatomic, weak) SpotlightController *controller;
@property (nonatomic, strong) NSArray<SLResultRow *> *rows;
@property (nonatomic, assign) NSInteger selectedRow;
@end

// A non-activating panel takes the keyboard without making LionessSpotlight the active app,
// so it works under macOS's cooperative activation and the app the user was in stays frontmost.
@interface SpotlightPanel : NSPanel
@end
@implementation SpotlightPanel
- (BOOL)canBecomeKeyWindow  { return YES; }
- (BOOL)canBecomeMainWindow { return NO; }
@end

// The blue highlight behind the menu bar magnifier while Spotlight is open (image-4).
@interface SpotlightIconView : NSView
@end
@implementation SpotlightIconView
- (void)drawRect:(NSRect)dirtyRect {
    (void)dirtyRect;
    NSGradient *g = [[NSGradient alloc] initWithStartingColor:RGB(105, 126, 237) endingColor:RGB(66, 93, 234)];
    [g drawInRect:self.bounds angle:-90.0];
    NSImage *glass = [NSImage imageWithSystemSymbolName:@"magnifyingglass" accessibilityDescription:nil];
    NSImageSymbolConfiguration *cfg = [NSImageSymbolConfiguration configurationWithPointSize:14.0 weight:NSFontWeightSemibold];
    glass = [[glass imageWithSymbolConfiguration:cfg] copy];
    if (glass) {
        NSSize sz = glass.size;
        NSRect r = NSMakeRect(floor(NSMidX(self.bounds) - sz.width / 2), floor(NSMidY(self.bounds) - sz.height / 2), sz.width, sz.height);
        NSImage *white = [NSImage imageWithSize:sz flipped:NO drawingHandler:^BOOL(NSRect dst) {
            [glass drawInRect:dst];
            [NSColor.whiteColor set];
            NSRectFillUsingOperation(dst, NSCompositingOperationSourceAtop);
            return YES;
        }];
        [white drawInRect:r];
    }
}
@end

@interface SpotlightController : NSObject <NSTextFieldDelegate, NSWindowDelegate>
@property (nonatomic, strong) SpotlightPanel *panel;
@property (nonatomic, strong) SpotlightCanvasView *canvas;
@property (nonatomic, strong) SLSearchField *searchField;
@property (nonatomic, strong) NSMetadataQuery *query;
@property (nonatomic, strong) NSMutableArray<SLResultRow *> *rows;
@property (nonatomic, assign) NSInteger selectedRow;
@property (nonatomic, strong) id globalClickMonitor;
@property (nonatomic, strong) NSPanel *iconPanel;
@property (nonatomic, assign) NSRect statusItemRect;
@property (nonatomic, assign) CFAbsoluteTime dismissedAt;
- (void)showSpotlight;
- (void)noteStatusItemRect:(id)object;
- (void)dismissSpotlight;
- (void)toggleSpotlight;
- (void)activateRowAtIndex:(NSInteger)idx revealInFinder:(BOOL)reveal;
@end

// MenuRefs/image-4 (2x): 431pt wide, a 31pt blue header, a 122pt category column with a 1pt
// divider, 21pt rows, 8pt between groups, 9pt from the divider to icons and 32pt to titles.
static const CGFloat kSLWidth    = 431.0;
static const CGFloat kSLHeaderH  = 31.0;
static const CGFloat kSLRowH     = 21.0;
static const CGFloat kSLGapH     = 8.0;
static const CGFloat kSLCatColW  = 122.0;
static const CGFloat kSLCorner   = 5.0;
static const CGFloat kSLTopPad   = 6.0;
static const CGFloat kSLBottomPad = 6.0;

static CGFloat RowHeight(SLRowKind k) { return k == SLRowSeparator ? kSLGapH : kSLRowH; }

@implementation SpotlightCanvasView
- (BOOL)isFlipped { return YES; }
- (BOOL)acceptsFirstMouse:(NSEvent *)event { (void)event; return YES; }

- (CGFloat)yForRow:(NSInteger)target {
    CGFloat y = kSLHeaderH + kSLTopPad;
    for (NSInteger i = 0; i < target && i < (NSInteger)self.rows.count; i++) y += RowHeight(self.rows[i].kind);
    return y;
}

- (NSInteger)rowAtPoint:(NSPoint)pt {
    if (pt.y < kSLHeaderH) return -1;
    CGFloat y = kSLHeaderH + kSLTopPad;
    for (NSInteger i = 0; i < (NSInteger)self.rows.count; i++) {
        CGFloat h = RowHeight(self.rows[i].kind);
        if (pt.y >= y && pt.y < y + h) return self.rows[i].kind == SLRowSeparator ? -1 : i;
        y += h;
    }
    return -1;
}

- (void)mouseMoved:(NSEvent *)event {
    NSInteger r = [self rowAtPoint:[self convertPoint:event.locationInWindow fromView:nil]];
    if (r >= 0 && r != self.selectedRow) {
        self.selectedRow = r;
        self.controller.selectedRow = r;
        [self setNeedsDisplay:YES];
    }
}

- (void)mouseDown:(NSEvent *)event {
    NSInteger r = [self rowAtPoint:[self convertPoint:event.locationInWindow fromView:nil]];
    if (r >= 0) [self.controller activateRowAtIndex:r revealInFinder:(event.modifierFlags & NSEventModifierFlagCommand) != 0];
}

- (void)drawRect:(NSRect)dirtyRect {
    (void)dirtyRect;
    NSRect b = self.bounds;
    // Square top flush under the menu bar, rounded bottom corners.
    NSBezierPath *clip = [NSBezierPath bezierPath];
    [clip moveToPoint:NSMakePoint(0, 0)];
    [clip lineToPoint:NSMakePoint(NSWidth(b), 0)];
    [clip lineToPoint:NSMakePoint(NSWidth(b), NSHeight(b) - kSLCorner)];
    [clip appendBezierPathWithArcFromPoint:NSMakePoint(NSWidth(b), NSHeight(b)) toPoint:NSMakePoint(NSWidth(b) - kSLCorner, NSHeight(b)) radius:kSLCorner];
    [clip lineToPoint:NSMakePoint(kSLCorner, NSHeight(b))];
    [clip appendBezierPathWithArcFromPoint:NSMakePoint(0, NSHeight(b)) toPoint:NSMakePoint(0, NSHeight(b) - kSLCorner) radius:kSLCorner];
    [clip closePath];
    [NSGraphicsContext saveGraphicsState];
    [clip addClip];

    // Header: (105,126,237) to (50,79,233).
    NSRect hdr = NSMakeRect(0, 0, NSWidth(b), kSLHeaderH);
    [[[NSGradient alloc] initWithStartingColor:RGB(105, 126, 237) endingColor:RGB(50, 79, 233)] drawInRect:hdr angle:90.0];

    NSShadow *etch = [[NSShadow alloc] init];
    etch.shadowColor = [NSColor colorWithWhite:0.0 alpha:0.4];
    etch.shadowOffset = NSMakeSize(0, -1);
    etch.shadowBlurRadius = 0.0;
    NSMutableParagraphStyle *right = [[NSMutableParagraphStyle alloc] init];
    right.alignment = NSTextAlignmentRight;
    [@"Spotlight" drawInRect:NSMakeRect(0, floor((kSLHeaderH - 17.0) / 2.0), kSLCatColW - 7.0, 18.0)
              withAttributes:@{ NSFontAttributeName: gSLBold, NSForegroundColorAttributeName: NSColor.whiteColor,
                                NSShadowAttributeName: etch, NSParagraphStyleAttributeName: right }];

    // Search field: a white capsule with a dark blue ring and a soft inner shadow at the top.
    NSRect pill = NSMakeRect(kSLCatColW + 8.5, 5.5, NSWidth(b) - kSLCatColW - 15.0, 21.0);
    NSBezierPath *pp = [NSBezierPath bezierPathWithRoundedRect:pill xRadius:10.5 yRadius:10.5];
    [NSColor.whiteColor setFill];
    [pp fill];
    [NSGraphicsContext saveGraphicsState];
    [pp addClip];
    [[[NSGradient alloc] initWithStartingColor:RGB(205, 208, 218) endingColor:[NSColor colorWithWhite:1.0 alpha:0.0]]
        drawInRect:NSMakeRect(NSMinX(pill), NSMinY(pill), NSWidth(pill), 3.0) angle:90.0];
    [NSGraphicsContext restoreGraphicsState];
    [RGB(52, 71, 164) setStroke];
    pp.lineWidth = 1.0;
    [pp stroke];

    if (self.rows.count > 0) {
        // Body: (246,248,250) category column, a (222,222,222) divider, (238,240,241) results.
        CGFloat bodyY = kSLHeaderH;
        [RGB(246, 248, 250) setFill];
        NSRectFill(NSMakeRect(0, bodyY, kSLCatColW, NSHeight(b) - bodyY));
        [RGB(222, 222, 222) setFill];
        NSRectFill(NSMakeRect(kSLCatColW, bodyY, 1.0, NSHeight(b) - bodyY));
        [RGB(238, 240, 241) setFill];
        NSRectFill(NSMakeRect(kSLCatColW + 1.0, bodyY, NSWidth(b) - kSLCatColW - 1.0, NSHeight(b) - bodyY));
    }

    NSMutableParagraphStyle *tail = [[NSMutableParagraphStyle alloc] init];
    tail.lineBreakMode = NSLineBreakByTruncatingTail;
    CGFloat y = kSLHeaderH + kSLTopPad;
    for (NSInteger i = 0; i < (NSInteger)self.rows.count; i++) {
        SLResultRow *row = self.rows[i];
        if (row.kind == SLRowSeparator) { y += kSLGapH; continue; }
        NSRect rr = NSMakeRect(0, y, NSWidth(b), kSLRowH);
        BOOL sel = (i == self.selectedRow);
        if (sel) DrawSelection(rr);

        if (row.category.length > 0) {
            NSMutableParagraphStyle *rps = [[NSMutableParagraphStyle alloc] init];
            rps.alignment = NSTextAlignmentRight;
            [row.category drawInRect:NSMakeRect(0, y + 3.0, kSLCatColW - 9.5, 17.0)
                      withAttributes:@{ NSFontAttributeName: gSLCategory,
                                        NSForegroundColorAttributeName: sel ? NSColor.whiteColor : RGB(128, 129, 131),
                                        NSParagraphStyleAttributeName: rps }];
        }
        CGFloat x = kSLCatColW + 9.0;
        if (row.icon) {
            [row.icon drawInRect:NSMakeRect(x, y + 2.5, 16.0, 16.0) fromRect:NSZeroRect
                       operation:NSCompositingOperationSourceOver fraction:1.0 respectFlipped:YES hints:nil];
        }
        if (row.icon || row.kind == SLRowFile || row.kind == SLRowCalculator || row.kind == SLRowDictionary ||
            row.kind == SLRowWebSearch || row.kind == SLRowWikiSearch) x = kSLCatColW + 32.0;
        else x = kSLCatColW + 8.0;
        [row.title drawInRect:NSMakeRect(x, y + 2.0, NSWidth(b) - x - 10.0, 18.0)
               withAttributes:@{ NSFontAttributeName: gSLRegular,
                                 NSForegroundColorAttributeName: sel ? NSColor.whiteColor : NSColor.blackColor,
                                 NSParagraphStyleAttributeName: tail }];
        y += kSLRowH;
    }
    [NSGraphicsContext restoreGraphicsState];
}
@end

@implementation SpotlightController

- (instancetype)init {
    if ((self = [super init])) {
        _rows = [NSMutableArray array];
        _selectedRow = -1;
        [self buildWindow];
    }
    return self;
}

- (void)buildWindow {
    NSRect frame = NSMakeRect(0, 0, kSLWidth, kSLHeaderH);
    self.panel = [[SpotlightPanel alloc] initWithContentRect:frame
                                                   styleMask:NSWindowStyleMaskBorderless | NSWindowStyleMaskNonactivatingPanel
                                                     backing:NSBackingStoreBuffered
                                                       defer:NO];
    self.panel.opaque = NO;
    self.panel.backgroundColor = NSColor.clearColor;
    self.panel.hasShadow = YES;
    self.panel.level = kCGPopUpMenuWindowLevel;
    self.panel.becomesKeyOnlyIfNeeded = NO;
    self.panel.hidesOnDeactivate = NO;
    self.panel.animationBehavior = NSWindowAnimationBehaviorNone;
    self.panel.collectionBehavior = NSWindowCollectionBehaviorCanJoinAllSpaces | NSWindowCollectionBehaviorFullScreenAuxiliary |
                                    NSWindowCollectionBehaviorTransient;
    self.panel.delegate = self;

    self.canvas = [[SpotlightCanvasView alloc] initWithFrame:frame];
    self.canvas.controller = self;
    self.canvas.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    [self.canvas addTrackingArea:[[NSTrackingArea alloc] initWithRect:NSZeroRect
                                                              options:NSTrackingMouseMoved | NSTrackingActiveAlways | NSTrackingInVisibleRect
                                                                owner:self.canvas userInfo:nil]];

    // Lucida Grande 13 in a 21pt capsule: the text field sits 2pt below the capsule's top.
    self.searchField = [[SLSearchField alloc] initWithFrame:NSMakeRect(kSLCatColW + 19.0, 7.5, kSLWidth - kSLCatColW - 37.0, 17.0)];
    self.searchField.bordered = NO;
    self.searchField.bezeled = NO;
    self.searchField.drawsBackground = NO;
    self.searchField.focusRingType = NSFocusRingTypeNone;
    self.searchField.font = gSLRegular;
    self.searchField.textColor = NSColor.blackColor;
    self.searchField.delegate = self;
    self.searchField.cell.scrollable = YES;
    self.searchField.cell.wraps = NO;
    [self.canvas addSubview:self.searchField];
    self.panel.contentView = self.canvas;

    self.iconPanel = [[NSPanel alloc] initWithContentRect:NSMakeRect(0, 0, 30, 24)
                                                styleMask:NSWindowStyleMaskBorderless | NSWindowStyleMaskNonactivatingPanel
                                                  backing:NSBackingStoreBuffered defer:YES];
    self.iconPanel.opaque = NO;
    self.iconPanel.backgroundColor = NSColor.clearColor;
    self.iconPanel.hasShadow = NO;
    self.iconPanel.ignoresMouseEvents = YES;
    self.iconPanel.level = kCGPopUpMenuWindowLevel;
    self.iconPanel.animationBehavior = NSWindowAnimationBehaviorNone;
    self.iconPanel.collectionBehavior = self.panel.collectionBehavior;
    self.iconPanel.contentView = [[SpotlightIconView alloc] initWithFrame:NSMakeRect(0, 0, 30, 24)];
}

- (void)noteStatusItemRect:(id)object {
    if (![object isKindOfClass:NSString.class]) return;
    NSArray<NSString *> *p = [(NSString *)object componentsSeparatedByString:@" "];
    if (p.count != 4) return;
    NSRect r = NSMakeRect(p[0].doubleValue, p[1].doubleValue, p[2].doubleValue, p[3].doubleValue);
    if (NSWidth(r) > 4.0 && NSHeight(r) > 4.0) self.statusItemRect = r;
}

- (NSScreen *)targetScreen {
    if (!NSIsEmptyRect(self.statusItemRect)) {
        for (NSScreen *s in NSScreen.screens) if (NSPointInRect(NSMakePoint(NSMidX(self.statusItemRect), NSMidY(self.statusItemRect)), s.frame)) return s;
    }
    return NSScreen.screens.firstObject ?: NSScreen.mainScreen;
}

// The magnifier's highlight, sized like a Mountain Lion menu bar item: the bar's full 24pt height.
- (NSRect)iconHighlightRect {
    NSScreen *scr = [self targetScreen];
    NSRect sf = scr.frame;
    if (NSIsEmptyRect(self.statusItemRect)) return NSMakeRect(NSMaxX(sf) - 52.0, NSMaxY(sf) - 24.0, 30.0, 24.0);
    return NSMakeRect(round(NSMinX(self.statusItemRect)), NSMaxY(sf) - 24.0, round(NSWidth(self.statusItemRect)), 24.0);
}

- (void)updatePanelFrame {
    NSScreen *scr = [self targetScreen];
    NSRect sf = scr.frame;
    CGFloat totalH = kSLHeaderH;
    if (self.rows.count > 0) {
        totalH += kSLTopPad + kSLBottomPad;
        for (SLResultRow *r in self.rows) totalH += RowHeight(r.kind);
    }
    totalH = MIN(totalH, NSHeight(sf) - 60.0);
    // Right edge flush with the magnifier's highlight, top flush under the 24pt bar.
    NSRect icon = [self iconHighlightRect];
    CGFloat x = MIN(NSMaxX(icon), NSMaxX(sf)) - kSLWidth;
    NSRect f = NSMakeRect(round(MAX(NSMinX(sf), x)), NSMaxY(sf) - 24.0 - ceil(totalH), kSLWidth, ceil(totalH));
    self.canvas.rows = [self.rows copy];
    self.canvas.selectedRow = self.selectedRow;
    [self.panel setFrame:f display:NO];
    [self.canvas setNeedsDisplay:YES];
    [self.panel displayIfNeeded];
    [self.panel invalidateShadow];
}

- (void)showSpotlight {
    [self.query stopQuery];
    self.searchField.stringValue = @"";
    [self.rows removeAllObjects];
    self.selectedRow = -1;
    [self updatePanelFrame];

    [self.iconPanel setFrame:[self iconHighlightRect] display:YES];
    [self.iconPanel orderFrontRegardless];
    [self.panel makeKeyAndOrderFront:nil];
    [self.panel makeFirstResponder:self.searchField];

    if (!self.globalClickMonitor) {
        __weak typeof(self) ws = self;
        self.globalClickMonitor = [NSEvent addGlobalMonitorForEventsMatchingMask:(NSEventMaskLeftMouseDown | NSEventMaskRightMouseDown) handler:^(NSEvent *e) {
            (void)e;
            if (!SpotlightMenuOpen) [ws dismissSpotlight];
        }];
    }
}

- (void)dismissSpotlight {
    if (!self.panel.isVisible) return;
    [self.query stopQuery];
    [self.panel orderOut:nil];
    [self.iconPanel orderOut:nil];
    self.dismissedAt = CFAbsoluteTimeGetCurrent();
    if (self.globalClickMonitor) {
        [NSEvent removeMonitor:self.globalClickMonitor];
        self.globalClickMonitor = nil;
    }
}

- (void)toggleSpotlight {
    if (self.panel.isVisible) { [self dismissSpotlight]; return; }
    // Clicking the magnifier while open: the click outside already closed it.
    if (CFAbsoluteTimeGetCurrent() - self.dismissedAt < 0.4) return;
    [self showSpotlight];
}

- (void)windowDidResignKey:(NSNotification *)notification {
    (void)notification;
    if (self.panel.isVisible && !SpotlightMenuOpen) [self dismissSpotlight];
}

static NSString *EvaluateSimpleMath(NSString *q) {
    NSCharacterSet *allowed = [NSCharacterSet characterSetWithCharactersInString:@"0123456789.+-*/() "];
    if (q.length < 3 || [q rangeOfCharacterFromSet:allowed.invertedSet].location != NSNotFound) return nil;
    if ([q rangeOfCharacterFromSet:[NSCharacterSet characterSetWithCharactersInString:@"+-*/"]].location == NSNotFound) return nil;
    @try {
        NSExpression *exp = [NSExpression expressionWithFormat:q];
        id val = [exp expressionValueWithObject:nil context:nil];
        if ([val isKindOfClass:NSNumber.class]) {
            double d = [val doubleValue];
            if (isfinite(d)) {
                return [NSString stringWithFormat:@"%@ = %g", q, d];
            }
        }
    } @catch (NSException *) {}
    return nil;
}

static NSString *CategoryForItem(NSMetadataItem *item, NSString *path) {
    NSString *ct = [item valueForAttribute:(NSString *)kMDItemContentType];
    if ([ct isEqualToString:@"com.apple.application-bundle"] || [path hasSuffix:@".app"]) return @"Applications";
    if ([path hasSuffix:@".prefPane"] || [path containsString:@"System Settings"]) return @"System Preferences";
    if ([ct isEqualToString:@"public.folder"]) return @"Folders";
    if ([ct containsString:@"font"] || [path hasSuffix:@".otf"] || [path hasSuffix:@".ttf"] || [path hasSuffix:@".ttc"]) return @"Fonts";
    if ([ct isEqualToString:@"com.adobe.pdf"]) return @"PDF Documents";
    if ([ct containsString:@"image"]) return @"Images";
    if ([ct containsString:@"audio"] || [ct containsString:@"mp3"]) return @"Music";
    return @"Documents";
}

- (void)rebuildRowsFromQuery:(NSString *)text mdItems:(NSArray<NSMetadataItem *> *)mdItems {
    [self.rows removeAllObjects];
    NSString *q = [text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (q.length == 0) {
        self.selectedRow = -1;
        [self updatePanelFrame];
        return;
    }

    // 1. Top row: Show All in Finder
    SLResultRow *showAll = [[SLResultRow alloc] init];
    showAll.kind = SLRowShowAllInFinder;
    showAll.title = @"Show All in Finder";
    [self.rows addObject:showAll];

    SLResultRow *sep0 = [[SLResultRow alloc] init];
    sep0.kind = SLRowSeparator;
    [self.rows addObject:sep0];

    // Group metadata results into Mountain Lion categories
    NSMutableArray<SLResultRow *> *allFileRows = [NSMutableArray array];
    NSString *qLow = q.lowercaseString;
    SLResultRow *bestHit = nil;
    int bestScore = -1;

    for (NSMetadataItem *it in mdItems) {
        NSString *path = [it valueForAttribute:(NSString *)kMDItemPath];
        NSString *name = path.length ? [[NSFileManager defaultManager] displayNameAtPath:path] : nil;   // "Terminal", as Finder shows it
        if (!name.length) name = [it valueForAttribute:(NSString *)kMDItemDisplayName] ?: path.lastPathComponent;
        if (!path.length || !name.length) continue;
        SLResultRow *r = [[SLResultRow alloc] init];
        r.kind = SLRowFile;
        r.title = name;
        r.path = path;
        r.category = CategoryForItem(it, path);
        r.icon = [[NSWorkspace sharedWorkspace] iconForFile:path];

        int score = 0;
        NSString *nl = name.lowercaseString;
        if ([nl isEqualToString:qLow]) score += 100;
        else if ([nl hasPrefix:qLow]) score += 60;
        else if ([nl containsString:qLow]) score += 20;
        if ([r.category isEqualToString:@"Applications"]) score += 40;
        if ([r.category isEqualToString:@"System Preferences"]) score += 30;
        if (score > bestScore) { bestScore = score; bestHit = r; }
        [allFileRows addObject:r];
        if (allFileRows.count >= 40) break;
    }

    // Calculator Top Hit if arithmetic
    NSString *math = EvaluateSimpleMath(q);
    if (math) {
        SLResultRow *mr = [[SLResultRow alloc] init];
        mr.kind = SLRowCalculator;
        mr.category = @"Top Hit";
        mr.title = math;
        mr.icon = [[NSWorkspace sharedWorkspace] iconForFile:@"/System/Applications/Calculator.app"];
        [self.rows addObject:mr];
        self.selectedRow = (NSInteger)self.rows.count - 1;
    } else if (bestHit) {
        SLResultRow *top = [[SLResultRow alloc] init];
        top.kind = SLRowFile;
        top.category = @"Top Hit";
        top.title = bestHit.title;
        top.path = bestHit.path;
        top.icon = bestHit.icon;
        [self.rows addObject:top];
        self.selectedRow = (NSInteger)self.rows.count - 1;
    } else {
        self.selectedRow = 0;
    }

    // Categorized rows (up to 4 per category, max ~18 rows total)
    NSArray<NSString *> *catOrder = @[ @"Applications", @"System Preferences", @"Documents", @"Folders", @"Fonts", @"PDF Documents", @"Images", @"Music" ];
    NSInteger addedFiles = 0;
    for (NSString *cat in catOrder) {
        if (addedFiles >= 14) break;
        NSMutableArray<SLResultRow *> *bucket = [NSMutableArray array];
        for (SLResultRow *r in allFileRows) {
            if ([r.category isEqualToString:cat] && (!bestHit || ![r.path isEqualToString:bestHit.path])) {
                [bucket addObject:r];
                if (bucket.count >= 4) break;
            }
        }
        if (bucket.count == 0) continue;
        SLResultRow *sep = [[SLResultRow alloc] init]; sep.kind = SLRowSeparator;
        [self.rows addObject:sep];
        for (NSInteger k = 0; k < (NSInteger)bucket.count; k++) {
            bucket[k].category = (k == 0) ? cat : nil;
            [self.rows addObject:bucket[k]];
            addedFiles++;
        }
    }

    // Dictionary Look Up (exact match to MenuRefs/image-4.webp!)
    CFStringRef def = DCSCopyTextDefinition(NULL, (__bridge CFStringRef)q, CFRangeMake(0, (CFIndex)q.length));
    if (def) {
        SLResultRow *sep = [[SLResultRow alloc] init]; sep.kind = SLRowSeparator;
        [self.rows addObject:sep];
        SLResultRow *dr = [[SLResultRow alloc] init];
        dr.kind = SLRowDictionary;
        dr.category = @"Look Up";
        dr.title = q;
        dr.path = q;
        dr.icon = [[NSWorkspace sharedWorkspace] iconForFile:@"/System/Applications/Dictionary.app"];
        [self.rows addObject:dr];
        CFRelease(def);
    }

    // Web Searches (exact match to MenuRefs/image-4.webp!)
    SLResultRow *sepW = [[SLResultRow alloc] init]; sepW.kind = SLRowSeparator;
    [self.rows addObject:sepW];

    NSImage *globe = [NSImage imageNamed:NSImageNameNetwork];
    SLResultRow *web = [[SLResultRow alloc] init];
    web.kind = SLRowWebSearch;
    web.category = @"Web Searches";
    web.title = [NSString stringWithFormat:@"Search Web for “%@”", q];
    web.path = q;
    web.icon = globe;
    [self.rows addObject:web];

    SLResultRow *wiki = [[SLResultRow alloc] init];
    wiki.kind = SLRowWikiSearch;
    wiki.category = nil;
    wiki.title = [NSString stringWithFormat:@"Search Wikipedia for “%@”", q];
    wiki.path = q;
    wiki.icon = globe;
    [self.rows addObject:wiki];

    // Bottom: Spotlight Preferences...
    SLResultRow *sepP = [[SLResultRow alloc] init]; sepP.kind = SLRowSeparator;
    [self.rows addObject:sepP];

    SLResultRow *prefs = [[SLResultRow alloc] init];
    prefs.kind = SLRowPreferences;
    prefs.title = @"Spotlight Preferences…";
    [self.rows addObject:prefs];

    [self updatePanelFrame];
}

- (void)startSearchForText:(NSString *)text {
    [self.query stopQuery];
    NSString *q = [text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (q.length == 0) {
        [self rebuildRowsFromQuery:@"" mdItems:@[]];
        return;
    }
    [self rebuildRowsFromQuery:q mdItems:@[]];

    self.query = [[NSMetadataQuery alloc] init];
    self.query.predicate = [NSPredicate predicateWithFormat:@"kMDItemDisplayName CONTAINS[cd] %@ OR kMDItemFSName CONTAINS[cd] %@", q, q];
    self.query.searchScopes = @[ @"/Applications", @"/System/Applications", NSMetadataQueryUserHomeScope ];
    self.query.sortDescriptors = @[ [NSSortDescriptor sortDescriptorWithKey:(NSString *)kMDItemLastUsedDate ascending:NO] ];

    __weak typeof(self) ws = self;
    [[NSNotificationCenter defaultCenter] removeObserver:self name:NSMetadataQueryDidFinishGatheringNotification object:nil];
    [[NSNotificationCenter defaultCenter] removeObserver:self name:NSMetadataQueryDidUpdateNotification object:nil];
    id handler = ^(NSNotification *n) {
        (void)n;
        __strong typeof(self) ss = ws;
        if (!ss || !ss.panel.isVisible) return;
        [ss.query disableUpdates];
        NSArray *res = [ss.query.results copy];
        [ss.query enableUpdates];
        [ss rebuildRowsFromQuery:ss.searchField.stringValue mdItems:res];
    };
    [[NSNotificationCenter defaultCenter] addObserverForName:NSMetadataQueryDidFinishGatheringNotification object:self.query queue:NSOperationQueue.mainQueue usingBlock:handler];
    [[NSNotificationCenter defaultCenter] addObserverForName:NSMetadataQueryDidUpdateNotification object:self.query queue:NSOperationQueue.mainQueue usingBlock:handler];
    [self.query startQuery];
}

- (void)controlTextDidChange:(NSNotification *)obj {
    (void)obj;
    [self startSearchForText:self.searchField.stringValue];
}

- (void)moveSelection:(NSInteger)delta {
    NSInteger n = (NSInteger)self.rows.count;
    if (n == 0) return;
    NSInteger cur = self.selectedRow;
    for (NSInteger k = 0; k < n; k++) {
        cur = (cur < 0) ? (delta > 0 ? 0 : n - 1) : ((cur + delta + n) % n);
        if (self.rows[cur].kind != SLRowSeparator) {
            self.selectedRow = cur;
            self.canvas.selectedRow = cur;
            [self.canvas setNeedsDisplay:YES];
            return;
        }
    }
}

- (BOOL)control:(NSControl *)control textView:(NSTextView *)textView doCommandBySelector:(SEL)commandSelector {
    (void)control; (void)textView;
    if (commandSelector == @selector(cancelOperation:)) {
        [self dismissSpotlight];
        return YES;
    }
    if (commandSelector == @selector(moveDown:)) {
        [self moveSelection:+1];
        return YES;
    }
    if (commandSelector == @selector(moveUp:)) {
        [self moveSelection:-1];
        return YES;
    }
    if (commandSelector == @selector(insertNewline:)) {
        BOOL reveal = (NSEvent.modifierFlags & NSEventModifierFlagCommand) != 0;
        if (self.selectedRow >= 0) [self activateRowAtIndex:self.selectedRow revealInFinder:reveal];
        return YES;
    }
    return NO;
}

- (void)activateRowAtIndex:(NSInteger)idx revealInFinder:(BOOL)reveal {
    if (idx < 0 || idx >= (NSInteger)self.rows.count) return;
    SLResultRow *row = self.rows[idx];
    NSString *q = self.searchField.stringValue ?: @"";
    [self dismissSpotlight];

    switch (row.kind) {
        case SLRowFile:
            if (reveal) [[NSWorkspace sharedWorkspace] activateFileViewerSelectingURLs:@[ [NSURL fileURLWithPath:row.path] ]];
            else [[NSWorkspace sharedWorkspace] openURL:[NSURL fileURLWithPath:row.path]];
            break;
        case SLRowCalculator:
            [[NSPasteboard generalPasteboard] clearContents];
            [[NSPasteboard generalPasteboard] setString:row.title forType:NSPasteboardTypeString];
            break;
        case SLRowDictionary: {
            NSString *enc = [row.path stringByAddingPercentEncodingWithAllowedCharacters:NSCharacterSet.URLPathAllowedCharacterSet];
            [[NSWorkspace sharedWorkspace] openURL:[NSURL URLWithString:[NSString stringWithFormat:@"dict://%@", enc]]];
            break;
        }
        case SLRowWebSearch: {
            NSString *enc = [row.path stringByAddingPercentEncodingWithAllowedCharacters:NSCharacterSet.URLQueryAllowedCharacterSet];
            [[NSWorkspace sharedWorkspace] openURL:[NSURL URLWithString:[NSString stringWithFormat:@"https://www.google.com/search?q=%@", enc]]];
            break;
        }
        case SLRowWikiSearch: {
            NSString *enc = [row.path stringByAddingPercentEncodingWithAllowedCharacters:NSCharacterSet.URLQueryAllowedCharacterSet];
            [[NSWorkspace sharedWorkspace] openURL:[NSURL URLWithString:[NSString stringWithFormat:@"https://en.wikipedia.org/wiki/Special:Search?search=%@", enc]]];
            break;
        }
        case SLRowShowAllInFinder: {
            // Open Finder search window
            NSTask *t = [[NSTask alloc] init];
            t.executableURL = [NSURL fileURLWithPath:@"/usr/bin/osascript"];
            t.arguments = @[ @"-e", @"tell application \"Finder\" to activate" ];
            [t launchAndReturnError:nil];
            (void)q;
            break;
        }
        case SLRowPreferences:
            [[NSWorkspace sharedWorkspace] openURL:[NSURL URLWithString:@"x-apple.systempreferences:com.apple.Spotlight-Settings.extension"]];
            break;
        default:
            break;
    }
}

@end

int main(int argc, const char **argv) {
    @autoreleasepool {
        // Single-instance check: if another LionessSpotlight is already running, toggle it and exit.
        pid_t me = getpid();
        for (NSRunningApplication *app in NSWorkspace.sharedWorkspace.runningApplications) {
            if (app.processIdentifier != me && [app.executableURL.lastPathComponent isEqualToString:@"LionessSpotlight"]) {
                NSString *notif = @"com.lioness.spotlight.toggle";
                if (argc >= 2 && !strcmp(argv[1], "--show")) notif = @"com.lioness.spotlight.show";
                else if (argc >= 2 && !strcmp(argv[1], "--dismiss")) notif = @"com.lioness.spotlight.dismiss";
                [[NSDistributedNotificationCenter defaultCenter] postNotificationName:notif object:nil userInfo:nil deliverImmediately:YES];
                return 0;
            }
        }

        NSApplication *app = [NSApplication sharedApplication];
        [app setActivationPolicy:NSApplicationActivationPolicyAccessory];
        LoadMountainLionSpotlightFonts();

        SpotlightController *ctrl = [[SpotlightController alloc] init];
        NSDistributedNotificationCenter *dnc = [NSDistributedNotificationCenter defaultCenter];
        [dnc addObserverForName:@LIONESS_SPOTLIGHT_TOGGLE_NOTE object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *n) {
            [ctrl noteStatusItemRect:n.object]; [ctrl toggleSpotlight];
        }];
        [dnc addObserverForName:@LIONESS_SPOTLIGHT_SHOW_NOTE object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *n) {
            [ctrl noteStatusItemRect:n.object]; [ctrl showSpotlight];
        }];
        [dnc addObserverForName:@LIONESS_SPOTLIGHT_DISMISS_NOTE object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *n) {
            (void)n; [ctrl dismissSpotlight];
        }];

        if (argc < 2 || strcmp(argv[1], "--daemon") != 0) {
            dispatch_async(dispatch_get_main_queue(), ^{ [ctrl showSpotlight]; });
        }

        [app run];
    }
    return 0;
}

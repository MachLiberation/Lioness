// One of every AppKit control, in a real window, for finding out what AppKit asks NSAppearance for and for
// looking at the answer. Writes what the window drew to a PNG; captures the real window too if PROBE_VISIBLE.
//
//   AquaGallery <out.png>

#import <AppKit/AppKit.h>
#import <QuartzCore/QuartzCore.h>
#include <objc/message.h>
#include <objc/Runtime.h>

@interface GalleryData : NSObject <NSTableViewDataSource, NSOutlineViewDataSource, NSToolbarDelegate, NSBrowserDelegate>
@end

@implementation GalleryData
- (NSInteger)numberOfRowsInTableView:(NSTableView *)t { return 6; }
- (id)tableView:(NSTableView *)t objectValueForTableColumn:(NSTableColumn *)c row:(NSInteger)r { return [NSString stringWithFormat:@"Row %ld", (long)r]; }
- (NSInteger)outlineView:(NSOutlineView *)o numberOfChildrenOfItem:(id)i { return i ? 2 : 3; }
- (id)outlineView:(NSOutlineView *)o child:(NSInteger)n ofItem:(id)i { return [NSString stringWithFormat:@"%@.%ld", i ?: @"Item", (long)n]; }
- (BOOL)outlineView:(NSOutlineView *)o isItemExpandable:(id)i { return [(NSString *)i length] < 8; }
- (id)outlineView:(NSOutlineView *)o objectValueForTableColumn:(NSTableColumn *)c byItem:(id)i { return i; }
- (NSArray<NSToolbarItemIdentifier> *)toolbarDefaultItemIdentifiers:(NSToolbar *)t { return @[ @"one", @"two", NSToolbarFlexibleSpaceItemIdentifier, @"search" ]; }
- (NSArray<NSToolbarItemIdentifier> *)toolbarAllowedItemIdentifiers:(NSToolbar *)t { return [self toolbarDefaultItemIdentifiers:t]; }
- (NSToolbarItem *)toolbar:(NSToolbar *)t itemForItemIdentifier:(NSToolbarItemIdentifier)i willBeInsertedIntoToolbar:(BOOL)f {
    if ([i isEqual:@"search"]) return [[NSSearchToolbarItem alloc] initWithItemIdentifier:i];
    NSToolbarItem *item = [[NSToolbarItem alloc] initWithItemIdentifier:i];
    item.label = i;
    item.image = [NSImage imageWithSystemSymbolName:[i isEqual:@"one"] ? @"star" : @"gear" accessibilityDescription:nil];
    return item;
}
- (NSInteger)browser:(NSBrowser *)b numberOfRowsInColumn:(NSInteger)c { return 4; }
- (void)browser:(NSBrowser *)b willDisplayCell:(id)cell atRow:(NSInteger)r column:(NSInteger)c { [cell setStringValue:@"Cell"]; [cell setLeaf:r > 1]; }
@end

static void DumpLayer(CALayer *layer, int depth) {
    printf("%*s%s %.0fx%.0f contents=%s delegate=%s\n", depth * 2, "", object_getClassName(layer), layer.bounds.size.width, layer.bounds.size.height,
           layer.contents ? object_getClassName(layer.contents) : "-", layer.delegate ? object_getClassName(layer.delegate) : "-");
    for (CALayer *sub in layer.sublayers) DumpLayer(sub, depth + 1);
}

// Menu highlight, simulated without a mouse.
static void SelectInMenu(CALayer *layer) {
    if ([layer.delegate isKindOfClass:NSClassFromString(@"NSTableViewBackedMenuRepresentation")]) {
        [(NSTableView *)layer.delegate selectRowIndexes:[NSIndexSet indexSetWithIndex:1] byExtendingSelection:NO];
        [CATransaction flush];
        return;
    }
    for (CALayer *sub in layer.sublayers) SelectInMenu(sub);
}

// What a label view holds, for finding out why its text is the colour it is.
static void DumpLabels(NSView *root, CALayer *layer, int depth) {
    id owner = layer.delegate;
    if ([owner isKindOfClass:NSTextField.class]) {
        NSTextField *f = owner;
        NSCell *cell = f.cell;
        NSView *parent = f.superview;
        NSMutableString *filters = [NSMutableString string];
        for (CALayer *l = layer; l && filters.length < 200; l = l.sublayers.firstObject) [filters appendFormat:@"%@ ", l.compositingFilter ?: @"-"];
        long mode = [f respondsToSelector:NSSelectorFromString(@"_vibrancyBlendMode")] ? ((long (*)(id, SEL))objc_msgSend)(f, NSSelectorFromString(@"_vibrancyBlendMode")) : -1;
        printf("LABEL [%s] in %s: filters=%s blendMode=%ld appearance=%s\n", f.stringValue.UTF8String, object_getClassName(parent), filters.UTF8String, mode, f.effectiveAppearance.name.UTF8String);
    }
    for (CALayer *sub in layer.sublayers) DumpLabels(root, sub, depth + 1);
}

// Every layer in the tree with a compositing filter still set.
static void AuditFilters(CALayer *layer) {
    if (layer.compositingFilter) {
        id owner = layer.delegate;
        NSString *text = [owner isKindOfClass:NSTextField.class] ? ((NSTextField *)owner).stringValue : @"";
        printf("FILTER %s on %s owner=%s [%s] super=%s\n", [[layer.compositingFilter description] UTF8String], object_getClassName(layer), owner ? object_getClassName(owner) : "-", text.UTF8String,
               layer.superlayer.delegate ? object_getClassName(layer.superlayer.delegate) : "-");
    }
    for (CALayer *sub in layer.sublayers) AuditFilters(sub);
}

static NSView *gContent;
static CGFloat gX, gY, gRowHeight;

static void Place(NSView *view, CGFloat w, CGFloat h) {
    if (gX + w > 1180) { gX = 16; gY -= gRowHeight + 10; gRowHeight = 0; }
    view.frame = NSMakeRect(gX, gY - h, w, h);
    [gContent addSubview:view];
    gX += w + 12;
    if (h > gRowHeight) gRowHeight = h;
}

static NSButton *Button(NSString *title, NSBezelStyle style, NSButtonType type, CGFloat w, CGFloat h) {
    NSButton *b = [[NSButton alloc] initWithFrame:NSZeroRect];
    b.title = title;
    b.bezelStyle = style;
    [b setButtonType:type];
    Place(b, w, h);
    return b;
}

int main(int argc, char **argv) {
    @autoreleasepool {
        [NSApplication sharedApplication];
        [NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory];
        GalleryData *data = [GalleryData new];
        NSWindow *window = [[NSWindow alloc] initWithContentRect:NSMakeRect(-6000, -6000, 1200, 860)
                                                       styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskMiniaturizable | NSWindowStyleMaskResizable
                                                         backing:NSBackingStoreBuffered defer:NO];
        window.title = @"Lioness gallery";
        gContent = window.contentView;
        gX = 16; gY = 850;

        // Push and square buttons, every bezel style.
        NSButton *primary = Button(@"Default", NSBezelStylePush, NSButtonTypeMomentaryPushIn, 90, 32);
        primary.keyEquivalent = @"\r";
        Button(@"Push", NSBezelStylePush, NSButtonTypeMomentaryPushIn, 80, 32);
        Button(@"Off", NSBezelStylePush, NSButtonTypeMomentaryPushIn, 70, 32).enabled = NO;
        Button(@"Small", NSBezelStylePush, NSButtonTypeMomentaryPushIn, 70, 28).controlSize = NSControlSizeSmall;
        Button(@"Mini", NSBezelStylePush, NSButtonTypeMomentaryPushIn, 60, 24).controlSize = NSControlSizeMini;
        Button(@"Flexible\ntall", NSBezelStyleFlexiblePush, NSButtonTypeMomentaryPushIn, 90, 48);
        Button(@"Bevel", NSBezelStyleSmallSquare, NSButtonTypeMomentaryPushIn, 70, 24);
        Button(@"Circle", NSBezelStyleCircular, NSButtonTypeMomentaryPushIn, 40, 40);
        Button(@"", NSBezelStyleHelpButton, NSButtonTypeMomentaryPushIn, 26, 26);
        Button(@"", NSBezelStyleDisclosure, NSButtonTypeOnOff, 22, 22);
        Button(@"", NSBezelStylePushDisclosure, NSButtonTypePushOnPushOff, 26, 26);
        Button(@"Tex", NSBezelStyleTexturedSquare, NSButtonTypeMomentaryPushIn, 60, 24);
        Button(@"Rounded", NSBezelStyleToolbar, NSButtonTypeMomentaryPushIn, 80, 26);
        Button(@"Access", NSBezelStyleAccessoryBarAction, NSButtonTypeMomentaryPushIn, 70, 22);
        Button(@"Access2", NSBezelStyleAccessoryBar, NSButtonTypePushOnPushOff, 70, 22);
        Button(@"Badge", NSBezelStyleBadge, NSButtonTypeMomentaryPushIn, 60, 20);
        Button(@"Inline", NSBezelStyleBadge, NSButtonTypePushOnPushOff, 60, 20);
        NSButton *shadowless = Button(@"Shadow", NSBezelStyleShadowlessSquare, NSButtonTypeMomentaryPushIn, 70, 28);
        shadowless.showsBorderOnlyWhileMouseInside = NO;
        Button(@"Dis", NSBezelStyleDisclosure, NSButtonTypeOnOff, 22, 22).state = NSControlStateValueOn;

        // Check boxes and radios in every size and value.
        for (NSNumber *size in @[ @(NSControlSizeRegular), @(NSControlSizeSmall), @(NSControlSizeMini) ]) {
            for (int v = 0; v < 3; v++) {
                NSButton *c = Button(@"Check", NSBezelStyleRegularSquare, NSButtonTypeSwitch, 76, 20);
                c.controlSize = size.integerValue; c.allowsMixedState = YES;
                c.state = v == 0 ? NSControlStateValueOff : v == 1 ? NSControlStateValueOn : NSControlStateValueMixed;
            }
            for (int v = 0; v < 2; v++) {
                NSButton *r = Button(@"Radio", NSBezelStyleRegularSquare, NSButtonTypeRadio, 76, 20);
                r.controlSize = size.integerValue; r.state = v ? NSControlStateValueOn : NSControlStateValueOff;
            }
        }
        Button(@"Check off", NSBezelStyleRegularSquare, NSButtonTypeSwitch, 90, 20).enabled = NO;

        // Popups, combo, text.
        NSPopUpButton *popup = [[NSPopUpButton alloc] initWithFrame:NSZeroRect pullsDown:NO];
        [popup addItemsWithTitles:@[ @"Popup", @"Two" ]];
        Place(popup, 110, 26);
        NSPopUpButton *pull = [[NSPopUpButton alloc] initWithFrame:NSZeroRect pullsDown:YES];
        [pull addItemsWithTitles:@[ @"Pull down", @"Two" ]];
        Place(pull, 110, 26);
        NSPopUpButton *smallPopup = [[NSPopUpButton alloc] initWithFrame:NSZeroRect pullsDown:NO];
        [smallPopup addItemsWithTitles:@[ @"Small" ]];
        smallPopup.controlSize = NSControlSizeSmall;
        Place(smallPopup, 90, 22);
        NSComboBox *combo = [[NSComboBox alloc] initWithFrame:NSZeroRect];
        [combo addItemWithObjectValue:@"Combo"];
        combo.stringValue = @"Combo";
        Place(combo, 110, 26);
        NSTextField *field = [NSTextField textFieldWithString:@"Text field"];
        Place(field, 110, 22);
        NSTextField *round = [NSTextField textFieldWithString:@"Rounded"];
        round.bordered = NO;
        round.bezeled = YES;
        round.bezelStyle = NSTextFieldRoundedBezel;
        Place(round, 110, 22);
        NSSecureTextField *secure = [[NSSecureTextField alloc] initWithFrame:NSZeroRect];
        secure.stringValue = @"secret";
        Place(secure, 90, 22);
        NSSearchField *search = [[NSSearchField alloc] initWithFrame:NSZeroRect];
        search.stringValue = @"Search";
        Place(search, 140, 22);
        NSTokenField *tokens = [[NSTokenField alloc] initWithFrame:NSZeroRect];
        tokens.objectValue = @[ @"token", @"two" ];
        Place(tokens, 140, 22);
        NSStepper *stepper = [[NSStepper alloc] initWithFrame:NSZeroRect];
        Place(stepper, 19, 27);
        NSDatePicker *date = [[NSDatePicker alloc] initWithFrame:NSZeroRect];
        date.dateValue = [NSDate dateWithTimeIntervalSince1970:1320000000];
        date.datePickerStyle = NSDatePickerStyleTextFieldAndStepper;
        Place(date, 180, 28);
        NSColorWell *well = [[NSColorWell alloc] initWithFrame:NSZeroRect];
        Place(well, 44, 24);
        NSPathControl *path = [[NSPathControl alloc] initWithFrame:NSZeroRect];
        path.URL = [NSURL fileURLWithPath:@"/Applications/Utilities"];
        Place(path, 200, 22);

        // Segmented controls.
        for (NSNumber *style in @[ @(NSSegmentStyleAutomatic), @(NSSegmentStyleRounded), @(NSSegmentStyleTexturedRounded), @(NSSegmentStyleRoundRect), @(NSSegmentStyleSmallSquare), @(NSSegmentStyleCapsule) ]) {
            NSSegmentedControl *s = [NSSegmentedControl segmentedControlWithLabels:@[ @"One", @"Two", @"Three" ] trackingMode:NSSegmentSwitchTrackingSelectOne target:nil action:nil];
            s.segmentStyle = style.integerValue;
            s.selectedSegment = 1;
            Place(s, 150, 26);
        }

        // Sliders, indicators.
        NSSlider *h = [NSSlider sliderWithValue:40 minValue:0 maxValue:100 target:nil action:nil];
        Place(h, 150, 22);
        NSSlider *ticks = [NSSlider sliderWithValue:60 minValue:0 maxValue:100 target:nil action:nil];
        ticks.numberOfTickMarks = 6;
        Place(ticks, 150, 28);
        NSSlider *v = [NSSlider sliderWithValue:30 minValue:0 maxValue:100 target:nil action:nil];
        v.vertical = YES;
        Place(v, 22, 90);
        NSSlider *knob = [NSSlider sliderWithValue:30 minValue:0 maxValue:100 target:nil action:nil];
        knob.sliderType = NSSliderTypeCircular;
        Place(knob, 32, 32);
        NSProgressIndicator *bar = [[NSProgressIndicator alloc] initWithFrame:NSZeroRect];
        bar.indeterminate = NO; bar.doubleValue = 45;
        Place(bar, 150, 20);
        NSProgressIndicator *spin = [[NSProgressIndicator alloc] initWithFrame:NSZeroRect];
        spin.style = NSProgressIndicatorStyleSpinning;
        Place(spin, 32, 32);
        [spin startAnimation:nil];
        NSProgressIndicator *busy = [[NSProgressIndicator alloc] initWithFrame:NSZeroRect];
        busy.indeterminate = YES;
        Place(busy, 150, 20);
        [busy startAnimation:nil];
        for (NSNumber *style in @[ @(NSLevelIndicatorStyleContinuousCapacity), @(NSLevelIndicatorStyleDiscreteCapacity), @(NSLevelIndicatorStyleRelevancy), @(NSLevelIndicatorStyleRating) ]) {
            NSLevelIndicator *l = [[NSLevelIndicator alloc] initWithFrame:NSZeroRect];
            l.levelIndicatorStyle = style.integerValue; l.maxValue = 5; l.doubleValue = 3; l.warningValue = 4; l.criticalValue = 5;
            Place(l, 110, 18);
        }
        NSScroller *vs = [[NSScroller alloc] initWithFrame:NSZeroRect];
        vs.enabled = YES; vs.doubleValue = 0.3; vs.knobProportion = 0.3; vs.scrollerStyle = NSScrollerStyleLegacy;
        Place(vs, 15, 110);
        NSScroller *hs = [[NSScroller alloc] initWithFrame:NSMakeRect(0, 0, 150, 15)];
        hs.enabled = YES; hs.doubleValue = 0.6; hs.knobProportion = 0.4; hs.scrollerStyle = NSScrollerStyleLegacy;
        Place(hs, 150, 15);

        // Overlay scrollers, which is what most real apps get.
        NSScroller *ovs = [[NSScroller alloc] initWithFrame:NSZeroRect];
        ovs.enabled = YES; ovs.doubleValue = 0.3; ovs.knobProportion = 0.3; ovs.scrollerStyle = NSScrollerStyleOverlay; ovs.knobStyle = NSScrollerKnobStyleDark;
        Place(ovs, 15, 110);
        NSScroller *ohs = [[NSScroller alloc] initWithFrame:NSMakeRect(0, 0, 150, 15)];
        ohs.enabled = YES; ohs.doubleValue = 0.6; ohs.knobProportion = 0.4; ohs.scrollerStyle = NSScrollerStyleOverlay; ohs.knobStyle = NSScrollerKnobStyleDark;
        Place(ohs, 150, 15);
        NSScrollView *overlayScroll = [[NSScrollView alloc] initWithFrame:NSZeroRect];
        overlayScroll.hasVerticalScroller = YES; overlayScroll.hasHorizontalScroller = YES; overlayScroll.scrollerStyle = NSScrollerStyleOverlay; overlayScroll.borderType = NSBezelBorder;
        NSTextView *overlayText = [[NSTextView alloc] initWithFrame:NSMakeRect(0, 0, 400, 400)];
        overlayText.string = @"Overlay scroll view";
        overlayScroll.documentView = overlayText;
        Place(overlayScroll, 160, 110);
        [overlayScroll flashScrollers];

        // Boxes, tabs, table, outline, browser, text view, split.
        NSBox *box = [[NSBox alloc] initWithFrame:NSZeroRect];
        box.title = @"Box";
        Place(box, 140, 80);
        NSBox *line = [[NSBox alloc] initWithFrame:NSZeroRect];
        line.boxType = NSBoxSeparator;
        Place(line, 100, 2);
        NSTabView *tabs = [[NSTabView alloc] initWithFrame:NSZeroRect];
        for (NSString *t in @[ @"First", @"Second" ]) { NSTabViewItem *i = [[NSTabViewItem alloc] initWithIdentifier:t]; i.label = t; [tabs addTabViewItem:i]; }
        Place(tabs, 220, 110);

        NSScrollView *tableScroll = [[NSScrollView alloc] initWithFrame:NSZeroRect];
        tableScroll.hasVerticalScroller = YES; tableScroll.hasHorizontalScroller = YES; tableScroll.scrollerStyle = NSScrollerStyleLegacy; tableScroll.borderType = NSBezelBorder;
        NSTableView *table = [[NSTableView alloc] initWithFrame:NSZeroRect];
        for (NSString *t in @[ @"Name", @"Kind" ]) { NSTableColumn *c = [[NSTableColumn alloc] initWithIdentifier:t]; c.title = t; c.width = 130; [table addTableColumn:c]; }
        table.dataSource = data; table.usesAlternatingRowBackgroundColors = YES; table.style = NSTableViewStyleFullWidth;
        [table reloadData];
        [table selectRowIndexes:[NSIndexSet indexSetWithIndex:1] byExtendingSelection:NO];
        [table setIndicatorImage:[NSImage imageNamed:@"NSAscendingSortIndicator"] inTableColumn:table.tableColumns[0]];
        tableScroll.documentView = table;
        Place(tableScroll, 280, 130);

        NSScrollView *outlineScroll = [[NSScrollView alloc] initWithFrame:NSZeroRect];
        outlineScroll.hasVerticalScroller = YES; outlineScroll.scrollerStyle = NSScrollerStyleLegacy;
        NSOutlineView *outline = [[NSOutlineView alloc] initWithFrame:NSZeroRect];
        NSTableColumn *oc = [[NSTableColumn alloc] initWithIdentifier:@"o"]; oc.title = @"Outline"; oc.width = 170;
        [outline addTableColumn:oc]; outline.outlineTableColumn = oc; outline.dataSource = data; outline.style = NSTableViewStyleSourceList;
        [outline reloadData];
        [outline expandItem:@"Item.0"];
        outlineScroll.documentView = outline;
        Place(outlineScroll, 200, 130);

        NSBrowser *browser = [[NSBrowser alloc] initWithFrame:NSZeroRect];
        browser.delegate = data;
        browser.titled = YES;
        Place(browser, 240, 130);
        NSScrollView *textScroll = [NSTextView scrollableTextView];
        ((NSTextView *)textScroll.documentView).string = @"Text view\nwith some text";
        textScroll.scrollerStyle = NSScrollerStyleLegacy; textScroll.borderType = NSBezelBorder;
        Place(textScroll, 180, 80);
        NSSplitView *split = [[NSSplitView alloc] initWithFrame:NSMakeRect(0, 0, 160, 80)];
        split.vertical = YES; split.dividerStyle = NSSplitViewDividerStylePaneSplitter;
        [split addSubview:[[NSView alloc] initWithFrame:NSMakeRect(0, 0, 70, 80)]];
        [split addSubview:[[NSView alloc] initWithFrame:NSMakeRect(0, 0, 80, 80)]];
        Place(split, 160, 80);
        NSMatrix *matrix = [[NSMatrix alloc] initWithFrame:NSZeroRect mode:NSRadioModeMatrix prototype:[[NSButtonCell alloc] initTextCell:@"M"] numberOfRows:2 numberOfColumns:1];
        [[matrix cellAtRow:0 column:0] setButtonType:NSButtonTypeRadio];
        [[matrix cellAtRow:1 column:0] setButtonType:NSButtonTypeRadio];
        Place(matrix, 60, 44);
        NSDatePicker *calendar = [[NSDatePicker alloc] initWithFrame:NSZeroRect];
        calendar.datePickerStyle = NSDatePickerStyleClockAndCalendar;
        calendar.dateValue = [NSDate dateWithTimeIntervalSince1970:1320000000];
        Place(calendar, 280, 150);

        NSToolbar *toolbar = [[NSToolbar alloc] initWithIdentifier:@"gallery"];
        toolbar.delegate = data;
        toolbar.displayMode = NSToolbarDisplayModeIconAndLabel;
        window.toolbarStyle = NSWindowToolbarStyleExpanded;
        window.toolbar = toolbar;

        bool visible = getenv("PROBE_VISIBLE") != NULL;
        if (visible) {
            [NSApp setActivationPolicy:NSApplicationActivationPolicyRegular];
            [window setFrameOrigin:NSMakePoint(60, 80)];
            [NSApp finishLaunching];
            [NSApp activateIgnoringOtherApps:YES];
            [window makeKeyAndOrderFront:nil];
        } else {
            [window orderFrontRegardless];
        }
        [window displayIfNeeded];
        [CATransaction flush];
        [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:visible ? 1.5 : 0.5]];
        [window displayIfNeeded];
        [CATransaction flush];
        // PROBE_HOLD: for a run launched with `open`, whose children lack screen-capture permission: publish the
        // window and stay up so the launching shell can capture it.
        if (getenv("PROBE_LABELS")) {
            DumpLabels(gContent, gContent.layer, 0);
            AuditFilters(gContent.superview.layer);
            fflush(stdout);
        }
        if (getenv("PROBE_HOLD")) {
            NSString *state = [NSString stringWithFormat:@"%ld active=%d key=%d main=%d\n", (long)window.windowNumber, NSApp.isActive, window.isKeyWindow, window.isMainWindow];
            [state writeToFile:@(getenv("PROBE_HOLD")) atomically:YES encoding:NSUTF8StringEncoding error:nil];
            [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:4]];
            return 0;
        }
        if (visible && argc > 1) {
            NSString *command = [NSString stringWithFormat:@"/usr/sbin/screencapture -x -o -l%ld '%s.screen.png'", (long)window.windowNumber, argv[1]];
            printf("key=%d capture=%d\n", window.isKeyWindow, system(command.UTF8String));
        }

        if (getenv("PROBE_DUMP")) {
            printf("--- spinner\n"); DumpLayer(spin.layer, 0);
            printf("--- horizontal overlay\n"); DumpLayer(ohs.layer, 0);
            printf("--- vertical overlay\n"); DumpLayer(ovs.layer, 0);
            for (NSString *name in @[ @"NSContextMenuItemView", @"NSRootMenuWindowBackgroundView", @"NSTableBackedMenuRowView", @"NSMenuItemHighlightView", @"NSTableViewBackedMenuRepresentation" ]) {
                Class cls = NSClassFromString(name);
                printf("--- %s : %s\n", name.UTF8String, cls ? class_getName(class_getSuperclass(cls)) : "absent");
                unsigned n = 0;
                Method *all = cls ? class_copyMethodList(cls, &n) : NULL;
                for (unsigned i = 0; i < n; i++) {
                    NSString *sel = NSStringFromSelector(method_getName(all[i]));
                    if ([sel rangeOfString:@"ighlight"].length || [sel rangeOfString:@"elect"].length || [sel rangeOfString:@"pdateLayer"].length || [sel rangeOfString:@"ackground"].length || [sel isEqual:@"layout"] || [sel isEqual:@"drawRect:"]) printf("  %s %s\n", sel.UTF8String, method_getTypeEncoding(all[i]));
                }
            }
        }

        // A real popup menu: open it, capture its window while it tracks, then cancel it.
        if (getenv("PROBE_MENU") && argc > 1) {
            NSMenu *menu = [[NSMenu alloc] initWithTitle:@"Menu"];
            [menu addItemWithTitle:@"First item" action:@selector(terminate:) keyEquivalent:@"n"];
            NSMenuItem *on = [menu addItemWithTitle:@"Checked item" action:@selector(terminate:) keyEquivalent:@""];
            on.state = NSControlStateValueOn;
            [menu addItem:NSMenuItem.separatorItem];
            NSMenuItem *more = [menu addItemWithTitle:@"Submenu" action:nil keyEquivalent:@""];
            more.submenu = [[NSMenu alloc] initWithTitle:@"More"];
            [more.submenu addItemWithTitle:@"Inner" action:nil keyEquivalent:@""];
            [menu addItemWithTitle:@"Disabled" action:nil keyEquivalent:@""];
            NSString *path = @(argv[1]);
            NSTimer *timer = [NSTimer timerWithTimeInterval:1.0 repeats:NO block:^(NSTimer *t) {
                if ([menu respondsToSelector:@selector(_highlightItem:)]) [menu performSelector:@selector(_highlightItem:) withObject:menu.itemArray[1]];
                for (NSWindow *w in NSApp.windows) {
                    if ([NSStringFromClass(w.class) containsString:@"Menu"]) SelectInMenu(w.contentView.superview.layer);
                    if (![NSStringFromClass(w.class) containsString:@"Menu"] && ![NSStringFromClass(w.class) containsString:@"Popup"]) continue;
                    printf("menu window %s\n", object_getClassName(w));
                    system([NSString stringWithFormat:@"/usr/sbin/screencapture -x -o -l%ld '%@.menu.png'", (long)w.windowNumber, path].UTF8String);
                }
                [menu cancelTracking];
            }];
            [[NSRunLoop currentRunLoop] addTimer:timer forMode:NSRunLoopCommonModes];
            [[NSRunLoop currentRunLoop] addTimer:timer forMode:NSEventTrackingRunLoopMode];
            [NSApp activateIgnoringOtherApps:YES];
            BOOL shown = [menu popUpMenuPositioningItem:nil atLocation:NSMakePoint(400, 400) inView:gContent];
            printf("popup returned %d\n", shown);
            fflush(stdout);
        }

        NSView *frame = gContent.superview;
        NSBitmapImageRep *rep = [frame bitmapImageRepForCachingDisplayInRect:frame.bounds];
        [frame cacheDisplayInRect:frame.bounds toBitmapImageRep:rep];
        if (argc > 1) [[rep representationUsingType:NSBitmapImageFileTypePNG properties:@{}] writeToFile:[NSString stringWithUTF8String:argv[1]] atomically:YES];
    }
    return 0;
}

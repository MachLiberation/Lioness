// libLionessMenus.dylib: Separate Ammonia tweak target with a broader blacklist
// (injects into Dock/DockHelper, MenuBarAgent, Siri AI/Spotlight, Finder, and all apps,
// while leaving ControlCenter, NotificationCenter, and pre-existing menu bar extras untouched).
//
// Redirects every menu entry point (contextual menus, popup menus, menu bar dropdowns,
// Dock dark-bubble menus) to lionessmenud (com.lioness.menud) for authentic Mountain Lion
// rendering & interaction, and hooks Spotlight (Siri AI / Spotlight.app) to launch/toggle
// /Library/Lioness/LionessSpotlight.

#import <Cocoa/Cocoa.h>
#import <objc/message.h>
#import <objc/runtime.h>
#import "../Shared/MenuProtocol.h"
#import "../Client/LionessMenuClient.h"

#include <spawn.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

extern char **environ;

// ---------------------------------------------------------------------------
// Process state & thread-local guards
// ---------------------------------------------------------------------------

static BOOL gIsDockHelper = NO;
static BOOL gIsMenuBarAgent = NO;
static _Thread_local int tlInLionessMenu = 0;
static _Thread_local int tlStatusItemDepth = 0;

// ---------------------------------------------------------------------------
// Safe ObjC swizzling helpers (no external swizzle lib, no superclass clobber)
// ---------------------------------------------------------------------------

static IMP SwizzleInstance(Class cls, SEL sel, IMP newImp) {
    if (!cls) return NULL;
    Method m = class_getInstanceMethod(cls, sel);
    if (!m) return NULL;
    const char *types = method_getTypeEncoding(m);
    IMP orig = method_getImplementation(m);
    if (class_addMethod(cls, sel, newImp, types)) {
        // Method was inherited from superclass; we added an override on `cls` directly.
        return orig;
    }
    return method_setImplementation(m, newImp);
}

static IMP SwizzleClass(Class cls, SEL sel, IMP newImp) {
    if (!cls) return NULL;
    Class meta = object_getClass((id)cls);
    return SwizzleInstance(meta, sel, newImp);
}

// ---------------------------------------------------------------------------
// StatusItem / Menu Bar Extra detection (keep pre-existing extras untouched)
// ---------------------------------------------------------------------------

static BOOL IsStatusItemPresentation(NSMenu *menu, NSView *view) {
    if (tlStatusItemDepth > 0) return YES;
    if (view) {
        NSString *vc = NSStringFromClass([view class]);
        if ([vc containsString:@"StatusBar"] || [vc containsString:@"StatusItem"]) return YES;
        NSWindow *win = view.window;
        if (win) {
            NSString *wc = NSStringFromClass([win class]);
            if ([wc containsString:@"StatusBar"] || [wc containsString:@"StatusItem"]) return YES;
        }
    }
    if (menu) {
        SEL statusSel = NSSelectorFromString(@"_statusItem");
        if ([menu respondsToSelector:statusSel]) {
            id si = ((id (*)(id, SEL))objc_msgSend)(menu, statusSel);
            if (si != nil) return YES;
        }
    }
    return NO;
}

static void (*origStatusItemPopUp)(id, SEL, NSMenu *) = NULL;
static void Hook_NSStatusItem_popUpStatusItemMenu(id self, SEL _cmd, NSMenu *menu) {
    tlStatusItemDepth++;
    if (origStatusItemPopUp) origStatusItemPopUp(self, _cmd, menu);
    tlStatusItemDepth--;
}

static void (*origStatusBarButtonMouseDown)(id, SEL, NSEvent *) = NULL;
static void Hook_NSStatusBarButton_mouseDown(id self, SEL _cmd, NSEvent *event) {
    tlStatusItemDepth++;
    if (origStatusBarButtonMouseDown) origStatusBarButtonMouseDown(self, _cmd, event);
    tlStatusItemDepth--;
}

// ---------------------------------------------------------------------------
// Spotlight interception (Siri AI.app / com.apple.campo + Spotlight.app)
// ---------------------------------------------------------------------------

// The menu bar magnifier's screen rect, so LionessSpotlight can hang under it (image-4).
static NSString *SpotlightStatusItemRect(void) {
    Class barWindow = objc_getClass("NSStatusBarWindow");
    NSRect best = NSZeroRect;
    for (NSWindow *w in NSApp.windows) {
        if (barWindow && ![w isKindOfClass:barWindow]) continue;
        if (!w.isVisible || NSWidth(w.frame) < 8.0 || NSWidth(w.frame) > 80.0) continue;
        if (NSMaxX(w.frame) > NSMaxX(best)) best = w.frame;
    }
    if (NSIsEmptyRect(best)) return nil;
    return [NSString stringWithFormat:@"%g %g %g %g", best.origin.x, best.origin.y, best.size.width, best.size.height];
}

// Siri AI is sandboxed: a distributed notification (name and string object only) is the one
// channel that always gets out. menud is asked separately to make sure LionessSpotlight runs;
// that request never toggles, so the panel can't open and close in one keypress.
static void TriggerLionessSpotlight(uint32_t action) {
    NSString *name = action == 1 ? @LIONESS_SPOTLIGHT_SHOW_NOTE
                   : action == 2 ? @LIONESS_SPOTLIGHT_DISMISS_NOTE
                   : @LIONESS_SPOTLIGHT_TOGGLE_NOTE;
    NSString *rect = [NSThread isMainThread] ? SpotlightStatusItemRect() : nil;
    NSLog(@"[LionessMenus] Spotlight %@ (item %@)", name, rect ?: @"unknown");
    [[NSDistributedNotificationCenter defaultCenter] postNotificationName:name object:rect userInfo:nil deliverImmediately:YES];
    if (action != 2) LionessMenuTriggerSpotlight(3);
}

static void Hook_Spotlight_toggle(id self, SEL _cmd, id screen) {
    (void)self; (void)_cmd; (void)screen;
    TriggerLionessSpotlight(0);
}

static void Hook_Spotlight_toggleNoArg(id self, SEL _cmd) {
    (void)self; (void)_cmd;
    TriggerLionessSpotlight(0);
}

static void Hook_Spotlight_invoke(id self, SEL _cmd, BOOL resetPos, NSInteger reason) {
    (void)self; (void)_cmd; (void)resetPos; (void)reason;
    TriggerLionessSpotlight(1);
}

// Siri AI calls this on its own (focus changes, its window hiding). Its panel never shows, so
// there is nothing to dismiss, and LionessSpotlight closes itself on Escape or a click outside.
static void Hook_Spotlight_dismiss(id self, SEL _cmd, NSInteger reason) {
    (void)self; (void)_cmd; (void)reason;
}

static void InstallSpotlightHooks(void) {
    NSArray<NSString *> *delegateClasses = @[
        @"_TtC7Siri_AI11AppDelegate",
        @"_TtC17SpotlightAppMacOS11AppDelegate",
        @"SPApplication",
    ];
    for (NSString *clsName in delegateClasses) {
        Class cls = objc_getClass(clsName.UTF8String);
        if (!cls) continue;
        SwizzleInstance(cls, NSSelectorFromString(@"toggleSpotlightForScreen:"), (IMP)Hook_Spotlight_toggle);
        SwizzleInstance(cls, NSSelectorFromString(@"invokeSpotlightAndResetPosition:withReason:"), (IMP)Hook_Spotlight_invoke);
        SwizzleInstance(cls, NSSelectorFromString(@"dismissSpotlightWithReason:"), (IMP)Hook_Spotlight_dismiss);
        SwizzleInstance(cls, NSSelectorFromString(@"toggleSpotlight:"), (IMP)Hook_Spotlight_toggle);
        SwizzleInstance(cls, NSSelectorFromString(@"showSpotlight:"), (IMP)Hook_Spotlight_toggle);
        SwizzleInstance(cls, NSSelectorFromString(@"toggleSpotlight"), (IMP)Hook_Spotlight_toggleNoArg);
    }
    // Also hook SpotlightUI menu-item/key-command helpers if loaded
    Class menuItemCls = objc_getClass("SPUISpotlightMenuItem");
    if (menuItemCls) {
        SwizzleInstance(menuItemCls, NSSelectorFromString(@"toggleSpotlight:"), (IMP)Hook_Spotlight_toggle);
        SwizzleInstance(menuItemCls, NSSelectorFromString(@"menuItemClicked:"), (IMP)Hook_Spotlight_toggle);
    }
    Class keyCmdCls = objc_getClass("SPUISpotlightKeyCommandManager");
    if (keyCmdCls) {
        SwizzleInstance(keyCmdCls, NSSelectorFromString(@"handleSpotlightKeyCommand:"), (IMP)Hook_Spotlight_toggle);
    }
}

// ---------------------------------------------------------------------------
// Menu serialization (NSMenu -> plist dictionary for lionessmenud)
// ---------------------------------------------------------------------------

// Mountain Lion draws a shortcut as two columns: the modifier glyphs right-aligned against a
// left-aligned key column (image-3: "⌘N" / "⇧⌘N" / "⌥⌘N" share one N column).
static BOOL FormatKeyEquivalent(NSMenuItem *item, NSString **outMods, NSString **outKey) {
    NSString *key = item.keyEquivalent;
    if (!key || key.length == 0) return NO;

    NSEventModifierFlags mask = item.keyEquivalentModifierMask;
    unichar ch = [key characterAtIndex:0];
    if (ch >= 'A' && ch <= 'Z') mask |= NSEventModifierFlagShift;   // an uppercase key implies Shift
    NSMutableString *mods = [NSMutableString string];
    if (mask & NSEventModifierFlagControl) [mods appendString:@"⌃"];
    if (mask & NSEventModifierFlagOption)  [mods appendString:@"⌥"];
    if (mask & NSEventModifierFlagShift)   [mods appendString:@"⇧"];
    if (mask & NSEventModifierFlagCommand) [mods appendString:@"⌘"];

    NSString *k = nil;
    switch (ch) {
        case '\r': case '\n': case 0x0003: k = @"↩"; break;
        case 0x0008: case 0x007f:          k = @"⌫"; break;
        case 0xF728:                       k = @"⌦"; break;
        case 0x001b:                       k = @"⎋"; break;
        case '\t':                         k = @"⇥"; break;
        case 0x0019:                       k = @"⇤"; break;
        case ' ':                          k = @"Space"; break;
        case NSUpArrowFunctionKey:         k = @"↑"; break;
        case NSDownArrowFunctionKey:       k = @"↓"; break;
        case NSLeftArrowFunctionKey:       k = @"←"; break;
        case NSRightArrowFunctionKey:      k = @"→"; break;
        case NSHomeFunctionKey:            k = @"↖"; break;
        case NSEndFunctionKey:             k = @"↘"; break;
        case NSPageUpFunctionKey:          k = @"⇞"; break;
        case NSPageDownFunctionKey:        k = @"⇟"; break;
        default:
            if (ch >= NSF1FunctionKey && ch <= NSF35FunctionKey) k = [NSString stringWithFormat:@"F%d", (int)(ch - NSF1FunctionKey + 1)];
            else k = key.uppercaseString;
            break;
    }
    *outMods = mods;
    *outKey = k;
    return YES;
}

static BOOL IsFinderTagCustomView(NSView *view, NSMenuItem *item) {
    if (!view) return NO;
    NSString *cls = NSStringFromClass([view class]);
    if ([cls rangeOfString:@"Tag" options:NSCaseInsensitiveSearch].location != NSNotFound ||
        [cls rangeOfString:@"Label" options:NSCaseInsensitiveSearch].location != NSNotFound) {
        return YES;
    }
    for (NSView *sub in view.subviews) {
        NSString *sc = NSStringFromClass([sub class]);
        if ([sc rangeOfString:@"Tag" options:NSCaseInsensitiveSearch].location != NSNotFound ||
            [sc rangeOfString:@"Label" options:NSCaseInsensitiveSearch].location != NSNotFound ||
            [sc rangeOfString:@"Dot" options:NSCaseInsensitiveSearch].location != NSNotFound) {
            return YES;
        }
    }
    NSString *t = item.title ?: @"";
    if ([t isEqualToString:@"Tags..."] || [t isEqualToString:@"Tags…"] || [t isEqualToString:@"Label:"]) {
        return YES;
    }
    return NO;
}

static NSData *SnapshotCustomViewPNG(NSView *view, CGFloat *outW, CGFloat *outH) {
    if (!view) return nil;
    NSRect bounds = view.bounds;
    if (bounds.size.width < 4.0 || bounds.size.height < 4.0) {
        [view layoutSubtreeIfNeeded];
        bounds = view.bounds;
    }
    if (bounds.size.width < 4.0 || bounds.size.height < 4.0) return nil;
    CGFloat w = MIN(bounds.size.width, 420.0);
    CGFloat h = MIN(bounds.size.height, 140.0);
    *outW = w;
    *outH = h;
    NSInteger pxW = (NSInteger)ceil(w * 2.0);
    NSInteger pxH = (NSInteger)ceil(h * 2.0);
    NSBitmapImageRep *rep = [[NSBitmapImageRep alloc]
        initWithBitmapDataPlanes:NULL
                      pixelsWide:pxW
                      pixelsHigh:pxH
                   bitsPerSample:8
                 samplesPerPixel:4
                        hasAlpha:YES
                        isPlanar:NO
                  colorSpaceName:NSCalibratedRGBColorSpace
                     bytesPerRow:0
                    bitsPerPixel:0];
    if (!rep) return nil;
    rep.size = NSMakeSize(w, h);
    @try {
        [view cacheDisplayInRect:NSMakeRect(0, 0, w, h) toBitmapImageRep:rep];
    } @catch (NSException *ex) {
        (void)ex;
        return nil;
    }
    return [rep representationUsingType:NSBitmapImageFileTypePNG properties:@{}];
}

static void PopulateMenu(NSMenu *menu, BOOL isRoot) {
    if (!menu) return;
    id<NSMenuDelegate> del = menu.delegate;
    @try {
        if (del) {
            if ([del respondsToSelector:@selector(menuNeedsUpdate:)]) {
                [del menuNeedsUpdate:menu];
            } else if ([del respondsToSelector:@selector(numberOfItemsInMenu:)] &&
                       [del respondsToSelector:@selector(menu:updateItem:atIndex:shouldCancel:)]) {
                NSInteger n = [del numberOfItemsInMenu:menu];
                while (menu.numberOfItems > n) [menu removeItemAtIndex:menu.numberOfItems - 1];
                while (menu.numberOfItems < n) [menu addItem:[[NSMenuItem alloc] initWithTitle:@"" action:nil keyEquivalent:@""]];
                for (NSInteger i = 0; i < n; i++) {
                    if (![del menu:menu updateItem:[menu itemAtIndex:i] atIndex:i shouldCancel:NO]) break;
                }
            }
        }
        [menu update];
        if (isRoot && del && [del respondsToSelector:@selector(menuWillOpen:)]) {
            [del menuWillOpen:menu];
        }
    } @catch (NSException *ex) {
        (void)ex;
    }
}

static NSArray<NSDictionary *> *SerializeMenuItems(NSMenu *menu,
                                                   NSInteger depth,
                                                   NSInteger *nextId,
                                                   NSMutableDictionary<NSNumber *, NSMenuItem *> *itemMap,
                                                   NSMutableDictionary<NSNumber *, NSMenu *> *ownerMap) {
    if (!menu || depth > 5) return @[];
    PopulateMenu(menu, depth == 0);

    NSEventModifierFlags curMods = NSEvent.modifierFlags;
    BOOL optHeld = (curMods & NSEventModifierFlagOption) != 0;

    NSMutableArray<NSDictionary *> *arr = [NSMutableArray array];
    NSArray<NSMenuItem *> *rawItems = [menu.itemArray copy];
    NSInteger count = (NSInteger)rawItems.count;

    for (NSInteger i = 0; i < count; i++) {
        NSMenuItem *mi = rawItems[i];
        if (mi.isHidden) continue;

        // Handle alternate items cleanly (skip unless Option held, in which case replace prior item)
        if (mi.isAlternate) {
            if (!optHeld) continue;
            if (arr.count > 0) [arr removeLastObject];
        }

        NSInteger itemId = (*nextId)++;
        itemMap[@(itemId)] = mi;
        ownerMap[@(itemId)] = menu;

        if (mi.isSeparatorItem) {
            // Avoid leading or duplicate consecutive separators
            if (arr.count == 0 || [arr.lastObject[@"separator"] boolValue]) continue;
            [arr addObject:@{ @"id": @(itemId), @"separator": @YES }];
            continue;
        }

        BOOL isSectionHdr = NO;
        if ([mi respondsToSelector:@selector(isSectionHeader)]) {
            isSectionHdr = ((BOOL (*)(id, SEL))objc_msgSend)(mi, @selector(isSectionHeader));
        }

        NSMutableDictionary *d = [NSMutableDictionary dictionary];
        d[@"id"] = @(itemId);
        d[@"title"] = mi.title ?: @"";
        // _NSAppleMenu fills "Log Out %@…" in only when AppKit opens it itself.
        if ([d[@"title"] containsString:@"%@"] && [NSStringFromClass([menu class]) isEqualToString:@"_NSAppleMenu"]) {
            NSString *who = NSFullUserName().length ? NSFullUserName() : NSUserName();
            d[@"title"] = [d[@"title"] stringByReplacingOccurrencesOfString:@"%@" withString:who];
        }
        d[@"enabled"] = @(mi.isEnabled);
        d[@"state"] = @(mi.state);
        if (mi.indentationLevel > 0) d[@"indent"] = @(mi.indentationLevel);
        if (isSectionHdr) {
            d[@"sectionHeader"] = @YES;
            d[@"enabled"] = @NO;
        }

        NSString *scMods = nil, *scKey = nil;
        if (FormatKeyEquivalent(mi, &scMods, &scKey)) {
            d[@"shortcutMods"] = scMods;
            d[@"shortcutKey"] = scKey;
        }

        // No item images: Mountain Lion's menus are text only, and macOS 27's SF Symbols are not.

        if (mi.view) {
            if (IsFinderTagCustomView(mi.view, mi)) {
                d[@"customViewKind"] = @"finderTags";
                d[@"title"] = @"Label:";
                d[@"enabled"] = @YES;
            } else {
                CGFloat cw = 0, ch = 0;
                NSData *snap = SnapshotCustomViewPNG(mi.view, &cw, &ch);
                if (snap) {
                    d[@"customViewKind"] = @"snapshot";
                    d[@"customViewWidth"] = @(cw);
                    d[@"customViewHeight"] = @(ch);
                    d[@"customViewPNG"] = snap;
                    d[@"enabled"] = @YES;
                }
            }
        }

        if (mi.hasSubmenu && mi.submenu && depth < 4) {
            NSArray *sub = SerializeMenuItems(mi.submenu, depth + 1, nextId, itemMap, ownerMap);
            if (sub.count > 0) {
                d[@"submenu"] = sub;
            }
        }

        [arr addObject:d];
    }

    // Trim trailing separator
    while (arr.count > 0 && [arr.lastObject[@"separator"] boolValue]) {
        [arr removeLastObject];
    }
    return arr;
}

// ---------------------------------------------------------------------------
// Custom view & action dispatch
// ---------------------------------------------------------------------------

static void DispatchCustomFinderTagClick(NSMenuItem *item, NSInteger tagIdx) {
    NSView *view = item.view;
    if (!view) return;
    // Try clicking the matching subview button/dot if Finder exposes individual tag controls
    NSMutableArray<NSView *> *candidates = [NSMutableArray array];
    for (NSView *sub in view.subviews) {
        if ([sub isKindOfClass:NSControl.class] || sub.bounds.size.width <= 32.0) {
            [candidates addObject:sub];
        } else {
            for (NSView *g in sub.subviews) {
                if ([g isKindOfClass:NSControl.class] || g.bounds.size.width <= 32.0) {
                    [candidates addObject:g];
                }
            }
        }
    }
    [candidates sortUsingComparator:^NSComparisonResult(NSView *a, NSView *b) {
        CGFloat ax = [a convertPoint:NSZeroPoint toView:view].x;
        CGFloat bx = [b convertPoint:NSZeroPoint toView:view].x;
        if (ax < bx) return NSOrderedAscending;
        if (ax > bx) return NSOrderedDescending;
        return NSOrderedSame;
    }];
    // tagIdx: 0 = Clear ('x'), 1..7 = Red..Gray
    if (tagIdx >= 0 && tagIdx < (NSInteger)candidates.count) {
        NSView *target = candidates[tagIdx];
        if ([target isKindOfClass:NSControl.class]) {
            NSControl *ctrl = (NSControl *)target;
            [ctrl performClick:nil];
            return;
        }
    }
    // Fallback: synthesize mouseDown/mouseUp at proportional X inside Finder's tag row
    NSRect b = view.bounds;
    if (b.size.width > 10.0 && b.size.height > 4.0) {
        CGFloat frac = (CGFloat)(tagIdx + 0.5) / 8.0;
        NSPoint pt = NSMakePoint(b.origin.x + b.size.width * frac, NSMidY(b));
        NSView *hit = [view hitTest:pt] ?: view;
        if ([hit isKindOfClass:NSControl.class]) {
            [(NSControl *)hit performClick:nil];
            return;
        }
        NSEvent *down = [NSEvent mouseEventWithType:NSEventTypeLeftMouseDown
                                           location:pt
                                      modifierFlags:0
                                          timestamp:NSProcessInfo.processInfo.systemUptime
                                       windowNumber:view.window.windowNumber
                                            context:nil
                                        eventNumber:0
                                         clickCount:1
                                           pressure:1.0];
        NSEvent *up = [NSEvent mouseEventWithType:NSEventTypeLeftMouseUp
                                         location:pt
                                    modifierFlags:0
                                        timestamp:NSProcessInfo.processInfo.systemUptime + 0.01
                                     windowNumber:view.window.windowNumber
                                          context:nil
                                      eventNumber:0
                                       clickCount:1
                                         pressure:0.0];
        [hit mouseDown:down];
        [hit mouseUp:up];
    }
}

static void DispatchCustomSnapshotClick(NSMenuItem *item, CGFloat clickX, CGFloat clickY) {
    NSView *view = item.view;
    if (!view) return;
    NSPoint pt = NSMakePoint(clickX, clickY);
    NSView *hit = [view hitTest:pt] ?: view;
    if ([hit isKindOfClass:NSControl.class]) {
        [(NSControl *)hit performClick:nil];
        return;
    }
    NSEvent *down = [NSEvent mouseEventWithType:NSEventTypeLeftMouseDown
                                       location:pt
                                  modifierFlags:0
                                      timestamp:NSProcessInfo.processInfo.systemUptime
                                   windowNumber:view.window.windowNumber
                                        context:nil
                                    eventNumber:0
                                     clickCount:1
                                       pressure:1.0];
    NSEvent *up = [NSEvent mouseEventWithType:NSEventTypeLeftMouseUp
                                     location:pt
                                modifierFlags:0
                                    timestamp:NSProcessInfo.processInfo.systemUptime + 0.01
                                 windowNumber:view.window.windowNumber
                                      context:nil
                                  eventNumber:0
                                   clickCount:1
                                     pressure:0.0];
    [hit mouseDown:down];
    [hit mouseUp:up];
}

static BOOL DispatchMenuReply(NSMenu *rootMenu,
                              NSView *presentingView,
                              NSDictionary *reply,
                              NSDictionary<NSNumber *, NSMenuItem *> *itemMap,
                              NSDictionary<NSNumber *, NSMenu *> *ownerMap) {
    id<NSMenuDelegate> del = rootMenu.delegate;
    if (del && [del respondsToSelector:@selector(menuDidClose:)]) {
        @try { [del menuDidClose:rootMenu]; } @catch (NSException *ex) { (void)ex; }
    }
    if (!reply) return NO;
    NSInteger res = [reply[@"result"] integerValue];
    if (res != LIONESS_MENU_RESULT_SELECTED) return NO;

    NSNumber *itemId = reply[@"itemId"];
    NSMenuItem *item = itemMap[itemId];
    NSMenu *owner = ownerMap[itemId] ?: rootMenu;
    if (!item) return NO;

    @try {
        if (reply[@"customSubIndex"]) {
            DispatchCustomFinderTagClick(item, [reply[@"customSubIndex"] integerValue]);
            return YES;
        }
        if (reply[@"clickX"] && reply[@"clickY"]) {
            DispatchCustomSnapshotClick(item, [reply[@"clickX"] doubleValue], [reply[@"clickY"] doubleValue]);
            return YES;
        }

        // If owned by an NSPopUpButton, update its selected item first
        NSPopUpButton *popUp = nil;
        if ([presentingView isKindOfClass:NSPopUpButton.class]) {
            popUp = (NSPopUpButton *)presentingView;
        } else {
            SEL ownSel = NSSelectorFromString(@"_owningPopUp");
            if ([rootMenu respondsToSelector:ownSel]) {
                id o = ((id (*)(id, SEL))objc_msgSend)(rootMenu, ownSel);
                if ([o isKindOfClass:NSPopUpButton.class]) popUp = (NSPopUpButton *)o;
            }
        }
        if (popUp && !popUp.pullsDown && owner == rootMenu) {
            [popUp selectItem:item];
        }

        NSInteger idx = [owner indexOfItem:item];
        if (idx >= 0) {
            [owner performActionForItemAtIndex:idx];
        } else if (item.action) {
            [NSApp sendAction:item.action to:item.target from:item];
        } else if (popUp && popUp.action) {
            [NSApp sendAction:popUp.action to:popUp.target from:popUp];
        }
    } @catch (NSException *ex) {
        (void)ex;
    }
    return YES;
}

// ---------------------------------------------------------------------------
// Core presentation bridge -> com.lioness.menud
// ---------------------------------------------------------------------------

static NSRect ScreenRectForPointInView(NSPoint loc, NSView *view) {
    if (view && view.window) {
        NSPoint inWin = [view convertPoint:loc toView:nil];
        NSRect r = [view.window convertRectToScreen:NSMakeRect(inWin.x, inWin.y, 1.0, 1.0)];
        return r;
    }
    if (loc.x != 0 || loc.y != 0) {
        return NSMakeRect(loc.x, loc.y, 1.0, 1.0);
    }
    NSPoint m = NSEvent.mouseLocation;
    return NSMakeRect(m.x, m.y, 1.0, 1.0);
}

static NSRect ScreenRectForRectInView(NSRect rect, NSView *view) {
    if (view && view.window) {
        NSRect inWin = [view convertRect:rect toView:nil];
        return [view.window convertRectToScreen:inWin];
    }
    if (rect.size.width > 0 || rect.size.height > 0) return rect;
    NSPoint m = NSEvent.mouseLocation;
    return NSMakeRect(m.x, m.y, 1.0, 1.0);
}

static BOOL PresentViaLionessMenudEx(NSMenu *menu, NSString *style, NSRect anchorScreenRect, NSRectEdge preferredEdge,
                                     NSInteger selectedIndex, NSView *presentingView, NSDictionary *extra, BOOL *outDidPresent);

static BOOL PresentViaLionessMenud(NSMenu *menu,
                                   NSString *style,
                                   NSRect anchorScreenRect,
                                   NSRectEdge preferredEdge,
                                   NSInteger selectedIndex,
                                   NSView *presentingView,
                                   BOOL *outDidPresent) {
    return PresentViaLionessMenudEx(menu, style, anchorScreenRect, preferredEdge, selectedIndex, presentingView, nil, outDidPresent);
}

static BOOL PresentViaLionessMenudEx(NSMenu *menu, NSString *style, NSRect anchorScreenRect, NSRectEdge preferredEdge,
                                     NSInteger selectedIndex, NSView *presentingView, NSDictionary *extra, BOOL *outDidPresent) {
    if (outDidPresent) *outDidPresent = NO;
    if (![menu isKindOfClass:NSMenu.class]) return NO;
    if (!menu || tlInLionessMenu > 0) return NO;
    if (IsStatusItemPresentation(menu, presentingView)) return NO;
    if (!LionessMenuServerIsReachable()) return NO;

    tlInLionessMenu++;
    NSInteger nextId = 1;
    NSMutableDictionary<NSNumber *, NSMenuItem *> *itemMap = [NSMutableDictionary dictionary];
    NSMutableDictionary<NSNumber *, NSMenu *> *ownerMap = [NSMutableDictionary dictionary];
    NSArray<NSDictionary *> *items = SerializeMenuItems(menu, 0, &nextId, itemMap, ownerMap);

    if (items.count == 0) {
        tlInLionessMenu--;
        return NO;
    }

    NSMutableDictionary *req = [NSMutableDictionary dictionary];
    req[@"style"] = style ?: @"context";
    req[@"anchorX"] = @(anchorScreenRect.origin.x);
    req[@"anchorY"] = @(anchorScreenRect.origin.y);
    req[@"anchorW"] = @(anchorScreenRect.size.width);
    req[@"anchorH"] = @(anchorScreenRect.size.height);
    req[@"preferredEdge"] = @((NSInteger)preferredEdge);
    // selectedIndex is AppKit's index; the serialized list leaves out hidden and alternate items.
    if (selectedIndex >= 0 && selectedIndex < menu.numberOfItems) {
        NSMenuItem *selItem = [menu itemAtIndex:selectedIndex];
        for (NSUInteger i = 0; i < items.count; i++) {
            if (itemMap[items[i][@"id"]] == selItem) { req[@"selectedIndex"] = @(i); break; }
        }
    }
    if (extra) [req addEntriesFromDictionary:extra];
    req[@"items"] = items;

    NSDictionary *reply = LionessMenuPresent(req);
    if (!reply) {
        tlInLionessMenu--;
        return NO;
    }

    if (outDidPresent) *outDidPresent = YES;
    BOOL selected = DispatchMenuReply(menu, presentingView, reply, itemMap, ownerMap);
    tlInLionessMenu--;
    return selected;
}

// ---------------------------------------------------------------------------
// 1. NSMenu public & private popup hooks (including DockHelper!)
// ---------------------------------------------------------------------------

static void (*origPopUpContextMenu3)(id, SEL, NSMenu *, NSEvent *, NSView *) = NULL;
static void Hook_NSMenu_popUpContextMenu3(id self, SEL _cmd, NSMenu *menu, NSEvent *event, NSView *view) {
    NSPoint loc = NSEvent.mouseLocation;
    if (event && event.window) {
        NSRect sr = [event.window convertRectToScreen:NSMakeRect(event.locationInWindow.x, event.locationInWindow.y, 1, 1)];
        loc = sr.origin;
    }
    BOOL presented = NO;
    PresentViaLionessMenud(menu, @"context", NSMakeRect(loc.x, loc.y, 1, 1), NSRectEdgeMinY, -1, view, &presented);
    if (!presented && origPopUpContextMenu3) {
        origPopUpContextMenu3(self, _cmd, menu, event, view);
    }
}

static void (*origPopUpContextMenu4)(id, SEL, NSMenu *, NSEvent *, NSView *, NSFont *) = NULL;
static void Hook_NSMenu_popUpContextMenu4(id self, SEL _cmd, NSMenu *menu, NSEvent *event, NSView *view, NSFont *font) {
    NSPoint loc = NSEvent.mouseLocation;
    if (event && event.window) {
        NSRect sr = [event.window convertRectToScreen:NSMakeRect(event.locationInWindow.x, event.locationInWindow.y, 1, 1)];
        loc = sr.origin;
    }
    BOOL presented = NO;
    PresentViaLionessMenud(menu, @"context", NSMakeRect(loc.x, loc.y, 1, 1), NSRectEdgeMinY, -1, view, &presented);
    if (!presented && origPopUpContextMenu4) {
        origPopUpContextMenu4(self, _cmd, menu, event, view, font);
    }
}

static BOOL (*origPopUpPositioning)(id, SEL, NSMenuItem *, NSPoint, NSView *) = NULL;
static BOOL Hook_NSMenu_popUpPositioning(NSMenu *self, SEL _cmd, NSMenuItem *item, NSPoint location, NSView *view) {
    if (![(id)self isKindOfClass:NSMenu.class])
        return origPopUpPositioning ? origPopUpPositioning(self, _cmd, item, location, view) : NO;
    NSRect anchor = ScreenRectForPointInView(location, view);
    NSInteger selIdx = item ? [self indexOfItem:item] : -1;
    NSString *style = gIsDockHelper ? @"dock" : (item ? @"popup" : @"context");
    BOOL presented = NO;
    BOOL picked = PresentViaLionessMenud(self, style, anchor, NSRectEdgeMaxY, selIdx, view, &presented);
    if (presented) return picked;
    return origPopUpPositioning ? origPopUpPositioning(self, _cmd, item, location, view) : NO;
}

static BOOL (*origPopUpRelativeToRect)(id, SEL, NSRect, NSView *, NSRectEdge) = NULL;
static BOOL Hook_NSMenu_popUpRelativeToRect(NSMenu *self, SEL _cmd, NSRect rect, NSView *view, NSRectEdge edge) {
    // AppKit's fallback sends this selector to its private NSContextMenuImpl too.
    if (![(id)self isKindOfClass:NSMenu.class])
        return origPopUpRelativeToRect ? origPopUpRelativeToRect(self, _cmd, rect, view, edge) : NO;
    NSRect anchor = ScreenRectForRectInView(rect, view);
    NSString *style = gIsDockHelper ? @"dock" : @"context";
    BOOL presented = NO;
    BOOL picked = PresentViaLionessMenud(self, style, anchor, edge, -1, view, &presented);
    if (presented) return picked;
    return origPopUpRelativeToRect ? origPopUpRelativeToRect(self, _cmd, rect, view, edge) : NO;
}

// ---------------------------------------------------------------------------
// 2. NSCocoaMenuImpl & NSContextMenuImpl hooks (macOS 27 async / SwiftUI / NSPopUpButton)
// ---------------------------------------------------------------------------

static void (*origCocoaPopUpCtxEvent)(id, SEL, NSMenu *, NSEvent *, NSView *, NSFont *, BOOL, id) = NULL;
static void Hook_NSCocoaMenuImpl_popUpCtxEvent(id self, SEL _cmd, NSMenu *menu, NSEvent *event,
                                               NSView *view, NSFont *font, BOOL async, id completionBlock) {
    NSPoint loc = NSEvent.mouseLocation;
    if (event && event.window) {
        NSRect sr = [event.window convertRectToScreen:NSMakeRect(event.locationInWindow.x, event.locationInWindow.y, 1, 1)];
        loc = sr.origin;
    }
    BOOL presented = NO;
    PresentViaLionessMenud(menu, @"context", NSMakeRect(loc.x, loc.y, 1, 1), NSRectEdgeMinY, -1, view, &presented);
    if (presented) {
        if (completionBlock) {
            void (^cb)(void) = (void (^)(void))completionBlock;
            cb();
        }
        return;
    }
    if (origCocoaPopUpCtxEvent) {
        origCocoaPopUpCtxEvent(self, _cmd, menu, event, view, font, async, completionBlock);
    }
}

static void (*origCocoaPopUpCtxObj)(id, SEL, NSMenu *, id, NSView *, NSFont *, BOOL, id) = NULL;
static void Hook_NSCocoaMenuImpl_popUpCtxObj(id self, SEL _cmd, NSMenu *menu, id context,
                                             NSView *view, NSFont *font, BOOL async, id completionBlock) {
    NSPoint loc = NSEvent.mouseLocation;
    BOOL presented = NO;
    PresentViaLionessMenud(menu, @"context", NSMakeRect(loc.x, loc.y, 1, 1), NSRectEdgeMinY, -1, view, &presented);
    if (presented) {
        if (completionBlock) {
            void (^cb)(void) = (void (^)(void))completionBlock;
            cb();
        }
        return;
    }
    if (origCocoaPopUpCtxObj) {
        origCocoaPopUpCtxObj(self, _cmd, menu, context, view, font, async, completionBlock);
    }
}

static BOOL (*origCocoaPopUpPos)(id, SEL, NSMenuItem *, NSUInteger, NSPoint, NSView *, NSUInteger, id, BOOL, id) = NULL;
static BOOL Hook_NSCocoaMenuImpl_popUpPos(id self, SEL _cmd, NSMenuItem *item, NSUInteger idx, NSPoint loc,
                                          NSView *view, NSUInteger flags, id appearance, BOOL async, id completionBlock) {
    NSMenu *menu = [self respondsToSelector:@selector(menu)] ? ((NSMenu *(*)(id, SEL))objc_msgSend)(self, @selector(menu)) : item.menu;
    NSRect anchor = ScreenRectForPointInView(loc, view);
    NSInteger selIdx = item ? [menu indexOfItem:item] : ((idx != NSNotFound) ? (NSInteger)idx : -1);
    NSString *style = gIsDockHelper ? @"dock" : ((selIdx >= 0) ? @"popup" : @"context");
    BOOL presented = NO;
    BOOL picked = PresentViaLionessMenud(menu, style, anchor, NSRectEdgeMaxY, selIdx, view, &presented);
    if (presented) {
        if (completionBlock) {
            void (^cb)(void) = (void (^)(void))completionBlock;
            cb();
        }
        return picked;
    }
    return origCocoaPopUpPos
        ? origCocoaPopUpPos(self, _cmd, item, idx, loc, view, flags, appearance, async, completionBlock)
        : NO;
}

// macOS 27's pop-up buttons (NSPopUpButtonCell -attachPopUpWithFrame:inView:) end here, with no
// completion block: "v120@0:8@16{CGPoint=dd}24d40@48@?56@64{CGRect=...}72Q104@112".
static void (*origCocoaPopUpRect)(id, SEL, NSMenu *, NSPoint, CGFloat, NSView *, id, NSFont *, NSRect, NSUInteger, id) = NULL;
static void Hook_NSCocoaMenuImpl_popUpRect(id self, SEL _cmd, NSMenu *menu, NSPoint loc, CGFloat width,
                                           NSView *view, id selProvider, NSFont *font, NSRect posRect,
                                           NSUInteger flags, id options) {
    NSPopUpButton *button = [view isKindOfClass:NSPopUpButton.class] ? (NSPopUpButton *)view : nil;
    NSRect r = (posRect.size.width > 0 || posRect.size.height > 0) ? posRect : (view ? view.bounds : NSZeroRect);
    NSRect screenR = view ? ScreenRectForRectInView(r, view) : NSMakeRect(loc.x, loc.y, 1, 1);
    BOOL presented = NO;
    if (button && button.pullsDown) {
        // A pull-down hangs below the button like a context menu.
        PresentViaLionessMenud(menu, @"context", NSMakeRect(NSMinX(screenR) - 1.0, NSMinY(screenR) + 1.0, 1, 1), NSRectEdgeMinY, -1, view, &presented);
    } else {
        // Mountain Lion lays the selected item over the button, titles aligned.
        NSInteger sel = button ? button.indexOfSelectedItem : -1;
        NSRect titleR = r;
        if (button && [button.cell respondsToSelector:@selector(titleRectForBounds:)]) titleR = [button.cell titleRectForBounds:button.bounds];
        NSRect titleScreen = view ? ScreenRectForRectInView(titleR, view) : screenR;
        NSRect anchor = NSMakeRect(NSMinX(titleScreen), floor(NSMidY(screenR) + 9.5), 0, 0);
        NSDictionary *extra = @{ @"minWidth": @(MAX(width, NSWidth(screenR)) + 10.0) };
        PresentViaLionessMenudEx(menu, @"popup", anchor, NSRectEdgeMaxY, sel, view, extra, &presented);
    }
    if (presented) return;
    if (origCocoaPopUpRect) origCocoaPopUpRect(self, _cmd, menu, loc, width, view, selProvider, font, posRect, flags, options);
}

static void (*origCocoaPopUpFull)(id, SEL, NSMenu *, NSPoint, CGFloat, NSView *, id, NSFont *, NSRect, NSUInteger, id, id) = NULL;
static void Hook_NSCocoaMenuImpl_popUpFull(id self, SEL _cmd, NSMenu *menu, NSPoint loc, CGFloat width,
                                           NSView *view, id selProvider, NSFont *font, NSRect posRect,
                                           NSUInteger flags, id options, id completionBlock) {
    NSRect anchor = (posRect.size.width > 0 || posRect.size.height > 0)
        ? ScreenRectForRectInView(posRect, view)
        : ScreenRectForPointInView(loc, view);
    NSInteger selIdx = -1;
    if (selProvider) {
        @try {
            NSInteger (^prov)(void) = (NSInteger (^)(void))selProvider;
            selIdx = prov();
        } @catch (NSException *ex) { (void)ex; }
    }
    NSString *style = gIsDockHelper ? @"dock" : ((selIdx >= 0 || [view isKindOfClass:NSPopUpButton.class]) ? @"popup" : @"context");
    BOOL presented = NO;
    PresentViaLionessMenud(menu, style, anchor, NSRectEdgeMaxY, selIdx, view, &presented);
    if (presented) {
        if (completionBlock) {
            void (^cb)(void) = (void (^)(void))completionBlock;
            cb();
        }
        return;
    }
    if (origCocoaPopUpFull) {
        origCocoaPopUpFull(self, _cmd, menu, loc, width, view, selProvider, font, posRect, flags, options, completionBlock);
    }
}

static void (*origContextPresentPopup)(id, SEL, NSMenu *, NSView *, id, BOOL, BOOL, id) = NULL;
static void Hook_NSContextMenuImpl_presentPopup(id self, SEL _cmd, NSMenu *menu, NSView *view,
                                                id context, BOOL animated, BOOL async, id completionBlock) {
    NSPoint loc = NSEvent.mouseLocation;
    BOOL presented = NO;
    PresentViaLionessMenud(menu, @"context", NSMakeRect(loc.x, loc.y, 1, 1), NSRectEdgeMinY, -1, view, &presented);
    if (presented) {
        if (completionBlock) {
            void (^cb)(void) = (void (^)(void))completionBlock;
            cb();
        }
        return;
    }
    if (origContextPresentPopup) {
        origContextPresentPopup(self, _cmd, menu, view, context, animated, async, completionBlock);
    }
}

// ---------------------------------------------------------------------------
// 3. Menu Bar Dropdown Hooks (NSRemoteMenuImpl / NSMenuBarImpl)
//    Handles Apple menu (MenuBarAgent) & App/File/Edit/View/Go/Window/Help
//    with flush 24pt attachment and horizontal menu-bar scrubbing!
// ---------------------------------------------------------------------------

// The screen whose menu bar the user is using: the one under the pointer when the pointer is in
// a menu bar, else the primary screen (which always has one).
static NSScreen *MenuBarScreen(void) {
    NSPoint m = NSEvent.mouseLocation;
    for (NSScreen *s in NSScreen.screens) {
        if (NSPointInRect(m, s.frame) && m.y >= NSMaxY(s.frame) - 40.0) return s;
    }
    return NSScreen.screens.firstObject ?: NSScreen.mainScreen;
}

// -[NSMenuBarImpl frameForViewAtMenuIndex:] is in the menu bar's own top-left-origin space
// (y = 0, height = 24 on macOS 27). Turn it into AppKit screen coordinates.
static BOOL MenuBarTitleFrame(id impl, NSInteger idx, NSScreen *screen, NSRect *out) {
    SEL frameSel = NSSelectorFromString(@"frameForViewAtMenuIndex:");
    if (![impl respondsToSelector:frameSel]) return NO;
    NSRect r = ((NSRect (*)(id, SEL, NSInteger))objc_msgSend)(impl, frameSel, idx);
    if (r.size.width <= 2.0 || r.size.height <= 2.0) return NO;
    NSRect sf = screen.frame;
    *out = NSMakeRect(NSMinX(sf) + r.origin.x, NSMaxY(sf) - r.origin.y - r.size.height, r.size.width, r.size.height);
    return YES;
}

// Index -1 is the Apple menu: it isn't in the app's main menu, and has no frame of its own.
// It sits in the 44pt before the first title (6pt to 50pt with Finder in front).
static const CGFloat kAppleTitleWidth = 44.0;

static NSMenu *MenuBarSubmenu(NSMenu *barMenu, NSInteger idx) {
    if (idx == -1) {
        Class barImpl = objc_getClass("NSMenuBarImpl");
        SEL appleSel = NSSelectorFromString(@"appleMenuItem");
        if (![barImpl respondsToSelector:appleSel]) return nil;
        NSMenuItem *apple = ((NSMenuItem *(*)(id, SEL))objc_msgSend)(barImpl, appleSel);
        NSMenu *m = [apple isKindOfClass:NSMenuItem.class] ? apple.submenu : nil;
        // _NSAppleMenu is empty until AppKit first opens it, and fills itself in -_addAppleMenuItems.
        SEL fill = NSSelectorFromString(@"_addAppleMenuItems");
        if (m && m.numberOfItems == 0 && [m respondsToSelector:fill]) {
            @try { ((void (*)(id, SEL))objc_msgSend)(m, fill); } @catch (NSException *ex) { (void)ex; }
        }
        return m;
    }
    if (idx < 0 || idx >= barMenu.numberOfItems) return nil;
    NSMenuItem *it = [barMenu itemAtIndex:idx];
    return it.hasSubmenu ? it.submenu : nil;
}

static NSRect MenuBarItemScreenFrame(id impl, NSInteger idx) {
    NSScreen *scr = MenuBarScreen();
    NSRect r;
    if (idx == -1 && MenuBarTitleFrame(impl, 0, scr, &r)) {
        return NSMakeRect(MAX(NSMinX(scr.frame), NSMinX(r) - kAppleTitleWidth), NSMinY(r), kAppleTitleWidth, NSHeight(r));
    }
    if (MenuBarTitleFrame(impl, idx, scr, &r)) return r;
    NSPoint m = NSEvent.mouseLocation;
    CGFloat h = NSMaxY(scr.frame) - NSMaxY(scr.visibleFrame);
    if (h < 20.0 || h > 40.0) h = 24.0;
    return NSMakeRect(m.x - 10.0, NSMaxY(scr.frame) - h, 20.0, h);
}

static NSArray<NSDictionary *> *CollectMenuBarTitles(id impl, NSMenu *barMenu) {
    NSMutableArray *titles = [NSMutableArray array];
    NSScreen *scr = MenuBarScreen();
    if (MenuBarSubmenu(barMenu, -1)) {
        NSRect a = MenuBarItemScreenFrame(impl, -1);
        if (NSWidth(a) > 2.0) [titles addObject:@{ @"index": @(-1), @"x": @(a.origin.x), @"w": @(a.size.width) }];
    }
    NSInteger n = barMenu.numberOfItems;
    for (NSInteger i = 0; i < n; i++) {
        NSMenuItem *it = [barMenu itemAtIndex:i];
        if (it.isHidden || !it.hasSubmenu) continue;
        NSRect r;
        if (MenuBarTitleFrame(impl, i, scr, &r)) {
            [titles addObject:@{ @"index": @(i), @"x": @(r.origin.x), @"w": @(r.size.width) }];
        }
    }
    return titles;
}

static void CleanUpMenuBarTracking(id impl) {
    SEL unhi = NSSelectorFromString(@"unhighlightItemIfNeeded");
    if ([impl respondsToSelector:unhi]) {
        @try { ((void (*)(id, SEL))objc_msgSend)(impl, unhi); } @catch (NSException *ex) { (void)ex; }
    }
    SEL tsSel = NSSelectorFromString(@"trackingSession");
    if ([impl respondsToSelector:tsSel]) {
        id ts = ((id (*)(id, SEL))objc_msgSend)(impl, tsSel);
        SEL tearSel = NSSelectorFromString(@"_tearDownMenuTracking");
        if (ts && [ts respondsToSelector:tearSel]) {
            @try { ((void (*)(id, SEL))objc_msgSend)(ts, tearSel); } @catch (NSException *ex) { (void)ex; }
        }
    }
}

static void HighlightMenuBarItem(id impl, NSInteger idx, BOOL unhighlightFirst) {
    if (unhighlightFirst) {
        SEL unhiSel = NSSelectorFromString(@"unhighlightItemIfNeeded");
        if ([impl respondsToSelector:unhiSel]) {
            @try { ((void (*)(id, SEL))objc_msgSend)(impl, unhiSel); } @catch (NSException *ex) { (void)ex; }
        }
    }
    SEL hiSel = NSSelectorFromString(@"highlightItemAtIndex:");
    if ([impl respondsToSelector:hiSel]) {
        @try { ((void (*)(id, SEL, NSInteger))objc_msgSend)(impl, hiSel, idx); } @catch (NSException *ex) { (void)ex; }
    }
}

static BOOL PresentMenuBarDropdown(id impl, NSInteger startIdx) {
    if (tlInLionessMenu > 0) return NO;
    if (!LionessMenuServerIsReachable()) return NO;
    if (![impl respondsToSelector:@selector(menu)]) return NO;

    NSMenu *barMenu = ((NSMenu *(*)(id, SEL))objc_msgSend)(impl, @selector(menu));
    if (!barMenu || !MenuBarSubmenu(barMenu, startIdx)) return NO;

    tlInLionessMenu++;
    NSInteger curIdx = startIdx;
    BOOL presentedAny = NO;
    NSArray<NSDictionary *> *barTitles = CollectMenuBarTitles(impl, barMenu);

    for (NSInteger hops = 0; hops < 64; hops++) {
        NSMenu *sub = MenuBarSubmenu(barMenu, curIdx);
        if (!sub) break;

        NSRect titleFrame = MenuBarItemScreenFrame(impl, curIdx);
        NSInteger nextId = 1;
        NSMutableDictionary<NSNumber *, NSMenuItem *> *itemMap = [NSMutableDictionary dictionary];
        NSMutableDictionary<NSNumber *, NSMenu *> *ownerMap = [NSMutableDictionary dictionary];
        NSArray<NSDictionary *> *items = SerializeMenuItems(sub, 0, &nextId, itemMap, ownerMap);
        if (items.count == 0) break;

        if (hops == 0) HighlightMenuBarItem(impl, curIdx, NO);

        NSMutableDictionary *req = [NSMutableDictionary dictionary];
        req[@"style"] = @"menubar";
        req[@"anchorX"] = @(titleFrame.origin.x);
        req[@"anchorY"] = @(titleFrame.origin.y);
        req[@"anchorW"] = @(titleFrame.size.width);
        req[@"anchorH"] = @(titleFrame.size.height);
        req[@"activeMenuBarIndex"] = @(curIdx);
        if (barTitles.count > 0) req[@"menuBarTitles"] = barTitles;
        req[@"items"] = items;

        NSDictionary *reply = LionessMenuPresent(req);
        if (!reply) {
            tlInLionessMenu--;
            return presentedAny;
        }
        presentedAny = YES;

        NSInteger res = [reply[@"result"] integerValue];
        if (res == LIONESS_MENU_RESULT_SWITCH_BAR) {
            id<NSMenuDelegate> del = sub.delegate;
            if (del && [del respondsToSelector:@selector(menuDidClose:)]) {
                @try { [del menuDidClose:sub]; } @catch (NSException *ex) { (void)ex; }
            }
            NSInteger nextBarIdx = [reply[@"switchMenuBarIndex"] integerValue];
            if (nextBarIdx != curIdx && MenuBarSubmenu(barMenu, nextBarIdx)) {
                curIdx = nextBarIdx;
                // Unlight the title being left first, or two titles stay lit.
                HighlightMenuBarItem(impl, curIdx, YES);
                continue;
            }
            break;
        }

        CleanUpMenuBarTracking(impl);
        DispatchMenuReply(sub, nil, reply, itemMap, ownerMap);
        tlInLionessMenu--;
        return YES;
    }

    // Nothing to show (an empty menu): let AppKit open it rather than swallow the click.
    if (presentedAny) CleanUpMenuBarTracking(impl);
    tlInLionessMenu--;
    return presentedAny;
}

static void (*origRemotePrepareSubmenu)(id, SEL, NSInteger, NSInteger) = NULL;
static void Hook_NSRemoteMenuImpl_prepareToOpenSubmenu(id self, SEL _cmd, NSInteger idx, NSInteger opts) {
    Class barCls = objc_getClass("NSRemoteMenuBarImpl");
    if (barCls && [self isKindOfClass:barCls]) {
        if (PresentMenuBarDropdown(self, idx)) return;
    }
    if (origRemotePrepareSubmenu) origRemotePrepareSubmenu(self, _cmd, idx, opts);
}

static void (*origMenuBarPrepareSubmenu)(id, SEL, NSInteger, NSInteger) = NULL;
static void Hook_NSMenuBarImpl_prepareToOpenSubmenu(id self, SEL _cmd, NSInteger idx, NSInteger opts) {
    if (PresentMenuBarDropdown(self, idx)) return;
    if (origMenuBarPrepareSubmenu) origMenuBarPrepareSubmenu(self, _cmd, idx, opts);
}

// ---------------------------------------------------------------------------
// Constructor: install appropriate hooks per process
// ---------------------------------------------------------------------------

static BOOL ProcessIsExcluded(const char *prog) {
    if (!prog) return YES;
    static const char *const kSkip[] = {
        "lionessmenud", "LionessSpotlight", "appkitd", "WindowServer",
        "skylightaugmentord", "ControlCenter", "NotificationCenter",
        "SystemUIServer", "TextInputMenuAgent", "WiFiAgent", "WeatherMenu",
        "AirPlayUIAgent", "loginwindow",
        NULL
    };
    for (int i = 0; kSkip[i]; i++) {
        if (strcmp(prog, kSkip[i]) == 0) return YES;
    }
    return NO;
}

__attribute__((constructor))
static void LionessMenusInit(void) {
    @autoreleasepool {
        const char *prog = getprogname();
        if (ProcessIsExcluded(prog)) return;

        gIsDockHelper   = (strcmp(prog, "DockHelper") == 0);
        gIsMenuBarAgent = (strcmp(prog, "MenuBarAgent") == 0);

        // Spotlight / Siri AI interception (runs even before AppKit windows appear)
        if (strcmp(prog, "Siri AI") == 0 || strcmp(prog, "Spotlight") == 0) {
            InstallSpotlightHooks();
            // Also re-run shortly after launch in case Swift classes finish loading late
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.4 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{
                InstallSpotlightHooks();
            });
        }

        // Only install AppKit menu hooks in processes that actually link AppKit
        Class nsMenuCls = objc_getClass("NSMenu");
        if (!nsMenuCls) return;

        // Guard pre-existing NSStatusItem menu bar extras so they remain unaffected
        Class statusItemCls = objc_getClass("NSStatusItem");
        if (statusItemCls) {
            origStatusItemPopUp = (void (*)(id, SEL, NSMenu *))
                SwizzleInstance(statusItemCls, @selector(popUpStatusItemMenu:), (IMP)Hook_NSStatusItem_popUpStatusItemMenu);
        }
        Class statusBtnCls = objc_getClass("NSStatusBarButton");
        if (statusBtnCls) {
            origStatusBarButtonMouseDown = (void (*)(id, SEL, NSEvent *))
                SwizzleInstance(statusBtnCls, @selector(mouseDown:), (IMP)Hook_NSStatusBarButton_mouseDown);
        }

        // 1. NSMenu public & private popup hooks
        origPopUpContextMenu3 = (void (*)(id, SEL, NSMenu *, NSEvent *, NSView *))
            SwizzleClass(nsMenuCls, @selector(popUpContextMenu:withEvent:forView:), (IMP)Hook_NSMenu_popUpContextMenu3);
        origPopUpContextMenu4 = (void (*)(id, SEL, NSMenu *, NSEvent *, NSView *, NSFont *))
            SwizzleClass(nsMenuCls, @selector(popUpContextMenu:withEvent:forView:withFont:), (IMP)Hook_NSMenu_popUpContextMenu4);
        origPopUpPositioning = (BOOL (*)(id, SEL, NSMenuItem *, NSPoint, NSView *))
            SwizzleInstance(nsMenuCls, @selector(popUpMenuPositioningItem:atLocation:inView:), (IMP)Hook_NSMenu_popUpPositioning);
        origPopUpRelativeToRect = (BOOL (*)(id, SEL, NSRect, NSView *, NSRectEdge))
            SwizzleInstance(nsMenuCls, NSSelectorFromString(@"_popUpMenuRelativeToRect:inView:preferredEdge:"), (IMP)Hook_NSMenu_popUpRelativeToRect);

        // 2. NSCocoaMenuImpl & NSContextMenuImpl hooks (macOS 27 async / SwiftUI / NSPopUpButton)
        Class cocoaImplCls = objc_getClass("NSCocoaMenuImpl");
        if (cocoaImplCls) {
            origCocoaPopUpCtxEvent = (void (*)(id, SEL, NSMenu *, NSEvent *, NSView *, NSFont *, BOOL, id))
                SwizzleInstance(cocoaImplCls,
                                NSSelectorFromString(@"_popUpContextMenu:withEvent:forView:withFont:async:completionBlock:"),
                                (IMP)Hook_NSCocoaMenuImpl_popUpCtxEvent);
            origCocoaPopUpCtxObj = (void (*)(id, SEL, NSMenu *, id, NSView *, NSFont *, BOOL, id))
                SwizzleInstance(cocoaImplCls,
                                NSSelectorFromString(@"_popUpContextMenu:withContext:forView:withFont:async:completionBlock:"),
                                (IMP)Hook_NSCocoaMenuImpl_popUpCtxObj);
            origCocoaPopUpPos = (BOOL (*)(id, SEL, NSMenuItem *, NSUInteger, NSPoint, NSView *, NSUInteger, id, BOOL, id))
                SwizzleInstance(cocoaImplCls,
                                NSSelectorFromString(@"_popUpMenuPositioningItem:atCocoaIndex:atLocation:inView:withPrivateFlags:appearance:async:completionBlock:"),
                                (IMP)Hook_NSCocoaMenuImpl_popUpPos);
            origCocoaPopUpFull = (void (*)(id, SEL, NSMenu *, NSPoint, CGFloat, NSView *, id, NSFont *, NSRect, NSUInteger, id, id))
                SwizzleInstance(cocoaImplCls,
                                NSSelectorFromString(@"popUpMenu:atLocation:width:view:selectedItemIndexProvider:font:positioningRect:flags:options:completionBlock:"),
                                (IMP)Hook_NSCocoaMenuImpl_popUpFull);
        }

        if (cocoaImplCls) {
            origCocoaPopUpRect = (void (*)(id, SEL, NSMenu *, NSPoint, CGFloat, NSView *, id, NSFont *, NSRect, NSUInteger, id))
                SwizzleInstance(cocoaImplCls,
                                NSSelectorFromString(@"popUpMenu:atLocation:width:view:selectedItemIndexProvider:font:positioningRect:flags:options:"),
                                (IMP)Hook_NSCocoaMenuImpl_popUpRect);
        }

        Class ctxImplCls = objc_getClass("NSContextMenuImpl");
        if (ctxImplCls) {
            origContextPresentPopup = (void (*)(id, SEL, NSMenu *, NSView *, id, BOOL, BOOL, id))
                SwizzleClass(ctxImplCls,
                             NSSelectorFromString(@"presentPopup:fromView:withContext:animated:async:completionBlock:"),
                             (IMP)Hook_NSContextMenuImpl_presentPopup);
        }

        // 3. Menu bar dropdown hooks
        Class remoteImplCls = objc_getClass("NSRemoteMenuImpl");
        if (remoteImplCls) {
            origRemotePrepareSubmenu = (void (*)(id, SEL, NSInteger, NSInteger))
                SwizzleInstance(remoteImplCls,
                                NSSelectorFromString(@"prepareToOpenSubmenuAtIndex:options:"),
                                (IMP)Hook_NSRemoteMenuImpl_prepareToOpenSubmenu);
        }
        Class menuBarImplCls = objc_getClass("NSMenuBarImpl");
        if (menuBarImplCls) {
            origMenuBarPrepareSubmenu = (void (*)(id, SEL, NSInteger, NSInteger))
                SwizzleInstance(menuBarImplCls,
                                NSSelectorFromString(@"prepareToOpenSubmenuAtIndex:options:"),
                                (IMP)Hook_NSMenuBarImpl_prepareToOpenSubmenu);
        }
    }
}

// MacOSXArt's code: what makes windows, toolbars, menus, tables and controls measure and behave like Lion's. Its hooks that
// only paint its own art are left out, because the pictures come from Lion itself through appkitd. It was written for Sequoia.
/*
MIT License

Copyright (c) 2026 schm1dtmac

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
*/

@import Cocoa;
#include <dlfcn.h>
#import <CoreText/CoreText.h>
#import "ZKSwizzle.h"
#import <dobby.h>
#include <os/log.h>

@interface NSThemeFrame : NSView
- (NSTextField *)_titleTextField;
- (NSView *)titlebarView;
@end
@interface NSWindow ()
- (NSThemeFrame *)_themeFrame;
@end
@interface NSMenu ()
- (bool)_isAppleMenu;
- (bool)isMainMenu;
@end
@interface NSContextMenuImpl : NSResponder
- (NSMenu *)menu;
- (NSObject *)selectionMaterialView;
@end
@interface NSPopupMenuWindow : NSWindow
@property (readonly, weak) NSResponder *associatedImpl;
@end
@interface NSCompositeAppearance : NSAppearance
@property (copy) NSAppearanceName name;
@end
@interface NSBuiltinAppearance : NSAppearance
@end
@interface NSAquaAppearance : NSBuiltinAppearance
@end
@interface NSDarkAquaAppearance : NSBuiltinAppearance
@end
@interface NSVibrantLightAppearance : NSBuiltinAppearance
@end
@interface NSVibrantDarkAppearance : NSBuiltinAppearance
@end
@interface UIView : NSObject
@property (nonatomic, readonly, nullable) UIView *superview;
@property (nonatomic, copy, readonly) NSArray<__kindof UIView *> *subviews;
@end

@interface NSObject (LionLayoutPrivate)
- (bool)_needsSelectionBlurBackgroundView;
- (bool)dragShouldRemove;
@end

static NSImage *cornerImage;
bool LionessImageIsGlyph(NSImage *image);

// The cut of Lucida Grande that Lion's interface used, which is what its text is measured in. It's in the system's own file, under a hidden name. AppKit copies font
// descriptors, and those go by name, and a hidden name then comes back as Times. So the face is taken out of the file and given a name that can be asked for, for this process.
static bool gHaveUIFonts;
static uint32_t BE32(const uint8_t *p) { return (uint32_t)p[0] << 24 | p[1] << 16 | p[2] << 8 | p[3]; }
static uint16_t BE16(const uint8_t *p) { return (uint16_t)(p[0] << 8 | p[1]); }
static void PutBE32(uint8_t *p, uint32_t v) { p[0] = v >> 24; p[1] = v >> 16; p[2] = v >> 8; p[3] = v; }
static NSData *FaceWithVisibleName(const uint8_t *file, size_t size, size_t offset) {
    if (offset + 12 > size) return nil;
    const uint8_t *directory = file + offset;
    uint16_t tables = BE16(directory + 4);
    if (offset + 12 + tables * 16u > size) return nil;
    size_t total = 12 + tables * 16u;
    for (uint16_t i = 0; i < tables; i++) {
        uint32_t start = BE32(directory + 12 + i * 16 + 8), length = BE32(directory + 12 + i * 16 + 12);
        if ((size_t)start + length > size) return nil;
        total += (length + 3) & ~3u;
    }
    NSMutableData *out = [NSMutableData dataWithLength:total];
    uint8_t *o = out.mutableBytes;
    memcpy(o, directory, 12 + tables * 16u);
    size_t at = 12 + tables * 16u;
    for (uint16_t i = 0; i < tables; i++) {
        uint8_t *entry = o + 12 + i * 16;
        uint32_t start = BE32(entry + 8), length = BE32(entry + 12);
        memcpy(o + at, file + start, length);
        PutBE32(entry + 8, (uint32_t)at);
        if (!memcmp(entry, "name", 4) && length >= 6) {
            uint8_t *name = o + at;
            uint16_t count = BE16(name + 2), strings = BE16(name + 4);
            for (uint16_t r = 0; r < count && 6u + (r + 1u) * 12 <= length; r++) {
                const uint8_t *record = name + 6 + r * 12;
                uint16_t platform = BE16(record), bytes = BE16(record + 8), from = BE16(record + 10);
                if ((size_t)strings + from + bytes > length || bytes < 2) continue;
                uint8_t *text = name + strings + from;
                // The same length, so nothing else in the table moves.
                if (platform == 1 ? text[0] == '.' : (text[0] == 0 && text[1] == '.')) text[platform == 1 ? 0 : 1] = 'L';
            }
            uint32_t sum = 0;
            for (uint32_t w = 0; w < ((length + 3) & ~3u); w += 4) sum += BE32(name + w);
            PutBE32(entry + 4, sum);
        }
        at += (length + 3) & ~3u;
    }
    return out;
}
static void RegisterUIFonts(void) {
    NSData *file = [NSData dataWithContentsOfFile:@"/System/Library/Fonts/LucidaGrande.ttc" options:NSDataReadingMappedIfSafe error:NULL];
    const uint8_t *bytes = file.bytes;
    if (file.length < 12 || memcmp(bytes, "ttcf", 4)) return;
    uint32_t faces = BE32(bytes + 8);
    if (12 + (size_t)faces * 4 > file.length) return;
    int registered = 0;
    for (uint32_t i = 0; i < faces; i++) {
        NSData *face = FaceWithVisibleName(bytes, file.length, BE32(bytes + 12 + i * 4));
        if (!face) continue;
        CGDataProviderRef provider = CGDataProviderCreateWithCFData((__bridge CFDataRef)face);
        CGFontRef font = CGFontCreateWithDataProvider(provider);
        CGDataProviderRelease(provider);
        if (!font) continue;
        NSString *name = CFBridgingRelease(CGFontCopyPostScriptName(font));
        if (([name isEqualToString:@"LLucidaGrandeUI"] || [name isEqualToString:@"LLucidaGrandeUI-Bold"]) && CTFontManagerRegisterGraphicsFont(font, NULL)) registered++;
        CGFontRelease(font);
    }
    gHaveUIFonts = registered == 2;
}

static CTFontRef (*gOrigFontCreate)(CTFontDescriptorRef, CGFloat, const CGAffineTransform *);

// Below NSFont, so AppKit still believes it has the system font and control sizes keep working.
static CTFontRef HookFontCreate(CTFontDescriptorRef descriptor, CGFloat size, const CGAffineTransform *matrix) {
    CFDictionaryRef dictionary = CTFontDescriptorCopyAttributes(descriptor);
    NSString *fontName = CFDictionaryGetValue(dictionary, (__bridge CFStringRef)NSFontNameAttribute);
    NSString *uiAttr = CFDictionaryGetValue(dictionary, CFSTR("NSCTFontUIUsageAttribute"));
    NSString *bundleID = NSBundle.mainBundle.bundleIdentifier;
    CTFontDescriptorRef lucida = NULL;
    if (uiAttr || !fontName || ([fontName containsString:@"AppleSystemUIFont"] && !([bundleID containsString:@"Passwords"] || [bundleID containsString:@"Safari"]))) {
        NSMutableDictionary *attributes = [(__bridge NSDictionary *)dictionary mutableCopy];
        [attributes removeObjectForKey:@"NSCTFontTraitsAttribute"];
        [attributes removeObjectForKey:@"NSCTFontUIUsageAttribute"];
        bool bold = [fontName containsString:@"Bold"];
        attributes[NSFontNameAttribute] = gHaveUIFonts ? (bold ? @"LLucidaGrandeUI-Bold" : @"LLucidaGrandeUI") : (bold ? @"LucidaGrande-Bold" : @"LucidaGrande");
        lucida = CTFontDescriptorCreateWithAttributes((__bridge CFDictionaryRef)attributes);
    }
    CFRelease(dictionary);
    CTFontRef font = gOrigFontCreate(lucida ?: descriptor, size, matrix);
    if (lucida) CFRelease(lucida);
    // A nil here reaches AppKit as a nil NSFont, and the menu bar's layout throws over it, ending the app.
    font = font ?: gOrigFontCreate(descriptor, size, matrix);
    // Never nil: AppKit's menu bar titles put this in a dictionary, and the exception ends the app.
    return font ?: CTFontCreateWithName(CFSTR("LucidaGrande"), size > 0 ? size : 13, matrix);
}

static bool FlagTrue(void) { return true; }
static bool FlagFalse(void) { return false; }

static void HookSymbol(const char *image, const char *symbol, void *replacement, void **original) {
    void *address = DobbySymbolResolver(image, symbol);
    int result = address ? DobbyHook(address, replacement, original) : -1;
    if (getenv("LIONESS_DUMP")) fprintf(stderr, "DOBBY %s %s address=%p result=%d\n", image ?: "-", symbol, address, result);
    if (result != 0) os_log(OS_LOG_DEFAULT, "Lioness: no %{public}s here (%d)", symbol, result);
}

__attribute__((constructor)) static void LionLayoutInit(void) {
    CGFloat radius = 6.5, dimension = 2 * radius + 1;
    cornerImage = [NSImage imageWithSize:NSMakeSize(dimension, dimension) flipped:false drawingHandler:^BOOL(NSRect r) {
        NSBezierPath *path = [NSBezierPath bezierPath];
        [path moveToPoint:NSMakePoint(NSMinX(r), NSMaxY(r))];
        [path lineToPoint:NSMakePoint(NSMinX(r), NSMinY(r) + radius)];
        [path curveToPoint:NSMakePoint(NSMinX(r) + radius, NSMinY(r)) controlPoint:NSMakePoint(NSMinX(r), NSMinY(r))];
        [path lineToPoint:NSMakePoint(NSMaxX(r) - radius, NSMinY(r))];
        [path curveToPoint:NSMakePoint(NSMaxX(r), NSMinY(r) + radius) controlPoint:NSMakePoint(NSMaxX(r), NSMinY(r))];
        [path lineToPoint:NSMakePoint(NSMaxX(r), NSMaxY(r))];
        [path closePath];
        [NSColor.blackColor set];
        [path fill];
        return true;
    }];
    cornerImage.capInsets = NSEdgeInsetsMake(radius, radius, radius, radius);
    cornerImage.resizingMode = NSImageResizingModeStretch;

    RegisterUIFonts();
    static void *original[16];
    int n = 0;
    HookSymbol(NULL, "CTFontCreateWithFontDescriptor", (void *)HookFontCreate, (void **)&gOrigFontCreate);
    HookSymbol("AppKit", "_NSToolbarItemViewerCompatabilitySelectionWidgetDefaultValueFunction", (void *)FlagTrue, &original[n++]);
    HookSymbol("AppKit", "_NSBoxUseLegacyMetricsDefaultValueFunction", (void *)FlagTrue, &original[n++]);
    HookSymbol("AppKit", "_NSCellUseLegacyFontSizeDefaultValueFunction", (void *)FlagTrue, &original[n++]);
    HookSymbol("AppKit", "_NSButtonAdjustAlignmentRectInsetsForGladeArtworkDefaultValueFunction", (void *)FlagTrue, &original[n++]);
    HookSymbol("AppKit", "_NSToolbarItemViewerSupportsSelectionRolloverDefaultValueFunction", (void *)FlagFalse, &original[n++]);
    HookSymbol("AppKit", "_NSToolbarCompatibilityExpansionMetricsDefaultValueFunction", (void *)FlagFalse, &original[n++]);
    HookSymbol("AppKit", "_NSSidebarUsesGoldenMetrics", (void *)FlagFalse, &original[n++]);
    NSString *bundleID = NSBundle.mainBundle.bundleIdentifier;
    if (![bundleID isEqualToString:@"com.apple.Music"] && ![bundleID isEqualToString:@"com.apple.Preview"])
        HookSymbol("AppKit", "_NSTableViewCanUseGoldenStylesDefaultValueFunction", (void *)FlagFalse, &original[n++]);
    HookSymbol("AppKit", "_NSScrollViewUseLegacyScrollingDefaultValueFunction", (void *)FlagTrue, &original[n++]);
    // SwiftUI's own switches for the modern look, separate from AppKit's. Only in apps that link it. Most of these getters are a single branch, too small to patch: an
    // inline hook there overwrites the next function. So the hook goes on what they branch to.
    if (dlsym(RTLD_DEFAULT, "$s7SwiftUI8SolariumVAAE9isEnabledSbvgZ")) {
        static void *swiftUIOriginal[8];
        int m = 0;
        HookSymbol("SwiftUI", "$s7SwiftUI8SolariumVAAE9isEnabledSbvgZ", (void *)FlagFalse, &swiftUIOriginal[m++]);
        const char *const stubs[] = { "$s7SwiftUI8SolariumV15FlexiGlassMacOSV9isEnabledSbvgZ", "$s7SwiftUI8SolariumV22FlexiGlassMacOSPointerV9isEnabledSbvgZ", "$s7SwiftUI8SolariumV3QFAV9isEnabledSbvgZ" };
        for (size_t i = 0; i < sizeof stubs / sizeof *stubs; i++) {
            uint32_t *stub = (uint32_t *)DobbySymbolResolver("SwiftUICore", stubs[i]);
            if (!stub || (*stub & 0xfc000000) != 0x14000000) continue;   // not `b`
            int32_t offset = (int32_t)(*stub << 6) >> 6;
            void *target = stub + offset;
            int result = DobbyHook(target, (void *)FlagFalse, &swiftUIOriginal[m++]);
            if (getenv("LIONESS_DUMP")) fprintf(stderr, "DOBBY %s -> %p result=%d\n", stubs[i], target, result);
        }
    }
}

hook(NSMenuBarPresentationInstance)
+(bool)_isMenuBarTransparencyEnabled {
    return false;
}
endhook

hook(NSMenuItem)
-(NSInteger)indentationLevel {
    return MAX(1, ZKOrig(NSInteger));
}

+ (id)standardImportFromDeviceMenuItem {
    return nil;
}
endhook

hook(NSPopupMenuWindow)
- (NSImage *)_cornerMask {
    NSMenu* menu = [[(NSPopupMenuWindow*)self associatedImpl] menu];
    if ([[menu supermenu] isMainMenu] || [menu _isAppleMenu]) {
        [[(NSWindow*)self contentView] setValue:@(0) forKey:@"_materialCornerRadius"];
        return cornerImage;
    }
    return ZKOrig(NSImage*);
}
endhook

hook(NSContextMenuImpl)
- (double)markWidthsForItem:(id)a0 {
    return 4.0;
}

// MacOSXArt takes 26 off here when a menu has shortcuts, which truncated plain items' titles on this OS.
- (double)_targetWidth {
    return ZKOrig(double);
}

- (CGRect)_selectionLayerFrameForView:(id)a0 {
    CGRect orig = ZKOrig(CGRect, a0);
    orig.size = [a0 bounds].size;
    orig.origin.x = 0;
    return orig;
}

- (double)_targetHeight:(bool)a0 {
    double height = ZKOrig(double, a0);
    NSInteger num = [[(NSContextMenuImpl*)self menu] numberOfItems];
    for(NSInteger i = 0; i < num ; i++) {
        double prefHeight = [self preferredViewHeightForMenuItemAtIndex:i];
        if((prefHeight > 19.0) && (prefHeight < 20.0))
            height -= 1000 * (prefHeight - 19.0);
    }
    return height;
}

- (double)preferredViewHeightForMenuItemAtIndex:(unsigned long long)a0 {
    double orig = ZKOrig(double, a0);
    return (orig > 19.0) && (orig < 27.0) ? 19.0 + (orig - 19.0)/1000 : orig;
}

// NSMenuItem's backgroundStyle asks for this, and AppKit's Services row asks that while it draws: without it the exception ends the app.
- (int)_backgroundStyle {
    return 0;
}
endhook

hook(NSCompositeAppearance)
- (NSAppearance*)_appearanceForVibrantContent {
    return [[(NSCompositeAppearance*)self name] containsString:@"Dark"] ? [NSAppearance appearanceNamed:@"NSAppearanceNameVibrantDark"] : [NSAppearance appearanceNamed:@"NSAppearanceNameVibrantLight"];
}

- (NSAppearance*)_appearanceForNonVibrantContent {
    return [[(NSCompositeAppearance*)self name] containsString:@"Dark"] ? [NSAppearance appearanceNamed:@"NSAppearanceNameDarkAqua"] : [NSAppearance appearanceNamed:@"NSAppearanceNameAqua"];
}

- (bool)_usesMetricsAppearance {
    return false;
}
endhook

hook(NSVibrantDarkAppearance)
- (bool)_usesMetricsAppearance {
    return false;
}
endhook

hook(NSVibrantLightAppearance)
- (bool)_usesMetricsAppearance {
    return false;
}
endhook

hook(NSAquaAppearance)
- (bool)_usesMetricsAppearance {
    return false;
}
endhook

hook(NSDarkAquaAppearance)
- (bool)_usesMetricsAppearance {
    return false;
}
endhook

hook(NSAlert)
- (void)_resetLayoutDone {
    ZKOrig(void);
    int *layoutStyle = &ZKHookIvar(self, int, "_layoutStyle");
    if (layoutStyle) {
        *layoutStyle = 3;
    }
}

- (void)_buildLayoutConstraintsForWideAppearance:(id)arg0 views:(id)arg1 metrics:(NSDictionary *)arg2 title:(id)arg3 formattedMessage:(id)arg4 numButtons:(NSUInteger)arg5 hasSecond:(bool)arg6 {
    ZKOrig(void, arg0, arg1, arg2, arg3, arg4, arg5, arg6);
    CGFloat *minPanelWidth = &ZKHookIvar(self, CGFloat, "_minPanelWidth");
    if (minPanelWidth) {
        *minPanelWidth = 450;
    }
}
endhook

hook(UIScene)
-(void)setTitle:(id)title {
    if (![[[NSBundle mainBundle] bundleIdentifier] isEqualToString:@"com.apple.iBooksX"])
        return ZKOrig(void, title);
}
endhook

// An About window is the one kind without a toolbar that had a title bar in Lion, whatever it asks for now.
static NSString *const kAboutThisMac = @"AquaMacOSXAbout", *const kAboutPanel = @"LionessAboutPanel";
static bool IsAboutWindow(NSWindow *window) {
    NSString *identifier = [[window _themeFrame] identifier];
    return [identifier isEqual:kAboutThisMac] || [identifier isEqual:kAboutPanel];
}
static void GiveAboutPanelsATitleBar(void) {
    for (NSWindow *window in NSApp.windows) {
        if (![window isKindOfClass:NSPanel.class] || !window.isVisible || IsAboutWindow(window) || window.toolbar) continue;
        if ((window.styleMask & NSWindowStyleMaskTitled) && window.title.length == 0 && [[window _themeFrame] respondsToSelector:@selector(setIdentifier:)]) {
            NSRect frame = window.frame;
            [[window _themeFrame] setIdentifier:kAboutPanel];
            window.titlebarAppearsTransparent = NO;
            window.titleVisibility = NSWindowTitleVisible;
            frame.size.height += 22;
            frame.origin.y -= 22;
            [window setFrame:frame display:YES];
        }
    }
}

hook(NSApplication)
- (void)orderFrontStandardAboutPanelWithOptions:(NSDictionary *)options {
    ZKOrig(void, options);
    GiveAboutPanelsATitleBar();
}
- (void)orderFrontStandardAboutPanel:(id)sender {
    ZKOrig(void, sender);
    GiveAboutPanelsATitleBar();
}
endhook

hook(NSWindow)
- (id)initWithContentRect:(NSRect)contentRect styleMask:(NSWindowStyleMask)style backing:(NSBackingStoreType)backingStoreType defer:(bool)flag {
    NSString *bundleIdentifier = [[NSBundle mainBundle] bundleIdentifier];
    if ([bundleIdentifier isEqualToString:@"com.apple.finder"] && [[(NSWindow*)self className] containsString:@"BrowserWindow"]) {
        return ZKOrig(id, NSMakeRect(contentRect.origin.x, contentRect.origin.y, 770, 436), style, backingStoreType, flag);
    }
    if ([bundleIdentifier isEqualToString:@"com.apple.iCal"]
        || [bundleIdentifier isEqualToString:@"com.apple.MobileSMS"]
        || [bundleIdentifier isEqualToString:@"com.apple.AppStore"]
        || [bundleIdentifier isEqualToString:@"com.apple.AddressBook"]) {
        style &= ~NSWindowStyleMaskFullSizeContentView;
    }
    return ZKOrig(id, contentRect, style, backingStoreType, flag);
}

-(void)setToolbarStyle:(NSWindowToolbarStyle)style {
    return;
}

-(NSWindowTitleVisibility)titleVisibility {
    // A window with no toolbar that hides its title means it. Lion's look only replaces the modern unified toolbar.
    if ([[[NSBundle mainBundle] bundleIdentifier] isEqualToString:@"com.apple.Music"] || (![(NSWindow*)self toolbar] && !IsAboutWindow((NSWindow*)self))) {
        return ZKOrig(NSWindowTitleVisibility);
    }
    return NSWindowTitleVisible;
}

-(bool)titlebarAppearsTransparent {
    if (IsAboutWindow((NSWindow*)self)) return false;
    if ([[[NSBundle mainBundle] bundleIdentifier] isEqualToString:@"com.apple.Music"]
        || [[[NSBundle mainBundle] bundleIdentifier] isEqualToString:@"com.apple.podcasts"]
        || (([(NSWindow*)self isKindOfClass:[NSPanel class]]) && ![[self className] isEqualToString:@"_NSAlertPanel"])
        || ![(NSWindow*)self canBecomeKeyWindow]
        || ![(NSWindow*)self toolbar]) {
        return ZKOrig(bool);
    }
    return false;
}

- (NSTitlebarSeparatorStyle)titlebarSeparatorStyle {
    return NSTitlebarSeparatorStyleNone;
}

- (NSTitlebarSeparatorStyle)contentTitlebarSeparatorStyle {
    return NSTitlebarSeparatorStyleNone;
}

- (id)_sidebarTrackingAdapter {
    return nil;
}

- (id)_trailingSidebarTrackingAdapter {
    return nil;
}

- (NSUInteger)sheetBehavior {
    return 3;
}

- (void)setTitlebarHeight:(CGFloat)value {
    if (![[[NSBundle mainBundle] bundleIdentifier] isEqualToString:@"com.apple.Music"]) {
        return;
    }
    ZKOrig(void, value);
}

-(void)setTitle:(NSString*)title {
    if ([[[NSBundle mainBundle] bundleIdentifier] isEqualToString:@"com.apple.AddressBook"] && [title isEqual:@""]) {
        return ZKOrig(void, [[NSRunningApplication currentApplication] localizedName]);
    }
    return ZKOrig(void, title);
}

-(bool)_zoomButtonIsFullScreenButton {
    return false;
}
endhook

hook(_NSTitlebarDecorationView)
- (void)setDrawsBottomSeparator:(bool)flag {
    return ZKOrig(void,![[(NSView*)self window] titlebarAppearsTransparent]);
}
- (void)_updateBottomSeparatorLayer {
    return;
}
endhook

hook(NSToolbar)
-(void)_userRemoveItemAtIndex:(long long)arg1 {
    ZKOrig(void, arg1);
    NSShowAnimationEffect(NSAnimationEffectPoof, [NSEvent mouseLocation], NSZeroSize, nil, nil, nil);
}
-(BOOL)allowsDisplayModeCustomization {
    return [(NSToolbar*)self allowsUserCustomization];
}
endhook

hook(NSToolbarItem)
-(id)_partitionAdapter {
    return nil;
}
- (id)initWithItemIdentifier:(id)identifier {
    return [identifier isEqualToString:@"toggleMessageListFilter:"] ? nil : ZKOrig(id, identifier);
}
endhook

hook(NSStatusItem)
-(void)setVisible:(bool)visible {
    if ([[(NSStatusItem*)self autosaveName] isEqual:@"BentoBox"])
        return ZKOrig(void, false);
    else
        return ZKOrig(void, visible);
}

- (bool)_allowItemDragging {
    return true;
}
endhook

hook(NSStatusBarWindow)
-(void)setHasCAShadow:(bool)flag {
    return ZKOrig(void, false);
}
endhook

hook(NSUserNotification)
- (void)setSoundName:(NSString *)soundName {
    if ([soundName isEqual:NSUserNotificationDefaultSoundName])
        return ZKOrig(void, @"Tri-tone");
    return ZKOrig(void, soundName);
}
endhook

hook(UNNotificationSound)
+ (id)_soundWithAlertType:(long long)a0 audioVolume:(id)a1 critical:(bool)a2 toneFileName:(id)a3 {
    if(a3 == nil)
        return ZKOrig(id, a0, a1, a2, @"Tri-Tone");
    return ZKOrig(id, a0, a1, a2, a3);
}
endhook

hook(NSTrackingSeparatorToolbarItem)
- (bool)_isPartitionItem {
    return false;
}
endhook

hook(NSSeparatorToolbarItemView)
- (bool)isHidden {
    return true;
}
endhook

hook(NSToolbarItemViewer)
-(CGSize)minSize {
    return [[[[(NSView*)self subviews] firstObject] className] containsString:@"NSSeparatorToolbarItemView"] ? CGSizeZero : ZKOrig(CGSize);
}
-(CGSize)maxSize {
    return [[[[(NSView*)self subviews] firstObject] className] containsString:@"NSSeparatorToolbarItemView"] ? CGSizeZero : ZKOrig(CGSize);
}
-(bool)wantsToBeCentered {
    if(([[[NSBundle mainBundle] bundleIdentifier] isEqualToString:@"com.apple.Safari"] && [[(NSObject*)[[(NSView*)self window] delegate] className] isEqualToString:@"PreferencesUIController"])
       || ([[[NSBundle mainBundle] bundleIdentifier] isEqualToString:@"com.apple.Photos"] && [[[(NSView*)self window] frameAutosaveName] isEqualToString:@"Preferences"])
       || [[[NSBundle mainBundle] bundleIdentifier] isEqualToString:@"com.apple.mail"]
       || [[[NSBundle mainBundle] bundleIdentifier] isEqualToString:@"com.apple.AddressBook"]
       || [[[NSBundle mainBundle] bundleIdentifier] isEqualToString:@"com.apple.MobileSMS"]
       || [[[NSBundle mainBundle] bundleIdentifier] isEqualToString:@"com.apple.iBooksX"]
       || [[[NSBundle mainBundle] bundleIdentifier] isEqualToString:@"com.apple.Maps"]
       || [[[NSBundle mainBundle] bundleIdentifier] isEqualToString:@"com.apple.shortcuts"])
        return false;
    return ZKOrig(bool);
}
endhook

hook(NSTabBarNewTabButton)
-(CGRect)frame {
    CGRect frame = ZKOrig(CGRect);
    frame.size.width = 27;
    return frame;
}
endhook

hook(NSTabBar)
-(CGRect)frame {
    CGRect frame = ZKOrig(CGRect);
    CGRect frame2 = [[(NSView*)self superview] frame];
    frame.size.height = frame2.size.height = 24;
    [[(NSView*)self superview] setFrame:frame2];
    return frame;
}
endhook

hook(NSTitlebarAccessoryViewController)
-(double)fullScreenMinHeight {
    return MIN(ZKOrig(double), [[(NSTitlebarAccessoryViewController*)self view] frame].size.height);
}
endhook

hook(NSSheetMoveHelper)
- (id)initWithSheet:(id)sheet {
    id helper = ZKOrig(id, sheet);
    NSInteger *animationStyle = &ZKHookIvar(helper, NSInteger, "_animationStyle");
    *animationStyle = 0;
    return helper;
}
endhook

hook(NSSplitViewItem)
- (bool)revealsOnEdgeHoverInFullscreen {
    return false;
}
endhook

hook(NSSplitView)
- (bool)_canDoSidebarProactivePeek {
    return false;
}
- (bool)_canDoInspectorProactivePeek {
    return false;
}
endhook

hook(NSTableRowView)
-(NSBackgroundStyle)interiorBackgroundStyle {
    return ([(NSTableRowView*)self isSelected] && [(id)self _needsSelectionBlurBackgroundView]) ? NSBackgroundStyleEmphasized : ZKOrig(NSBackgroundStyle);
}
endhook

hook(NSTableView)
- (id)_sourceListGroupCellAttributedStringForString:(NSString*)string withDefaultAttributes:(id)attributes highlighted:(_Bool)highlighted {
    return ZKOrig(id, string, attributes, highlighted);
}
- (id)_sourceListWithBlurGroupCellAttributedStringForString:(NSString*)string withDefaultAttributes:(id)attributes highlighted:(_Bool)highlighted {
    return [self _sourceListGroupCellAttributedStringForString: [string uppercaseString] withDefaultAttributes:attributes highlighted:highlighted];
}
- (NSSize)intercellSpacing {
    NSSize orig = ZKOrig(NSSize);
    if (orig.width == 17 && orig.height == 0)
        return NSMakeSize(3,2);
    return orig;
}
- (CGFloat)rowHeight {
    if ([[[NSBundle mainBundle] bundleIdentifier] isEqualToString:@"com.apple.ActivityMonitor"])
        return 17.0;
    switch ([(id)self effectiveRowSizeStyle]) {
        case NSTableViewRowSizeStyleSmall:
            return 20.0;
        case NSTableViewRowSizeStyleMedium:
            return 24.0;
        case NSTableViewRowSizeStyleLarge:
            return 34.0;
        default:
            return ZKOrig(CGFloat);
    }
}
endhook

hook(NSOutlineView)
- (bool)_canUseUpdatedIdentation {
    return false;
}

- (double)_legacyIndentationForLevel:(long long)level isSourceListGroupRow:(_Bool)row {
    return level == 0 ? 10.0 : 14.0 * level;
}
endhook

hook(NSTableViewStyleData)
-(double)rowContentInset {
    if ([[[NSBundle mainBundle] bundleIdentifier] isEqualToString:@"com.apple.Preview"]) {
        double orig = ZKOrig(double);
        return orig == 10 ? orig : 0.0;
    }
    return 0.0;
}
endhook

hook(NSTableHeaderView)
- (bool)_canSupportTallerHeight {
    return false;
}
-(CGRect)frame {
    CGRect frame = ZKOrig(CGRect);
    frame.size.height = MIN(frame.size.height, 17);
    return frame;
}
endhook

hook(NSThemeFrame)
- (bool)_isUtility {
    return [[(NSView*)self identifier] isEqual:kAboutThisMac] ? true : ZKOrig(bool);
}

- (CGPoint)_closeButtonOrigin {
    CGPoint origin = ZKOrig(CGPoint);
    if ([[[NSBundle mainBundle] bundleIdentifier] isEqualToString:@"com.apple.Music"])
        origin.y = NSMaxY([(NSView*)self frame]) - 19;
    return origin;
}

- (CGPoint)_fullScreenButtonOrigin {
    CGPoint origin = ZKOrig(CGPoint);
    if ([[[NSBundle mainBundle] bundleIdentifier] isEqualToString:@"com.apple.Music"])
        origin.y = NSMaxY([(NSView*)self frame]) - 21;
    return origin;
}

// This OS also passes whether Solarium is on.
+(double)_windowTitlebarTitleMinHeight:(unsigned long long)a0 hasSolariumAppearance:(bool)a1 {
    return MIN(ZKOrig(double, a0, a1), 22.0);
}

-(double)_minYTitlebarButtonsOffset {
    return -2.0;
}

- (CGRect)_maxTitlebarTitleRect {
    CGRect frame = ZKOrig(CGRect);
    frame.size.height -= 2;
    return frame;
}

-(double)_toolbarOffsetIfTitleIsHidden {
    return -2.5;
}

-(double)_distanceFromToolbarBaseToTitlebar {
    if ([[[(NSView*)self window] toolbar] isVisible] ){
        if([[[(NSView*)self window] titlebarAccessoryViewControllers] count] >=0 && ([[[(NSView*)self window] titlebarAccessoryViewControllers] indexOfObjectPassingTest:^BOOL(__kindof NSTitlebarAccessoryViewController * _Nonnull obj, NSUInteger idx, BOOL * _Nonnull stop) {
            return ![obj isHidden];
        }] != NSNotFound)) {
            return ZKOrig(double) + 4.0;
        } else {
            return ZKOrig(double) + 5.0;
        }
    }
    else {
        return ZKOrig(double);
    }
}
// 3 from Lion through Mavericks.
-(double)_toolbarLeadingSpace {
    return 3;
}

-(double)_toolbarTrailingSpace {
    return 3;
}
endhook

hook(_NSThemeWidgetCell)
-(CGSize)cellSizeForBounds:(CGRect)arg1 {
    CGSize size = ZKOrig(CGSize);
    if (size.height == 9)
        size.height = 13;
    return size;
}
endhook

hook(NSControl)
- (void)setControlSize:(NSControlSize)controlSize {
    return ZKOrig(void, controlSize % 3);
}

- (NSControlSize)controlSize {
    return ZKOrig(NSControlSize) % 3;
}
endhook

hook(NSButtonCell)
- (NSControlSize)controlSize {
    return ZKOrig(NSControlSize) % 3;
}
endhook

hook(NSSplitDividerView)
- (void)setStyle:(long long)style {
    return ZKOrig(void, 4);
}
endhook

hook(NSSegmentItemImageView)
- (void)setFrame:(CGRect)frame {
    NSImage* image = [(NSImageView*)self image];
    double widthForCalc = [image size].width;
    double heightForCalc = [image size].height;
    
    CGPoint center = CGPointMake(frame.origin.x - 0.5 * (widthForCalc - frame.size.width), 0.5 * ([[(NSView*)self superview] frame].size.height - heightForCalc));
    if ([(NSSegmentedControl*)[(id)self superview] controlSize] == NSControlSizeRegular)
        center.y -= 1;
    
    return ZKOrig(void, CGRectMake(center.x, center.y, widthForCalc, heightForCalc));
}
endhook

// The icons that stand in for symbols have Lion's size, and are placed at it rather than stretched to the modern frame.
hook(NSButtonImageView)
- (void)setFrame:(CGRect)frame {
    NSImage* image = [(NSImageView*)self image];
    if (!LionessImageIsGlyph(image)) {
        return ZKOrig(void, frame);
    }

    double widthForCalc = [image size].width;
    double heightForCalc = [image size].height;

    CGPoint center = CGPointMake(frame.origin.x - 0.5 * (widthForCalc - frame.size.width), 0.5 * ([[(NSView*)self superview] frame].size.height - heightForCalc));
    if ([(NSButton*)[(id)self superview] bezelStyle] == NSBezelStyleToolbar)
        center.y -= 1;

    return ZKOrig(void, CGRectMake(center.x, center.y, widthForCalc, heightForCalc));
}
endhook

hook(TBrowserContentViewController)
- (NSLayoutConstraint *)makeStatusBarLeadingConstraint {
    NSLayoutConstraint* constraint = [[ZKOrig(NSLayoutConstraint*) firstAnchor] constraintEqualToAnchor:[[(NSViewController*)self view] leadingAnchor]];
    return constraint;
}
endhook

hook(TImageView)
-(void)setImage:(NSImage*)image {
    if([image size].height <= 64)
        [image setTemplate:YES];
    return ZKOrig(void, image);
}
-(void)setFrame:(CGRect)rect {
    if ([[(NSImageView*)self superview] frame].size.height == 24.0)
        return ZKOrig(void, ((CGRect){rect.origin, NSMakeSize(18, 18)}));
    else if ([[(NSImageView*)self superview] frame].size.height == 20.0)
        return ZKOrig(void, ((CGRect){NSMakePoint(rect.origin.x, 2), rect.size}));
    return ZKOrig(void, rect);
}
endhook

hook(FI_TImageView)
-(void)setImage:(NSImage*)image {
    if([image size].height <= 64)
        [image setTemplate:YES];
    return ZKOrig(void, image);
}
-(void)setFrame:(CGRect)rect {
    if ([[(NSImageView*)self superview] frame].size.height == 24.0)
        return ZKOrig(void, ((CGRect){rect.origin, NSMakeSize(18, 18)}));
    else if ([[(NSImageView*)self superview] frame].size.height == 20.0)
        return ZKOrig(void, ((CGRect){NSMakePoint(rect.origin.x, 2), rect.size}));
    return ZKOrig(void, rect);
}
endhook

hook(TSidebarViewController)
- (void)outlineView:(id)view draggingEndedAt:(CGPoint)at operation:(unsigned long long)operation {
    if([(id)self dragShouldRemove])
        NSShowAnimationEffect(NSAnimationEffectPoof, [NSEvent mouseLocation], NSZeroSize, nil, nil, nil);
    ZKOrig(void, view, at, operation);
}
endhook

hook(FI_TSidebarViewController)
- (void)outlineView:(id)view draggingEndedAt:(CGPoint)at operation:(unsigned long long)operation {
    if([(id)self dragShouldRemove])
        NSShowAnimationEffect(NSAnimationEffectPoof, [NSEvent mouseLocation], NSZeroSize, nil, nil, nil);
    ZKOrig(void, view, at, operation);
}
endhook

hook(TTextField)
- (void)setFrameOrigin:(NSPoint)origin {
    if ([[self valueForKey:@"identifier"] isEqualToString:@"xSidebarHeader"]) {
        origin.x = 6.0;
    }
    return ZKOrig(void, origin);
}
endhook

hook(FI_TTextField)
- (void)setFrameOrigin:(NSPoint)origin {
    if ([[self valueForKey:@"identifier"] isEqualToString:@"xSidebarHeader"]) {
        origin.x = 6.0;
    }
    return ZKOrig(void, origin);
}
endhook

hook(_TtC6Safari31CompletionListURLCompletionData)
-(long long)type {
    return 0;
}
-(NSString*)subtitle {
    return nil;
}
endhook

hook(_TtC6Safari24CompletionListActionData)
-(long long)type {
    return 0;
}
-(NSString*)subtitle {
    return nil;
}
endhook

hook(_TtC6Safari31CompletionListSuggestedSiteData)
-(long long)type {
    return 0;
}
-(NSString*)subtitle {
    return nil;
}
endhook

hook(_TtC6Safari36CompletionListQuickWebsiteSearchData)
-(long long)type {
    return 0;
}
-(NSString*)subtitle {
    return nil;
}
endhook

hook(_TtC6Safari35CompletionListPegasusSuggestionData)
-(long long)type {
    return 0;
}
-(NSString*)subtitle {
    return nil;
}
endhook

hook(_TtC6Safari40CompletionListSearchEngineSuggestionData)
-(NSString*)subtitle {
    return nil;
}
endhook

hook(_TtC6Safari24CompletionListBannerData)
-(long long)type {
    return 0;
}
-(NSString*)subtitle {
    return nil;
}
endhook

hook(_TtCC6Safari32CompletionListCollectionViewItem4View)
- (void)setFrame:(CGRect)frame {
    frame.origin.x -= 16;
    frame.size.width += 32;
    frame.size.height = 24;
    return ZKOrig(void, frame);
}
endhook

// MacOSXArt returned nil from init, but a collection view throws if it's handed no view, which ends Safari. So it exists, and is never seen.
hook(_TtCC6Safari38CompletionListCollectionViewController22InterItemSeparatorView)
- (bool)isHidden {
    return true;
}
endhook

hook(BrowserWindow)
-(NSThemeFrame*)_themeFrame {
    return ZKOrig(NSThemeFrame*);
}

-(void)layoutIfNeeded {
    ZKOrig(void);
    [[[self _themeFrame] _titleTextField] setStringValue:[(NSWindow*)self title]];
}

-(void)updateCGSWindowTitle {
    ZKOrig(void);
    [[[self _themeFrame] _titleTextField] setStringValue:[(NSWindow*)self title]];
}

-(bool)_inLiveResize {
    NSRect titleBarRect = [[[self _themeFrame] titlebarView] frame];
    [[[self _themeFrame] _titleTextField] setFrameSize:[[[self _themeFrame] _titleTextField] sizeThatFits:NSMakeSize(titleBarRect.size.width - 111, 18)]];
    NSRect titleRect = [[[self _themeFrame] _titleTextField] frame];
    [[[self _themeFrame] _titleTextField] setFrameOrigin:NSMakePoint(MAX(titleBarRect.size.width * 0.5 - titleRect.size.width * 0.5, 68), titleRect.origin.y)];
    return ZKOrig(bool);
}
endhook

hook(FavoritesBarView)
- (void)_layOutButtons {
    ZKOrig(void);
    if([[[NSBundle mainBundle] bundleIdentifier] isEqualToString:@"com.apple.Safari"]) {
        NSMutableArray *_buttons = [self valueForKey:@"_buttons"];
        for (NSButton* button in _buttons) {
            if ([_buttons indexOfObject:button] == 0) {
                [button setFrameOrigin:NSMakePoint(37, 5.5)];
            }
            else {
                NSButton *prevButton = [_buttons objectAtIndex:[_buttons indexOfObject:button] - 1];
                [button setFrameOrigin:NSMakePoint(NSMaxX([prevButton frame]), 5.5)];
            }
        }
    }
}
-(CGRect)frame {
    CGRect frame = ZKOrig(CGRect);
    if([[[NSBundle mainBundle] bundleIdentifier] isEqualToString:@"com.apple.Safari"]) {
        CGRect frame2 = [[(NSView*)self superview] frame];
        frame2.size.height = 16;
        [[(NSView*)self superview] setFrame:frame2];
    }
    return frame;
}
endhook

hook(NSToolbarView)
-(void)setFrame:(CGRect)frame {
    if([[[NSBundle mainBundle] bundleIdentifier] isEqualToString:@"com.apple.Safari"] && frame.size.height == 34) {
        frame.size.height = 28;
    }
    return ZKOrig(void,frame);
}
endhook

hook(StartPageCollectionViewLayout)
-(void)setCenterContentVerticallyIfPossible:(bool)flag {
    return ZKOrig(void,false);
}
endhook

hook(TabBarView)
-(CGRect)frame {
    CGRect frame = ZKOrig(CGRect);
    frame.size.height = 24;
    return frame;
}
endhook

hook(ToolbarDownloadsButton)
- (void)layout {
    ZKOrig(void);
    NSView *progressBar = ZKHookIvar(self, NSView *, "_progressBar");
    NSRect frame = progressBar.frame;
    frame.origin.y = frame.origin.y - 5;
    progressBar.frame = frame;
}
endhook

hook(TopSitesButton)
-(void)setFrame:(CGRect)frame {
    if([(NSButton*)self bezelStyle] != NSBezelStyleToolbar)
        frame.origin.y = 8;
    return ZKOrig(void,frame);
}
endhook

hook(UnifiedField)
- (id)_progressBarColor {
    return [NSColor clearColor];
}
- (double)_progressBarCornerRadius {
    return 0.0;
}
- (void)setBrowsingMode:(NSUInteger)flag {
    return;
}
-(void)setBezelStyle:(NSTextFieldBezelStyle)style {
    return ZKOrig(void, NSTextFieldSquareBezel);
}
- (bool)_shouldLeftAlignContent {
    return true;
}
- (bool)_shouldSeparateTabBarAssistantButtonBeVisible {
    return false;
}
- (bool)_canShowOneStepBookmarkingButton {
    return false;
}
- (bool)_isMagnifyingGlassButtonVisible {
    return ZKOrig(bool);
}
- (bool)_shouldReserveSpaceForOneStepBookmarkingButton {
    return ![self _isMagnifyingGlassButtonVisible];
}
- (CGFloat)_urlTextYOffset {
    return -3;
}
- (CGFloat)_defaultButtonYOffset {
    return -3;
}
- (CGFloat)_siteIconYOffset {
    return 1.5;
}
- (CGFloat)_urlTextHeight {
    return 22;
}
- (CGFloat)_urlFieldHeight {
    return 22;
}
-(void)setFrame:(CGRect)frame {
    frame.size.height = 22.0;
    frame.origin.y = 1/[[NSScreen mainScreen] backingScaleFactor];
    return ZKOrig(void,frame);
}
endhook

hook(UnifiedFieldBezelView)
// Its backing material is a live visual effect view.
- (void)_updateBackingMaterial {
    return;
}
-(void)setBrowsingMode:(NSUInteger)flag {
    return;
}
-(void)setBezelStyle:(NSTextFieldBezelStyle)style {
    return ZKOrig(void, NSTextFieldSquareBezel);
}
- (void)drawRect:(NSRect)rect {
    ZKSuper(void, rect);
}
-(void)setFrame:(CGRect)frame {
    frame.size.height = 22.0;
    frame.origin.y = 1/[[NSScreen mainScreen] backingScaleFactor];
    return ZKOrig(void,frame);
}
endhook

hook(MailBarContainerView)
-(CGRect)frame {
    CGRect frame = ZKOrig(CGRect);
    frame.size.height = 25;
    return frame;
}
endhook

hook(DDMContext)
-(id)environmentName {
    return nil;
}
endhook

// About This Mac: the window Lion had, with a title bar. Its picture and text stay as they are, for there's none of Lion's to hand.
// MacOSXArt did this from SPImageView's setFrame:, which isn't called here now that it's laid out by constraints.
hook(SPAboutViewController)
- (void)viewWillAppear {
    ZKOrig(void);
    NSWindow *window = [[(NSViewController*)self view] window];
    if (!window || IsAboutWindow(window)) return;
    NSSize content = [[window contentView] frame].size;
    [[window _themeFrame] setIdentifier:kAboutThisMac];
    [window setStyleMask:[window styleMask] & ~NSWindowStyleMaskFullSizeContentView];
    window.titlebarAppearsTransparent = NO;
    window.titleVisibility = NSWindowTitleVisible;
    [window setTitle:@"About This Mac"];
    [window setContentSize:content];
}
endhook

hook(DockBar)
-(float)tileSize {
    return ZKOrig(float);
}

-(float)distanceBottom {
    return [self tileSize] < 64 ? [self tileSize]*[self tileSize] * 13/(64*64) : [self tileSize] * 13/64; // Lion
}
endhook

hook(CKUIBehaviorMac)
- (double)snapToMinConversationListCellWidth {
    return 250;
}
- (double)snapToMinConversationListWidth {
    return 270;
}
- (double)defaultConversationListWidth {
    return 270;
}
endhook

hook(IMFeatureFlags)
- (bool)macToolbarEnabled {
    return false;
}
endhook

hook(CKComposeRecipientView)
-(void)setFrame:(CGRect)frame {
    frame.origin.y -= 6;
    return ZKOrig(void, frame);
}
endhook

hook(CKNavigationBarCanvasView)
- (CGSize)sizeThatFits:(CGSize)a3 {
    CGSize orig = ZKOrig(CGSize);
    orig.height = 38;
    return orig;
}
- (void)setFrame:(CGRect)frame {
    return ZKOrig(void, frame);
}
- (CGRect)frame {
    return ZKOrig(CGRect);
}
- (void)layoutSubviews {
    CGRect frame = [self frame];
    frame.origin.y = -14;
    [self setFrame:frame];
    ZKOrig(void);
}
- (void)drawRect:(CGRect)rect{
    [self layoutSubviews];
    return ZKOrig(void, rect);
}
endhook

hook(CKLabel)
-(void)setFont:(id)font {
    if([[[(UIView*)self superview] className] isEqualToString:@"CKNavigationBarCanvasView"])
        return;
    return ZKOrig(void, font);
}
endhook

hook(_UIBarBackground)
-(void)setHidden:(bool)flag {
    return ZKOrig(void, ([[[(UIView*)self superview] className] isEqualToString:@"CKAvatarNavigationBar"] && [[[[(UIView*)self subviews] firstObject] className] isEqualToString:@"UIImageView"]) ? true : flag);
}

-(void)setFrame:(CGRect)frame {
    if([[[(UIView*)self superview] className] isEqualToString:@"CKAvatarNavigationBar"])
        frame.size.height -= 5;
    return ZKOrig(void, frame);
}
endhook

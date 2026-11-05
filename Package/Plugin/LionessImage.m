// The installer page: where Mountain Lion comes from. It only records the choice; postinstall and LionessSetup.sh act on it.
// Runs as the user, in Installer's plugin service.
#import <Cocoa/Cocoa.h>
#import <InstallerPlugins/InstallerPlugins.h>
#import <CommonCrypto/CommonDigest.h>
#include <sys/clonefile.h>
#include <sys/stat.h>

static NSString *const kChoices = @"/Users/Shared/.lioness-setup";
static NSString *const kRootCoreUI = @"/Library/Lioness/ml-root/System/Library/PrivateFrameworks/CoreUI.framework/Versions/A/CoreUI";
static const char *const kCoreUIMD5 = "321891e887e4c674a4d1667fad9427f8";   // as in LionessSetup.sh
static NSString *const kApplePage = @"https://support.apple.com/en-us/106387";

static BOOL ExistingRootIsGood(void) {
    NSData *data = [NSData dataWithContentsOfFile:kRootCoreUI options:NSDataReadingMappedIfSafe error:nil];
    if (!data) return NO;
    unsigned char digest[CC_MD5_DIGEST_LENGTH];
    CC_MD5(data.bytes, (CC_LONG)data.length, digest);
    char hex[CC_MD5_DIGEST_LENGTH * 2 + 1];
    for (int i = 0; i < CC_MD5_DIGEST_LENGTH; i++) snprintf(hex + i * 2, 3, "%02x", digest[i]);
    return strcmp(hex, kCoreUIMD5) == 0;
}

@interface LionessImagePane : InstallerPane {
    NSView *_view;
    NSButton *_keep, *_download, *_own, *_choose;
    NSTextField *_picked;
    NSString *_path, *_themes;
    NSPopUpButton *_themeChoice;
    BOOL _ammonia;
}
@end

@implementation LionessImagePane

- (NSString *)title { return @"Mountain Lion Image"; }

static NSTextField *Text(NSString *string, NSRect frame, CGFloat size, NSColor *color) {
    NSTextField *t = [NSTextField wrappingLabelWithString:string];
    t.frame = frame;
    t.font = [NSFont systemFontOfSize:size];
    t.textColor = color;
    t.selectable = NO;
    return t;
}

- (NSButton *)radio:(NSString *)title y:(CGFloat)y {
    NSButton *b = [NSButton radioButtonWithTitle:title target:self action:@selector(changed:)];
    b.frame = NSMakeRect(16, y, 380, 20);
    [_view addSubview:b];
    return b;
}

- (NSView *)contentView {
    if (_view) return _view;
    _ammonia = [NSFileManager.defaultManager fileExistsAtPath:@"/private/var/ammonia/core/tweaks"];
    _view = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 416, 328)];
    NSColor *secondary = NSColor.secondaryLabelColor;
    [_view addSubview:Text(@"Lioness draws controls with Mountain Lion's own artwork and frameworks, which come from Apple's installer image. Nothing else is taken from it, and it is not installed as a system.",
                           NSMakeRect(16, 262, 384, 56), 12, NSColor.labelColor)];
    if (!_ammonia) {   // preinstall refuses too, but only after everything else has been asked
        [_view addSubview:Text(@"Ammonia is not installed. Lioness loads through it: install Ammonia first, then open this package again.",
                               NSMakeRect(16, 220, 384, 48), 13, NSColor.systemRedColor)];
        return _view;
    }
    CGFloat y = 232;
    if (ExistingRootIsGood()) {
        _keep = [self radio:@"Keep the Mountain Lion files already installed" y:y];
        [_view addSubview:Text(@"Found from an earlier install. Nothing to download or unpack.", NSMakeRect(34, y - 18, 366, 16), 11, secondary)];
        y -= 44;
    }
    _download = [self radio:@"Download the official image from Apple" y:y];
    [_view addSubview:Text(@"4.4 GB from Apple's server, and 11 GB free while it is unpacked. It continues in the background after Installer finishes, and you are told when it is ready.",
                           NSMakeRect(34, y - 44, 366, 42), 11, secondary)];
    NSButton *link = [NSButton buttonWithTitle:@"Apple's download page" target:self action:@selector(openApple:)];
    link.bordered = NO;
    link.attributedTitle = [[NSAttributedString alloc] initWithString:@"Apple's download page"
        attributes:@{ NSForegroundColorAttributeName: NSColor.linkColor, NSFontAttributeName: [NSFont systemFontOfSize:11] }];
    link.frame = NSMakeRect(32, y - 62, 140, 16);
    [_view addSubview:link];
    y -= 84;
    _own = [self radio:@"Use a Mountain Lion image I already have" y:y];
    [_view addSubview:Text(@"Apple's InstallMacOSX.dmg. Needs 7 GB free to unpack.", NSMakeRect(34, y - 18, 366, 16), 11, secondary)];
    _choose = [NSButton buttonWithTitle:@"Choose…" target:self action:@selector(choose:)];
    _choose.frame = NSMakeRect(32, y - 50, 90, 28);
    [_view addSubview:_choose];
    _picked = Text(@"", NSMakeRect(126, y - 46, 274, 16), 11, secondary);
    _picked.lineBreakMode = NSLineBreakByTruncatingMiddle;
    [_view addSubview:_picked];
    [_view addSubview:Text(@"Flavours themes:", NSMakeRect(16, 12, 96, 16), 11, NSColor.labelColor)];
    _themeChoice = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(112, 6, 288, 26) pullsDown:NO];
    [_themeChoice addItemsWithTitles:@[ @"None", @"Download Flavours 2 (331 MB, Internet Archive)", @"Choose a zip, DMG, theme or folder…" ]];
    _themeChoice.target = self;
    _themeChoice.action = @selector(themeChoiceChanged:);
    [_view addSubview:_themeChoice];
    (_keep ?: _download).state = NSControlStateValueOn;
    [self update];
    return _view;
}

- (void)update {
    BOOL own = _own.state == NSControlStateValueOn;
    _choose.enabled = own;
    self.nextEnabled = _ammonia && (!own || _path != nil);
}

- (void)didEnterPane:(InstallerSectionDirection)dir { [self contentView]; [self update]; }
- (void)changed:(id)sender { [self update]; }
- (void)openApple:(id)sender { [NSWorkspace.sharedWorkspace openURL:[NSURL URLWithString:kApplePage]]; }

- (void)choose:(id)sender {
    NSOpenPanel *panel = [NSOpenPanel openPanel];
    panel.allowedFileTypes = @[ @"dmg" ];
    panel.message = @"Choose the Mountain Lion image (InstallMacOSX.dmg)";
    if ([panel runModal] != NSModalResponseOK) return;
    _path = panel.URL.path;
    _picked.stringValue = _path;
    [self update];
}

- (void)themeChoiceChanged:(id)sender {
    _themes = nil;
    if (_themeChoice.indexOfSelectedItem != 2) return;
    NSOpenPanel *panel = [NSOpenPanel openPanel];
    panel.allowedFileTypes = @[ @"zip", @"dmg", @"flavour", @"xml" ];
    panel.canChooseDirectories = YES;
    panel.message = @"Choose a Flavours zip or DMG, a theme, or a folder of themes";
    if ([panel runModal] != NSModalResponseOK) { [_themeChoice selectItemAtIndex:0]; return; }
    _themes = panel.URL.path;
    [_themeChoice itemAtIndex:2].title = _themes.lastPathComponent;
}

- (BOOL)shouldExitPane:(InstallerSectionDirection)dir {
    if (dir != InstallerDirectionForward) return YES;
    NSFileManager *fm = NSFileManager.defaultManager;
    [fm removeItemAtPath:kChoices error:nil];
    [fm createDirectoryAtPath:kChoices withIntermediateDirectories:YES attributes:@{ NSFilePosixPermissions: @0755 } error:nil];
    NSString *choice = @"download\n";
    if (_keep.state == NSControlStateValueOn) choice = @"keep\n";
    if (_own.state == NSControlStateValueOn) {
        choice = [NSString stringWithFormat:@"dmg\n%@\n", _path];
        // A clone costs no space and sits where the root job can read it. On another volume there is none: the job tries the path itself.
        NSString *clone = [kChoices stringByAppendingPathComponent:@"image.dmg"];
        if (clonefile(_path.fileSystemRepresentation, clone.fileSystemRepresentation, 0) != 0)
            NSLog(@"Lioness: no clone of %@: %s", _path, strerror(errno));
    }
    NSString *themeChoice = _themeChoice.indexOfSelectedItem == 1 ? @"download" : _themes;
    if (themeChoice) {
        if (_themes) {
            // Readable by the root job, as with the image. A clone costs no space; a folder is cloned as a whole.
            NSString *name = _themes.pathExtension.length ? [@"flavours-source" stringByAppendingPathExtension:_themes.pathExtension] : @"flavours-source";
            NSString *clone = [kChoices stringByAppendingPathComponent:name];
            if (clonefile(_themes.fileSystemRepresentation, clone.fileSystemRepresentation, 0) != 0)
                NSLog(@"Lioness: no clone of %@: %s", _themes, strerror(errno));
        }
        [[themeChoice stringByAppendingString:@"\n"] writeToFile:[kChoices stringByAppendingPathComponent:@"flavours"] atomically:YES encoding:NSUTF8StringEncoding error:nil];
    }
    NSError *error = nil;
    if (![choice writeToFile:[kChoices stringByAppendingPathComponent:@"choice"] atomically:YES encoding:NSUTF8StringEncoding error:&error])
        NSLog(@"Lioness: cannot record the choice: %@", error);   // postinstall asks instead
    return YES;
}

@end

@interface LionessImageSection : InstallerSection {
    LionessImagePane *_pane;
}
@end

@implementation LionessImageSection
- (BOOL)shouldLoad {
    [NSFileManager.defaultManager removeItemAtPath:kChoices error:nil];   // from an install that was cancelled
    return YES;
}
- (InstallerPane *)firstPane {
    if (!_pane) _pane = [[LionessImagePane alloc] initWithSection:self];
    return _pane;
}
@end

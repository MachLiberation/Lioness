// Mach IPC protocol between libLionessMenus.dylib (and LionessSpotlight) and the Aqua menu
// host LaunchAgent (lionessmenud). Menu requests and replies travel as binary property lists
// in an OOL descriptor.
//
// Request dictionary keys (all coordinates are AppKit screen points, origin bottom-left):
//   style            "context" | "popup" | "menubar" | "dock"
//   anchorX/Y/W/H    anchor rect. context: the click point. popup: the point the selected item's
//                    top-left goes to. menubar: the menu bar title's rect. dock: the Dock icon.
//   preferredEdge    NSRectEdge (dock: which side of the icon the bubble opens on)
//   selectedIndex    popup only: index of the item to place over the anchor
//   activeMenuBarIndex, menuBarTitles [{index, x, w}]   menubar only, for scrubbing across titles
//   items            [item]
// Item keys: id, title, enabled, state (-1/0/1), indent, separator, sectionHeader,
//   shortcutMods ("⇧⌘"), shortcutKey ("N"), iconPNG, submenu [item],
//   customViewKind ("finderTags" | "snapshot"), customViewPNG, customViewWidth, customViewHeight
// Reply keys: result, itemId, customSubIndex, clickX, clickY, switchMenuBarIndex

#ifndef LIONESS_MENU_PROTOCOL_H
#define LIONESS_MENU_PROTOCOL_H

#include <mach/message.h>
#include <stdint.h>

#define LIONESS_MENU_SERVICE      "com.lioness.menud"
#define LIONESS_MENU_TOKEN_CLASS  "com.apple.app-sandbox.mach"
#define LIONESS_MENU_TOKEN_PATH   "/private/var/ammonia/core/tweaks/.com.lioness.menud.token"

#define LIONESS_MENU_MSG_PRESENT   0x4c4d4e01   // present a menu; reply arrives when it closes
#define LIONESS_MENU_MSG_DISMISS   0x4c4d4e02   // dismiss any active menu
#define LIONESS_MENU_MSG_SPOTLIGHT 0x4c4d4e03   // flags: 0 toggle, 1 show, 2 dismiss, 3 ensure running
#define LIONESS_MENU_MSG_PING      0x4c4d4e04   // health check
#define LIONESS_MENU_MSG_KEY       0x4c4d4e05   // a key event the client's app received while a menu is open

#define LIONESS_MENU_RESULT_CANCELLED   0
#define LIONESS_MENU_RESULT_SELECTED    1
#define LIONESS_MENU_RESULT_SWITCH_BAR  2

#define LIONESS_SPOTLIGHT_TOGGLE_NOTE  "com.lioness.spotlight.toggle"
#define LIONESS_SPOTLIGHT_SHOW_NOTE    "com.lioness.spotlight.show"
#define LIONESS_SPOTLIGHT_DISMISS_NOTE "com.lioness.spotlight.dismiss"

typedef struct {
    mach_msg_header_t header;
    mach_msg_body_t body;
    mach_msg_ool_descriptor_t payload;
    uint32_t flags;
    uint32_t reserved;
} LionessMenuMachMessage;

typedef struct {
    mach_msg_header_t header;
    uint32_t flags;
    uint32_t reserved;
} LionessMenuSimpleMessage;

typedef struct {
    mach_msg_header_t header;
    uint32_t keyCode;
    uint32_t modifiers;   // NSEventModifierFlags (low 32 bits)
    uint32_t character;   // first UTF-16 unit of charactersIgnoringModifiers, or 0
    uint32_t reserved;
} LionessMenuKeyMessage;

#endif // LIONESS_MENU_PROTOCOL_H

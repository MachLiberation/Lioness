// The Mach protocol between the dylib and appkitd's guest renderer. Compiled for arm64, arm64e and x86-64,
// and laid out alike on all three: natural alignment, 32-bit fields, nothing pointer-sized outside the descriptor.

#ifndef LIONESS_PROTOCOL_H
#define LIONESS_PROTOCOL_H

#include <mach/message.h>
#include <stdint.h>

#define LIONESS_SERVICE     "com.lioness.appkitd"
#define LIONESS_MSG_RENDER  0x4c494f01   // 'LIO' 1: a control by kind, drawn with HITheme
#define LIONESS_MSG_DRAW    0x4c494f02   // AppKit's options, drawn with Lion's CUIDraw
#define LIONESS_MAX_OPTIONS 8192
// A sandbox extension for this one service, for sandboxed apps: appkitd issues it, the dylib consumes it.
#define LIONESS_TOKEN_CLASS "com.apple.app-sandbox.mach"
#define LIONESS_TOKEN_PATH  "/private/var/ammonia/core/tweaks/.com.lioness.appkitd.token"
#define LIONESS_MAX_POINTS  4096
#define LIONESS_MAX_SCALE   3

typedef enum {
    LionessPushButton = 1,
    LionessCheckBox,
    LionessRadioButton,
    LionessPopupButton,
    LionessCloseWidget,
    LionessMinimizeWidget,
    LionessZoomWidget,
    LionessWindowFrame,
    LionessScrollerTrack,
} LionessKind;

typedef enum {
    LionessStateActive = 0,
    LionessStatePressed,
    LionessStateInactive,
    LionessStateDisabled,
} LionessState;

typedef enum { LionessValueOff = 0, LionessValueOn, LionessValueMixed } LionessValue;

typedef struct {
    uint32_t kind, state, value;
    uint32_t isDefault, focused;
    uint32_t width, height;     // the control, in points
    uint32_t scale;             // pixels per point, 1 to LIONESS_MAX_SCALE
} LionessRequest;

typedef struct {
    mach_msg_header_t header;
    LionessRequest request;
} LionessRequestMessage;

// A binary property list of the CoreUI options. Message length follows `length`, rounded up to 4.
typedef struct {
    mach_msg_header_t header;
    uint32_t width, height, scale;
    uint32_t length;
    uint8_t options[LIONESS_MAX_OPTIONS];
} LionessDrawMessage;

// The bitmap: premultiplied BGRA, top row first. It is `padding` points larger than the control on every
// side, because Aqua draws shadows and glows outside its bounds.
typedef struct {
    uint32_t status;            // 0, or the OSStatus Lion returned
    uint32_t pixelWidth, pixelHeight, rowBytes;
    uint32_t padding;
    uint32_t blank;             // nothing was drawn: Lion has no such widget
} LionessImageInfo;

typedef struct {
    mach_msg_header_t header;
    mach_msg_body_t body;
    mach_msg_ool_descriptor_t pixels;
    LionessImageInfo info;
} LionessReplyMessage;

#define LIONESS_PADDING 8

// Mountain Lion's sheet effect: CoreGraphics' own MetalSheetProgress, run in the guest against a stand-in for the window
// server. The reply's descriptor is a binary property list, one array of operations per progress value asked for, then one
// for the release; `info.rowBytes` is its length. An operation is a dictionary with "op" (move, warp, order, alpha, new,
// shape, image, release, level) and "wid": 1 is the sheet, 2 its parent, anything else a window the effect made itself.
// Frames are window server coordinates: points, origin at the top left of the main display.
#define LIONESS_MSG_SHEET        0x4c494f03
#define LIONESS_MAX_SHEET_FRAMES 64
#define LIONESS_SHEET_WID        1
#define LIONESS_PARENT_WID       2

typedef struct {
    float sheet[4];             // x, y, width, height
    float parent[4];
    float leftEdge, rightEdge;  // where the sheet meets its parent, in the sheet's own x
    uint32_t frames;            // progress values that follow
    float progress[LIONESS_MAX_SHEET_FRAMES];
} LionessSheetRequest;

typedef struct {
    mach_msg_header_t header;
    LionessSheetRequest sheet;
} LionessSheetMessage;

#endif

// Shared remote state layout between skylightaugmentord (host) and the self-contained
// ARM64/ARM64e payload copied into WindowServer's address space.
// Page 0 (+0x0000, 16 KB RX): __ws_payload code + relocated original-prologue trampolines.
// Page 1 (+0x4000, 16 KB RW): WSRemoteState + Mountain Lion SArtFile.bin pixel buffer + ASCII strings.

#ifndef LIONESS_SKYLIGHT_PAYLOAD_H
#define LIONESS_SKYLIGHT_PAYLOAD_H

#include <stdint.h>

#define WS_STATE_MAGIC     0x4C494F4E534B5931ULL  // "LIONSKY1"
#define WS_STATE_VERSION   7U
#define WS_PAYLOAD_PAGE_SZ 0x4000U                // 16 KB Apple Silicon page
#define WS_BAR_W_2X        2U
#define WS_BAR_H_2X        42U                    // Pure 42 px SArtFile 0x4e50+0x4e8d gradient (hairline is separate 1pt layer)
#define WS_BAR_BYTES_2X    (WS_BAR_W_2X * WS_BAR_H_2X * 4U)
#define WS_HAIRLINE_BYTES  (2U * 2U * 4U)         // 2x2 premultiplied BGRA8888 rgba(0,0,0,0.55)

typedef struct WSContextOffsets {
    uint32_t off_root;
    uint32_t off_backstop_fs;
    uint32_t off_backstop_ax;
    uint32_t off_desktop_capture;
    uint32_t off_desktop_enh;
    uint32_t _pad;
} WSContextOffsets;

typedef struct __attribute__((aligned(16))) WSRemoteState {
    uint64_t magic;
    uint32_t version;
    uint32_t enabled;
    volatile uint32_t initialized;
    volatile uint32_t configGen;
    volatile uint32_t appliedGen;
    volatile uint32_t solUpdateCount;
    volatile uint32_t solReshapeCount;
    volatile uint32_t qfaUpdateCount;
    volatile uint32_t qfaReshapeCount;
    volatile uint32_t styledCount;
    volatile uint32_t lastW;
    volatile uint32_t lastH;
    volatile uint32_t lastFlags;
    uint32_t _pad0;

    // Dynamically discovered CALayer* field offsets for both Solarium and LiveActivitiesQFA contexts.
    WSContextOffsets solOffsets;
    WSContextOffsets qfaOffsets;

    // Tunable Mountain Lion menu bar parameters (all derived from ml-root).
    float blurRadius;         // Gaussian blur radius behind the translucent white-glass veil
    float saturationAmount;   // Subtle saturation lift for wallpaper color behind translucent bar
    float brightnessLift;     // Frosted white floor lift so dark wallpapers stay crisp Mountain Lion silver-white
    float shadowDensity;      // Mountain Lion CoreGraphics menu bar drop shadow density (0.75)

    // Relocated original-prologue trampolines inside Page 0 (unsigned raw addresses).
    uint64_t orig_sol_update;
    uint64_t orig_sol_reshape;
    uint64_t orig_qfa_update;
    uint64_t orig_qfa_reshape;

    // Resolved unsigned (PAC-stripped) function pointers in WindowServer's shared cache.
    uint64_t fn_objc_msgSend;
    uint64_t fn_objc_getClass;
    uint64_t fn_sel_registerName;
    uint64_t fn_CGColorSpaceCreateDeviceRGB;
    uint64_t fn_CGColorSpaceRelease;
    uint64_t fn_CGDataProviderCreateWithData;
    uint64_t fn_CGDataProviderRelease;
    uint64_t fn_CGImageCreate;
    uint64_t fn_CFStringCreateWithCString;
    uint64_t fn_CFRelease;
    uint64_t fn_set_shadow_properties;
    uint64_t fn_ca_manager;
    uint64_t fn_invalidate_state_seed;

    // Lazily initialized ObjC classes, selectors, and cached CA/CG objects inside WindowServer.
    void *cls_CATransaction;
    void *cls_CALayer;
    void *cls_CABackdropLayer;
    void *cls_CAFilter;
    void *cls_NSNumber;
    void *cls_NSArray;
    void *cls_NSDictionary;
    void *cls_NSNull;

    void *sel_begin;
    void *sel_commit;
    void *sel_setDisableActions;
    void *sel_layer;
    void *sel_sublayers;
    void *sel_count;
    void *sel_objectAtIndex;
    void *sel_name;
    void *sel_isEqualToString;
    void *sel_isHidden;
    void *sel_setHidden;
    void *sel_opacity;
    void *sel_bounds;
    void *sel_setFrame;
    void *sel_setName;
    void *sel_setContents;
    void *sel_setContentsScale;
    void *sel_setContentsGravity;
    void *sel_setContentsCenter;
    void *sel_setFilters;
    void *sel_setActions;
    void *sel_setZPosition;
    void *sel_setMasksToBounds;
    void *sel_insertSublayerAtIndex;
    void *sel_filterWithType;
    void *sel_setValueForKey;
    void *sel_numberWithDouble;
    void *sel_numberWithBool;
    void *sel_arrayWithObjectsCount;
    void *sel_dictionaryWithObjectsForKeysCount;
    void *sel_null;
    void *sel_hasPrefix;
    void *sel_retain;
    void *sel_isGeometryFlipped;
    void *sel_context;
    void *sel_setCommittingContexts;
    void *sel_flush;
    void *sel_setBleedAmount;
    void *sel_setMarginWidth;

    double zBackdrop;
    double zGloss;
    double zHairline;

    void *cachedBarImage;       // CGImageRef (2x42 premultiplied BGRA8888 from ml-root SArtFile.bin)
    void *cachedHairlineImage;  // CGImageRef (2x2 premultiplied rgba(0,0,0,0.45))
    void *cachedFilters;        // NSArray* ([gaussianBlur, colorSaturate, colorBrightness])
    void *cachedActions;        // NSDictionary* (disables implicit CA animations)
    void *strClipName;          // CFString "lioness.ws.clip"
    void *strBackdropName;      // CFString "lioness.ws.backdrop"
    void *strGlossName;         // CFString "lioness.ws.gloss"
    void *strHairlineName;      // CFString "lioness.ws.hairline"
    void *strGravityResize;     // CFString "resize"
    void *strPkgPrefix;         // CFString "menubar."
    void *strAuxShadowPrefix;   // CFString "menubar.aux."

    // Mountain Lion 2x42 premultiplied BGRA8888 texture extracted from ml-root SArtFile.bin + 2x2 hairline.
    uint8_t barPixels2x[WS_BAR_BYTES_2X];
    uint8_t hairlinePixels[WS_HAIRLINE_BYTES];

    // Embedded ASCII strings so the RX payload has ZERO external __cstring relocations.
    char ascii_CATransaction[24];
    char ascii_CALayer[16];
    char ascii_CABackdropLayer[24];
    char ascii_CAFilter[16];
    char ascii_NSNumber[16];
    char ascii_NSArray[16];
    char ascii_NSDictionary[24];
    char ascii_NSNull[16];

    char ascii_begin[16];
    char ascii_commit[16];
    char ascii_setDisableActions[24];
    char ascii_layer[16];
    char ascii_sublayers[16];
    char ascii_count[16];
    char ascii_objectAtIndex[24];
    char ascii_name[16];
    char ascii_isEqualToString[24];
    char ascii_isHidden[16];
    char ascii_setHidden[16];
    char ascii_opacity[16];
    char ascii_bounds[16];
    char ascii_setFrame[16];
    char ascii_setName[16];
    char ascii_setContents[16];
    char ascii_setContentsScale[24];
    char ascii_setContentsGravity[24];
    char ascii_setContentsCenter[24];
    char ascii_setFilters[16];
    char ascii_setActions[16];
    char ascii_setZPosition[24];
    char ascii_setMasksToBounds[24];
    char ascii_insertSublayerAtIndex[32];
    char ascii_filterWithType[24];
    char ascii_setValueForKey[24];
    char ascii_numberWithDouble[24];
    char ascii_numberWithBool[24];
    char ascii_arrayWithObjectsCount[32];
    char ascii_dictWithObjectsForKeysCount[40];
    char ascii_null[16];
    char ascii_hasPrefix[16];
    char ascii_retain[16];
    char ascii_isGeometryFlipped[24];
    char ascii_context[16];
    char ascii_setCommittingContexts[32];
    char ascii_flush[16];
    char ascii_setBleedAmount[24];
    char ascii_setMarginWidth[24];

    char ascii_clipName[32];
    char ascii_backdropName[32];
    char ascii_glossName[32];
    char ascii_hairlineName[32];
    char ascii_gaussianBlur[24];
    char ascii_colorSaturate[24];
    char ascii_colorBrightness[24];
    char ascii_inputRadius[24];
    char ascii_inputNormalizeEdges[24];
    char ascii_inputHardEdges[24];
    char ascii_inputDither[24];
    char ascii_inputAmount[24];
    char ascii_resize[16];
    char ascii_actBounds[16];
    char ascii_actPosition[16];
    char ascii_actContents[16];
    char ascii_actHidden[16];
    char ascii_actFrame[16];
    char ascii_menubarPrefix[16];
    char ascii_auxShadowPrefix[16];
} WSRemoteState;

#ifdef __cplusplus
extern "C" {
#endif

// Entry points placed in __TEXT,__ws_payload.
void LionessWSPayloadSolUpdateEntry(void);
void LionessWSPayloadSolReshapeEntry(void);
void LionessWSPayloadQfaUpdateEntry(void);
void LionessWSPayloadQfaReshapeEntry(void);

#ifdef __cplusplus
}
#endif

#endif // LIONESS_SKYLIGHT_PAYLOAD_H

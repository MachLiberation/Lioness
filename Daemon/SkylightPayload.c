// Self-contained ARM64/ARM64e payload compiled into __TEXT,__ws_payload and copied into
// WindowServer's own allocated RX page by skylightaugmentord.
//
// Invariants:
// - ZERO external symbol references, ZERO GOT/cstring/literal-pool references outside __ws_payload.
// - All external calls use unsigned `blr x16` (works on both arm64 and arm64e regardless of per-process PAC keys).
// - All state and ml-root pixel data live on the adjacent RW page at (page0_base + 0x4000).
// - Completely independent of skylightaugmentord's lifetime: WindowServer keeps running if skylightaugmentord exits.

#include "SkylightPayload.h"
#include <stddef.h>

#define WS_PAYLOAD_FN __attribute__((section("__TEXT,__ws_payload,regular,pure_instructions"), noinline, used))

typedef struct {
    double x, y, w, h;
} WSRect;

// Returns the adjacent RW WSRemoteState page at (this_page_base + WS_PAYLOAD_PAGE_SZ).
static inline WSRemoteState *GetState(void) {
    uintptr_t pc;
    __asm__ volatile("adr %0, ." : "=r"(pc));
    return (WSRemoteState *)((pc & ~(uintptr_t)(WS_PAYLOAD_PAGE_SZ - 1)) + WS_PAYLOAD_PAGE_SZ);
}

// Unsigned indirect calls (safe across processes on arm64e where PAC keys differ).
static inline void *Call0(uint64_t fn) {
    register uint64_t x16 __asm__("x16") = fn;
    register uint64_t x0 __asm__("x0");
    __asm__ volatile("blr x16" : "=r"(x0) : "r"(x16)
                     : "x1","x2","x3","x4","x5","x6","x7","x8","x9","x10","x11","x12","x13","x14","x15","x17","x30","memory","cc",
                       "v0","v1","v2","v3","v4","v5","v6","v7","v16","v17","v18","v19","v20","v21","v22","v23","v24","v25","v26","v27","v28","v29","v30","v31");
    return (void *)x0;
}

static inline void *Call1(uint64_t fn, uint64_t a0) {
    register uint64_t x16 __asm__("x16") = fn;
    register uint64_t x0 __asm__("x0") = a0;
    __asm__ volatile("blr x16" : "+r"(x0) : "r"(x16)
                     : "x1","x2","x3","x4","x5","x6","x7","x8","x9","x10","x11","x12","x13","x14","x15","x17","x30","memory","cc",
                       "v0","v1","v2","v3","v4","v5","v6","v7","v16","v17","v18","v19","v20","v21","v22","v23","v24","v25","v26","v27","v28","v29","v30","v31");
    return (void *)x0;
}

static inline void *Call2(uint64_t fn, uint64_t a0, uint64_t a1) {
    register uint64_t x16 __asm__("x16") = fn;
    register uint64_t x0 __asm__("x0") = a0;
    register uint64_t x1 __asm__("x1") = a1;
    __asm__ volatile("blr x16" : "+r"(x0), "+r"(x1) : "r"(x16)
                     : "x2","x3","x4","x5","x6","x7","x8","x9","x10","x11","x12","x13","x14","x15","x17","x30","memory","cc",
                       "v0","v1","v2","v3","v4","v5","v6","v7","v16","v17","v18","v19","v20","v21","v22","v23","v24","v25","v26","v27","v28","v29","v30","v31");
    return (void *)x0;
}

static inline void *Call3(uint64_t fn, uint64_t a0, uint64_t a1, uint64_t a2) {
    register uint64_t x16 __asm__("x16") = fn;
    register uint64_t x0 __asm__("x0") = a0;
    register uint64_t x1 __asm__("x1") = a1;
    register uint64_t x2 __asm__("x2") = a2;
    __asm__ volatile("blr x16" : "+r"(x0), "+r"(x1), "+r"(x2) : "r"(x16)
                     : "x3","x4","x5","x6","x7","x8","x9","x10","x11","x12","x13","x14","x15","x17","x30","memory","cc",
                       "v0","v1","v2","v3","v4","v5","v6","v7","v16","v17","v18","v19","v20","v21","v22","v23","v24","v25","v26","v27","v28","v29","v30","v31");
    return (void *)x0;
}

static inline void *Call4(uint64_t fn, uint64_t a0, uint64_t a1, uint64_t a2, uint64_t a3) {
    register uint64_t x16 __asm__("x16") = fn;
    register uint64_t x0 __asm__("x0") = a0;
    register uint64_t x1 __asm__("x1") = a1;
    register uint64_t x2 __asm__("x2") = a2;
    register uint64_t x3 __asm__("x3") = a3;
    __asm__ volatile("blr x16" : "+r"(x0), "+r"(x1), "+r"(x2), "+r"(x3) : "r"(x16)
                     : "x4","x5","x6","x7","x8","x9","x10","x11","x12","x13","x14","x15","x17","x30","memory","cc",
                       "v0","v1","v2","v3","v4","v5","v6","v7","v16","v17","v18","v19","v20","v21","v22","v23","v24","v25","v26","v27","v28","v29","v30","v31");
    return (void *)x0;
}

static inline void *Call5(uint64_t fn, uint64_t a0, uint64_t a1, uint64_t a2, uint64_t a3, uint64_t a4) {
    register uint64_t x16 __asm__("x16") = fn;
    register uint64_t x0 __asm__("x0") = a0;
    register uint64_t x1 __asm__("x1") = a1;
    register uint64_t x2 __asm__("x2") = a2;
    register uint64_t x3 __asm__("x3") = a3;
    register uint64_t x4 __asm__("x4") = a4;
    __asm__ volatile("blr x16" : "+r"(x0), "+r"(x1), "+r"(x2), "+r"(x3), "+r"(x4) : "r"(x16)
                     : "x5","x6","x7","x8","x9","x10","x11","x12","x13","x14","x15","x17","x30","memory","cc",
                       "v0","v1","v2","v3","v4","v5","v6","v7","v16","v17","v18","v19","v20","v21","v22","v23","v24","v25","v26","v27","v28","v29","v30","v31");
    return (void *)x0;
}

static inline void *CallDoubleArg(uint64_t fn, uint64_t a0, uint64_t a1, double d) {
    register uint64_t x16 __asm__("x16") = fn;
    register uint64_t x0 __asm__("x0") = a0;
    register uint64_t x1 __asm__("x1") = a1;
    register double d0 __asm__("d0") = d;
    __asm__ volatile("blr x16" : "+r"(x0), "+r"(x1), "+w"(d0) : "r"(x16)
                     : "x2","x3","x4","x5","x6","x7","x8","x9","x10","x11","x12","x13","x14","x15","x17","x30","memory","cc",
                       "v1","v2","v3","v4","v5","v6","v7","v16","v17","v18","v19","v20","v21","v22","v23","v24","v25","v26","v27","v28","v29","v30","v31");
    return (void *)x0;
}

static inline float CallRetFloat(uint64_t fn, uint64_t a0, uint64_t a1) {
    register uint64_t x16 __asm__("x16") = fn;
    register uint64_t x0 __asm__("x0") = a0;
    register uint64_t x1 __asm__("x1") = a1;
    register float s0 __asm__("s0");
    __asm__ volatile("blr x16" : "=w"(s0), "+r"(x0), "+r"(x1) : "r"(x16)
                     : "x2","x3","x4","x5","x6","x7","x8","x9","x10","x11","x12","x13","x14","x15","x17","x30","memory","cc",
                       "v1","v2","v3","v4","v5","v6","v7","v16","v17","v18","v19","v20","v21","v22","v23","v24","v25","v26","v27","v28","v29","v30","v31");
    return s0;
}

static inline void CallShadowProps(uint64_t fn, float density, void *win) {
    register uint64_t x16 __asm__("x16") = fn;
    register float s0 __asm__("s0") = density;
    register uint64_t x0 __asm__("x0") = (uint64_t)win;
    __asm__ volatile("blr x16" : "+w"(s0), "+r"(x0) : "r"(x16)
                     : "x1","x2","x3","x4","x5","x6","x7","x8","x9","x10","x11","x12","x13","x14","x15","x17","x30","memory","cc",
                       "v1","v2","v3","v4","v5","v6","v7","v16","v17","v18","v19","v20","v21","v22","v23","v24","v25","v26","v27","v28","v29","v30","v31");
}

static inline WSRect CallRetRect(uint64_t fn, uint64_t a0, uint64_t a1) {
    register uint64_t x16 __asm__("x16") = fn;
    register uint64_t x0 __asm__("x0") = a0;
    register uint64_t x1 __asm__("x1") = a1;
    register double d0 __asm__("d0");
    register double d1 __asm__("d1");
    register double d2 __asm__("d2");
    register double d3 __asm__("d3");
    __asm__ volatile("blr x16" : "=w"(d0), "=w"(d1), "=w"(d2), "=w"(d3), "+r"(x0), "+r"(x1) : "r"(x16)
                     : "x2","x3","x4","x5","x6","x7","x8","x9","x10","x11","x12","x13","x14","x15","x17","x30","memory","cc",
                       "v4","v5","v6","v7","v16","v17","v18","v19","v20","v21","v22","v23","v24","v25","v26","v27","v28","v29","v30","v31");
    WSRect r = { d0, d1, d2, d3 };
    return r;
}

static inline void CallRectArg(uint64_t fn, uint64_t a0, uint64_t a1, WSRect r) {
    register uint64_t x16 __asm__("x16") = fn;
    register uint64_t x0 __asm__("x0") = a0;
    register uint64_t x1 __asm__("x1") = a1;
    register double d0 __asm__("d0") = r.x;
    register double d1 __asm__("d1") = r.y;
    register double d2 __asm__("d2") = r.w;
    register double d3 __asm__("d3") = r.h;
    __asm__ volatile("blr x16" : "+r"(x0), "+r"(x1), "+w"(d0), "+w"(d1), "+w"(d2), "+w"(d3) : "r"(x16)
                     : "x2","x3","x4","x5","x6","x7","x8","x9","x10","x11","x12","x13","x14","x15","x17","x30","memory","cc",
                       "v4","v5","v6","v7","v16","v17","v18","v19","v20","v21","v22","v23","v24","v25","v26","v27","v28","v29","v30","v31");
}

// CGImageCreate takes 11 args: x0..x7 + 3 stack slots (8 bytes each, 16-byte aligned SP).
WS_PAYLOAD_FN
static void *CallCGImageCreate(uint64_t fn,
                               uint64_t w, uint64_t h, uint64_t bpc, uint64_t bpp,
                               uint64_t rowBytes, void *space, uint32_t bitmapInfo, void *provider,
                               void *decode, uint32_t shouldInterpolate, uint32_t intent) {
    register uint64_t x16 __asm__("x16") = fn;
    register uint64_t x0 __asm__("x0") = w;
    register uint64_t x1 __asm__("x1") = h;
    register uint64_t x2 __asm__("x2") = bpc;
    register uint64_t x3 __asm__("x3") = bpp;
    register uint64_t x4 __asm__("x4") = rowBytes;
    register uint64_t x5 __asm__("x5") = (uint64_t)space;
    register uint64_t x6 __asm__("x6") = bitmapInfo;
    register uint64_t x7 __asm__("x7") = (uint64_t)provider;
    register uint64_t s0 __asm__("x9") = (uint64_t)decode;
    register uint64_t s1 __asm__("x10") = shouldInterpolate;
    register uint64_t s2 __asm__("x11") = intent;
    __asm__ volatile(
        "sub sp, sp, #32\n"
        "str %[s0], [sp, #0]\n"
        "str %[s1], [sp, #8]\n"
        "str %[s2], [sp, #16]\n"
        "blr x16\n"
        "add sp, sp, #32\n"
        : "+r"(x0), "+r"(x1), "+r"(x2), "+r"(x3), "+r"(x4), "+r"(x5), "+r"(x6), "+r"(x7)
        : "r"(x16), [s0]"r"(s0), [s1]"r"(s1), [s2]"r"(s2)
        : "x8","x12","x13","x14","x15","x17","x30","memory","cc",
          "v0","v1","v2","v3","v4","v5","v6","v7","v16","v17","v18","v19","v20","v21","v22","v23","v24","v25","v26","v27","v28","v29","v30","v31");
    return (void *)x0;
}

WS_PAYLOAD_FN
static void *MakeCFStr(WSRemoteState *st, const char *cstr) {
    // kCFStringEncodingUTF8 = 0x08000100
    return Call3(st->fn_CFStringCreateWithCString, 0, (uint64_t)cstr, 0x08000100ULL);
}

WS_PAYLOAD_FN
static void RebuildVisualAssets(WSRemoteState *st) {
    // Build CGImageRef backed directly by state->barPixels2x (lives forever in WindowServer's RW page).
    // kCGImageAlphaPremultipliedFirst (2) | kCGBitmapByteOrder32Little (2 << 12 = 0x2000) = 0x2002.
    void *space = Call0(st->fn_CGColorSpaceCreateDeviceRGB);
    void *prov  = Call4(st->fn_CGDataProviderCreateWithData, 0, (uint64_t)st->barPixels2x, WS_BAR_BYTES_2X, 0);
    if (space && prov) {
        void *img = CallCGImageCreate(st->fn_CGImageCreate,
            WS_BAR_W_2X, WS_BAR_H_2X, 8, 32, WS_BAR_W_2X * 4, space, 0x2002U, prov, 0, 1, 0);
        if (img) st->cachedBarImage = img;
    }
    if (prov) Call1(st->fn_CGDataProviderRelease, (uint64_t)prov);

    void *hProv = Call4(st->fn_CGDataProviderCreateWithData, 0, (uint64_t)st->hairlinePixels, WS_HAIRLINE_BYTES, 0);
    if (space && hProv) {
        void *hImg = CallCGImageCreate(st->fn_CGImageCreate,
            2, 2, 8, 32, 8, space, 0x2002U, hProv, 0, 0, 0);
        if (hImg) st->cachedHairlineImage = hImg;
    }
    if (hProv) Call1(st->fn_CGDataProviderRelease, (uint64_t)hProv);
    if (space) Call1(st->fn_CGColorSpaceRelease, (uint64_t)space);

    // Build Mountain Lion backdrop blur + subtle saturation + frosted brightness lift CAFilter array.
    if (st->cls_CAFilter && st->cls_NSNumber && st->cls_NSArray) {
        void *sBlur = MakeCFStr(st, st->ascii_gaussianBlur);
        void *sSat  = MakeCFStr(st, st->ascii_colorSaturate);
        void *sBrt  = MakeCFStr(st, st->ascii_colorBrightness);
        void *sRad  = MakeCFStr(st, st->ascii_inputRadius);
        void *sNorm = MakeCFStr(st, st->ascii_inputNormalizeEdges);
        void *sHard = MakeCFStr(st, st->ascii_inputHardEdges);
        void *sDith = MakeCFStr(st, st->ascii_inputDither);
        void *sAmt  = MakeCFStr(st, st->ascii_inputAmount);

        void *fBlur = Call3(st->fn_objc_msgSend, (uint64_t)st->cls_CAFilter, (uint64_t)st->sel_filterWithType, (uint64_t)sBlur);
        if (fBlur) {
            void *nRad  = CallDoubleArg(st->fn_objc_msgSend, (uint64_t)st->cls_NSNumber, (uint64_t)st->sel_numberWithDouble, (double)st->blurRadius);
            void *nYes  = Call3(st->fn_objc_msgSend, (uint64_t)st->cls_NSNumber, (uint64_t)st->sel_numberWithBool, 1);
            Call4(st->fn_objc_msgSend, (uint64_t)fBlur, (uint64_t)st->sel_setValueForKey, (uint64_t)nRad, (uint64_t)sRad);
            Call4(st->fn_objc_msgSend, (uint64_t)fBlur, (uint64_t)st->sel_setValueForKey, (uint64_t)nYes, (uint64_t)sNorm);
            Call4(st->fn_objc_msgSend, (uint64_t)fBlur, (uint64_t)st->sel_setValueForKey, (uint64_t)nYes, (uint64_t)sHard);
            Call4(st->fn_objc_msgSend, (uint64_t)fBlur, (uint64_t)st->sel_setValueForKey, (uint64_t)nYes, (uint64_t)sDith);
        }
        void *fSat = Call3(st->fn_objc_msgSend, (uint64_t)st->cls_CAFilter, (uint64_t)st->sel_filterWithType, (uint64_t)sSat);
        if (fSat) {
            void *nAmt = CallDoubleArg(st->fn_objc_msgSend, (uint64_t)st->cls_NSNumber, (uint64_t)st->sel_numberWithDouble, (double)st->saturationAmount);
            Call4(st->fn_objc_msgSend, (uint64_t)fSat, (uint64_t)st->sel_setValueForKey, (uint64_t)nAmt, (uint64_t)sAmt);
        }
        void *fBrt = Call3(st->fn_objc_msgSend, (uint64_t)st->cls_CAFilter, (uint64_t)st->sel_filterWithType, (uint64_t)sBrt);
        if (fBrt) {
            void *nBrt = CallDoubleArg(st->fn_objc_msgSend, (uint64_t)st->cls_NSNumber, (uint64_t)st->sel_numberWithDouble, (double)st->brightnessLift);
            Call4(st->fn_objc_msgSend, (uint64_t)fBrt, (uint64_t)st->sel_setValueForKey, (uint64_t)nBrt, (uint64_t)sAmt);
        }
        void *items[3];
        uint64_t n = 0;
        if (fBlur) items[n++] = fBlur;
        if (fSat)  items[n++] = fSat;
        if (fBrt)  items[n++] = fBrt;
        if (n > 0) {
            void *arr = Call4(st->fn_objc_msgSend, (uint64_t)st->cls_NSArray, (uint64_t)st->sel_arrayWithObjectsCount, (uint64_t)items, n);
            if (arr) {
                Call2(st->fn_objc_msgSend, (uint64_t)arr, (uint64_t)st->sel_retain);
                st->cachedFilters = arr;
            }
        }
        if (sBlur) Call1(st->fn_CFRelease, (uint64_t)sBlur);
        if (sSat)  Call1(st->fn_CFRelease, (uint64_t)sSat);
        if (sBrt)  Call1(st->fn_CFRelease, (uint64_t)sBrt);
        if (sRad)  Call1(st->fn_CFRelease, (uint64_t)sRad);
        if (sNorm) Call1(st->fn_CFRelease, (uint64_t)sNorm);
        if (sHard) Call1(st->fn_CFRelease, (uint64_t)sHard);
        if (sDith) Call1(st->fn_CFRelease, (uint64_t)sDith);
        if (sAmt)  Call1(st->fn_CFRelease, (uint64_t)sAmt);
    }
    st->appliedGen = st->configGen;
}

WS_PAYLOAD_FN
static void EnsureInitialized(WSRemoteState *st) {
    if (!st->initialized) {
        st->cls_CATransaction  = Call1(st->fn_objc_getClass, (uint64_t)st->ascii_CATransaction);
        st->cls_CALayer        = Call1(st->fn_objc_getClass, (uint64_t)st->ascii_CALayer);
        st->cls_CABackdropLayer= Call1(st->fn_objc_getClass, (uint64_t)st->ascii_CABackdropLayer);
        st->cls_CAFilter       = Call1(st->fn_objc_getClass, (uint64_t)st->ascii_CAFilter);
        st->cls_NSNumber       = Call1(st->fn_objc_getClass, (uint64_t)st->ascii_NSNumber);
        st->cls_NSArray        = Call1(st->fn_objc_getClass, (uint64_t)st->ascii_NSArray);
        st->cls_NSDictionary   = Call1(st->fn_objc_getClass, (uint64_t)st->ascii_NSDictionary);
        st->cls_NSNull         = Call1(st->fn_objc_getClass, (uint64_t)st->ascii_NSNull);

        st->sel_begin                  = Call1(st->fn_sel_registerName, (uint64_t)st->ascii_begin);
        st->sel_commit                 = Call1(st->fn_sel_registerName, (uint64_t)st->ascii_commit);
        st->sel_setDisableActions      = Call1(st->fn_sel_registerName, (uint64_t)st->ascii_setDisableActions);
        st->sel_layer                  = Call1(st->fn_sel_registerName, (uint64_t)st->ascii_layer);
        st->sel_sublayers              = Call1(st->fn_sel_registerName, (uint64_t)st->ascii_sublayers);
        st->sel_count                  = Call1(st->fn_sel_registerName, (uint64_t)st->ascii_count);
        st->sel_objectAtIndex          = Call1(st->fn_sel_registerName, (uint64_t)st->ascii_objectAtIndex);
        st->sel_name                   = Call1(st->fn_sel_registerName, (uint64_t)st->ascii_name);
        st->sel_isEqualToString        = Call1(st->fn_sel_registerName, (uint64_t)st->ascii_isEqualToString);
        st->sel_isHidden               = Call1(st->fn_sel_registerName, (uint64_t)st->ascii_isHidden);
        st->sel_setHidden              = Call1(st->fn_sel_registerName, (uint64_t)st->ascii_setHidden);
        st->sel_opacity                = Call1(st->fn_sel_registerName, (uint64_t)st->ascii_opacity);
        st->sel_bounds                 = Call1(st->fn_sel_registerName, (uint64_t)st->ascii_bounds);
        st->sel_setFrame               = Call1(st->fn_sel_registerName, (uint64_t)st->ascii_setFrame);
        st->sel_setName                = Call1(st->fn_sel_registerName, (uint64_t)st->ascii_setName);
        st->sel_setContents            = Call1(st->fn_sel_registerName, (uint64_t)st->ascii_setContents);
        st->sel_setContentsScale       = Call1(st->fn_sel_registerName, (uint64_t)st->ascii_setContentsScale);
        st->sel_setContentsGravity     = Call1(st->fn_sel_registerName, (uint64_t)st->ascii_setContentsGravity);
        st->sel_setContentsCenter      = Call1(st->fn_sel_registerName, (uint64_t)st->ascii_setContentsCenter);
        st->sel_setFilters             = Call1(st->fn_sel_registerName, (uint64_t)st->ascii_setFilters);
        st->sel_setActions             = Call1(st->fn_sel_registerName, (uint64_t)st->ascii_setActions);
        st->sel_setZPosition           = Call1(st->fn_sel_registerName, (uint64_t)st->ascii_setZPosition);
        st->sel_setMasksToBounds       = Call1(st->fn_sel_registerName, (uint64_t)st->ascii_setMasksToBounds);
        st->sel_insertSublayerAtIndex  = Call1(st->fn_sel_registerName, (uint64_t)st->ascii_insertSublayerAtIndex);
        st->sel_filterWithType         = Call1(st->fn_sel_registerName, (uint64_t)st->ascii_filterWithType);
        st->sel_setValueForKey         = Call1(st->fn_sel_registerName, (uint64_t)st->ascii_setValueForKey);
        st->sel_numberWithDouble       = Call1(st->fn_sel_registerName, (uint64_t)st->ascii_numberWithDouble);
        st->sel_numberWithBool         = Call1(st->fn_sel_registerName, (uint64_t)st->ascii_numberWithBool);
        st->sel_arrayWithObjectsCount  = Call1(st->fn_sel_registerName, (uint64_t)st->ascii_arrayWithObjectsCount);
        st->sel_dictionaryWithObjectsForKeysCount = Call1(st->fn_sel_registerName, (uint64_t)st->ascii_dictWithObjectsForKeysCount);
        st->sel_null                   = Call1(st->fn_sel_registerName, (uint64_t)st->ascii_null);
        st->sel_hasPrefix              = Call1(st->fn_sel_registerName, (uint64_t)st->ascii_hasPrefix);
        st->sel_retain                 = Call1(st->fn_sel_registerName, (uint64_t)st->ascii_retain);
        st->sel_isGeometryFlipped      = Call1(st->fn_sel_registerName, (uint64_t)st->ascii_isGeometryFlipped);
        st->sel_context                = Call1(st->fn_sel_registerName, (uint64_t)st->ascii_context);
        st->sel_setCommittingContexts  = Call1(st->fn_sel_registerName, (uint64_t)st->ascii_setCommittingContexts);
        st->sel_flush                  = Call1(st->fn_sel_registerName, (uint64_t)st->ascii_flush);
        st->sel_setBleedAmount         = Call1(st->fn_sel_registerName, (uint64_t)st->ascii_setBleedAmount);
        st->sel_setMarginWidth         = Call1(st->fn_sel_registerName, (uint64_t)st->ascii_setMarginWidth);

        st->strClipName        = MakeCFStr(st, st->ascii_clipName);
        st->strBackdropName    = MakeCFStr(st, st->ascii_backdropName);
        st->strGlossName       = MakeCFStr(st, st->ascii_glossName);
        st->strHairlineName    = MakeCFStr(st, st->ascii_hairlineName);
        st->strGravityResize   = MakeCFStr(st, st->ascii_resize);
        st->strPkgPrefix       = MakeCFStr(st, st->ascii_menubarPrefix);
        st->strAuxShadowPrefix = MakeCFStr(st, st->ascii_auxShadowPrefix);

        // Build actions dictionary disabling implicit animations on our layers.
        if (st->cls_NSDictionary && st->cls_NSNull) {
            void *nsNull = Call2(st->fn_objc_msgSend, (uint64_t)st->cls_NSNull, (uint64_t)st->sel_null);
            void *keys[5] = {
                MakeCFStr(st, st->ascii_actBounds),
                MakeCFStr(st, st->ascii_actPosition),
                MakeCFStr(st, st->ascii_actContents),
                MakeCFStr(st, st->ascii_actHidden),
                MakeCFStr(st, st->ascii_actFrame),
            };
            void *vals[5] = { nsNull, nsNull, nsNull, nsNull, nsNull };
            void *dict = Call5(st->fn_objc_msgSend, (uint64_t)st->cls_NSDictionary,
                               (uint64_t)st->sel_dictionaryWithObjectsForKeysCount,
                               (uint64_t)vals, (uint64_t)keys, 5);
            if (dict) Call2(st->fn_objc_msgSend, (uint64_t)dict, (uint64_t)st->sel_retain);
            st->cachedActions = dict;
            for (int i = 0; i < 5; i++) if (keys[i]) Call1(st->fn_CFRelease, (uint64_t)keys[i]);
        }

        RebuildVisualAssets(st);
        // Broadcast updated CGSDisplaySystemState (menubarHeight=24) to ControlCenter & all apps.
        if (st->fn_ca_manager && st->fn_invalidate_state_seed) {
            void *mgr = Call0(st->fn_ca_manager);
            if (mgr) Call2(st->fn_invalidate_state_seed, (uint64_t)mgr, 1);
        }
        st->initialized = 1;
    } else if (st->appliedGen != st->configGen) {
        RebuildVisualAssets(st);
        if (st->fn_ca_manager && st->fn_invalidate_state_seed) {
            void *mgr = Call0(st->fn_ca_manager);
            if (mgr) Call2(st->fn_invalidate_state_seed, (uint64_t)mgr, 1);
        }
    }
}

// Re-usable helper: applies Mountain Lion translucent blurred backdrop + SArtFile.bin gloss + shadow
// to either SolariumMenuBarContext (isQfa=0) or LiveActivitiesQFAMenuBarContext (isQfa=1).
WS_PAYLOAD_FN __attribute__((visibility("hidden")))
void LionessStyleMenuBar(void *ctx, void *cgx_window, int fromReshape, int isQfa) {
    WSRemoteState *st = GetState();
    if (!st || st->magic != WS_STATE_MAGIC || !st->enabled || !ctx) return;

    if (isQfa) {
        if (fromReshape) st->qfaReshapeCount++;
        else st->qfaUpdateCount++;
    } else {
        if (fromReshape) st->solReshapeCount++;
        else st->solUpdateCount++;
    }

    int needsRefresh = (st->initialized && st->appliedGen != st->configGen);
    EnsureInitialized(st);
    if (!st->cls_CATransaction || !st->cls_CALayer) return;

    const WSContextOffsets *off = isQfa ? &st->qfaOffsets : &st->solOffsets;
    if (!off->off_root) return;

    void *root       = *(void **)((char *)ctx + off->off_root);
    void *backstopFS = off->off_backstop_fs     ? *(void **)((char *)ctx + off->off_backstop_fs)     : NULL;
    void *backstopAX = off->off_backstop_ax     ? *(void **)((char *)ctx + off->off_backstop_ax)     : NULL;
    void *desktopCap = off->off_desktop_capture ? *(void **)((char *)ctx + off->off_desktop_capture) : NULL;
    void *desktopEnh = off->off_desktop_enh     ? *(void **)((char *)ctx + off->off_desktop_enh)     : NULL;
    if (!root) return;

    // Detect fullscreen black backstop: don't paint light translucent bar over fullscreen black space.
    int isFullScreen = 0;
    if (backstopFS) {
        uint64_t hid = (uint64_t)Call2(st->fn_objc_msgSend, (uint64_t)backstopFS, (uint64_t)st->sel_isHidden) & 1;
        float op = CallRetFloat(st->fn_objc_msgSend, (uint64_t)backstopFS, (uint64_t)st->sel_opacity);
        if (!hid && op > 0.5f) isFullScreen = 1;
    }

    WSRect bounds = CallRetRect(st->fn_objc_msgSend, (uint64_t)root, (uint64_t)st->sel_bounds);
    st->lastW = (uint32_t)(bounds.w > 0.0 ? bounds.w : 0.0);
    st->lastH = (uint32_t)(bounds.h > 0.0 ? bounds.h : 0.0);
    if (bounds.w < 1.0 || bounds.h < 1.0) return;

    uint32_t flipped = st->sel_isGeometryFlipped
        ? (uint32_t)((uint64_t)Call2(st->fn_objc_msgSend, (uint64_t)root, (uint64_t)st->sel_isGeometryFlipped) & 1)
        : 0;

    Call2(st->fn_objc_msgSend, (uint64_t)st->cls_CATransaction, (uint64_t)st->sel_begin);
    Call3(st->fn_objc_msgSend, (uint64_t)st->cls_CATransaction, (uint64_t)st->sel_setDisableActions, 1);
    // Register menubar.root's CAContext with CATransaction just like WSCAContextScopeTransaction::~D1
    // so our layer mutations commit to WindowServer's compositor on this exact frame.
    void *caCtx = st->sel_context ? Call2(st->fn_objc_msgSend, (uint64_t)root, (uint64_t)st->sel_context) : NULL;
    if (caCtx && st->cls_NSArray && st->sel_setCommittingContexts) {
        void *ctxArr = Call4(st->fn_objc_msgSend, (uint64_t)st->cls_NSArray,
                             (uint64_t)st->sel_arrayWithObjectsCount, (uint64_t)&caCtx, 1);
        if (ctxArr) {
            Call3(st->fn_objc_msgSend, (uint64_t)st->cls_CATransaction,
                  (uint64_t)st->sel_setCommittingContexts, (uint64_t)ctxArr);
        }
    }

    // Hide Solarium's heavy 360px desktop_capture / enhancement / AX backstop so our live CABackdropLayer shines.
    if (!isFullScreen) {
        if (desktopCap) Call3(st->fn_objc_msgSend, (uint64_t)desktopCap, (uint64_t)st->sel_setHidden, 1);
        if (desktopEnh) Call3(st->fn_objc_msgSend, (uint64_t)desktopEnh, (uint64_t)st->sel_setHidden, 1);
        if (backstopAX) Call3(st->fn_objc_msgSend, (uint64_t)backstopAX, (uint64_t)st->sel_setHidden, 1);
    }

    // Locate our layers on menubar.root (clip container -> backdrop, gloss, hairline).
    // Any unclipped legacy lioness.ws.backdrop directly on root from an older version is hidden cleanly.
    void *clip     = NULL;
    void *backdrop = NULL;
    void *gloss    = NULL;
    void *hairline = NULL;
    void *subs = Call2(st->fn_objc_msgSend, (uint64_t)root, (uint64_t)st->sel_sublayers);
    if (subs) {
        uint64_t count = (uint64_t)Call2(st->fn_objc_msgSend, (uint64_t)subs, (uint64_t)st->sel_count);
        for (uint64_t i = 0; i < count; i++) {
            void *sub = Call3(st->fn_objc_msgSend, (uint64_t)subs, (uint64_t)st->sel_objectAtIndex, i);
            if (!sub) continue;
            void *nm = Call2(st->fn_objc_msgSend, (uint64_t)sub, (uint64_t)st->sel_name);
            if (nm && st->strClipName &&
                ((uint64_t)Call3(st->fn_objc_msgSend, (uint64_t)nm, (uint64_t)st->sel_isEqualToString, (uint64_t)st->strClipName) & 1)) {
                clip = sub;
            } else if (nm && st->strGlossName &&
                       ((uint64_t)Call3(st->fn_objc_msgSend, (uint64_t)nm, (uint64_t)st->sel_isEqualToString, (uint64_t)st->strGlossName) & 1)) {
                gloss = sub;
            } else if (nm && st->strHairlineName &&
                       ((uint64_t)Call3(st->fn_objc_msgSend, (uint64_t)nm, (uint64_t)st->sel_isEqualToString, (uint64_t)st->strHairlineName) & 1)) {
                hairline = sub;
            } else if (!isFullScreen && sub != backstopFS) {
                int isMenubarNamed = nm && st->strPkgPrefix &&
                    ((uint64_t)Call3(st->fn_objc_msgSend, (uint64_t)nm, (uint64_t)st->sel_hasPrefix, (uint64_t)st->strPkgPrefix) & 1);
                int isAuxShadow = nm && st->strAuxShadowPrefix &&
                    ((uint64_t)Call3(st->fn_objc_msgSend, (uint64_t)nm, (uint64_t)st->sel_hasPrefix, (uint64_t)st->strAuxShadowPrefix) & 1);
                if (!isMenubarNamed || isAuxShadow) {
                    Call3(st->fn_objc_msgSend, (uint64_t)sub, (uint64_t)st->sel_setHidden, 1);
                }
            }
        }
    }

    // Create lioness.ws.clip (masksToBounds=YES parent so gaussianBlur NEVER overshoots below the hairline).
    if (!clip && st->cls_CALayer) {
        clip = Call2(st->fn_objc_msgSend, (uint64_t)st->cls_CALayer, (uint64_t)st->sel_layer);
        if (clip) {
            Call3(st->fn_objc_msgSend, (uint64_t)clip, (uint64_t)st->sel_setName, (uint64_t)st->strClipName);
            CallDoubleArg(st->fn_objc_msgSend, (uint64_t)clip, (uint64_t)st->sel_setZPosition, st->zBackdrop);
            Call3(st->fn_objc_msgSend, (uint64_t)clip, (uint64_t)st->sel_setMasksToBounds, 1);
            if (st->cachedActions)
                Call3(st->fn_objc_msgSend, (uint64_t)clip, (uint64_t)st->sel_setActions, (uint64_t)st->cachedActions);
            Call4(st->fn_objc_msgSend, (uint64_t)root, (uint64_t)st->sel_insertSublayerAtIndex, (uint64_t)clip, 0);
        }
    }
    if (clip) {
        void *csubs = Call2(st->fn_objc_msgSend, (uint64_t)clip, (uint64_t)st->sel_sublayers);
        if (csubs) {
            uint64_t cc = (uint64_t)Call2(st->fn_objc_msgSend, (uint64_t)csubs, (uint64_t)st->sel_count);
            for (uint64_t i = 0; i < cc; i++) {
                void *sub = Call3(st->fn_objc_msgSend, (uint64_t)csubs, (uint64_t)st->sel_objectAtIndex, i);
                if (!sub) continue;
                void *nm = Call2(st->fn_objc_msgSend, (uint64_t)sub, (uint64_t)st->sel_name);
                if (nm && st->strBackdropName &&
                    ((uint64_t)Call3(st->fn_objc_msgSend, (uint64_t)nm, (uint64_t)st->sel_isEqualToString, (uint64_t)st->strBackdropName) & 1)) {
                    backdrop = sub;
                    break;
                }
            }
        }
    }

    // Create lioness.ws.backdrop (live CABackdropLayer blur inside masksToBounds=YES clip layer) if needed.
    if (!backdrop && clip && st->cls_CABackdropLayer) {
        backdrop = Call2(st->fn_objc_msgSend, (uint64_t)st->cls_CABackdropLayer, (uint64_t)st->sel_layer);
        if (backdrop) {
            Call3(st->fn_objc_msgSend, (uint64_t)backdrop, (uint64_t)st->sel_setName, (uint64_t)st->strBackdropName);
            Call3(st->fn_objc_msgSend, (uint64_t)backdrop, (uint64_t)st->sel_setMasksToBounds, 1);
            if (st->sel_setBleedAmount)
                CallDoubleArg(st->fn_objc_msgSend, (uint64_t)backdrop, (uint64_t)st->sel_setBleedAmount, 0.0);
            if (st->sel_setMarginWidth)
                CallDoubleArg(st->fn_objc_msgSend, (uint64_t)backdrop, (uint64_t)st->sel_setMarginWidth, 0.0);
            if (st->cachedActions)
                Call3(st->fn_objc_msgSend, (uint64_t)backdrop, (uint64_t)st->sel_setActions, (uint64_t)st->cachedActions);
            if (st->cachedFilters)
                Call3(st->fn_objc_msgSend, (uint64_t)backdrop, (uint64_t)st->sel_setFilters, (uint64_t)st->cachedFilters);
            Call4(st->fn_objc_msgSend, (uint64_t)clip, (uint64_t)st->sel_insertSublayerAtIndex, (uint64_t)backdrop, 0);
        }
    } else if (backdrop && needsRefresh && st->cachedFilters) {
        Call3(st->fn_objc_msgSend, (uint64_t)backdrop, (uint64_t)st->sel_setFilters, (uint64_t)st->cachedFilters);
    }

    // Create lioness.ws.gloss (ml-root SArtFile.bin 0x4e50 pure 42px gradient).
    if (!gloss && st->cls_CALayer) {
        gloss = Call2(st->fn_objc_msgSend, (uint64_t)st->cls_CALayer, (uint64_t)st->sel_layer);
        if (gloss) {
            Call3(st->fn_objc_msgSend, (uint64_t)gloss, (uint64_t)st->sel_setName, (uint64_t)st->strGlossName);
            CallDoubleArg(st->fn_objc_msgSend, (uint64_t)gloss, (uint64_t)st->sel_setZPosition, st->zGloss);
            if (st->cachedActions)
                Call3(st->fn_objc_msgSend, (uint64_t)gloss, (uint64_t)st->sel_setActions, (uint64_t)st->cachedActions);
            if (st->cachedBarImage) {
                Call3(st->fn_objc_msgSend, (uint64_t)gloss, (uint64_t)st->sel_setContents, (uint64_t)st->cachedBarImage);
                CallDoubleArg(st->fn_objc_msgSend, (uint64_t)gloss, (uint64_t)st->sel_setContentsScale, 2.0);
                if (st->strGravityResize)
                    Call3(st->fn_objc_msgSend, (uint64_t)gloss, (uint64_t)st->sel_setContentsGravity, (uint64_t)st->strGravityResize);
                WSRect unit = { 0.0, 0.0, 1.0, 1.0 };
                CallRectArg(st->fn_objc_msgSend, (uint64_t)gloss, (uint64_t)st->sel_setContentsCenter, unit);
            }
            Call4(st->fn_objc_msgSend, (uint64_t)root, (uint64_t)st->sel_insertSublayerAtIndex, (uint64_t)gloss, clip ? 1 : 0);
        }
    } else if (gloss && needsRefresh && st->cachedBarImage) {
        Call3(st->fn_objc_msgSend, (uint64_t)gloss, (uint64_t)st->sel_setContents, (uint64_t)st->cachedBarImage);
    }

    // Create lioness.ws.hairline (exact 1.0pt bottom dark edge — never stretches on 43pt notched displays).
    if (!hairline && st->cls_CALayer) {
        hairline = Call2(st->fn_objc_msgSend, (uint64_t)st->cls_CALayer, (uint64_t)st->sel_layer);
        if (hairline) {
            Call3(st->fn_objc_msgSend, (uint64_t)hairline, (uint64_t)st->sel_setName, (uint64_t)st->strHairlineName);
            CallDoubleArg(st->fn_objc_msgSend, (uint64_t)hairline, (uint64_t)st->sel_setZPosition, st->zHairline);
            if (st->cachedActions)
                Call3(st->fn_objc_msgSend, (uint64_t)hairline, (uint64_t)st->sel_setActions, (uint64_t)st->cachedActions);
            if (st->cachedHairlineImage) {
                Call3(st->fn_objc_msgSend, (uint64_t)hairline, (uint64_t)st->sel_setContents, (uint64_t)st->cachedHairlineImage);
                if (st->strGravityResize)
                    Call3(st->fn_objc_msgSend, (uint64_t)hairline, (uint64_t)st->sel_setContentsGravity, (uint64_t)st->strGravityResize);
            }
            uint64_t idx = (clip ? 1 : 0) + (gloss ? 1 : 0);
            Call4(st->fn_objc_msgSend, (uint64_t)root, (uint64_t)st->sel_insertSublayerAtIndex, (uint64_t)hairline, idx);
        }
    } else if (hairline && needsRefresh && st->cachedHairlineImage) {
        Call3(st->fn_objc_msgSend, (uint64_t)hairline, (uint64_t)st->sel_setContents, (uint64_t)st->cachedHairlineImage);
    }

    WSRect gFrame = { bounds.x, flipped ? bounds.y : (bounds.y + 1.0), bounds.w, bounds.h > 1.0 ? (bounds.h - 1.0) : bounds.h };
    if (clip) {
        CallRectArg(st->fn_objc_msgSend, (uint64_t)clip, (uint64_t)st->sel_setFrame, gFrame);
        Call3(st->fn_objc_msgSend, (uint64_t)clip, (uint64_t)st->sel_setHidden, (uint64_t)isFullScreen);
    }
    if (backdrop) {
        WSRect local = { 0.0, 0.0, gFrame.w, gFrame.h };
        CallRectArg(st->fn_objc_msgSend, (uint64_t)backdrop, (uint64_t)st->sel_setFrame, local);
        Call3(st->fn_objc_msgSend, (uint64_t)backdrop, (uint64_t)st->sel_setHidden, (uint64_t)isFullScreen);
    }
    if (gloss) {
        // Pure 0x4e50 white-glass gradient fills everything above the 1pt bottom hairline (matches CoreUI DrawMenuBar).
        CallRectArg(st->fn_objc_msgSend, (uint64_t)gloss, (uint64_t)st->sel_setFrame, gFrame);
        Call3(st->fn_objc_msgSend, (uint64_t)gloss, (uint64_t)st->sel_setHidden, (uint64_t)isFullScreen);
    }
    if (hairline) {
        WSRect hFrame = { bounds.x, flipped ? (bounds.y + bounds.h - 1.0) : bounds.y, bounds.w, 1.0 };
        CallRectArg(st->fn_objc_msgSend, (uint64_t)hairline, (uint64_t)st->sel_setFrame, hFrame);
        Call3(st->fn_objc_msgSend, (uint64_t)hairline, (uint64_t)st->sel_setHidden, (uint64_t)isFullScreen);
    }

    Call2(st->fn_objc_msgSend, (uint64_t)st->cls_CATransaction, (uint64_t)st->sel_commit);
    if (st->sel_flush) {
        Call2(st->fn_objc_msgSend, (uint64_t)st->cls_CATransaction, (uint64_t)st->sel_flush);
    }

    // Apply Mountain Lion's iconic menu bar drop shadow (0.50 density, 8.0pt radius, 0.0 rim) when not fullscreen.
    if (!isFullScreen && cgx_window && st->fn_set_shadow_properties) {
        CallShadowProps(st->fn_set_shadow_properties, st->shadowDensity, cgx_window);
    }

    st->lastFlags = (uint32_t)((isFullScreen ? 1 : 0) |
                               (backdrop ? 2 : 0) |
                               (gloss ? 4 : 0) |
                               (st->cachedBarImage ? 8 : 0) |
                               (st->cachedFilters ? 16 : 0) |
                               (cgx_window ? 32 : 0) |
                               (flipped ? 64 : 0) |
                               (caCtx ? 128 : 0));
    st->styledCount++;
}

// Helper macro for update_layers wrappers (Solarium = 0, LiveActivitiesQFA = 1).
#define DEFINE_UPDATE_ENTRY(NAME, ORIG_FIELD, IS_QFA) \
WS_PAYLOAD_FN __attribute__((naked)) \
void NAME(void) { \
    __asm__ volatile( \
        "pacibsp\n" \
        "sub sp, sp, #0x70\n" \
        "stp x19, x20, [sp, #0x40]\n" \
        "str x21, [sp, #0x50]\n" \
        "stp x29, x30, [sp, #0x60]\n" \
        "add x29, sp, #0x60\n" \
        "mov x19, x0\n" \
        "mov x20, x3\n" \
        "ldp x9,  x10, [sp, #0x70]\n" \
        "stp x9,  x10, [sp, #0x00]\n" \
        "ldp x11, x12, [sp, #0x80]\n" \
        "stp x11, x12, [sp, #0x10]\n" \
        "ldp x13, x14, [sp, #0x90]\n" \
        "stp x13, x14, [sp, #0x20]\n" \
        "ldp x15, x17, [sp, #0xa0]\n" \
        "stp x15, x17, [sp, #0x30]\n" \
        "adr x21, .\n" \
        "and x21, x21, #-16384\n" \
        "add x21, x21, #0x4000\n" \
        "ldr x16, [x21, %[off_orig]]\n" \
        "blr x16\n" \
        "mov x0, x19\n" \
        "mov x1, x20\n" \
        "mov w2, #0\n" \
        "mov w3, %[is_qfa]\n" \
        "bl _LionessStyleMenuBar\n" \
        "ldp x29, x30, [sp, #0x60]\n" \
        "ldr x21, [sp, #0x50]\n" \
        "ldp x19, x20, [sp, #0x40]\n" \
        "add sp, sp, #0x70\n" \
        "retab\n" \
        : \
        : [off_orig] "i"(offsetof(WSRemoteState, ORIG_FIELD)), [is_qfa] "i"(IS_QFA) \
    ); \
}

#define DEFINE_RESHAPE_ENTRY(NAME, ORIG_FIELD, IS_QFA) \
WS_PAYLOAD_FN __attribute__((naked)) \
void NAME(void) { \
    __asm__ volatile( \
        "pacibsp\n" \
        "sub sp, sp, #0x30\n" \
        "stp x19, x20, [sp, #0x10]\n" \
        "stp x29, x30, [sp, #0x20]\n" \
        "add x29, sp, #0x20\n" \
        "mov x19, x0\n" \
        "adr x20, .\n" \
        "and x20, x20, #-16384\n" \
        "add x20, x20, #0x4000\n" \
        "ldr x16, [x20, %[off_orig]]\n" \
        "blr x16\n" \
        "mov x0, x19\n" \
        "mov x1, #0\n" \
        "mov w2, #1\n" \
        "mov w3, %[is_qfa]\n" \
        "bl _LionessStyleMenuBar\n" \
        "ldp x29, x30, [sp, #0x20]\n" \
        "ldp x19, x20, [sp, #0x10]\n" \
        "add sp, sp, #0x30\n" \
        "retab\n" \
        : \
        : [off_orig] "i"(offsetof(WSRemoteState, ORIG_FIELD)), [is_qfa] "i"(IS_QFA) \
    ); \
}

DEFINE_UPDATE_ENTRY(LionessWSPayloadSolUpdateEntry,  orig_sol_update,  0)
DEFINE_RESHAPE_ENTRY(LionessWSPayloadSolReshapeEntry, orig_sol_reshape, 0)
DEFINE_UPDATE_ENTRY(LionessWSPayloadQfaUpdateEntry,  orig_qfa_update,  1)
DEFINE_RESHAPE_ENTRY(LionessWSPayloadQfaReshapeEntry, orig_qfa_reshape, 1)

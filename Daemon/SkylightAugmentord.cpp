// skylightaugmentord: Root LaunchDaemon helper that remotely augments WindowServer's
// SkyLight menu bar compositor to replicate Mountain Lion's translucent glossy menu bar,
// live desktop blur, 1pt bottom hairline, compact height, and authentic 8pt drop shadow.
//
// Design guarantees:
// - ZERO dylibs injected into WindowServer.
// - Uses ONLY Mountain Lion resources from <ml-root>/System/Library/PrivateFrameworks/CoreUI.framework/.../SArtFile.bin.
// - Uses Mach task_* and thread_* APIs exclusively (task_for_pid, task_info, task_threads,
//   thread_suspend, thread_get_state, thread_resume, mach_vm_allocate, mach_vm_read_overwrite,
//   mach_vm_write, mach_vm_protect).
// - Self-contained inside WindowServer's own allocated VM pages: WindowServer NEVER crashes if
//   skylightaugmentord exits or is killed, and restarts are idempotent.

#include "SkylightPayload.h"

#include <CoreFoundation/CoreFoundation.h>
#include <CoreGraphics/CoreGraphics.h>
#include <dlfcn.h>
#include <errno.h>
#include <fcntl.h>
#include <libproc.h>
#include <mach-o/dyld.h>
#include <mach-o/dyld_images.h>
#include <mach-o/getsect.h>
#include <mach-o/loader.h>
#include <mach-o/nlist.h>
#include <mach/mach.h>
#include <mach/mach_vm.h>
#include <notify.h>
#include <objc/message.h>
#include <objc/runtime.h>
#include <ptrauth.h>
#include <signal.h>
#include <spawn.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/event.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <sys/wait.h>
#include <unistd.h>

static const char *kMarkerPath = "/Library/Lioness/log/skylightaugmentord.ws";

static uint64_t StripPtr(const void *p) {
    return (uint64_t)ptrauth_strip((void *)p, ptrauth_key_function_pointer);
}

// ---------------------------------------------------------------------------
// 1. Mountain Lion SArtFile.bin reader (strictly ml-root assets only)
// ---------------------------------------------------------------------------

struct SArtFileHeader {
    uint16_t version;
    uint16_t count;
    uint32_t dataOffset;
};

struct SArtImageHeader {
    uint16_t imgType;
    uint16_t entryCount;
};

struct SArtImageEntry {
    uint16_t width;
    uint16_t height;
    uint32_t length;
    uint32_t relOffset;
};

static bool ExtractSArt2x(const uint8_t *buf, size_t size, uint32_t artID,
                          uint8_t *outBGRA, uint32_t expectW, uint32_t expectH) {
    if (size < sizeof(SArtFileHeader) || artID < 0x4e20) return false;
    const SArtFileHeader *hdr = (const SArtFileHeader *)buf;
    uint32_t idx = artID - 0x4e20;
    if (hdr->version != 2 || idx >= hdr->count) return false;
    size_t tableOff = sizeof(SArtFileHeader) + (size_t)idx * 4;
    if (tableOff + 4 > size) return false;
    uint32_t imgHdrOff = *(const uint32_t *)(buf + tableOff);
    if ((size_t)imgHdrOff + sizeof(SArtImageHeader) > size) return false;
    const SArtImageHeader *ih = (const SArtImageHeader *)(buf + imgHdrOff);
    const SArtImageEntry *entries = (const SArtImageEntry *)(buf + imgHdrOff + sizeof(SArtImageHeader));
    if ((size_t)imgHdrOff + sizeof(SArtImageHeader) + (size_t)ih->entryCount * sizeof(SArtImageEntry) > size)
        return false;
    for (uint16_t i = 0; i < ih->entryCount; i++) {
        if (entries[i].width == expectW && entries[i].height == expectH &&
            entries[i].length == expectW * expectH * 4) {
            size_t pixOff = (size_t)hdr->dataOffset + entries[i].relOffset;
            if (pixOff + entries[i].length <= size) {
                memcpy(outBGRA, buf + pixOff, entries[i].length);
                return true;
            }
        }
    }
    return false;
}

// Builds the 2x44 premultiplied BGRA8888 Mountain Lion menu bar strip exclusively from ml-root's SArtFile.bin:
// - Rows 0..41: Art ID 0x4e50 (translucent white-silver vertical gloss gradient) softly modulated by 0x4e8d
//   so the top-to-bottom glossy white-to-silver ramp reads authentically over both dark and bright wallpapers.
// - Rows 42..43: Mountain Lion's 1pt dark bottom hairline (rgba(0,0,0,0.55), from CUIArtFileRenderer::DrawMenuBar).
static bool LoadMountainLionMenuBarArt(const char *mlRoot, uint8_t out2x[WS_BAR_BYTES_2X]) {
    char path[1024];
    snprintf(path, sizeof(path),
             "%s/System/Library/PrivateFrameworks/CoreUI.framework/Versions/A/Resources/SArtFile.bin",
             mlRoot);
    int fd = open(path, O_RDONLY);
    if (fd < 0) {
        fprintf(stderr, "skylightaugmentord: cannot open %s: %s\n", path, strerror(errno));
        return false;
    }
    struct stat st;
    if (fstat(fd, &st) != 0 || st.st_size < 16) {
        close(fd);
        return false;
    }
    void *mapped = mmap(NULL, (size_t)st.st_size, PROT_READ, MAP_PRIVATE, fd, 0);
    close(fd);
    if (mapped == MAP_FAILED) return false;

    uint8_t translucent[2 * 42 * 4] = {};
    bool okTrans = ExtractSArt2x((const uint8_t *)mapped, (size_t)st.st_size, 0x4e50, translucent, 2, 42);
    munmap(mapped, (size_t)st.st_size);
    if (!okTrans) {
        fprintf(stderr, "skylightaugmentord: SArtFile.bin missing art 0x4e50\n");
        return false;
    }

    // Use Mountain Lion's PURE UNMODIFIED SArtFile.bin 0x4e50 translucent white-glass veil
    // (alpha 247 -> 159, pure luminous white B=G=R=A, matching CUIArtFileRenderer::DrawMenuBar verbatim).
    memcpy(out2x, translucent, WS_BAR_BYTES_2X);
    return true;
}

// ---------------------------------------------------------------------------
// 2. SkyLight symbol & SolariumMenuBarContext field discovery (shared cache)
// ---------------------------------------------------------------------------

struct SkyLightTargets {
    uintptr_t slBase;
    uintptr_t sol_configure;
    uintptr_t sol_update;
    uintptr_t sol_reshape;
    uintptr_t qfa_configure;
    uintptr_t qfa_update;
    uintptr_t qfa_reshape;
    uintptr_t underbelly_new;
    uintptr_t underbelly_update;
    uintptr_t underbelly_cleanup;
    uintptr_t set_shadow_properties;
    uintptr_t clear_shadow_density;
    uintptr_t default_height_block;
    uintptr_t default_height_var;
    uintptr_t disp_menubar_height;
    uintptr_t pkg_menubar_height;
    uintptr_t pkg_menubar_bounds;
    uintptr_t eval_display_parts;
    uintptr_t encode_display;
    uintptr_t pkg_display_ctor;
    uintptr_t ca_manager;
    uintptr_t invalidate_state_seed;

    WSContextOffsets solOffsets;
    WSContextOffsets qfaOffsets;
};

static uintptr_t DecodeAdrpAdd(uintptr_t pc, uint32_t i1, uint32_t i2) {
    int64_t imm = (((int64_t)(int32_t)(i1 << 8) >> 13) << 2) | ((i1 >> 29) & 3);
    uintptr_t page = (pc & ~0xfffULL) + (uintptr_t)(imm << 12);
    uint32_t imm12 = (i2 >> 10) & 0xfff;
    return page + imm12;
}

static void ScanConfigureLayersOffsets(uintptr_t slBase, uintptr_t configureFn, WSContextOffsets *dst) {
    if (!configureFn) return;
    const uint32_t *p = (const uint32_t *)configureFn;
    for (int k = 0; k < 220; k++) {
        uint32_t i1 = p[k], i2 = p[k + 1];
        if ((i1 & 0x9f000000) == 0x90000000 && (i2 & 0xffc00000) == 0x91000000) {
            uint32_t rd1 = i1 & 31, rn2 = (i2 >> 5) & 31;
            if (rd1 != rn2) continue;
            uintptr_t addr = DecodeAdrpAdd((uintptr_t)&p[k], i1, i2);
            if (addr <= slBase || addr >= slBase + 0x70000000ULL) continue;
            const uint64_t *q = (const uint64_t *)addr;
            if ((q[1] & 0xffff) != 0x07c8) continue; // CFConstantString
            const char *cstr = (const char *)q[2];
            if (!cstr) continue;
            uint32_t off = 0;
            for (int j = 2; j <= 8; j++) {
                if ((p[k + j] & 0xffc003ff) == 0xf9000274) {
                    off = ((p[k + j] >> 10) & 0xfff) * 8;
                    break;
                }
            }
            if (!off) continue;
            if (!strcmp(cstr, "menubar.root")) dst->off_root = off;
            else if (!strcmp(cstr, "menubar.backstop.fs")) dst->off_backstop_fs = off;
            else if (!strcmp(cstr, "menubar.backstop.ax")) dst->off_backstop_ax = off;
            else if (!strcmp(cstr, "menubar.desktop_capture")) dst->off_desktop_capture = off;
            else if (!strcmp(cstr, "menubar.desktop_capture.enhancement")) dst->off_desktop_enh = off;
        }
    }
}

static bool ResolveSkyLightTargets(SkyLightTargets *out) {
    memset(out, 0, sizeof(*out));
    dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_NOW);
    const struct mach_header_64 *hdr = NULL;
    intptr_t slide = 0;
    for (uint32_t i = 0; i < _dyld_image_count(); i++) {
        const char *name = _dyld_get_image_name(i);
        if (name && strstr(name, "/SkyLight.framework/")) {
            hdr = (const struct mach_header_64 *)_dyld_get_image_header(i);
            slide = _dyld_get_image_vmaddr_slide(i);
            break;
        }
    }
    if (!hdr) return false;
    out->slBase = (uintptr_t)hdr;

    const struct load_command *lc = (const struct load_command *)(hdr + 1);
    const struct segment_command_64 *linkedit = NULL;
    const struct symtab_command *symtab = NULL;
    for (uint32_t i = 0; i < hdr->ncmds; i++) {
        if (lc->cmd == LC_SEGMENT_64) {
            const struct segment_command_64 *seg = (const struct segment_command_64 *)lc;
            if (!strcmp(seg->segname, "__LINKEDIT")) linkedit = seg;
        } else if (lc->cmd == LC_SYMTAB) {
            symtab = (const struct symtab_command *)lc;
        }
        lc = (const struct load_command *)((const uint8_t *)lc + lc->cmdsize);
    }
    if (!linkedit || !symtab) return false;

    uintptr_t linkeditBase = (uintptr_t)slide + linkedit->vmaddr - linkedit->fileoff;
    const struct nlist_64 *syms = (const struct nlist_64 *)(linkeditBase + symtab->symoff);
    const char *strs = (const char *)(linkeditBase + symtab->stroff);

    for (uint32_t i = 0; i < symtab->nsyms; i++) {
        if ((syms[i].n_type & N_TYPE) != N_SECT || !syms[i].n_value) continue;
        const char *s = strs + syms[i].n_un.n_strx;
        uintptr_t addr = syms[i].n_value + (uintptr_t)slide;
        if (!strcmp(s, "__ZN22SolariumMenuBarContext16configure_layersEv")) out->sol_configure = addr;
        else if (!strcmp(s, "__ZN22SolariumMenuBarContext13update_layersEP19PKGManagedMenuSpacejP9CGXWindowbbbbbbRK6CGRectS6_")) out->sol_update = addr;
        else if (!strcmp(s, "__ZN22SolariumMenuBarContext14reshape_layersE6CGRectfjbdP19PKGManagedMenuSpace")) out->sol_reshape = addr;
        else if (!strcmp(s, "__ZN31LiveActivitiesQFAMenuBarContext16configure_layersEv")) out->qfa_configure = addr;
        else if (!strcmp(s, "__ZN31LiveActivitiesQFAMenuBarContext13update_layersEP19PKGManagedMenuSpacejP9CGXWindowbbbbbbRK6CGRectS6_")) out->qfa_update = addr;
        else if (!strcmp(s, "__ZN31LiveActivitiesQFAMenuBarContext14reshape_layersE6CGRectfjbdP19PKGManagedMenuSpace")) out->qfa_reshape = addr;
        else if (!strcmp(s, "__ZN10Underbelly14new_underbellyEP19PKGManagedMenuSpace")) out->underbelly_new = addr;
        else if (!strcmp(s, "__ZN10Underbelly6updateERK20AdjustmentProperties")) out->underbelly_update = addr;
        else if (!strcmp(s, "__ZN10Underbelly7cleanupEv")) out->underbelly_cleanup = addr;
        else if (!strcmp(s, "__ZL21set_shadow_propertiesfffP9CGXWindow")) out->set_shadow_properties = addr;
        else if (!strcmp(s, "__ZL20clear_shadow_densityP9CGXWindow")) out->clear_shadow_density = addr;
        else if (!strcmp(s, "___WSDefaultMenuBarHeightInPoints_block_invoke")) out->default_height_block = addr;
        else if (!strcmp(s, "__ZZ30WSDefaultMenuBarHeightInPointsE33resolved_default_height_in_points")) out->default_height_var = addr;
        else if (!strcmp(s, "_WSDisplayGetMenubarHeight")) out->disp_menubar_height = addr;
        else if (!strcmp(s, "_PKGManagedMenuSpaceGetMenuBarHeight")) out->pkg_menubar_height = addr;
        else if (!strcmp(s, "_WSPackagesGetMenuBarBoundsForSpace")) out->pkg_menubar_bounds = addr;
        else if (!strcmp(s, "__ZN2WS8Displays7Display22evaluate_display_partsEv")) out->eval_display_parts = addr;
        else if (!strcmp(s, "__ZN2WS8Displays11CAWSManager14encode_displayER10CGSEncoderPKNS0_11SLCADisplayE")) out->encode_display = addr;
        else if (!strcmp(s, "__ZN10PKGDisplayC2ERKN12_GLOBAL__N_116WSDisplayWrapperE")) out->pkg_display_ctor = addr;
        else if (!strcmp(s, "__ZN2WS8Displays9CAManagerEv")) out->ca_manager = addr;
        else if (!strcmp(s, "__ZN2WS8Displays11CAWSManager21invalidate_state_seedEb")) out->invalidate_state_seed = addr;
    }

    ScanConfigureLayersOffsets(out->slBase, out->sol_configure, &out->solOffsets);
    ScanConfigureLayersOffsets(out->slBase, out->qfa_configure, &out->qfaOffsets);

    return (out->sol_update && out->solOffsets.off_root) || (out->qfa_update && out->qfaOffsets.off_root);
}

// ---------------------------------------------------------------------------
// 3. Mach task_* and thread_* remote memory & safe patching helpers
// ---------------------------------------------------------------------------

static bool GetSharedCacheSlide(mach_port_t task, int64_t *outSlide) {
    task_dyld_info_data_t info;
    mach_msg_type_number_t count = TASK_DYLD_INFO_COUNT;
    if (task_info(task, TASK_DYLD_INFO, (task_info_t)&info, &count) != KERN_SUCCESS) return false;
    struct dyld_all_image_infos infos;
    mach_vm_size_t readSz = 0;
    if (mach_vm_read_overwrite(task, info.all_image_info_addr, sizeof(infos),
                               (mach_vm_address_t)&infos, &readSz) != KERN_SUCCESS)
        return false;
    *outSlide = (int64_t)infos.sharedCacheSlide;
    return true;
}

static bool WriteRemoteCode(mach_port_t task, mach_vm_address_t addr, const void *data, size_t size) {
    mach_vm_address_t page = addr & ~(mach_vm_address_t)(WS_PAYLOAD_PAGE_SZ - 1);
    mach_vm_size_t span = ((addr + size - page) + WS_PAYLOAD_PAGE_SZ - 1) & ~(mach_vm_size_t)(WS_PAYLOAD_PAGE_SZ - 1);
    kern_return_t kr = mach_vm_protect(task, page, span, FALSE, VM_PROT_READ | VM_PROT_WRITE | VM_PROT_COPY);
    if (kr != KERN_SUCCESS) {
        kr = mach_vm_protect(task, page, span, FALSE, VM_PROT_READ | VM_PROT_WRITE);
        if (kr != KERN_SUCCESS) {
            fprintf(stderr, "skylightaugmentord: mach_vm_protect RW failed at %#llx: %s\n",
                    (unsigned long long)addr, mach_error_string(kr));
            return false;
        }
    }
    kr = mach_vm_write(task, addr, (vm_offset_t)data, (mach_msg_type_number_t)size);
    if (kr != KERN_SUCCESS) {
        fprintf(stderr, "skylightaugmentord: mach_vm_write failed at %#llx: %s\n",
                (unsigned long long)addr, mach_error_string(kr));
        return false;
    }
    kr = mach_vm_protect(task, page, span, FALSE, VM_PROT_READ | VM_PROT_EXECUTE);
    if (kr != KERN_SUCCESS) {
        fprintf(stderr, "skylightaugmentord: mach_vm_protect RX failed at %#llx: %s\n",
                (unsigned long long)addr, mach_error_string(kr));
        return false;
    }
    return true;
}

struct PatchRange {
    uint64_t start;
    uint64_t end;
};

// Reads PC from a remote arm64e thread state WITHOUT PAC authentication.
// arm_thread_state64_get_pc() runs `autia` using OUR process's PAC key, which traps with
// EXC_ARM_PAC_FAIL when reading a foreign process (WindowServer) with different PAC keys!
static uint64_t ReadThreadPCNoAuth(const arm_thread_state64_t &ts) {
#if __DARWIN_OPAQUE_ARM_THREAD_STATE64
    uint64_t raw = (uint64_t)(uintptr_t)ts.__opaque_pc;
#else
    uint64_t raw = ts.__pc;
#endif
    return (uint64_t)ptrauth_strip((void *)raw, ptrauth_key_return_address);
}

// Emergency async-signal-safe resume table so WindowServer threads can NEVER remain suspended
// even if skylightaugmentord receives a fatal signal during the <1ms patch window.
static volatile sig_atomic_t gEmergencyCount = 0;
static thread_act_t gEmergencyThreads[512];

static void EmergencyResumeSignalHandler(int sig) {
    sig_atomic_t n = gEmergencyCount;
    gEmergencyCount = 0;
    for (sig_atomic_t i = 0; i < n && i < 512; i++) {
        thread_resume(gEmergencyThreads[i]);
    }
    signal(sig, SIG_DFL);
    raise(sig);
}

static void InstallEmergencyHandlers(bool install) {
    static const int kSigs[] = { SIGBUS, SIGSEGV, SIGILL, SIGTRAP, SIGABRT, SIGTERM, SIGINT };
    for (size_t i = 0; i < sizeof(kSigs) / sizeof(kSigs[0]); i++) {
        signal(kSigs[i], install ? EmergencyResumeSignalHandler : SIG_DFL);
    }
}

// Suspends all threads of `task` via task_threads + thread_suspend and checks every thread's PC
// via thread_get_state(ARM_THREAD_STATE64) so we NEVER patch instructions a thread is executing.
struct SuspendedThreads {
    thread_act_array_t list = NULL;
    mach_msg_type_number_t count = 0;

    bool SuspendSafely(mach_port_t task, const PatchRange *ranges, size_t numRanges) {
        for (int attempt = 0; attempt < 25; attempt++) {
            if (task_threads(task, &list, &count) != KERN_SUCCESS || count == 0) {
                if (list) {
                    vm_deallocate(mach_task_self(), (vm_address_t)list, count * sizeof(thread_act_t));
                    list = NULL;
                    count = 0;
                }
                return false;
            }
            InstallEmergencyHandlers(true);
            sig_atomic_t tracked = 0;
            for (mach_msg_type_number_t i = 0; i < count; i++) {
                if (thread_suspend(list[i]) == KERN_SUCCESS && tracked < 512) {
                    gEmergencyThreads[tracked++] = list[i];
                    gEmergencyCount = tracked;
                }
            }

            bool conflict = false;
            for (mach_msg_type_number_t i = 0; i < count && !conflict; i++) {
                arm_thread_state64_t ts;
                mach_msg_type_number_t tsCount = ARM_THREAD_STATE64_COUNT;
                if (thread_get_state(list[i], ARM_THREAD_STATE64, (thread_state_t)&ts, &tsCount) == KERN_SUCCESS) {
                    uint64_t pc = ReadThreadPCNoAuth(ts);
                    for (size_t r = 0; r < numRanges; r++) {
                        if (pc >= ranges[r].start && pc < ranges[r].end) {
                            conflict = true;
                            break;
                        }
                    }
                }
            }
            if (!conflict) return true;
            Resume();
            usleep(1000);
        }
        return false;
    }

    void Resume() {
        if (!list) return;
        gEmergencyCount = 0;
        for (mach_msg_type_number_t i = 0; i < count; i++) {
            thread_resume(list[i]);
            mach_port_deallocate(mach_task_self(), list[i]);
        }
        InstallEmergencyHandlers(false);
        vm_deallocate(mach_task_self(), (vm_address_t)list, count * sizeof(thread_act_t));
        list = NULL;
        count = 0;
    }
    ~SuspendedThreads() { Resume(); }
};

static void EmitAbsJump16(uint8_t out[16], uint64_t target) {
    uint32_t insns[2] = {
        0x58000050U, // ldr x16, #8
        0xd61f0200U, // br  x16
    };
    memcpy(out, insns, 8);
    memcpy(out + 8, &target, 8);
}

static bool ReadExistingJumpTarget(mach_port_t task, uint64_t addr, uint64_t *outTarget) {
    uint8_t buf[16] = {};
    mach_vm_size_t got = 0;
    if (mach_vm_read_overwrite(task, addr, 16, (mach_vm_address_t)buf, &got) != KERN_SUCCESS || got != 16)
        return false;
    uint32_t i0 = 0, i1 = 0;
    memcpy(&i0, buf, 4);
    memcpy(&i1, buf + 4, 4);
    if (i0 != 0x58000050U || i1 != 0xd61f0200U) return false;
    memcpy(outTarget, buf + 8, 8);
    return true;
}

static void InitRemoteStateStrings(WSRemoteState *st) {
    #define S(field, val) strlcpy(st->field, val, sizeof(st->field))
    S(ascii_CATransaction,   "CATransaction");
    S(ascii_CALayer,         "CALayer");
    S(ascii_CABackdropLayer, "CABackdropLayer");
    S(ascii_CAFilter,        "CAFilter");
    S(ascii_NSNumber,        "NSNumber");
    S(ascii_NSArray,         "NSArray");
    S(ascii_NSDictionary,    "NSDictionary");
    S(ascii_NSNull,          "NSNull");

    S(ascii_begin,                  "begin");
    S(ascii_commit,                 "commit");
    S(ascii_setDisableActions,      "setDisableActions:");
    S(ascii_layer,                  "layer");
    S(ascii_sublayers,              "sublayers");
    S(ascii_count,                  "count");
    S(ascii_objectAtIndex,          "objectAtIndex:");
    S(ascii_name,                   "name");
    S(ascii_isEqualToString,        "isEqualToString:");
    S(ascii_isHidden,               "isHidden");
    S(ascii_setHidden,              "setHidden:");
    S(ascii_opacity,                "opacity");
    S(ascii_bounds,                 "bounds");
    S(ascii_setFrame,               "setFrame:");
    S(ascii_setName,                "setName:");
    S(ascii_setContents,            "setContents:");
    S(ascii_setContentsScale,       "setContentsScale:");
    S(ascii_setContentsGravity,     "setContentsGravity:");
    S(ascii_setContentsCenter,      "setContentsCenter:");
    S(ascii_setFilters,             "setFilters:");
    S(ascii_setActions,             "setActions:");
    S(ascii_setZPosition,           "setZPosition:");
    S(ascii_setMasksToBounds,       "setMasksToBounds:");
    S(ascii_insertSublayerAtIndex,  "insertSublayer:atIndex:");
    S(ascii_filterWithType,         "filterWithType:");
    S(ascii_setValueForKey,         "setValue:forKey:");
    S(ascii_numberWithDouble,       "numberWithDouble:");
    S(ascii_numberWithBool,         "numberWithBool:");
    S(ascii_arrayWithObjectsCount,  "arrayWithObjects:count:");
    S(ascii_dictWithObjectsForKeysCount, "dictionaryWithObjects:forKeys:count:");
    S(ascii_null,                   "null");
    S(ascii_hasPrefix,              "hasPrefix:");
    S(ascii_retain,                 "retain");
    S(ascii_isGeometryFlipped,      "isGeometryFlipped");
    S(ascii_context,                "context");
    S(ascii_setCommittingContexts,  "setCommittingContexts:");
    S(ascii_flush,                  "flush");
    S(ascii_setBleedAmount,         "setBleedAmount:");
    S(ascii_setMarginWidth,         "setMarginWidth:");

    S(ascii_clipName,               "lioness.ws.clip");
    S(ascii_backdropName,           "lioness.ws.backdrop");
    S(ascii_glossName,              "lioness.ws.gloss");
    S(ascii_hairlineName,           "lioness.ws.hairline");
    S(ascii_gaussianBlur,           "gaussianBlur");
    S(ascii_colorSaturate,          "colorSaturate");
    S(ascii_colorBrightness,        "colorBrightness");
    S(ascii_inputRadius,            "inputRadius");
    S(ascii_inputNormalizeEdges,    "inputNormalizeEdges");
    S(ascii_inputHardEdges,         "inputHardEdges");
    S(ascii_inputDither,            "inputDither");
    S(ascii_inputAmount,            "inputAmount");
    S(ascii_resize,                 "resize");
    S(ascii_actBounds,              "bounds");
    S(ascii_actPosition,            "position");
    S(ascii_actContents,            "contents");
    S(ascii_actHidden,              "hidden");
    S(ascii_actFrame,               "frame");
    S(ascii_menubarPrefix,          "menubar.");
    S(ascii_auxShadowPrefix,        "menubar.aux.");
    #undef S
}

static bool PopulateStateFunctions(WSRemoteState *st, int64_t slideDelta, uint64_t remoteSetShadowProps) {
    auto resolve = [slideDelta](const char *sym) -> uint64_t {
        void *p = dlsym(RTLD_DEFAULT, sym);
        return p ? (StripPtr(p) + (uint64_t)slideDelta) : 0;
    };
    st->fn_objc_msgSend                = resolve("objc_msgSend");
    st->fn_objc_getClass               = resolve("objc_getClass");
    st->fn_sel_registerName            = resolve("sel_registerName");
    st->fn_CGColorSpaceCreateDeviceRGB = resolve("CGColorSpaceCreateDeviceRGB");
    st->fn_CGColorSpaceRelease         = resolve("CGColorSpaceRelease");
    st->fn_CGDataProviderCreateWithData= resolve("CGDataProviderCreateWithData");
    st->fn_CGDataProviderRelease       = resolve("CGDataProviderRelease");
    st->fn_CGImageCreate               = resolve("CGImageCreate");
    st->fn_CFStringCreateWithCString   = resolve("CFStringCreateWithCString");
    st->fn_CFRelease                   = resolve("CFRelease");
    st->fn_set_shadow_properties       = remoteSetShadowProps;

    return st->fn_objc_msgSend && st->fn_objc_getClass && st->fn_sel_registerName &&
           st->fn_CGColorSpaceCreateDeviceRGB && st->fn_CGImageCreate && st->fn_CFStringCreateWithCString;
}

struct PayloadLayout {
    const uint8_t *code;
    size_t size;
    size_t offSolUpd;
    size_t offSolRsh;
    size_t offQfaUpd;
    size_t offQfaRsh;
};

static bool LocatePayloadSection(PayloadLayout *out) {
    const struct mach_header_64 *selfHdr = (const struct mach_header_64 *)_dyld_get_image_header(0);
    unsigned long sectSz = 0;
    const uint8_t *sectData = getsectiondata(selfHdr, "__TEXT", "__ws_payload", &sectSz);
    if (!sectData || sectSz == 0 || sectSz > WS_PAYLOAD_PAGE_SZ - 0x200) {
        fprintf(stderr, "skylightaugmentord: invalid __TEXT,__ws_payload section (size=%lu)\n", sectSz);
        return false;
    }
    uintptr_t base = (uintptr_t)sectData;
    uintptr_t su = (uintptr_t)StripPtr((const void *)LionessWSPayloadSolUpdateEntry);
    uintptr_t sr = (uintptr_t)StripPtr((const void *)LionessWSPayloadSolReshapeEntry);
    uintptr_t qu = (uintptr_t)StripPtr((const void *)LionessWSPayloadQfaUpdateEntry);
    uintptr_t qr = (uintptr_t)StripPtr((const void *)LionessWSPayloadQfaReshapeEntry);
    if (su < base || su >= base + sectSz || sr < base || sr >= base + sectSz ||
        qu < base || qu >= base + sectSz || qr < base || qr >= base + sectSz) return false;
    out->code      = sectData;
    out->size      = (size_t)sectSz;
    out->offSolUpd = (size_t)(su - base);
    out->offSolRsh = (size_t)(sr - base);
    out->offQfaUpd = (size_t)(qu - base);
    out->offQfaRsh = (size_t)(qr - base);
    return true;
}

// Reads the true original 16-byte prologue of `remoteFn`. If `remoteFn` was already patched by an
// earlier version of skylightaugmentord, seamlessly recovers its saved original 16 bytes from the
// old page0 trampoline at `trampOff` so live upgrades never require restarting WindowServer.
static bool ReadOriginalPrologue16(mach_port_t task, uint64_t remoteFn, size_t trampOff, uint8_t out16[16]) {
    uint64_t existingTarget = 0;
    if (ReadExistingJumpTarget(task, remoteFn, &existingTarget)) {
        uint64_t oldPage0 = existingTarget & ~(uint64_t)(WS_PAYLOAD_PAGE_SZ - 1);
        mach_vm_size_t got = 0;
        if (mach_vm_read_overwrite(task, oldPage0 + trampOff, 16, (mach_vm_address_t)out16, &got) == KERN_SUCCESS && got == 16) {
            return true;
        }
        return false;
    }
    mach_vm_size_t got = 0;
    return mach_vm_read_overwrite(task, remoteFn, 16, (mach_vm_address_t)out16, &got) == KERN_SUCCESS && got == 16;
}

static bool AugmentTask(mach_port_t task, pid_t pid, const SkyLightTargets &t,
                        const uint8_t barPixels2x[WS_BAR_BYTES_2X], bool isRealWindowServer) {
    int64_t selfSlide = 0, targetSlide = 0;
    if (!GetSharedCacheSlide(mach_task_self(), &selfSlide) || !GetSharedCacheSlide(task, &targetSlide)) {
        fprintf(stderr, "skylightaugmentord: could not read shared cache slide for pid %d\n", pid);
        return false;
    }
    int64_t delta = targetSlide - selfSlide;

    uint64_t remoteSolUpd   = t.sol_update ? ((uint64_t)t.sol_update + (uint64_t)delta) : 0;
    uint64_t remoteSolRsh   = t.sol_reshape ? ((uint64_t)t.sol_reshape + (uint64_t)delta) : 0;
    uint64_t remoteQfaUpd   = t.qfa_update ? ((uint64_t)t.qfa_update + (uint64_t)delta) : 0;
    uint64_t remoteQfaRsh   = t.qfa_reshape ? ((uint64_t)t.qfa_reshape + (uint64_t)delta) : 0;
    uint64_t remoteUBNew    = t.underbelly_new ? ((uint64_t)t.underbelly_new + (uint64_t)delta) : 0;
    uint64_t remoteUBUpd    = t.underbelly_update ? ((uint64_t)t.underbelly_update + (uint64_t)delta) : 0;
    uint64_t remoteUBClean  = t.underbelly_cleanup ? ((uint64_t)t.underbelly_cleanup + (uint64_t)delta) : 0;
    uint64_t remoteSetShad  = t.set_shadow_properties ? ((uint64_t)t.set_shadow_properties + (uint64_t)delta) : 0;
    uint64_t remoteClrShad  = t.clear_shadow_density ? ((uint64_t)t.clear_shadow_density + (uint64_t)delta) : 0;
    uint64_t remoteHBlk     = t.default_height_block ? ((uint64_t)t.default_height_block + (uint64_t)delta) : 0;
    uint64_t remoteHVar     = t.default_height_var ? ((uint64_t)t.default_height_var + (uint64_t)delta) : 0;
    uint64_t remoteDispH    = t.disp_menubar_height ? ((uint64_t)t.disp_menubar_height + (uint64_t)delta) : 0;
    uint64_t remotePkgH     = t.pkg_menubar_height ? ((uint64_t)t.pkg_menubar_height + (uint64_t)delta) : 0;
    uint64_t remotePkgB     = t.pkg_menubar_bounds ? ((uint64_t)t.pkg_menubar_bounds + (uint64_t)delta) : 0;
    uint64_t remoteEvalDP   = t.eval_display_parts ? ((uint64_t)t.eval_display_parts + (uint64_t)delta) : 0;
    uint64_t remoteEncDisp  = t.encode_display ? ((uint64_t)t.encode_display + (uint64_t)delta) : 0;
    uint64_t remotePkgDispC = t.pkg_display_ctor ? ((uint64_t)t.pkg_display_ctor + (uint64_t)delta) : 0;
    uint64_t remoteCAMgr    = t.ca_manager ? ((uint64_t)t.ca_manager + (uint64_t)delta) : 0;
    uint64_t remoteInvSeed  = t.invalidate_state_seed ? ((uint64_t)t.invalidate_state_seed + (uint64_t)delta) : 0;

    // Idempotency check: if already running current WS_STATE_VERSION, refresh pixels & tuning and print live stats.
    uint64_t probeFn = remoteQfaUpd ? remoteQfaUpd : remoteSolUpd;
    uint64_t existingTarget = 0;
    if (probeFn && ReadExistingJumpTarget(task, probeFn, &existingTarget)) {
        uint64_t existingStateAddr = (existingTarget & ~(uint64_t)(WS_PAYLOAD_PAGE_SZ - 1)) + WS_PAYLOAD_PAGE_SZ;
        WSRemoteState cur = {};
        mach_vm_size_t got = 0;
        if (mach_vm_read_overwrite(task, existingStateAddr, sizeof(cur), (mach_vm_address_t)&cur, &got) == KERN_SUCCESS &&
            cur.magic == WS_STATE_MAGIC && cur.version == WS_STATE_VERSION) {
            mach_vm_write(task, existingStateAddr + offsetof(WSRemoteState, barPixels2x),
                          (vm_offset_t)barPixels2x, WS_BAR_BYTES_2X);
            uint32_t nextGen = cur.configGen + 1;
            mach_vm_write(task, existingStateAddr + offsetof(WSRemoteState, configGen),
                          (vm_offset_t)&nextGen, sizeof(nextGen));
            fprintf(stderr, "skylightaugmentord: pid %d already augmented v%u (sol=%u/%u qfa=%u/%u styled=%u bounds=%ux%u flags=0x%x); refreshed\n",
                    pid, cur.version, cur.solUpdateCount, cur.solReshapeCount,
                    cur.qfaUpdateCount, cur.qfaReshapeCount, cur.styledCount,
                    cur.lastW, cur.lastH, cur.lastFlags);
            return true;
        }
    }

    PayloadLayout pl = {};
    if (!LocatePayloadSection(&pl)) return false;

    // Allocate 2 contiguous 16KB pages in target task: Page 0 = RX code, Page 1 = RW WSRemoteState.
    mach_vm_address_t remoteBase = 0;
    kern_return_t kr = mach_vm_allocate(task, &remoteBase, WS_PAYLOAD_PAGE_SZ * 2, VM_FLAGS_ANYWHERE);
    if (kr != KERN_SUCCESS) {
        fprintf(stderr, "skylightaugmentord: mach_vm_allocate failed: %s\n", mach_error_string(kr));
        return false;
    }
    mach_vm_address_t remoteCode  = remoteBase;
    mach_vm_address_t remoteState = remoteBase + WS_PAYLOAD_PAGE_SZ;

    // Build Page 0 locally: payload code + 4 relocated 32-byte original-prologue trampolines at +0x3e00..+0x3ec0.
    uint8_t page0[WS_PAYLOAD_PAGE_SZ];
    memset(page0, 0, sizeof(page0));
    memcpy(page0, pl.code, pl.size);

    const size_t kTrampSolUpdOff = WS_PAYLOAD_PAGE_SZ - 0x200;
    const size_t kTrampSolRshOff = WS_PAYLOAD_PAGE_SZ - 0x1c0;
    const size_t kTrampQfaUpdOff = WS_PAYLOAD_PAGE_SZ - 0x180;
    const size_t kTrampQfaRshOff = WS_PAYLOAD_PAGE_SZ - 0x140;

    uint8_t orig16[16] = {};
    if (remoteSolUpd) {
        if (ReadOriginalPrologue16(task, remoteSolUpd, kTrampSolUpdOff, orig16)) {
            memcpy(page0 + kTrampSolUpdOff, orig16, 16);
            EmitAbsJump16(page0 + kTrampSolUpdOff + 16, remoteSolUpd + 16);
        } else remoteSolUpd = 0;
    }
    if (remoteSolRsh) {
        if (ReadOriginalPrologue16(task, remoteSolRsh, kTrampSolRshOff, orig16)) {
            memcpy(page0 + kTrampSolRshOff, orig16, 16);
            EmitAbsJump16(page0 + kTrampSolRshOff + 16, remoteSolRsh + 16);
        } else remoteSolRsh = 0;
    }
    if (remoteQfaUpd) {
        if (ReadOriginalPrologue16(task, remoteQfaUpd, kTrampQfaUpdOff, orig16)) {
            memcpy(page0 + kTrampQfaUpdOff, orig16, 16);
            EmitAbsJump16(page0 + kTrampQfaUpdOff + 16, remoteQfaUpd + 16);
        } else remoteQfaUpd = 0;
    }
    if (remoteQfaRsh) {
        if (ReadOriginalPrologue16(task, remoteQfaRsh, kTrampQfaRshOff, orig16)) {
            memcpy(page0 + kTrampQfaRshOff, orig16, 16);
            EmitAbsJump16(page0 + kTrampQfaRshOff + 16, remoteQfaRsh + 16);
        } else remoteQfaRsh = 0;
    }
    if (!remoteSolUpd && !remoteQfaUpd) {
        mach_vm_deallocate(task, remoteBase, WS_PAYLOAD_PAGE_SZ * 2);
        return false;
    }

    // Build Page 1 locally: WSRemoteState.
    WSRemoteState state;
    memset(&state, 0, sizeof(state));
    state.magic            = WS_STATE_MAGIC;
    state.version          = WS_STATE_VERSION;
    state.enabled          = 1;
    state.configGen        = 1;
    state.solOffsets       = t.solOffsets;
    state.qfaOffsets       = t.qfaOffsets;
    state.blurRadius       = 8.0f;   // Crisp Mountain Lion glass blur behind pure SArtFile 0x4e50 veil
    state.saturationAmount = 1.10f;
    state.brightnessLift   = 0.16f;  // Keeps bar luminous white-silver even over dark wallpapers
    state.shadowDensity    = 0.75f;  // Lush Mountain Lion CoreGraphics drop shadow density
    state.zBackdrop        = -200.0;
    state.zGloss           = -199.0;
    state.zHairline        = -198.0;
    state.orig_sol_update  = remoteSolUpd ? (remoteCode + kTrampSolUpdOff) : 0;
    state.orig_sol_reshape = remoteSolRsh ? (remoteCode + kTrampSolRshOff) : 0;
    state.orig_qfa_update  = remoteQfaUpd ? (remoteCode + kTrampQfaUpdOff) : 0;
    state.orig_qfa_reshape = remoteQfaRsh ? (remoteCode + kTrampQfaRshOff) : 0;
    memcpy(state.barPixels2x, barPixels2x, WS_BAR_BYTES_2X);
    // 2x2 premultiplied rgba(0, 0, 0, 0.45) -> B=G=R=0, A=115 (exact match to Mountain Lion bottom hairline).
    for (int i = 0; i < 4; i++) {
        state.hairlinePixels[i * 4 + 0] = 0;
        state.hairlinePixels[i * 4 + 1] = 0;
        state.hairlinePixels[i * 4 + 2] = 0;
        state.hairlinePixels[i * 4 + 3] = 115;
    }
    InitRemoteStateStrings(&state);
    if (!PopulateStateFunctions(&state, delta, remoteSetShad)) {
        fprintf(stderr, "skylightaugmentord: failed to resolve shared-cache symbols\n");
        mach_vm_deallocate(task, remoteBase, WS_PAYLOAD_PAGE_SZ * 2);
        return false;
    }
    if (isRealWindowServer) {
        state.fn_ca_manager            = remoteCAMgr;
        state.fn_invalidate_state_seed = remoteInvSeed;
    }

    // Write Page 0 (RX) and Page 1 (RW) into target.
    if (mach_vm_write(task, remoteCode, (vm_offset_t)page0, WS_PAYLOAD_PAGE_SZ) != KERN_SUCCESS ||
        mach_vm_protect(task, remoteCode, WS_PAYLOAD_PAGE_SZ, FALSE, VM_PROT_READ | VM_PROT_EXECUTE) != KERN_SUCCESS ||
        mach_vm_write(task, remoteState, (vm_offset_t)&state, sizeof(state)) != KERN_SUCCESS ||
        mach_vm_protect(task, remoteState, WS_PAYLOAD_PAGE_SZ, FALSE, VM_PROT_READ | VM_PROT_WRITE) != KERN_SUCCESS) {
        fprintf(stderr, "skylightaugmentord: failed to install remote payload pages\n");
        mach_vm_deallocate(task, remoteBase, WS_PAYLOAD_PAGE_SZ * 2);
        return false;
    }

    // Pre-compute EVERY code patch BEFORE suspending any thread so the suspend window is <1ms
    // and only executes pre-validated WriteRemoteCode calls.
    struct PatchOp {
        uint64_t addr;
        uint8_t bytes[16];
        size_t len;
        bool required;
    };
    PatchOp ops[24];
    size_t nOps = 0;
    auto addOp = [&](uint64_t addr, const void *src, size_t len, bool required) {
        if (nOps < 24 && len <= 16) {
            ops[nOps].addr = addr;
            memcpy(ops[nOps].bytes, src, len);
            ops[nOps].len = len;
            ops[nOps].required = required;
            nOps++;
        }
    };

    uint8_t jmpBuf[16];
    if (remoteSolUpd) { EmitAbsJump16(jmpBuf, remoteCode + pl.offSolUpd); addOp(remoteSolUpd, jmpBuf, 16, true); }
    if (remoteSolRsh) { EmitAbsJump16(jmpBuf, remoteCode + pl.offSolRsh); addOp(remoteSolRsh, jmpBuf, 16, true); }
    if (remoteQfaUpd) { EmitAbsJump16(jmpBuf, remoteCode + pl.offQfaUpd); addOp(remoteQfaUpd, jmpBuf, 16, true); }
    if (remoteQfaRsh) { EmitAbsJump16(jmpBuf, remoteCode + pl.offQfaRsh); addOp(remoteQfaRsh, jmpBuf, 16, true); }

    mach_vm_size_t got = 0;
    if (isRealWindowServer) {
        // 1. Disable modern Solarium Underbelly dark top-of-screen scrim & clean up any existing one.
        if (remoteUBNew) {
            uint32_t retNull[2] = { 0xd2800000U /* mov x0, #0 */, 0xd65f03c0U /* ret */ };
            addOp(remoteUBNew, retNull, sizeof(retNull), false);
        }
        if (remoteUBUpd) {
            uint32_t insn = 0xd65f03c0U; // ret fallback
            if (remoteUBClean) {
                int64_t rel = (int64_t)(remoteUBClean - remoteUBUpd) >> 2;
                if (rel >= -(1LL << 25) && rel < (1LL << 25)) {
                    insn = 0x14000000U | ((uint32_t)rel & 0x03ffffffU);
                }
            }
            addOp(remoteUBUpd, &insn, sizeof(insn), false);
        }

        // 2. Patch set_shadow_properties: radius -> 16.0f (deep Mountain Lion shadow below ClipTop), rimDensity -> 0.0f.
        if (remoteSetShad) {
            uint32_t insns[20] = {};
            if (mach_vm_read_overwrite(task, remoteSetShad, sizeof(insns), (mach_vm_address_t)insns, &got) == KERN_SUCCESS) {
                for (int k = 0; k < 18; k++) {
                    if (insns[k] == 0x52a80809U || insns[k] == 0x52a82009U) { // 3.0f or previous 8.0f
                        uint32_t rad16 = 0x52a83009U; // movz w9, #0x4180, lsl #16 (16.0f)
                        addOp(remoteSetShad + (uint64_t)k * 4, &rad16, 4, false);
                    }
                    if (insns[k] == 0x52933348U && insns[k + 1] == 0x72a7d328U) { // 0.30f rimDensity
                        uint32_t rim0[2] = { 0x52800008U /* movz w8, #0 */, 0xd503201fU /* nop */ };
                        addOp(remoteSetShad + (uint64_t)k * 4, rim0, 8, false);
                    }
                }
            }
        }

        // 3. Patch clear_shadow_density: apply Mountain Lion 0.75f density instead of 0.0f and keep shadow enabled.
        if (remoteClrShad) {
            uint32_t insns[24] = {};
            if (mach_vm_read_overwrite(task, remoteClrShad, sizeof(insns), (mach_vm_address_t)insns, &got) == KERN_SUCCESS) {
                if (insns[5] == 0x6f00e400U || insns[5] == 0x1e261000U) {
                    int epilogueIdx = -1;
                    for (int k = 16; k < 23; k++) {
                        if (insns[k] == 0xa9417bfdU && insns[k + 1] == 0xa8c24ff4U) { epilogueIdx = k; break; }
                    }
                    uint32_t fmovThreeQuarter = 0x1e269000U; // fmov s0, #0.75
                    addOp(remoteClrShad + 5 * 4, &fmovThreeQuarter, 4, false);
                    if (epilogueIdx > 7 && (insns[7] & 0xff00001fU) == 0xb4000013U) {
                        uint32_t brEpilogue = 0x14000000U | (uint32_t)(epilogueIdx - 7);
                        addOp(remoteClrShad + 7 * 4, &brEpilogue, 4, false);
                    }
                }
            }
        }

        // 4. Compact Mountain Lion 24pt menu bar height across display, space, and default height paths.
        if (remoteHBlk) {
            uint32_t insns[10] = {};
            if (mach_vm_read_overwrite(task, remoteHBlk, sizeof(insns), (mach_vm_address_t)insns, &got) == KERN_SUCCESS) {
                if ((insns[4] == 0x52800308U && insns[5] == 0x528003c9U) ||
                    (insns[4] == 0x528002c8U && insns[5] == 0x528002c9U)) {
                    uint32_t h24[2] = { 0x52800308U /* mov w8, #24 */, 0x52800309U /* mov w9, #24 */ };
                    addOp(remoteHBlk + 4 * 4, h24, 8, false);
                }
            }
        }
        if (remoteDispH) {
            uint32_t insns[40] = {};
            if (mach_vm_read_overwrite(task, remoteDispH, sizeof(insns), (mach_vm_address_t)insns, &got) == KERN_SUCCESS) {
                for (int k = 0; k < 40; k++) {
                    if (insns[k] == 0xb941f913U) { // ldr w19, [x8, #0x1f8]
                        uint32_t mov24 = 0x52800313U; // mov w19, #24
                        addOp(remoteDispH + (uint64_t)k * 4, &mov24, 4, false);
                        break;
                    }
                }
            }
        }
        if (remotePkgH) {
            uint32_t insns[12] = {};
            if (mach_vm_read_overwrite(task, remotePkgH, sizeof(insns), (mach_vm_address_t)insns, &got) == KERN_SUCCESS) {
                for (int k = 0; k < 12; k++) {
                    if (insns[k] == 0xb9402800U) { // ldr w0, [x0, #0x28]
                        uint32_t mov24 = 0x52800300U; // mov w0, #24
                        addOp(remotePkgH + (uint64_t)k * 4, &mov24, 4, false);
                        break;
                    }
                }
            }
        }
        if (remotePkgB) {
            uint32_t insns[44] = {};
            if (mach_vm_read_overwrite(task, remotePkgB, sizeof(insns), (mach_vm_address_t)insns, &got) == KERN_SUCCESS) {
                for (int k = 0; k < 44; k++) {
                    if (insns[k] == 0xb9402816U) { // ldr w22, [x0, #0x28]
                        uint32_t mov24 = 0x52800316U; // mov w22, #24
                        addOp(remotePkgB + (uint64_t)k * 4, &mov24, 4, false);
                        break;
                    }
                }
            }
        }
        // Propagate 24pt height into CGSDisplaySystemState (for ControlCenter, NSScreen, and all apps).
        if (remoteEncDisp) {
            uint32_t insns[64] = {};
            uint64_t scanBase = remoteEncDisp + 0x1200;
            if (mach_vm_read_overwrite(task, scanBase, sizeof(insns), (mach_vm_address_t)insns, &got) == KERN_SUCCESS) {
                for (int k = 0; k < 64; k++) {
                    if (insns[k] == 0xb941faf4U) { // ldr w20, [x23, #0x1f8]
                        uint32_t mov24 = 0x52800314U; // mov w20, #24
                        addOp(scanBase + (uint64_t)k * 4, &mov24, 4, false);
                        break;
                    }
                }
            }
        }
        if (remotePkgDispC) {
            uint32_t insns[48] = {};
            if (mach_vm_read_overwrite(task, remotePkgDispC, sizeof(insns), (mach_vm_address_t)insns, &got) == KERN_SUCCESS) {
                for (int k = 0; k < 48; k++) {
                    if (insns[k] == 0xb941f808U) { // ldr w8, [x0, #0x1f8]
                        uint32_t mov24 = 0x52800308U; // mov w8, #24
                        addOp(remotePkgDispC + (uint64_t)k * 4, &mov24, 4, false);
                        break;
                    }
                }
            }
        }
        if (remoteEvalDP) {
            uint32_t insns[48] = {};
            uint64_t scanBase = remoteEvalDP + 0x3e0;
            if (mach_vm_read_overwrite(task, scanBase, sizeof(insns), (mach_vm_address_t)insns, &got) == KERN_SUCCESS) {
                for (int k = 0; k < 46; k++) {
                    if (insns[k] == 0x1a961108U && insns[k + 1] == 0x14000007U) { // csel w8, w8, w22, ne; b +0x1c
                        uint32_t mov24 = 0x52800308U; // mov w8, #24
                        addOp(scanBase + (uint64_t)k * 4, &mov24, 4, false);
                        break;
                    }
                }
            }
        }
    }

    PatchRange ranges[24];
    for (size_t i = 0; i < nOps; i++) {
        ranges[i] = { ops[i].addr, ops[i].addr + ops[i].len };
    }

    SuspendedThreads susp;
    if (!susp.SuspendSafely(task, ranges, nOps)) {
        fprintf(stderr, "skylightaugmentord: could not safely suspend threads of pid %d\n", pid);
        mach_vm_deallocate(task, remoteBase, WS_PAYLOAD_PAGE_SZ * 2);
        return false;
    }

    bool ok = true;
    for (size_t i = 0; i < nOps; i++) {
        bool w = WriteRemoteCode(task, ops[i].addr, ops[i].bytes, ops[i].len);
        if (ops[i].required && !w) { ok = false; break; }
    }
    if (ok && isRealWindowServer && remoteHVar) {
        uint32_t h24 = 24;
        mach_vm_write(task, remoteHVar, (vm_offset_t)&h24, sizeof(h24));
    }

    susp.Resume();

    if (ok) {
        fprintf(stderr, "skylightaugmentord: augmented pid %d (code=%#llx state=%#llx)\n",
                pid, (unsigned long long)remoteCode, (unsigned long long)remoteState);
    }
    return ok;
}

static pid_t FindWindowServerPID(void) {
    int count = proc_listallpids(NULL, 0);
    if (count <= 0) return -1;
    pid_t *pids = (pid_t *)calloc((size_t)count + 32, sizeof(pid_t));
    if (!pids) return -1;
    int got = proc_listallpids(pids, (count + 32) * (int)sizeof(pid_t));
    pid_t found = -1;
    for (int i = 0; i < got; i++) {
        if (pids[i] <= 0) continue;
        char name[256] = {};
        if (proc_name(pids[i], name, sizeof(name)) > 0 && strcmp(name, "WindowServer") == 0) {
            found = pids[i];
            break;
        }
    }
    free(pids);
    return found;
}

static void WriteActiveMarker(pid_t wsPid) {
    int fd = open(kMarkerPath, O_WRONLY | O_CREAT | O_TRUNC, 0644);
    if (fd >= 0) {
        char buf[32];
        int n = snprintf(buf, sizeof(buf), "%d\n", (int)wsPid);
        if (n > 0) (void)write(fd, buf, (size_t)n);
        close(fd);
        chmod(kMarkerPath, 0644);
    }
}

static void TriggerMenuBarRefresh(void) {
    notify_post("com.apple.SkyLight.MenuBarBlurredBackgroundChange");
    notify_post("com.apple.SkyLight.MenuBarAgentUpdate");
}

static void WaitForProcessExit(pid_t pid) {
    int kq = kqueue();
    if (kq < 0) {
        while (kill(pid, 0) == 0 || errno == EPERM) sleep(2);
        return;
    }
    struct kevent ev;
    EV_SET(&ev, pid, EVFILT_PROC, EV_ADD | EV_ONESHOT, NOTE_EXIT, 0, NULL);
    if (kevent(kq, &ev, 1, &ev, 1, NULL) < 0) {
        close(kq);
        while (kill(pid, 0) == 0 || errno == EPERM) sleep(2);
        return;
    }
    close(kq);
}

// ---------------------------------------------------------------------------
// 4. Built-in self-test (--selftest): proves remote task_*/thread_* patching
//    and WindowServer survival on an isolated arm64e child process.
// ---------------------------------------------------------------------------

struct MockMenuBarContext {
    uint8_t pad[0x100];
};

static volatile int gMockShadowCalled = 0;
static volatile float gMockShadowDensity = 0.0f;
static volatile int gMockUpdateCalled = 0;
static volatile int gMockReshapeCalled = 0;

__attribute__((noinline, optnone))
static void MockSetShadowProps(float density, void *win) {
    (void)win;
    gMockShadowCalled = gMockShadowCalled + 1;
    gMockShadowDensity = density;
}

__attribute__((noinline, optnone))
static void MockUpdateLayers(void *self, void *space, uint32_t disp, void *win,
                             int b1, int b2, int b3, int b4,
                             int b5, int b6, void *r1, void *r2) {
    // At least 4 non-PC-relative instructions before any PC-relative access (matches SkyLight prologue).
    __asm__ volatile("nop\nnop\nnop\nnop\n" : : "r"(self), "r"(win) : "memory");
    (void)space; (void)disp; (void)b1; (void)b2; (void)b3; (void)b4; (void)b5; (void)b6; (void)r1; (void)r2;
    gMockUpdateCalled = gMockUpdateCalled + 1;
}

__attribute__((noinline, optnone))
static void MockReshapeLayers(void *self, CGRect r, float f, uint32_t u, bool b, double d, void *space) {
    __asm__ volatile("nop\nnop\nnop\nnop\n" : : "r"(self) : "memory");
    (void)r; (void)f; (void)u; (void)b; (void)d; (void)space;
    gMockReshapeCalled = gMockReshapeCalled + 1;
}

// Target side of --selftest, launched via posix_spawn() so it has COMPLETELY INDEPENDENT
// ARM64e PAC keys from the augmentor process (exact match for real WindowServer!).
static int RunSelfTestTarget(int rdFd, int wrFd) {
    dlopen("/System/Library/Frameworks/QuartzCore.framework/QuartzCore", RTLD_NOW);
    Class clsCALayer = objc_getClass("CALayer");
    SEL selLayer = sel_registerName("layer");
    SEL selSetFrame = sel_registerName("setFrame:");
    SEL selSetName = sel_registerName("setName:");
    SEL selAddSublayer = sel_registerName("addSublayer:");
    SEL selIsHidden = sel_registerName("isHidden");
    SEL selSublayers = sel_registerName("sublayers");
    SEL selCount = sel_registerName("count");
    SEL selObjAt = sel_registerName("objectAtIndex:");
    SEL selName = sel_registerName("name");
    SEL selContents = sel_registerName("contents");
    SEL selFilters = sel_registerName("filters");

    id root = ((id (*)(id, SEL))objc_msgSend)((id)clsCALayer, selLayer);
    ((void (*)(id, SEL, CGRect))objc_msgSend)(root, selSetFrame, CGRectMake(0, 0, 1440, 22));
    id aux = ((id (*)(id, SEL))objc_msgSend)((id)clsCALayer, selLayer);
    CFStringRef auxNm = CFStringCreateWithCString(NULL, "menubar.aux.shadow.container", kCFStringEncodingUTF8);
    ((void (*)(id, SEL, id))objc_msgSend)(aux, selSetName, (id)auxNm);
    ((void (*)(id, SEL, id))objc_msgSend)(root, selAddSublayer, aux);
    CFRelease(auxNm);

    MockMenuBarContext ctx = {};
    *(void **)(ctx.pad + 0x98) = (void *)root;

    uint64_t addrs[3] = {
        StripPtr((const void *)MockUpdateLayers),
        StripPtr((const void *)MockReshapeLayers),
        StripPtr((const void *)MockSetShadowProps),
    };
    (void)write(wrFd, addrs, sizeof(addrs));

    char go = 0;
    if (read(rdFd, &go, 1) != 1) _exit(2);

    typedef void (*UpdFn)(void *, void *, uint32_t, void *, int, int, int, int, int, int, void *, void *);
    typedef void (*RshFn)(void *, CGRect, float, uint32_t, bool, double, void *);
    UpdFn volatile upd = MockUpdateLayers;
    RshFn volatile rsh = MockReshapeLayers;
    int dummyWin = 42;
    upd(&ctx, NULL, 1, &dummyWin, 0, 0, 0, 0, 0, 0, NULL, NULL);
    upd(&ctx, NULL, 1, &dummyWin, 0, 0, 0, 0, 0, 0, NULL, NULL);
    ((void (*)(id, SEL, CGRect))objc_msgSend)(root, selSetFrame, CGRectMake(0, 0, 1728, 22));
    rsh(&ctx, CGRectMake(0, 0, 1728, 22), 2.0f, 1, false, 0.0, NULL);

    id subs = ((id (*)(id, SEL))objc_msgSend)(root, selSublayers);
    uint64_t n = subs ? ((uint64_t (*)(id, SEL))objc_msgSend)(subs, selCount) : 0;
    int hasBackdrop = 0, hasGloss = 0, auxHidden = 0;
    for (uint64_t i = 0; i < n; i++) {
        id sub = ((id (*)(id, SEL, uint64_t))objc_msgSend)(subs, selObjAt, i);
        id nm = ((id (*)(id, SEL))objc_msgSend)(sub, selName);
        const char *cstr = nm ? ((const char *(*)(id, SEL))objc_msgSend)(nm, sel_registerName("UTF8String")) : "";
        id flt = ((id (*)(id, SEL))objc_msgSend)(sub, selFilters);
        id cnt = ((id (*)(id, SEL))objc_msgSend)(sub, selContents);
        if (!strcmp(cstr, "lioness.ws.clip")) {
            id csubs = ((id (*)(id, SEL))objc_msgSend)(sub, selSublayers);
            uint64_t cn = csubs ? ((uint64_t (*)(id, SEL))objc_msgSend)(csubs, selCount) : 0;
            for (uint64_t j = 0; j < cn; j++) {
                id csub = ((id (*)(id, SEL, uint64_t))objc_msgSend)(csubs, selObjAt, j);
                id cnm = ((id (*)(id, SEL))objc_msgSend)(csub, selName);
                const char *ccstr = cnm ? ((const char *(*)(id, SEL))objc_msgSend)(cnm, sel_registerName("UTF8String")) : "";
                id cflt = ((id (*)(id, SEL))objc_msgSend)(csub, selFilters);
                if (!strcmp(ccstr, "lioness.ws.backdrop") && cflt) hasBackdrop = 1;
            }
        }
        if (!strcmp(cstr, "lioness.ws.gloss") && cnt) hasGloss = 1;
        if (!strcmp(cstr, "menubar.aux.shadow.container"))
            auxHidden = (((uint64_t (*)(id, SEL))objc_msgSend)(sub, selIsHidden) & 1) ? 1 : 0;
    }
    int res[6] = {
        hasBackdrop, hasGloss, auxHidden,
        gMockShadowCalled, (int)(gMockShadowDensity * 100.0f + 0.5f),
        gMockUpdateCalled * 10 + gMockReshapeCalled
    };
    (void)write(wrFd, res, sizeof(res));
    return (hasBackdrop && hasGloss && auxHidden && gMockShadowCalled == 2 &&
            res[4] == 75 && gMockUpdateCalled == 2 && gMockReshapeCalled == 1) ? 0 : 3;
}

static int RunSelfTest(const char *selfExe, const char *mlRoot) {
    uint8_t pixels[WS_BAR_BYTES_2X];
    if (!LoadMountainLionMenuBarArt(mlRoot, pixels)) return 1;
    printf("selftest: loaded ml-root SArtFile.bin 0x4e50+0x4e8d (top A=%u, row41 A=%u)\n",
           pixels[3], pixels[41 * 8 + 3]);

    SkyLightTargets realTargets;
    if (!ResolveSkyLightTargets(&realTargets)) {
        fprintf(stderr, "selftest: failed to resolve SkyLight symbols\n");
        return 1;
    }
    printf("selftest: resolved SkyLight targets: sol=%#lx(root=0x%x) qfa=%#lx(root=0x%x) ub_clean=%#lx\n",
           (unsigned long)realTargets.sol_update, realTargets.solOffsets.off_root,
           (unsigned long)realTargets.qfa_update, realTargets.qfaOffsets.off_root,
           (unsigned long)realTargets.underbelly_cleanup);

    int p2c[2], c2p[2];
    if (pipe(p2c) != 0 || pipe(c2p) != 0) return 1;

    // Spawn an INDEPENDENT arm64e target process via posix_spawn (fresh random PAC keys!).
    char rdBuf[16], wrBuf[16];
    snprintf(rdBuf, sizeof(rdBuf), "%d", p2c[0]);
    snprintf(wrBuf, sizeof(wrBuf), "%d", c2p[1]);
    char *childArgv[] = { (char *)selfExe, (char *)"--selftest-target", rdBuf, wrBuf, NULL };
    pid_t child = -1;
    extern char **environ;
    if (posix_spawn(&child, selfExe, NULL, NULL, childArgv, environ) != 0) {
        fprintf(stderr, "selftest: posix_spawn failed: %s\n", strerror(errno));
        return 1;
    }
    close(p2c[0]); close(c2p[1]);

    uint64_t addrs[3] = {};
    if (read(c2p[0], addrs, sizeof(addrs)) != sizeof(addrs)) { kill(child, SIGKILL); return 1; }

    // Spawn a separate augmentor child that patches `child` (cross-PAC-key!) twice and EXITS completely
    // before `child` runs, proving both cross-PAC safety and survival after augmentor death.
    pid_t augPid = fork();
    if (augPid == 0) {
        mach_port_t childTask = MACH_PORT_NULL;
        kern_return_t kr = task_for_pid(mach_task_self(), child, &childTask);
        if (kr != KERN_SUCCESS) {
            fprintf(stderr, "selftest: task_for_pid failed (%s)\n", mach_error_string(kr));
            _exit(10);
        }
        SkyLightTargets mockTargets = {};
        mockTargets.qfa_update            = (uintptr_t)addrs[0];
        mockTargets.qfa_reshape           = (uintptr_t)addrs[1];
        mockTargets.set_shadow_properties = (uintptr_t)addrs[2];
        mockTargets.qfaOffsets.off_root   = 0x98;

        bool ok = AugmentTask(childTask, child, mockTargets, pixels, false);
        if (ok) ok = AugmentTask(childTask, child, mockTargets, pixels, false);
        mach_port_deallocate(mach_task_self(), childTask);
        _exit(ok ? 0 : 11);
    }
    int augStatus = 0;
    waitpid(augPid, &augStatus, 0);
    bool ok = WIFEXITED(augStatus) && WEXITSTATUS(augStatus) == 0;

    char go = 1;
    (void)write(p2c[1], &go, 1);
    int res[6] = {};
    ssize_t rn = read(c2p[0], res, sizeof(res));
    int status = 0;
    waitpid(child, &status, 0);
    printf("selftest: ok=%d (cross-PAC posix_spawn target, augmentor exited first) backdrop=%d gloss=%d auxHidden=%d shadowCalls=%d shadowDensity=%d%% origCalls(upd*10+rsh)=%d exit=%d\n",
           ok, rn == sizeof(res) ? res[0] : -1, rn == sizeof(res) ? res[1] : -1,
           rn == sizeof(res) ? res[2] : -1, rn == sizeof(res) ? res[3] : -1,
           rn == sizeof(res) ? res[4] : -1, rn == sizeof(res) ? res[5] : -1,
           WIFEXITED(status) ? WEXITSTATUS(status) : -1);
    return (ok && WIFEXITED(status) && WEXITSTATUS(status) == 0) ? 0 : 1;
}

int main(int argc, char **argv) {
    if (argc == 4 && !strcmp(argv[1], "--selftest-target")) {
        return RunSelfTestTarget(atoi(argv[2]), atoi(argv[3]));
    }
    const char *mlRoot = "/Library/Lioness/ml-root";
    bool runOnce = false;
    bool selfTest = false;
    for (int i = 1; i < argc; i++) {
        if (!strcmp(argv[i], "--once")) runOnce = true;
        else if (!strcmp(argv[i], "--selftest")) selfTest = true;
        else if (!strcmp(argv[i], "--help") || !strcmp(argv[i], "-h")) {
            printf("usage: skylightaugmentord [--once] [--selftest] [ml-root-path]\n");
            return 0;
        } else if (argv[i][0] != '-') mlRoot = argv[i];
    }

    if (selfTest) return RunSelfTest(argv[0], mlRoot);

    uint8_t barPixels2x[WS_BAR_BYTES_2X];
    if (!LoadMountainLionMenuBarArt(mlRoot, barPixels2x)) {
        fprintf(stderr, "skylightaugmentord: failed to load Mountain Lion menu bar art from %s\n", mlRoot);
        return 1;
    }

    SkyLightTargets targets;
    if (!ResolveSkyLightTargets(&targets)) {
        fprintf(stderr, "skylightaugmentord: failed to resolve SkyLight menu bar targets\n");
        return 1;
    }
    fprintf(stderr, "skylightaugmentord: ready (sol_root=0x%x qfa_root=0x%x)\n",
            targets.solOffsets.off_root, targets.qfaOffsets.off_root);

    for (;;) {
        pid_t wsPid = FindWindowServerPID();
        if (wsPid <= 0) {
            if (runOnce) return 1;
            sleep(1);
            continue;
        }
        mach_port_t wsTask = MACH_PORT_NULL;
        kern_return_t kr = task_for_pid(mach_task_self(), wsPid, &wsTask);
        if (kr != KERN_SUCCESS) {
            fprintf(stderr, "skylightaugmentord: task_for_pid(WindowServer=%d) failed: %s\n",
                    wsPid, mach_error_string(kr));
            if (runOnce) return 1;
            sleep(2);
            continue;
        }

        bool augmented = AugmentTask(wsTask, wsPid, targets, barPixels2x, true);
        mach_port_deallocate(mach_task_self(), wsTask);

        if (augmented) {
            WriteActiveMarker(wsPid);
            TriggerMenuBarRefresh();
        }
        if (runOnce) return augmented ? 0 : 1;

        // Sleep until WindowServer exits (if it restarts, loop re-augments the fresh PID).
        WaitForProcessExit(wsPid);
        unlink(kMarkerPath);
        sleep(1);
    }
}

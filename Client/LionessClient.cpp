#include "LionessClient.h"
#include <bootstrap.h>
#include <mach/mach.h>
#include <mutex>
#include <stdio.h>
#include <stdlib.h>
#include <servers/bootstrap.h>
#include <stddef.h>
#include <string.h>
#include <string>
#include <time.h>
#include <unordered_map>
#include <vector>

namespace {

constexpr mach_msg_timeout_t kTimeoutMs = 1000;
constexpr time_t kRetrySeconds = 5;

struct Key {
    LionessRequest r;
    bool operator==(const Key &o) const { return !memcmp(&r, &o.r, sizeof r); }
};
struct KeyHash {
    size_t operator()(const Key &k) const {
        const uint32_t *w = (const uint32_t *)&k.r;
        size_t h = 14695981039346656037ull;
        for (size_t i = 0; i < sizeof k.r / 4; i++) h = (h ^ w[i]) * 1099511628211ull;
        return h;
    }
};

std::mutex gLock;
std::unordered_map<Key, CGImageRef, KeyHash> gCache;   // a failure is cached too, so a bad request is asked once
mach_port_t gService = MACH_PORT_NULL;
time_t gNextLookup = 0;

extern "C" int64_t sandbox_extension_consume(const char *token);

// A sandboxed app may not look the service up without this. It is harmless to try in an app that is not.
void ConsumeSandboxToken() {
    static bool consumed;
    if (consumed) return;
    const char *fromEnvironment = getenv("LIONESS_TOKEN");
    char token[4096] = {0};
    if (fromEnvironment) {
        strlcpy(token, fromEnvironment, sizeof token);
    } else {
        FILE *f = fopen(LIONESS_TOKEN_PATH, "r");
        if (!f) { if (getenv("LIONESS_DUMP")) fprintf(stderr, "TOKEN unreadable\n"); return; }
        size_t n = fread(token, 1, sizeof token - 1, f);
        fclose(f);
        token[n] = 0;
    }
    int64_t handle = sandbox_extension_consume(token);
    if (getenv("LIONESS_DUMP")) fprintf(stderr, "TOKEN consume=%lld\n", (long long)handle);
    consumed = handle >= 0;
}

// With gLock held. A daemon that is gone is looked for again every few seconds, not on every draw.
mach_port_t Service() {
    if (gService) return gService;
    time_t now = time(NULL);
    if (now < gNextLookup) return MACH_PORT_NULL;
    ConsumeSandboxToken();
    const char *testService = getenv("LIONESS_APPKITD_TEST_SERVICE");   // a test's own appkitd, beside the installed one
    if (bootstrap_look_up(bootstrap_port, testService ? testService : LIONESS_SERVICE, &gService) != KERN_SUCCESS) {
        gService = MACH_PORT_NULL;
        gNextLookup = now + kRetrySeconds;
    }
    return gService;
}

void ReleasePixels(void *, const void *data, size_t size) {
    vm_deallocate(mach_task_self(), (vm_address_t)data, size);
}

// With gLock held. `message` has its body filled in; `sendSize` of it goes out and the reply comes back in it.
CGImageRef Exchange(mach_msg_header_t *message, mach_msg_size_t sendSize, mach_msg_size_t room, int id, int *status) {
    mach_port_t service = Service();
    if (!service) { if (status) *status = MACH_SEND_INVALID_DEST; return NULL; }

    union Received {
        mach_msg_header_t header;
        struct { LionessReplyMessage reply; mach_msg_trailer_t trailer; } received;
    };
    Received &m = *(Received *)message;
    mach_port_t reply = mig_get_reply_port();
    message->msgh_bits = MACH_MSGH_BITS(MACH_MSG_TYPE_COPY_SEND, MACH_MSG_TYPE_MAKE_SEND_ONCE);
    message->msgh_size = sendSize;
    message->msgh_remote_port = service;
    message->msgh_local_port = reply;
    message->msgh_id = id;
    mach_msg_return_t kr = mach_msg(message, MACH_SEND_MSG | MACH_RCV_MSG | MACH_SEND_TIMEOUT | MACH_RCV_TIMEOUT,
                                    sendSize, room, reply, kTimeoutMs, MACH_PORT_NULL);
    if (kr != MACH_MSG_SUCCESS) {
        if (kr == MACH_SEND_INVALID_DEST || kr == MACH_RCV_TIMED_OUT || kr == MACH_SEND_TIMED_OUT) {
            mach_port_deallocate(mach_task_self(), service);
            gService = MACH_PORT_NULL;
            gNextLookup = time(NULL) + kRetrySeconds;
        }
        if (kr == MACH_RCV_TIMED_OUT) {   // the answer may still come; this reply port must not see it
            mig_dealloc_reply_port(reply);
        }
        if (status) *status = kr;
        return NULL;
    }
    const LionessReplyMessage &r = m.received.reply;
    if (r.header.msgh_id != id + 100 || !(r.header.msgh_bits & MACH_MSGH_BITS_COMPLEX)) {
        mach_msg_destroy(message);
        if (status) *status = MIG_REMOTE_ERROR;
        return NULL;
    }
    if (status) *status = (int)r.info.status;
    size_t size = r.pixels.size;
    void *pixels = r.pixels.address;
    size_t expected = (size_t)r.info.rowBytes * r.info.pixelHeight;
    if (r.info.status != 0 || r.info.blank || !pixels || size < expected) {
        if (pixels) vm_deallocate(mach_task_self(), (vm_address_t)pixels, size);
        return NULL;
    }
    CGDataProviderRef provider = CGDataProviderCreateWithData(NULL, pixels, size, ReleasePixels);
    CGColorSpaceRef space = CGColorSpaceCreateDeviceRGB();
    CGImageRef image = CGImageCreate(r.info.pixelWidth, r.info.pixelHeight, 8, 32, r.info.rowBytes, space,
                                     kCGImageAlphaPremultipliedFirst | kCGBitmapByteOrder32Little, provider, NULL, false,
                                     kCGRenderingIntentDefault);
    CGColorSpaceRelease(space);
    CGDataProviderRelease(provider);
    return image;
}

CGImageRef Ask(const LionessRequest *request, int *status) {
    union {
        LionessRequestMessage request;
        struct { LionessReplyMessage reply; mach_msg_trailer_t trailer; } received;
    } m;
    memset(&m, 0, sizeof m);
    m.request.request = *request;
    return Exchange(&m.request.header, sizeof m.request, sizeof m, LIONESS_MSG_RENDER, status);
}

// Drawn pictures come in every size a window is resized through, so this cache is bounded.
constexpr size_t kMaxDrawn = 1024;
std::unordered_map<std::string, CGImageRef> gDrawn;

// Only what a property list can carry. AppKit's options are strings and numbers for everything
// traced, and anything else is left out rather than failing the widget.
CFDictionaryRef CreateCleanOptions(CFDictionaryRef options) {
    CFIndex count = CFDictionaryGetCount(options);
    std::vector<const void *> keys(count), values(count);
    CFDictionaryGetKeysAndValues(options, keys.data(), values.data());
    CFMutableDictionaryRef clean = CFDictionaryCreateMutable(NULL, count, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    for (CFIndex i = 0; i < count; i++)
        if (CFPropertyListIsValid(values[i], kCFPropertyListBinaryFormat_v1_0)) CFDictionarySetValue(clean, keys[i], values[i]);
    return clean;
}

} // namespace

extern "C" CGImageRef LionessCopyDrawnImage(CFDictionaryRef options, uint32_t width, uint32_t height, uint32_t scale) {
    CFDictionaryRef clean = CreateCleanOptions(options);
    CFDataRef data = CFPropertyListCreateData(NULL, clean, kCFPropertyListBinaryFormat_v1_0, 0, NULL);
    CFRelease(clean);
    if (!data || (size_t)CFDataGetLength(data) > LIONESS_MAX_OPTIONS) { if (data) CFRelease(data); return NULL; }

    std::string key((const char *)CFDataGetBytePtr(data), (size_t)CFDataGetLength(data));
    key.append((const char *)&width, sizeof width);
    key.append((const char *)&height, sizeof height);
    key.append((const char *)&scale, sizeof scale);

    std::lock_guard<std::mutex> lock(gLock);
    auto found = gDrawn.find(key);
    if (found != gDrawn.end()) {
        CFRelease(data);
        return found->second ? CGImageRetain(found->second) : NULL;
    }
    static thread_local union {
        LionessDrawMessage draw;
        struct { LionessReplyMessage reply; mach_msg_trailer_t trailer; } received;
    } m;
    m.draw.width = width;
    m.draw.height = height;
    m.draw.scale = scale;
    m.draw.length = (uint32_t)CFDataGetLength(data);
    memcpy(m.draw.options, CFDataGetBytePtr(data), m.draw.length);
    mach_msg_size_t sendSize = (mach_msg_size_t)(offsetof(LionessDrawMessage, options) + ((m.draw.length + 3) & ~3u));
    CFRelease(data);

    int status = 0;
    CGImageRef image = Exchange(&m.draw.header, sendSize, sizeof m, LIONESS_MSG_DRAW, &status);
    bool answered = image || (status != MACH_SEND_INVALID_DEST && status != MACH_RCV_TIMED_OUT && status != MACH_SEND_TIMED_OUT);
    if (answered) {
        if (gDrawn.size() >= kMaxDrawn) {
            for (auto &entry : gDrawn) if (entry.second) CGImageRelease(entry.second);
            gDrawn.clear();
        }
        gDrawn[key] = image ? CGImageRetain(image) : NULL;
    }
    return image;
}

extern "C" CGImageRef LionessCopyCachedImage(const LionessRequest *request, int *status) {
    Key key;
    memset(&key, 0, sizeof key);
    key.r = *request;
    std::lock_guard<std::mutex> lock(gLock);
    auto found = gCache.find(key);
    if (found != gCache.end()) { if (status) *status = 0; return found->second; }
    CGImageRef image = Ask(request, status);
    // A missing daemon is not an answer about this control, so only a real reply is remembered.
    if (image || (status && *status != MACH_SEND_INVALID_DEST && *status != MACH_RCV_TIMED_OUT && *status != MACH_SEND_TIMED_OUT))
        gCache[key] = image;
    return image;
}

bool LionessIsReachable(void) {
    std::lock_guard<std::mutex> lock(gLock);
    return Service() != MACH_PORT_NULL;
}

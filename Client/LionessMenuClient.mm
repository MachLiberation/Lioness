#import "LionessMenuClient.h"
#import <AppKit/AppKit.h>
#import "../Shared/MenuProtocol.h"

#include <bootstrap.h>
#include <mach/mach.h>
#include <mutex>
#include <servers/bootstrap.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

extern "C" int64_t sandbox_extension_consume(const char *token);

namespace {

constexpr time_t kRetrySeconds = 3;
constexpr mach_msg_timeout_t kPingTimeoutMs = 250;

std::mutex gMenuLock;
mach_port_t gMenuService = MACH_PORT_NULL;
time_t gNextMenuLookup = 0;

void ConsumeMenuSandboxToken() {
    static bool consumed = false;
    if (consumed) return;
    char token[4096] = {};
    FILE *f = fopen(LIONESS_MENU_TOKEN_PATH, "r");
    if (!f) return;
    size_t n = fread(token, 1, sizeof(token) - 1, f);
    fclose(f);
    token[n] = '\0';
    if (n > 0) {
        int64_t h = sandbox_extension_consume(token);
        consumed = (h >= 0);
    }
}

mach_port_t MenuServicePort() {
    if (gMenuService != MACH_PORT_NULL) return gMenuService;
    time_t now = time(NULL);
    if (now < gNextMenuLookup) return MACH_PORT_NULL;
    ConsumeMenuSandboxToken();
    mach_port_t port = MACH_PORT_NULL;
    if (bootstrap_look_up(bootstrap_port, LIONESS_MENU_SERVICE, &port) == KERN_SUCCESS && port != MACH_PORT_NULL) {
        gMenuService = port;
    } else {
        gNextMenuLookup = now + kRetrySeconds;
    }
    return gMenuService;
}

void ResetMenuServicePortLocked(mach_port_t badPort) {
    if (gMenuService == badPort && gMenuService != MACH_PORT_NULL) {
        mach_port_deallocate(mach_task_self(), gMenuService);
        gMenuService = MACH_PORT_NULL;
        gNextMenuLookup = time(NULL) + kRetrySeconds;
    }
}

} // namespace

namespace {

bool SendKeyToMenud(mach_port_t service, NSEvent *e) {
    LionessMenuKeyMessage msg = {};
    msg.header.msgh_bits = MACH_MSGH_BITS(MACH_MSG_TYPE_COPY_SEND, 0);
    msg.header.msgh_size = sizeof(msg);
    msg.header.msgh_remote_port = service;
    msg.header.msgh_id = LIONESS_MENU_MSG_KEY;
    msg.keyCode = e.keyCode;
    msg.modifiers = (uint32_t)(e.modifierFlags & 0xffffffffu);
    NSString *chars = e.charactersIgnoringModifiers;
    msg.character = chars.length ? [chars characterAtIndex:0] : 0;
    return mach_msg(&msg.header, MACH_SEND_MSG | MACH_SEND_TIMEOUT, sizeof(msg), 0,
                    MACH_PORT_NULL, 100, MACH_PORT_NULL) == MACH_MSG_SUCCESS;
}

bool PortIsDead(mach_port_t port) {
    mach_port_type_t type = 0;
    if (mach_port_type(mach_task_self(), port, &type) != KERN_SUCCESS) return true;
    return (type & MACH_PORT_TYPE_DEAD_NAME) != 0;
}

} // namespace

static BOOL PingMenuServer(bool *portWasDead);

// menud restarts (it is a KeepAlive agent): a cached port that has died is looked up again at
// once, so the first menu after a restart doesn't fall back to AppKit's.
extern "C" BOOL LionessMenuServerIsReachable(void) {
    bool dead = false;
    if (PingMenuServer(&dead)) return YES;
    if (!dead) return NO;
    {
        std::lock_guard<std::mutex> lock(gMenuLock);
        gNextMenuLookup = 0;
    }
    return PingMenuServer(&dead);
}

static BOOL PingMenuServer(bool *portWasDead) {
    *portWasDead = false;
    mach_port_t service = MACH_PORT_NULL;
    {
        std::lock_guard<std::mutex> lock(gMenuLock);
        service = MenuServicePort();
        if (service != MACH_PORT_NULL) {
            mach_port_mod_refs(mach_task_self(), service, MACH_PORT_RIGHT_SEND, 1);
        }
    }
    if (service == MACH_PORT_NULL) return NO;

    mach_port_t reply = MACH_PORT_NULL;
    if (mach_port_allocate(mach_task_self(), MACH_PORT_RIGHT_RECEIVE, &reply) != KERN_SUCCESS) {
        mach_port_deallocate(mach_task_self(), service);
        return NO;
    }

    struct {
        LionessMenuSimpleMessage msg;
        mach_msg_trailer_t trailer;
    } buf = {};
    buf.msg.header.msgh_bits = MACH_MSGH_BITS(MACH_MSG_TYPE_COPY_SEND, MACH_MSG_TYPE_MAKE_SEND_ONCE);
    buf.msg.header.msgh_size = sizeof(LionessMenuSimpleMessage);
    buf.msg.header.msgh_remote_port = service;
    buf.msg.header.msgh_local_port = reply;
    buf.msg.header.msgh_id = LIONESS_MENU_MSG_PING;

    mach_msg_return_t kr = mach_msg(&buf.msg.header,
                                    MACH_SEND_MSG | MACH_RCV_MSG | MACH_SEND_TIMEOUT | MACH_RCV_TIMEOUT,
                                    sizeof(LionessMenuSimpleMessage), sizeof(buf), reply,
                                    kPingTimeoutMs, MACH_PORT_NULL);
    mach_port_mod_refs(mach_task_self(), reply, MACH_PORT_RIGHT_RECEIVE, -1);

    if (kr != MACH_MSG_SUCCESS) {
        *portWasDead = (kr == MACH_SEND_INVALID_DEST) || PortIsDead(service);
        std::lock_guard<std::mutex> lock(gMenuLock);
        ResetMenuServicePortLocked(service);
        mach_port_deallocate(mach_task_self(), service);
        return NO;
    }
    mach_port_deallocate(mach_task_self(), service);
    return (buf.msg.header.msgh_id == LIONESS_MENU_MSG_PING + 100) ? YES : NO;
}


// Sends the request, then waits for menud's reply. On an AppKit main thread it keeps pulling
// the app's events in the tracking run loop mode, like NSMenu's own tracking does: key events
// go to menud (it cannot see another app's keys without Accessibility access), mouse events
// are swallowed (menud sees them through its global monitor), and nothing is left queued to
// reach the app's windows after the menu closes. There is no overall timeout; it ends when
// menud replies or dies.
extern "C" NSDictionary *LionessMenuPresent(NSDictionary *request) {
    if (!request) return nil;
    NSData *plist = [NSPropertyListSerialization dataWithPropertyList:request
                                                               format:NSPropertyListBinaryFormat_v1_0
                                                              options:0
                                                                error:nil];
    if (!plist || plist.length == 0) return nil;

    mach_port_t service = MACH_PORT_NULL;
    {
        std::lock_guard<std::mutex> lock(gMenuLock);
        service = MenuServicePort();
        if (service != MACH_PORT_NULL) {
            mach_port_mod_refs(mach_task_self(), service, MACH_PORT_RIGHT_SEND, 1);
        }
    }
    if (service == MACH_PORT_NULL) return nil;

    mach_port_t replyPort = MACH_PORT_NULL;
    if (mach_port_allocate(mach_task_self(), MACH_PORT_RIGHT_RECEIVE, &replyPort) != KERN_SUCCESS) {
        mach_port_deallocate(mach_task_self(), service);
        return nil;
    }

    LionessMenuMachMessage msg = {};
    msg.header.msgh_bits = MACH_MSGH_BITS_COMPLEX | MACH_MSGH_BITS(MACH_MSG_TYPE_COPY_SEND, MACH_MSG_TYPE_MAKE_SEND_ONCE);
    msg.header.msgh_size = sizeof(LionessMenuMachMessage);
    msg.header.msgh_remote_port = service;
    msg.header.msgh_local_port = replyPort;
    msg.header.msgh_id = LIONESS_MENU_MSG_PRESENT;
    msg.body.msgh_descriptor_count = 1;
    msg.payload.address = (void *)plist.bytes;
    msg.payload.size = (mach_msg_size_t)plist.length;
    msg.payload.deallocate = FALSE;
    msg.payload.copy = MACH_MSG_VIRTUAL_COPY;
    msg.payload.type = MACH_MSG_OOL_DESCRIPTOR;

    mach_msg_return_t kr = mach_msg(&msg.header, MACH_SEND_MSG | MACH_SEND_TIMEOUT, sizeof(msg), 0,
                                    MACH_PORT_NULL, 1000, MACH_PORT_NULL);
    if (kr != MACH_MSG_SUCCESS) {
        mach_port_mod_refs(mach_task_self(), replyPort, MACH_PORT_RIGHT_RECEIVE, -1);
        if (kr == MACH_SEND_INVALID_DEST || kr == MACH_SEND_TIMED_OUT) {
            std::lock_guard<std::mutex> lock(gMenuLock);
            ResetMenuServicePortLocked(service);
        }
        mach_port_deallocate(mach_task_self(), service);
        return nil;
    }

    Class appClass = NSClassFromString(@"NSApplication");
    id app = appClass ? [appClass sharedApplication] : nil;
    const bool pump = app && [NSThread isMainThread];

    struct {
        LionessMenuMachMessage msg;
        mach_msg_trailer_t trailer;
    } buf;
    bool gotReply = false;
    for (;;) {
        memset(&buf, 0, sizeof(buf));
        kr = mach_msg(&buf.msg.header, MACH_RCV_MSG | MACH_RCV_TIMEOUT, 0, sizeof(buf), replyPort,
                      pump ? 0 : 50, MACH_PORT_NULL);
        if (kr == MACH_MSG_SUCCESS) { gotReply = true; break; }
        if (kr != MACH_RCV_TIMED_OUT) break;
        if (PortIsDead(service)) break;
        if (!pump) continue;
        @autoreleasepool {
            NSEvent *e = [app nextEventMatchingMask:NSEventMaskAny
                                          untilDate:[NSDate dateWithTimeIntervalSinceNow:1.0 / 120.0]
                                             inMode:NSEventTrackingRunLoopMode
                                            dequeue:YES];
            if (!e) continue;
            switch (e.type) {
                case NSEventTypeKeyDown:
                    SendKeyToMenud(service, e);
                    break;
                case NSEventTypeKeyUp:
                case NSEventTypeFlagsChanged:
                case NSEventTypeLeftMouseDown: case NSEventTypeLeftMouseUp:
                case NSEventTypeRightMouseDown: case NSEventTypeRightMouseUp:
                case NSEventTypeOtherMouseDown: case NSEventTypeOtherMouseUp:
                case NSEventTypeMouseMoved: case NSEventTypeLeftMouseDragged:
                case NSEventTypeRightMouseDragged: case NSEventTypeOtherMouseDragged:
                case NSEventTypeMouseEntered: case NSEventTypeMouseExited:
                case NSEventTypeScrollWheel:
                case NSEventTypeMagnify: case NSEventTypeSwipe: case NSEventTypeRotate:
                case NSEventTypeGesture: case NSEventTypeBeginGesture: case NSEventTypeEndGesture:
                case NSEventTypeSmartMagnify: case NSEventTypePressure:
                    break;   // menud handles the pointer
                case NSEventTypeAppKitDefined:
                    if (e.subtype == NSEventSubtypeApplicationDeactivated) LionessMenuDismiss();
                    [app sendEvent:e];
                    break;
                default:
                    [app sendEvent:e];
                    break;
            }
        }
    }

    mach_port_mod_refs(mach_task_self(), replyPort, MACH_PORT_RIGHT_RECEIVE, -1);
    if (!gotReply && PortIsDead(service)) {
        std::lock_guard<std::mutex> lock(gMenuLock);
        ResetMenuServicePortLocked(service);
    }
    mach_port_deallocate(mach_task_self(), service);
    if (!gotReply) return nil;

    if (buf.msg.header.msgh_id != LIONESS_MENU_MSG_PRESENT + 100 ||
        !(buf.msg.header.msgh_bits & MACH_MSGH_BITS_COMPLEX) ||
        !buf.msg.payload.address || buf.msg.payload.size == 0) {
        mach_msg_destroy(&buf.msg.header);
        return nil;
    }

    NSData *replyData = [NSData dataWithBytes:buf.msg.payload.address length:buf.msg.payload.size];
    vm_deallocate(mach_task_self(), (vm_address_t)buf.msg.payload.address, buf.msg.payload.size);

    id obj = [NSPropertyListSerialization propertyListWithData:replyData
                                                       options:NSPropertyListImmutable
                                                        format:NULL
                                                         error:nil];
    return [obj isKindOfClass:NSDictionary.class] ? (NSDictionary *)obj : nil;
}

extern "C" void LionessMenuDismiss(void) {
    mach_port_t service = MACH_PORT_NULL;
    {
        std::lock_guard<std::mutex> lock(gMenuLock);
        service = MenuServicePort();
        if (service != MACH_PORT_NULL) {
            mach_port_mod_refs(mach_task_self(), service, MACH_PORT_RIGHT_SEND, 1);
        }
    }
    if (service == MACH_PORT_NULL) return;

    LionessMenuSimpleMessage msg = {};
    msg.header.msgh_bits = MACH_MSGH_BITS(MACH_MSG_TYPE_COPY_SEND, 0);
    msg.header.msgh_size = sizeof(msg);
    msg.header.msgh_remote_port = service;
    msg.header.msgh_local_port = MACH_PORT_NULL;
    msg.header.msgh_id = LIONESS_MENU_MSG_DISMISS;

    mach_msg_return_t kr = mach_msg(&msg.header, MACH_SEND_MSG | MACH_SEND_TIMEOUT,
                                    sizeof(msg), 0, MACH_PORT_NULL, 250, MACH_PORT_NULL);
    if (kr == MACH_SEND_INVALID_DEST) {
        std::lock_guard<std::mutex> lock(gMenuLock);
        ResetMenuServicePortLocked(service);
    }
    mach_port_deallocate(mach_task_self(), service);
}

extern "C" BOOL LionessMenuTriggerSpotlight(uint32_t action) {
    mach_port_t service = MACH_PORT_NULL;
    {
        std::lock_guard<std::mutex> lock(gMenuLock);
        service = MenuServicePort();
        if (service != MACH_PORT_NULL) {
            mach_port_mod_refs(mach_task_self(), service, MACH_PORT_RIGHT_SEND, 1);
        }
    }
    if (service == MACH_PORT_NULL) return NO;

    LionessMenuSimpleMessage msg = {};
    msg.header.msgh_bits = MACH_MSGH_BITS(MACH_MSG_TYPE_COPY_SEND, 0);
    msg.header.msgh_size = sizeof(msg);
    msg.header.msgh_remote_port = service;
    msg.header.msgh_local_port = MACH_PORT_NULL;
    msg.header.msgh_id = LIONESS_MENU_MSG_SPOTLIGHT;
    msg.flags = action;

    mach_msg_return_t kr = mach_msg(&msg.header, MACH_SEND_MSG | MACH_SEND_TIMEOUT,
                                    sizeof(msg), 0, MACH_PORT_NULL, 500, MACH_PORT_NULL);
    if (kr != MACH_MSG_SUCCESS) {
        if (kr == MACH_SEND_INVALID_DEST) {
            std::lock_guard<std::mutex> lock(gMenuLock);
            ResetMenuServicePortLocked(service);
        }
        mach_port_deallocate(mach_task_self(), service);
        return NO;
    }
    mach_port_deallocate(mach_task_self(), service);
    return YES;
}

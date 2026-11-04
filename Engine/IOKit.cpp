// Gives Lion's IOKit an empty registry and refuses its bootstrap lookups, including com.apple.windowserver,
// so the guest never talks to modern services. Drawing into a bitmap needs neither.

#include <pthread.h>
#include <unistd.h>
#include "IOKit.h"
#include "Runtime.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <map>
#include <mutex>
#include <string>
#include <servers/bootstrap.h>

extern "C" char *sandbox_extension_issue_mach(const char *, const char *, uint32_t);

namespace Lioness {

namespace {

// A name the real kernel never hands out, so a message to it never reaches the kernel.
constexpr uint32_t kVirtualBase = 0xf0000003;

#pragma pack(push, 4)
struct PortReply {
    mach_msg_header_t h;
    mach_msg_body_t body;
    mach_msg_port_descriptor_t port;
};
struct ReturnReply {
    mach_msg_header_t h;
    NDR_record_t ndr;
    kern_return_t ret;
};
#pragma pack(pop)

void Header(uint8_t *message, int id, mach_port_t replyPort, mach_msg_size_t size, bool complex) {
    mach_msg_header_t *h = (mach_msg_header_t *)message;
    h->msgh_bits = MACH_MSGH_BITS(MACH_MSG_TYPE_MOVE_SEND_ONCE, 0) | (complex ? MACH_MSGH_BITS_COMPLEX : 0);
    h->msgh_size = size;
    h->msgh_remote_port = MACH_PORT_NULL;
    h->msgh_local_port = replyPort;
    h->msgh_id = id + 100;
}

void Return(uint8_t *message, int id, mach_port_t replyPort, kern_return_t ret) {
    Header(message, id, replyPort, sizeof(ReturnReply), false);
    ReturnReply *r = (ReturnReply *)message;
    r->ndr = NDR_record;
    r->ret = ret;
}

void Port(uint8_t *message, int id, mach_port_t replyPort, uint32_t name, mach_msg_type_name_t disposition = MACH_MSG_TYPE_MOVE_SEND) {
    Header(message, id, replyPort, sizeof(PortReply), true);
    PortReply *r = (PortReply *)message;
    r->body.msgh_descriptor_count = 1;
    r->port.name = name;
    r->port.disposition = disposition;
    r->port.type = MACH_MSG_PORT_DESCRIPTOR;
}

} // namespace

bool VirtualIOKitMessage(uint8_t *message, mach_msg_option_t option, mach_msg_return_t &result, mach_msg_size_t sendSize, mach_msg_size_t receiveSize) {
    if (!(option & MACH_SEND_MSG)) return false;
    mach_msg_header_t *h = (mach_msg_header_t *)message;
    int id = h->msgh_id;
    mach_port_t reply = h->msgh_local_port;
    result = MACH_MSG_SUCCESS;

    if (id == 404 && h->msgh_remote_port < kVirtualBase) {   // bootstrap look_up. Request: h, ndr, name_t
        if (gConfig && gConfig->trace)
            fprintf(stderr, "  [bootstrap] look_up %.128s refused\n", (const char *)(message + sizeof(mach_msg_header_t) + sizeof(NDR_record_t)));
        Return(message, id, reply, 1102);   // BOOTSTRAP_UNKNOWN_SERVICE
        return true;
    }
    if (id == 205) {   // host_get_io_master
        Port(message, id, reply, kVirtualBase);
        return true;
    }
    // A release of the virtual name is a message to the real task port. A bad name is a guard exception
    // on this OS, so the kernel must not see it.
    if ((id == 3206 || id == 3208) && h->msgh_remote_port == mach_task_self()) {
        uint32_t name = *(uint32_t *)(message + sizeof(mach_msg_header_t) + sizeof(NDR_record_t));
        if (name < kVirtualBase) return false;
        Return(message, id, reply, KERN_SUCCESS);
        return true;
    }
    if (h->msgh_remote_port < kVirtualBase) return false;

    switch (id) {
        case 2804: case 2857: case 2802: case 2809:   // matching, iterator_next, from_path: the same empty answer
            Port(message, id, reply, id == 2802 || id == 2809 ? MACH_PORT_NULL : kVirtualBase);
            return true;
        default:
            if (gConfig && gConfig->trace) fprintf(stderr, "  [iokit] no answer for message %d\n", id);
            Return(message, id, reply, (kern_return_t)0xe00002c7);   // kIOReturnUnsupported
            return true;
    }
}

} // namespace Lioness

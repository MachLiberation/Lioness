// An empty IOKit and a refusing bootstrap namespace for the guest, answered at the MIG boundary.

#ifndef LIONESS_IOKIT_H
#define LIONESS_IOKIT_H

#include <mach/mach.h>

namespace Lioness {

// True if the message was for one of these; the reply is then already in `message`.
bool VirtualIOKitMessage(uint8_t *message, mach_msg_option_t option, mach_msg_return_t &result, mach_msg_size_t sendSize, mach_msg_size_t receiveSize);

} // namespace Lioness

#endif

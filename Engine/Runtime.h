// One Lion executable running in the engine, inside a host process.

#ifndef LIONESS_RUNTIME_H
#define LIONESS_RUNTIME_H

#include "Lioness/Cpu.h"
#include <string>
#include <sys/types.h>
#include <utility>
#include <vector>

namespace Lioness {

struct GuestConfig {
    std::string root;                      // ml-root on the host
    std::string executable;                // the guest path, e.g. /bin/echo
    std::vector<std::string> arguments;    // argv, including argv[0]
    std::vector<std::string> environment;
    bool trace = false;                    // log each syscall
};

// Maps the executable and Lion's dyld, builds the stack the kernel would, and runs the main thread on
// the calling thread. Returns the guest's exit status.
int RunGuest(const GuestConfig &config);

// Guest memory: 4 KB guest semantics over the host's 16 KB pages.
bool GuestMap(uint64_t address, size_t length);                 // ensures it is backed; keeps contents
uint64_t GuestMapAnywhere(size_t length);
bool GuestOverlaps(uint64_t address, size_t length);            // any of it already the guest's
void GuestZero(uint64_t address, size_t length);
void GuestUnmap(uint64_t address, size_t length);
bool GuestOwns(uint64_t address, size_t length);

// Guest-path handling, shared with the host calls.
std::string HostPath(const char *guestPath);

// The host-call table.
void RegisterHostCalls();

void PatchHostCalls(int fd, off_t sliceOffset, uint8_t *text, size_t length, uint64_t textVmaddr);
void SetupCommpage();
void GuestExit(Cpu &c, int code);
void DumpGuest(const Cpu &c, const char *why);
Cpu *CurrentGuest();                   // this thread's guest, for a host fault handler

extern const GuestConfig *gConfig;

} // namespace Lioness

#endif

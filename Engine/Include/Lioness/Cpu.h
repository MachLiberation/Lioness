// The x86-64 state of one guest thread, and the host's view of guest memory.
//
// Guest addresses are host addresses: Lion's images live at their own virtual addresses in the host
// process (0x7fff... maps on arm64), so a guest pointer can be dereferenced as it is. The one exception
// is the commpage, whose address is above the arm64 user address space, so
// every access goes through Xlat.

#ifndef LIONESS_CPU_H
#define LIONESS_CPU_H

#include <stdint.h>
#include <stddef.h>
#include <string.h>

namespace Lioness {

union Xmm {
    uint8_t  b[16];
    int8_t   sb[16];
    uint16_t w[4 * 2];
    int16_t  sw[4 * 2];
    uint32_t d[4];
    int32_t  sd[4];
    uint64_t q[2];
    int64_t  sq[2];
    float    f[4];
    double   g[2];
};

struct Cpu {
    uint64_t r[16];      // rax rcx rdx rbx rsp rbp rsi rdi r8..r15
    uint64_t rip;
    uint64_t fsBase, gsBase;

    // Flags are kept apart: CF, ZF, SF, OF and DF as they are, PF and AF as the bytes they are computed from.
    bool cf, zf, sf, of, df;
    uint8_t pfByte, afByte;

    Xmm xmm[16];
    uint64_t mm[8];      // MMX does not alias the x87 stack here; nothing in Lion mixes them mid-run
    uint32_t mxcsr;

    double st[8];        // x87 at double precision: 80-bit values lose bits on load
    int top;
    uint16_t fpuControl, fpuStatus;
    bool c0, c1, c2, c3;

    bool running;
    int exitCode;
    uint64_t instructions;
    void *thread;        // the runtime's per-thread record
};

enum { RAX, RCX, RDX, RBX, RSP, RBP, RSI, RDI, R8, R9, R10, R11, R12, R13, R14, R15 };

constexpr uint64_t kCommpageBase = 0x7fffffe00000ull;
constexpr uint64_t kCommpageSize = 0x2000;

extern uint8_t gCommpage[kCommpageSize];

inline uint8_t *Xlat(uint64_t address) {
    if (__builtin_expect((address >> 13) == (kCommpageBase >> 13), 0))
        return gCommpage + (address - kCommpageBase);
    return reinterpret_cast<uint8_t *>(address);
}

// Runs until the thread stops. Returns its exit code.
int Run(Cpu &cpu);

// Host services, implemented by the runtime.
void Syscall(Cpu &cpu);                 // the SYSCALL instruction
void HostCall(Cpu &cpu, uint32_t id);   // the UD2 + id patch that replaces a Lion function
bool CommpageCall(Cpu &cpu);            // a call into the commpage's code; false if not implemented
[[noreturn]] void GuestPanic(Cpu &cpu, const char *why);

uint64_t GuestTicks();                  // what RDTSC returns (nanoseconds, see the commpage setup)

} // namespace Lioness

#endif

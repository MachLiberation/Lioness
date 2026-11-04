// x86-64 to arm64. A translation is a straight run of guest instructions that leaves at a conditional branch taken and ends at anything unconditional.
//
// Registers: guest RAX..R15 live in x0..x15 for as long as translated code runs, so Cpu::r is only current when a thunk has spilled it.
//   x16 x17    scratch; x16 holds a memory operand's address, which is how the fault handler finds a commpage access
//   x18        the platform's; never touched
//   x19        Cpu *
//   x20 x21 x22  flags not yet worked out: operands and what to do with them (below)
//   x23 x25 x26  scratch: operands and result
//   x24        thunks' return address
//   x27        the indirect branch table
//
// Flags: x22 is 0 when Cpu's flag bytes are current. Otherwise it says which operation last set them and x20, x21 hold its operands, shifted so that the operation's top bit is
// bit 63. One CMP of those two gives the guest's N, Z, C and V at any operand size, so most branches never work the flags out at all. Whatever reads Cpu's bytes works them out
// first (JitFlags). Flags that nothing can read before the next instruction sets them are not recorded in the first place.
//
// Memory order: x86 promises TSO. LDAPR and STLR give it for aligned accesses; a misaligned access is legal on x86 and has no such form here, and gets a plain load or store.
// Accesses relative to RSP and RBP are left plain and much faster: a thread's own stack, and anything shared through it is announced with a locked instruction, which is a barrier.
//
// PAC: on arm64e a C function pointer is signed, so calls into C here use the stripped address, and JitRun signs the way in.

#include "Jit.h"
#include "Decode.h"
#include "Runtime.h"
#include <algorithm>
#include <atomic>
#include <cstddef>
#include <libkern/OSCacheControl.h>
#include <mach/mach.h>
#include <map>
#include <mutex>
#include <ptrauth.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <sys/mman.h>
#include <sys/ucontext.h>
#include <vector>

namespace Lioness {

namespace {

enum { X16 = 16, X17 = 17, XCPU = 19, XA = 20, XB = 21, XK = 22, XT0 = 23, XLR = 24, XT1 = 25, XT2 = 26, XTABLE = 27, XZR = 31 };
enum Kind { kAdd = 1, kSub, kLogic, kInc, kDec, kAdc, kSbb, kShiftBase = 8 };   // kShiftBase + the x86 shift number; b holds the count
enum Arm { EQ, NE, CS, CC, MI, PL, VS, VC, HI, LS, GE, LT, GT, LE };

constexpr size_t kCacheSize = 120u << 20;   // within reach of a B
constexpr unsigned kFastBits = 16, kLookupBits = 22, kMaxUnit = 48;

uint8_t *gCache, *gCursor;
void *gEnter, *gFlagsThunk, *gStepThunk, *gChainThunk, *gMissThunk, *gExitThunk;
std::mutex gLock;
std::atomic<void *> *gFast;
struct Entry { std::atomic<uint64_t> rip; std::atomic<void *> code; };
Entry *gLookup;
std::vector<std::pair<uint32_t *, uint32_t>> gLinks;       // patched sites, and what they held
std::vector<std::pair<uint64_t, uint64_t>> gText;
thread_local uint64_t tColdPage;
uint32_t gLookupCount;
bool gStats;
std::atomic<uint64_t> gFallbacks[3][256], gFaultFixes;

inline uint64_t Raw(void *f) { return (uint64_t)ptrauth_strip(f, ptrauth_key_function_pointer); }
inline uint32_t FastHash(uint64_t rip) { return (uint32_t)((rip ^ (rip >> 16)) & ((1u << kFastBits) - 1)); }
inline uint32_t LookupHash(uint64_t rip) { return (uint32_t)(((rip >> 0) * 0x9E3779B97F4A7C15ull) >> (64 - kLookupBits)); }

struct Writable {
    Writable() { pthread_jit_write_protect_np(0); }
    ~Writable() { pthread_jit_write_protect_np(1); }
};

struct Asm {
    uint32_t *at;
    void W(uint32_t i) { *at++ = i; }

    void Movz(int d, uint16_t imm, int hw) { W(0xD2800000u | (uint32_t)hw << 21 | (uint32_t)imm << 5 | d); }
    void Movk(int d, uint16_t imm, int hw) { W(0xF2800000u | (uint32_t)hw << 21 | (uint32_t)imm << 5 | d); }
    void Imm(int d, uint64_t v) {
        if (!v) { Movz(d, 0, 0); return; }
        if (~v <= 0xffff) { W(0x92800000u | (uint32_t)(~v & 0xffff) << 5 | d); return; }   // movn
        bool first = true;
        for (int hw = 0; hw < 4; hw++) {
            uint16_t part = (uint16_t)(v >> (hw * 16));
            if (!part) continue;
            if (first) Movz(d, part, hw); else Movk(d, part, hw);
            first = false;
        }
    }
    void Mov(int d, int m) { if (d != m) W(0xAA0003E0u | (uint32_t)m << 16 | d); }
    void MovW(int d, int m) { W(0x2A0003E0u | (uint32_t)m << 16 | d); }
    void Op3(uint32_t base, int d, int n, int m) { W(base | (uint32_t)m << 16 | (uint32_t)n << 5 | d); }
    void Add(int d, int n, int m) { Op3(0x8B000000u, d, n, m); }
    void AddShift(int d, int n, int m, int lsl) { W(0x8B000000u | (uint32_t)m << 16 | (uint32_t)lsl << 10 | (uint32_t)n << 5 | d); }
    void Sub(int d, int n, int m) { Op3(0xCB000000u, d, n, m); }
    void And(int d, int n, int m) { Op3(0x8A000000u, d, n, m); }
    void Orr(int d, int n, int m) { Op3(0xAA000000u, d, n, m); }
    void Eor(int d, int n, int m) { Op3(0xCA000000u, d, n, m); }
    void AddImm(int d, int n, uint32_t imm) { W(0x91000000u | imm << 10 | (uint32_t)n << 5 | d); }
    void SubImm(int d, int n, uint32_t imm) { W(0xD1000000u | imm << 10 | (uint32_t)n << 5 | d); }
    void CmpReg(int n, int m) { Op3(0xEB000000u, XZR, n, m); }
    void CmnReg(int n, int m) { Op3(0xAB000000u, XZR, n, m); }
    void TstReg(int n, int m) { Op3(0xEA000000u, XZR, n, m); }
    void CmpZero(int n) { W(0xF100001Fu | (uint32_t)n << 5); }
    void Lsl(int d, int n, int s) { if (!s) { Mov(d, n); return; } W(0xD3400000u | (uint32_t)((64 - s) % 64) << 16 | (uint32_t)(63 - s) << 10 | (uint32_t)n << 5 | d); }
    void Lsr(int d, int n, int s) { if (!s) { Mov(d, n); return; } W(0xD3400000u | (uint32_t)s << 16 | 63u << 10 | (uint32_t)n << 5 | d); }
    void Asr(int d, int n, int s) { if (!s) { Mov(d, n); return; } W(0x93400000u | (uint32_t)s << 16 | 63u << 10 | (uint32_t)n << 5 | d); }
    void Ubfx0(int d, int n, int bits) { W(0xD3400000u | (uint32_t)(bits - 1) << 10 | (uint32_t)n << 5 | d); }   // the low `bits`, zero-extended
    void Sbfx0(int d, int n, int bits) { W(0x93400000u | (uint32_t)(bits - 1) << 10 | (uint32_t)n << 5 | d); }   // the low `bits`, sign-extended
    void SignOf(int d, int n, int bit) { W(0x93400000u | (uint32_t)bit << 16 | (uint32_t)bit << 10 | (uint32_t)n << 5 | d); }   // all copies of a bit
    void Bfi0(int d, int n, int bits) { W(0xB3400000u | (uint32_t)(bits - 1) << 10 | (uint32_t)n << 5 | d); }    // into the low `bits`
    void Lslv(int d, int n, int m) { Op3(0x9AC02000u, d, n, m); }
    void Lsrv(int d, int n, int m) { Op3(0x9AC02400u, d, n, m); }
    void Asrv(int d, int n, int m) { Op3(0x9AC02800u, d, n, m); }
    void Mul(int d, int n, int m) { W(0x9B000000u | (uint32_t)m << 16 | 31u << 10 | (uint32_t)n << 5 | d); }
    void Mvn(int d, int m) { W(0xAA2003E0u | (uint32_t)m << 16 | d); }
    void Csel(int d, int n, int m, int cond) { W(0x9A800000u | (uint32_t)m << 16 | (uint32_t)cond << 12 | (uint32_t)n << 5 | d); }
    void Cset(int d, int cond) { W(0x9A9F07E0u | (uint32_t)(cond ^ 1) << 12 | d); }
    void TstMask(int n, int sz) { static const uint32_t ones[] = { 0, 0, 0, 0, 1, 0, 0, 0, 2 }; W(0xF240001Fu | ones[sz] << 10 | (uint32_t)n << 5); }   // sz-1, for sz 2 4 8

    void Ldr(int t, int n, uint32_t offset) { W(0xF9400000u | (offset / 8) << 10 | (uint32_t)n << 5 | t); }
    void Str(int t, int n, uint32_t offset) { W(0xF9000000u | (offset / 8) << 10 | (uint32_t)n << 5 | t); }
    void Ldrb(int t, int n, uint32_t offset) { W(0x39400000u | offset << 10 | (uint32_t)n << 5 | t); }
    void Ldp(int a, int b, int n, int offset) { W(0xA9400000u | (uint32_t)((offset / 8) & 0x7f) << 15 | (uint32_t)b << 10 | (uint32_t)n << 5 | a); }
    void Stp(int a, int b, int n, int offset) { W(0xA9000000u | (uint32_t)((offset / 8) & 0x7f) << 15 | (uint32_t)b << 10 | (uint32_t)n << 5 | a); }
    void PushTo(int t, int n) { W(0xF8000C00u | (uint32_t)(-8 & 0x1ff) << 12 | (uint32_t)n << 5 | t); }          // str t, [n, #-8]!
    void PopFrom(int t, int n) { W(0xF8400400u | 8u << 12 | (uint32_t)n << 5 | t); }                              // ldr t, [n], #8
    void Ldur(int t, int n, int offset) { W(0xF8400000u | (uint32_t)(offset & 0x1ff) << 12 | (uint32_t)n << 5 | t); }

    void Bl(const void *to) { int64_t d = ((uint8_t *)to - (uint8_t *)at) / 4; W(0x94000000u | ((uint32_t)d & 0x03ffffff)); }
    void B(const void *to) { int64_t d = ((uint8_t *)to - (uint8_t *)at) / 4; W(0x14000000u | ((uint32_t)d & 0x03ffffff)); }
    void BCondSkip(int cond, int instructions) { W(0x54000000u | (uint32_t)(instructions + 1) << 5 | cond); }     // over the next `instructions`
    void Cbz(int t, int instructions) { W(0xB4000000u | (uint32_t)(instructions + 1) << 5 | t); }
    void Br(int n) { W(0xD61F0000u | (uint32_t)n << 5); }
    void Blr(int n) { W(0xD63F0000u | (uint32_t)n << 5); }
    void RetTo(int n) { W(0xD65F0000u | (uint32_t)n << 5); }

    void Spill() { for (int i = 0; i < 16; i += 2) Stp(i, i + 1, XCPU, i * 8); }
    void Reload() { for (int i = 0; i < 16; i += 2) Ldp(i, i + 1, XCPU, i * 8); }
    void CallC(void *f) { Imm(X16, Raw(f)); Blr(X16); }
};

void JitFlags(Cpu *c, uint64_t a, uint64_t b, uint64_t what) {
    int kind = what & 0xff, sz = (int)(what >> 8);
    int shift = 64 - sz * 8;
    a >>= shift;
    if (kind >= kShiftBase) { Shift(*c, kind - kShiftBase, a, (unsigned)b, sz); return; }
    b >>= shift;
    switch (kind) {
        case kAdd: Alu(*c, 0, a, b, sz); break;
        case kSub: Alu(*c, 5, a, b, sz); break;
        case kLogic: Alu(*c, 4, a, a, sz); break;
        case kAdc: Alu(*c, 2, a, b, sz); break;   // with CF already in Cpu
        case kSbb: Alu(*c, 3, a, b, sz); break;
        case kInc: { bool cf = c->cf; Alu(*c, 0, a, 1, sz); c->cf = cf; break; }
        default: { bool cf = c->cf; Alu(*c, 5, a, 1, sz); c->cf = cf; break; }
    }
}

void JitStep(Cpu *c) {
    if (__builtin_expect(gStats, 0)) {
        const uint8_t *p = (const uint8_t *)c->rip;
        while (*p == 0x66 || *p == 0xf2 || *p == 0xf3 || *p == 0xf0 || *p == 0x64 || *p == 0x65 || *p == 0x67) p++;
        if ((*p & 0xf0) == 0x40) p++;
        if (*p == 0x0f) gFallbacks[1][p[1]]++; else gFallbacks[0][*p]++;
    }
    StepInstruction(*c);
}

void *JitChain(Cpu *c, uint32_t *site) {
    if (!c->running) return NULL;
    void *code = JitLookup(c->rip);
    if (!code) return NULL;
    gFast[FastHash(c->rip)].store(code, std::memory_order_release);
    if (site) {
        std::lock_guard<std::mutex> lock(gLock);
        int64_t d = ((uint8_t *)code - (uint8_t *)site) / 4;
        uint32_t branch = 0x14000000u | ((uint32_t)d & 0x03ffffff);
        Writable w;
        gLinks.push_back({ site, *site });
        __atomic_store_n(site, branch, __ATOMIC_RELEASE);
        sys_icache_invalidate(site, 4);
    }
    return code;
}

void BuildThunks() {
    Writable w;
    Asm a { (uint32_t *)gCache };
    // A place for the indirect branch table to point at: its header says no guest address, so nothing matches it, and on it goes to the miss path.
    *a.at++ = 0; *a.at++ = 0;
    gMissThunk = a.at;
    a.Mov(X16, X17);
    a.Movz(X17, 0, 0);
    uint32_t *toChain = a.at;
    a.W(0);   // b chain

    gExitThunk = a.at;   // registers spilled
    a.Cbz(XK, 5 + 0);
    a.Mov(0, XCPU); a.Mov(1, XA); a.Mov(2, XB); a.Mov(3, XK);
    a.CallC((void *)JitFlags);
    // the Cbz above must clear the call: fixed below
    uint32_t *afterCall = a.at;
    a.Ldp(19, 20, 31, 0); a.Ldp(21, 22, 31, 16); a.Ldp(23, 24, 31, 32); a.Ldp(25, 26, 31, 48); a.Ldp(27, 28, 31, 64); a.Ldp(29, 30, 31, 80);
    a.AddImm(31, 31, 96);
    a.RetTo(30);
    {
        uint32_t *cbz = (uint32_t *)gExitThunk;
        *cbz = 0xB4000000u | (uint32_t)(afterCall - cbz) << 5 | XK;
    }

    gChainThunk = a.at;  // x16: where to, x17: the branch to patch, or 0
    *toChain = 0x14000000u | (uint32_t)(((uint32_t *)gChainThunk - toChain) & 0x03ffffff);
    a.Str(X16, XCPU, offsetof(Cpu, rip));
    a.Spill();
    a.Mov(0, XCPU);
    a.Mov(1, X17);
    a.CallC((void *)JitChain);
    uint32_t *exitBranch = a.at;
    a.W(0);   // cbz x0, exit
    a.Mov(X16, 0);
    a.Reload();
    a.Br(X16);
    *exitBranch = 0xB4000000u | (uint32_t)(((uint32_t *)gExitThunk - exitBranch) & 0x7ffff) << 5 | 0;

    gFlagsThunk = a.at;  // works Cpu's flag bytes out; leaves guest registers as they were
    a.Mov(XLR, 30);
    a.Spill();
    a.Mov(0, XCPU); a.Mov(1, XA); a.Mov(2, XB); a.Mov(3, XK);
    a.CallC((void *)JitFlags);
    a.Movz(XK, 0, 0);
    a.Reload();
    a.RetTo(XLR);

    gStepThunk = a.at;   // one instruction in the interpreter, with Cpu::rip and any flags it wants already there
    a.Mov(XLR, 30);
    a.Spill();
    a.Mov(0, XCPU);
    a.CallC((void *)JitStep);
    a.Reload();
    a.RetTo(XLR);

    while ((uintptr_t)a.at & 15) a.W(0xD503201Fu);
    gEnter = a.at;       // (Cpu *, code)
    a.SubImm(31, 31, 96);
    a.Stp(19, 20, 31, 0); a.Stp(21, 22, 31, 16); a.Stp(23, 24, 31, 32); a.Stp(25, 26, 31, 48); a.Stp(27, 28, 31, 64); a.Stp(29, 30, 31, 80);
    a.Mov(XCPU, 0);
    a.Mov(X16, 1);
    a.Imm(XTABLE, (uint64_t)gFast);
    a.Movz(XK, 0, 0);
    a.Reload();
    a.Br(X16);

    gCursor = (uint8_t *)a.at;
    sys_icache_invalidate(gCache, gCursor - gCache);
}

bool Setup() {
    if (getenv("LIONESS_NO_JIT")) return false;
    void *cache = mmap(NULL, kCacheSize, PROT_READ | PROT_WRITE | PROT_EXEC, MAP_PRIVATE | MAP_ANON | MAP_JIT, -1, 0);
    if (cache == MAP_FAILED) { fprintf(stderr, "lioness: no executable memory; interpreting\n"); return false; }
    gCache = (uint8_t *)cache;
    gFast = (std::atomic<void *> *)mmap(NULL, sizeof(void *) << kFastBits, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANON, -1, 0);
    gLookup = (Entry *)mmap(NULL, sizeof(Entry) << kLookupBits, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANON, -1, 0);
    if (gFast == MAP_FAILED || gLookup == MAP_FAILED) return false;
    static_assert(offsetof(Cpu, xmm) % 16 == 0, "the vector load and store forms need this");
    gStats = getenv("LIONESS_JIT_STATS") != NULL;
    BuildThunks();
    for (size_t i = 0; i < 1u << kFastBits; i++) gFast[i].store(gMissThunk, std::memory_order_relaxed);
    return true;
}

struct Ins {
    uint64_t ip = 0, next = 0;
    uint8_t op = 0, op2 = 0, op3 = 0;   // op2: after 0F; op3: after 0F 38 or 0F 3A
    uint8_t rex = 0;
    bool hasRex = false, opsize16 = false, rep = false, repne = false, lock = false, addr32 = false;
    int seg = 0;
    bool hasModRM = false, isReg = false, ripRel = false;
    int mod = 0, reg = 0, rm = 0;
    int base = -1, index = -1, scale = 0;
    int64_t disp = 0;
    uint64_t imm = 0;
    int immBytes = 0;

    bool translated = false;       // otherwise the interpreter does it
    bool ends = false;             // nothing after it in this run
    bool defsFlags = false;        // sets every flag, whatever they were
    bool usesFlags = false;        // reads them, or may: Cpu's bytes must be right
    bool neutral = false;          // the interpreter doing it neither reads nor writes flags
    bool wantsDeadFlags = false;   // translated only if its flags are not needed
    bool flagsLive = true;         // does anything read what this instruction leaves in the flags?

    int OpSize() const { return (rex & 8) ? 8 : opsize16 ? 2 : 4; }
};

bool Decode(uint64_t ip, uint64_t limit, Ins &n) {
    const uint8_t *p = (const uint8_t *)ip, *start = p;
    if (ip + 16 > limit) return false;
    n.ip = ip;
    for (;;) {
        uint8_t b = *p;
        if (b == 0x66) n.opsize16 = true;
        else if (b == 0x67) n.addr32 = true;
        else if (b == 0xf0) n.lock = true;
        else if (b == 0xf2) n.repne = true;
        else if (b == 0xf3) n.rep = true;
        else if (b == 0x64) n.seg = 1;
        else if (b == 0x65) n.seg = 2;
        else if (b == 0x26 || b == 0x2e || b == 0x36 || b == 0x3e) {}
        else break;
        p++;
        if (p - start > 8) return false;
    }
    if ((*p & 0xf0) == 0x40) { n.rex = *p++; n.hasRex = true; }
    n.op = *p++;

    bool modrm = false;
    int imm = 0;
    bool imm64 = false, immOp = false;
    uint8_t op = n.op;
    int threeByteImm = 0;
    if (op == 0x0f) {
        n.op2 = *p++;
        uint8_t o = n.op2;
        if (o == 0x38) { n.op3 = *p++; modrm = true; }
        else if (o == 0x3a) { n.op3 = *p++; modrm = true; threeByteImm = 1; }
        else if (o == 0x05 || o == 0x0b || o == 0x31 || o == 0x77 || o == 0xa2 || o == 0xa0 || o == 0xa1 || o == 0xa8 || o == 0xa9 || (o >= 0xc8 && o <= 0xcf)) modrm = false;
        else if (o >= 0x80 && o <= 0x8f) imm = 4;
        else {
            modrm = true;
            if (o == 0x70 || o == 0x71 || o == 0x72 || o == 0x73 || o == 0xa4 || o == 0xac || o == 0xba || o == 0xc2 || o == 0xc4 || o == 0xc5 || o == 0xc6) imm = 1;
            if (o == 0x01 && (*p == 0xd0 || *p == 0xf9)) { modrm = false; p++; }
        }
        if (threeByteImm) imm = 1;
    } else if (op < 0x40 && (op & 7) < 6) {
        if ((op & 7) < 4) modrm = true;
        else if ((op & 7) == 4) imm = 1;
        else immOp = true;
    } else switch (op) {
        case 0x63: case 0x69: case 0x6b: case 0x80: case 0x81: case 0x83: case 0x84: case 0x85: case 0x86: case 0x87: case 0x88: case 0x89: case 0x8a: case 0x8b: case 0x8d: case 0x8f:
        case 0xc0: case 0xc1: case 0xc6: case 0xc7: case 0xd0: case 0xd1: case 0xd2: case 0xd3: case 0xd8: case 0xd9: case 0xda: case 0xdb: case 0xdc: case 0xdd: case 0xde: case 0xdf:
        case 0xf6: case 0xf7: case 0xfe: case 0xff:
            modrm = true;
            if (op == 0x69 || op == 0x81 || op == 0xc7) immOp = true;
            if (op == 0x6b || op == 0x80 || op == 0x83 || op == 0xc0 || op == 0xc1 || op == 0xc6) imm = 1;
            break;
        case 0x68: case 0xa9: case 0xe8: case 0xe9:
            if (op == 0xa9) immOp = true; else imm = 4;
            break;
        case 0x6a: case 0xa8: case 0xe3: case 0xeb: imm = 1; break;
        case 0x70: case 0x71: case 0x72: case 0x73: case 0x74: case 0x75: case 0x76: case 0x77:
        case 0x78: case 0x79: case 0x7a: case 0x7b: case 0x7c: case 0x7d: case 0x7e: case 0x7f: imm = 1; break;
        case 0xb0: case 0xb1: case 0xb2: case 0xb3: case 0xb4: case 0xb5: case 0xb6: case 0xb7: imm = 1; break;
        case 0xb8: case 0xb9: case 0xba: case 0xbb: case 0xbc: case 0xbd: case 0xbe: case 0xbf: imm64 = true; immOp = true; break;
        case 0xc2: imm = 2; break;
        case 0xc8: imm = 3; break;
        case 0x50: case 0x51: case 0x52: case 0x53: case 0x54: case 0x55: case 0x56: case 0x57: case 0x58: case 0x59: case 0x5a: case 0x5b: case 0x5c: case 0x5d: case 0x5e: case 0x5f:
        case 0x90: case 0x91: case 0x92: case 0x93: case 0x94: case 0x95: case 0x96: case 0x97: case 0x98: case 0x99: case 0x9b: case 0x9c: case 0x9d: case 0x9e: case 0x9f:
        case 0xa4: case 0xa5: case 0xa6: case 0xa7: case 0xaa: case 0xab: case 0xac: case 0xad: case 0xae: case 0xaf:
        case 0xc3: case 0xc9: case 0xcc: case 0xf4: case 0xf5: case 0xf8: case 0xf9: case 0xfc: case 0xfd:
            break;
        case 0xcd: imm = 1; break;
        default: return false;
    }

    if (modrm) {
        uint8_t m = *p++;
        n.hasModRM = true;
        n.mod = m >> 6;
        n.reg = ((m >> 3) & 7) | ((n.rex & 4) << 1);
        int rm = m & 7;
        if (n.mod == 3) { n.isReg = true; n.rm = rm | ((n.rex & 1) << 3); }
        else {
            if (rm == 4) {
                uint8_t sib = *p++;
                n.scale = sib >> 6;
                int index = ((sib >> 3) & 7) | ((n.rex & 2) << 2), base = (sib & 7) | ((n.rex & 1) << 3);
                if (index != 4) n.index = index;
                if ((sib & 7) == 5 && n.mod == 0) { int32_t d; memcpy(&d, p, 4); p += 4; n.disp = d; }
                else n.base = base;
            } else if (rm == 5 && n.mod == 0) {
                int32_t d; memcpy(&d, p, 4); p += 4; n.disp = d; n.ripRel = true;
            } else n.base = rm | ((n.rex & 1) << 3);
            if (n.mod == 1) { n.disp += (int8_t)*p++; }
            else if (n.mod == 2) { int32_t d; memcpy(&d, p, 4); p += 4; n.disp += d; }
        }
    }
    if (immOp) {
        int sz = n.OpSize();
        if (imm64 && sz == 8) imm = 8;
        else imm = sz == 2 ? 2 : 4;
    }
    if (op == 0xf6 || op == 0xf7) {   // TEST alone has an immediate
        if ((n.reg & 7) < 2) imm = op == 0xf6 ? 1 : (n.OpSize() == 2 ? 2 : 4);
    }
    n.immBytes = imm;
    if (imm) { uint64_t v = 0; memcpy(&v, p, imm > 8 ? 8 : imm); n.imm = v; p += imm; }
    n.next = (uint64_t)p;
    return n.next <= limit;
}

inline bool HighByte(const Ins &n, int index, int sz) { return sz == 1 && !n.hasRex && index >= 4 && index < 8; }

// Three-operand vector integer operations with a NEON twin: x = x op E. 0 for none.
uint32_t VectorThree(uint8_t o) {
    switch (o) {
        case 0xfc: return 0x4E208400u; case 0xfd: return 0x4E608400u; case 0xfe: return 0x4EA08400u; case 0xd4: return 0x4EE08400u;   // add
        case 0xf8: return 0x6E208400u; case 0xf9: return 0x6E608400u; case 0xfa: return 0x6EA08400u; case 0xfb: return 0x6EE08400u;   // sub
        case 0xd5: return 0x4E609C00u;                                                                                                // mul low
        case 0xdb: return 0x4E201C00u; case 0xeb: return 0x4EA01C00u; case 0xef: return 0x6E201C00u;                                  // and or xor
        case 0x60: return 0x4E003800u; case 0x61: return 0x4E403800u; case 0x62: return 0x4E803800u; case 0x6c: return 0x4EC03800u;   // unpack low
        case 0x68: return 0x4E007800u; case 0x69: return 0x4E407800u; case 0x6a: return 0x4E807800u; case 0x6d: return 0x4EC07800u;   // unpack high
        case 0x64: return 0x4E203400u; case 0x65: return 0x4E603400u; case 0x66: return 0x4EA03400u;                                  // cmpgt
        case 0x74: return 0x6E208C00u; case 0x75: return 0x6E608C00u; case 0x76: return 0x6EA08C00u;                                  // cmpeq
        case 0xd8: return 0x6E202C00u; case 0xd9: return 0x6E602C00u; case 0xdc: return 0x6E200C00u; case 0xdd: return 0x6E600C00u;   // unsigned saturating
        case 0xe8: return 0x4E202C00u; case 0xe9: return 0x4E602C00u; case 0xec: return 0x4E200C00u; case 0xed: return 0x4E600C00u;   // signed saturating
        case 0xda: return 0x6E206C00u; case 0xde: return 0x6E206400u; case 0xea: return 0x4E606C00u; case 0xee: return 0x4E606400u;   // min max
        case 0xe0: return 0x6E201400u; case 0xe3: return 0x6E601400u;                                                                 // average
        default: return 0;
    }
}

// The vector instructions translated, as the interpreter treats them (InterpreterSSE.cpp). All leave the flags alone. No prefix on an integer one means MMX, which stays interpreted.
bool VectorForm(const Ins &n) {
    uint8_t o = n.op2;
    if (n.lock || n.addr32) return false;
    bool f3 = n.rep, f2 = n.repne && !n.rep, p66 = n.opsize16 && !f3 && !f2, none = !f3 && !f2 && !p66, anyRep = n.rep || n.repne;
    if (VectorThree(o) || o == 0xdf || o == 0x63 || o == 0x67 || o == 0x6b || o == 0xf5 || o == 0xe4 || o == 0xe5 || o == 0xf4) return n.opsize16 && !anyRep;
    if (o == 0xd1 || o == 0xd2 || o == 0xd3 || o == 0xe1 || o == 0xe2 || o == 0xf1 || o == 0xf2 || o == 0xf3 || o == 0xf6) return n.opsize16 && !anyRep;
    switch (o) {
        case 0x10: case 0x11: return true;
        case 0x12: return (none || p66);
        case 0x13: case 0x17: return !n.isReg && !anyRep;
        case 0x14: case 0x15: return none || p66;
        case 0x16: return none || p66;
        case 0x28: case 0x29: return none || p66;
        case 0x2b: case 0xe7: return !n.isReg && !anyRep && (o == 0x2b || p66);
        case 0x2a: return f3 || f2;
        case 0x51: case 0x58: case 0x59: case 0x5c: case 0x5e: return true;
        case 0x54: case 0x55: case 0x56: case 0x57: return !anyRep;
        case 0x5a: return true;
        case 0x52: return f3 || none;
        case 0x53: return f3 || none;
        case 0xe6: return f3 || f2 || p66;
        case 0x6e: return p66;
        case 0x6f: case 0x7f: return p66 || f3;
        case 0x70: return !none && n.immBytes == 1;
        case 0x71: case 0x72: return p66 && n.isReg && ((n.reg & 7) == 2 || (n.reg & 7) == 4 || (n.reg & 7) == 6);
        case 0x73: return p66 && n.isReg && ((n.reg & 7) == 2 || (n.reg & 7) == 3 || (n.reg & 7) == 6 || (n.reg & 7) == 7);
        case 0x7e: return p66 || f3;
        case 0xc6: return none || p66;
        case 0xd6: return p66;
        case 0xd7: return p66 && n.isReg;
        case 0x38: return p66 && n.op3 == 0x00;
        case 0x3a: return p66 && n.op3 == 0x0f && n.immBytes == 1 && n.imm < 16;
        case 0x2c: case 0x2d: return f3 || f2;
        case 0x50: return (none || p66) && n.isReg;
        case 0x5b: return true;
        case 0x5d: case 0x5f: return true;
        case 0x7c: return p66 || f2;
        case 0xc2: return n.immBytes == 1;
        case 0xc4: return p66;
        case 0xc5: return p66 && n.isReg;
        case 0xf0: return f2;
        default: return false;
    }
}

// What this implementation does with an instruction, in terms the run as a whole needs.
void Classify(Ins &n) {
    auto HighByte = [](const Ins &, int, int) { return false; };   // ReadReg and WriteReg handle AH and the like
    uint8_t op = n.op;
    // Locked read-modify-writes on memory, as the atomic instructions they are.
    if (n.lock && !n.isReg && n.hasModRM && !n.addr32 && !n.rep && !n.repne) {
        if (op < 0x38 && (op & 7) < 2 && (op >> 3) != 2 && (op >> 3) != 3) { n.translated = true; n.defsFlags = true; return; }
        if ((op == 0x80 || op == 0x81 || op == 0x83) && (n.reg & 7) != 2 && (n.reg & 7) != 3 && (n.reg & 7) != 7) { n.translated = true; n.defsFlags = true; return; }
        if ((op == 0xfe || op == 0xff) && (n.reg & 7) < 2) { n.translated = true; return; }
        if (op == 0xf6 || op == 0xf7) { if ((n.reg & 7) == 2) n.translated = true; return; }
        if (op == 0x86 || op == 0x87) { n.translated = true; return; }
        if (op == 0x0f && (n.op2 == 0xc0 || n.op2 == 0xc1 || n.op2 == 0xb0 || n.op2 == 0xb1)) { n.translated = true; n.defsFlags = true; return; }
        if (op == 0x0f && n.op2 == 0xba && (n.reg & 7) >= 4) { n.translated = true; return; }
        return;
    }
    bool plain = !n.lock && !n.addr32 && !n.rep && !n.repne;
    bool memOk = !n.lock && !n.addr32;
    auto regsOk = [&](int sz) { return !HighByte(n, n.reg, sz) && (!n.isReg || !HighByte(n, n.rm, sz)); };

    auto alu = [&](int which) {
        n.translated = true;
        n.defsFlags = true;
        if (which == 2 || which == 3) n.usesFlags = true;   // adc sbb
        return true;
    };

    if (op < 0x40 && (op & 7) < 6) {
        int which = op >> 3;
        if (!plain) return;
        int form = op & 7;
        int sz = form == 0 || form == 2 || form == 4 ? 1 : n.OpSize();
        if (form < 4 && !regsOk(sz)) return;
        alu(which);
        return;
    }
    switch (op) {
        case 0x50: case 0x51: case 0x52: case 0x53: case 0x54: case 0x55: case 0x56: case 0x57:
        case 0x58: case 0x59: case 0x5a: case 0x5b: case 0x5c: case 0x5d: case 0x5e: case 0x5f:
        case 0x68: case 0x6a:
            if (plain && !n.opsize16) n.translated = true;
            return;
        case 0x63:
            if (memOk && !n.rep && !n.repne) n.translated = n.OpSize() != 2;
            return;
        case 0x69: case 0x6b:
            if (plain && n.OpSize() != 2) n.translated = true;
            return;
        case 0x70: case 0x71: case 0x72: case 0x73: case 0x74: case 0x75: case 0x76: case 0x77:
        case 0x78: case 0x79: case 0x7a: case 0x7b: case 0x7c: case 0x7d: case 0x7e: case 0x7f:
            n.translated = true; n.usesFlags = true;
            return;
        case 0x80: case 0x81: case 0x83: {
            int sz = op == 0x80 ? 1 : n.OpSize();
            if (plain && (!n.isReg || !HighByte(n, n.rm, sz))) alu(n.reg & 7);   // the reg field is part of the opcode here
            return;
        }
        case 0x84: case 0x85: {
            int sz = op & 1 ? n.OpSize() : 1;
            if (plain && regsOk(sz)) { n.translated = true; n.defsFlags = true; }
            return;
        }
        case 0x88: case 0x89: case 0x8a: case 0x8b: {
            int sz = op & 1 ? n.OpSize() : 1;
            if (plain && regsOk(sz)) n.translated = true;
            return;
        }
        case 0xa8: case 0xa9:
            if (plain) { n.translated = true; n.defsFlags = true; }
            return;
        case 0x8d:
            if (plain && !n.isReg) n.translated = true;
            return;
        case 0x90:
            if (!n.lock && !(n.rex & 1)) n.translated = true;   // also PAUSE
            return;
        case 0x98: case 0x99:
            if (plain) n.translated = true;
            return;
        case 0xb0: case 0xb1: case 0xb2: case 0xb3: case 0xb4: case 0xb5: case 0xb6: case 0xb7:
            if (plain && !HighByte(n, (op & 7) | ((n.rex & 1) << 3), 1)) n.translated = true;
            return;
        case 0xb8: case 0xb9: case 0xba: case 0xbb: case 0xbc: case 0xbd: case 0xbe: case 0xbf:
            if (plain) n.translated = true;
            return;
        case 0xc0: case 0xc1: case 0xd0: case 0xd1: case 0xd2: case 0xd3: {
            int sz = op & 1 ? n.OpSize() : 1;
            int kind = n.reg & 7;
            if (!plain || (n.isReg && HighByte(n, n.rm, sz))) return;
            bool byImmediate = op < 0xd2;
            unsigned count = (op >= 0xd0 ? 1 : (unsigned)n.imm) & (sz == 8 ? 63 : 31);
            if (kind == 4 || kind == 5 || kind == 6 || kind == 7) {
                n.translated = true;
                if (byImmediate && count) n.defsFlags = true;   // by CL it may be zero, which leaves the flags alone: decided as it runs
            } else if ((kind == 0 || kind == 1) && sz >= 4) {
                n.translated = true;                            // rotates set only CF and OF, over what was there
            }
            return;
        }
        case 0xc2: case 0xc3: n.translated = plain || n.rep; n.ends = true; return;   // REP RET is a RET
        case 0xc6: case 0xc7: {
            int sz = op & 1 ? n.OpSize() : 1;
            if (plain && (n.reg & 7) == 0 && (!n.isReg || !HighByte(n, n.rm, sz))) n.translated = true;
            return;
        }
        case 0xc9:
            if (plain) n.translated = true;
            return;
        case 0xe8: case 0xe9: case 0xeb:
            n.translated = plain; n.ends = true;
            return;
        case 0xf6: case 0xf7: {
            int sz = op & 1 ? n.OpSize() : 1;
            int kind = n.reg & 7;
            if (!plain || (n.isReg && HighByte(n, n.rm, sz))) return;
            if (kind < 2) { n.translated = true; n.defsFlags = true; }
            else if (kind == 2) n.translated = true;
            else if (kind == 3) { n.translated = true; n.defsFlags = true; }
            else if (sz >= 4) n.translated = true;   // mul imul div idiv: the rest of the flags stay as they were
            return;
        }
        case 0x8f:
            if (plain) n.translated = true;
            return;
        case 0xf5: case 0xf8: case 0xf9: case 0xfc: case 0xfd:
            if (plain) n.translated = true;
            return;
        case 0xfe: case 0xff: {
            int sz = op & 1 ? n.OpSize() : 1;
            int kind = n.reg & 7;
            if (kind >= 2 && kind != 6) n.ends = true;   // the interpreter takes any of these for a branch, even where FE has no such instruction
            if (!plain || (n.isReg && HighByte(n, n.rm, sz))) return;
            if (kind < 2) n.translated = true;
            else if (op == 0xff && (kind == 2 || kind == 4)) { n.translated = true; n.ends = true; }
            else if (op == 0xff && kind == 6) n.translated = true;
            return;
        }
        case 0x0f: {
            uint8_t o = n.op2;
            if (o >= 0x80 && o <= 0x8f) { n.translated = true; n.usesFlags = true; return; }
            if (o >= 0x90 && o <= 0x9f) {
                if (plain && (!n.isReg || !HighByte(n, n.rm, 1))) { n.translated = true; n.usesFlags = true; }
                return;
            }
            if (o >= 0x40 && o <= 0x4f) {
                if (plain && !HighByte(n, n.reg, 4)) { n.translated = true; n.usesFlags = true; }
                return;
            }
            if (o == 0xb6 || o == 0xb7 || o == 0xbe || o == 0xbf) {
                if (plain) n.translated = true;   // from AH and the like too
                return;
            }
            if (o == 0x1f || o == 0x0d || (o >= 0x18 && o <= 0x1e)) { n.translated = true; return; }   // hint nops
            if (o == 0xaf) {
                if (plain && n.OpSize() != 2) n.translated = true;
                return;
            }
            if (o >= 0xc8 && o <= 0xcf) { if (plain && n.OpSize() != 2) n.translated = true; return; }
            if (o == 0xbc || o == 0xbd) { if (!n.lock && !n.addr32 && !n.repne) n.translated = true; return; }
            if ((o == 0xc0 || o == 0xc1 || o == 0xb0 || o == 0xb1) && plain && !n.isReg) { n.translated = true; n.defsFlags = true; return; }
            if ((o == 0xc0 || o == 0xc1) && plain && n.isReg) { n.translated = true; n.defsFlags = true; return; }
            if ((o == 0xa3 || o == 0xab || o == 0xb3 || o == 0xbb) && plain && n.isReg) { n.translated = true; return; }
            if (o == 0xba && plain && (n.reg & 7) >= 4) { n.translated = true; return; }
            if (o == 0x05 || o == 0x0b) { n.ends = true; return; }
            if ((o == 0x2e || o == 0x2f) && !n.lock && !n.addr32 && !n.rep && !n.repne) { n.translated = true; n.defsFlags = true; return; }
            if (VectorForm(n)) { n.translated = true; return; }
            // Everything else in 0F is the interpreter's. Most of it, the vector instructions, has nothing to do with the flags.
            switch (o) {
                case 0x2e: case 0x2f: case 0xa3: case 0xab: case 0xb3: case 0xbb: case 0xba: case 0xa4: case 0xa5: case 0xac: case 0xad:
                case 0xb0: case 0xb1: case 0xbc: case 0xbd: case 0xc0: case 0xc1: case 0xc7:
                    break;
                default: n.neutral = true; break;
            }
            return;
        }
        case 0x86: case 0x87:
            if (plain) n.translated = true;
            else n.neutral = true;
            return;
        case 0x91: case 0x92: case 0x93: case 0x94: case 0x95: case 0x96: case 0x97:
            if (plain) n.translated = true;
            else n.neutral = true;
            return;
        case 0xe3: case 0xcc: case 0xcd: case 0xf4:
            n.ends = true;
            return;
        default:
            return;
    }
}

struct Stub { uint32_t *site; uint64_t target; };

struct Emit {
    Asm a;
    std::vector<Stub> stubs;
    enum { kUnknown, kCurrent, kKnown } state = kUnknown;   // what is known about x22 here
    int knownKind = 0, knownSize = 0;

    void Ea(const Ins &n) {
        if (n.ripRel) {
            a.Imm(X16, n.next + (uint64_t)n.disp);
        } else {
            if (n.base >= 0 && n.index >= 0) a.AddShift(X16, n.base, n.index, n.scale);
            else if (n.base >= 0) a.Mov(X16, n.base);
            else if (n.index >= 0) a.Lsl(X16, n.index, n.scale);
            else a.Movz(X16, 0, 0);
            AddDisp(n.disp);
        }
        if (n.seg) {
            a.Ldr(X17, XCPU, n.seg == 1 ? offsetof(Cpu, fsBase) : offsetof(Cpu, gsBase));
            a.Add(X16, X16, X17);
        }
    }
    void AddDisp(int64_t disp) {
        if (!disp) return;
        uint64_t size = disp < 0 ? (uint64_t)-disp : (uint64_t)disp;
        if (size < 4096) { if (disp < 0) a.SubImm(X16, X16, (uint32_t)size); else a.AddImm(X16, X16, (uint32_t)size); return; }
        a.Imm(X17, (uint64_t)disp);
        a.Add(X16, X16, X17);
    }
    static bool Stacky(const Ins &n) { return !n.seg && !n.ripRel && (n.base == RSP || n.base == RBP); }

    // The address is in x16. Zero-extends.
    void Load(int t, int sz, bool relaxed) {
        static const uint32_t plain[] = { 0, 0x39400000u, 0x79400000u, 0, 0xB9400000u, 0, 0, 0, 0xF9400000u };
        static const uint32_t acquire[] = { 0, 0x38BFC000u, 0x78BFC000u, 0, 0xB8BFC000u, 0, 0, 0, 0xF8BFC000u };
        uint32_t rn = (uint32_t)X16 << 5 | t;
        if (relaxed) { a.W(plain[sz] | rn); return; }
        if (sz == 1) { a.W(acquire[1] | rn); return; }
        a.TstMask(X16, sz);
        a.BCondSkip(NE, 2);
        a.W(acquire[sz] | rn);
        a.W(0x14000002u);
        a.W(plain[sz] | rn);
    }
    void Store(int t, int sz, bool relaxed) {
        static const uint32_t plain[] = { 0, 0x39000000u, 0x79000000u, 0, 0xB9000000u, 0, 0, 0, 0xF9000000u };
        static const uint32_t release[] = { 0, 0x089FFC00u, 0x489FFC00u, 0, 0x889FFC00u, 0, 0, 0, 0xC89FFC00u };
        uint32_t rn = (uint32_t)X16 << 5 | t;
        if (relaxed) { a.W(plain[sz] | rn); return; }
        if (sz == 1) { a.W(release[1] | rn); return; }
        a.TstMask(X16, sz);
        a.BCondSkip(NE, 2);
        a.W(release[sz] | rn);
        a.W(0x14000002u);
        a.W(plain[sz] | rn);
    }
    bool noRex = false;
    void ReadReg(int d, int index, int sz) {
        if (sz == 1 && noRex && index >= 4 && index < 8) { a.W(0xD3400000u | 8u << 16 | 15u << 10 | (uint32_t)(index - 4) << 5 | d); return; }   // AH CH DH BH
        switch (sz) {
            case 1: a.Ubfx0(d, index, 8); break;
            case 2: a.Ubfx0(d, index, 16); break;
            case 4: a.MovW(d, index); break;
            default: a.Mov(d, index); break;
        }
    }
    void WriteReg(int index, int sz, int s) {
        if (sz == 1 && noRex && index >= 4 && index < 8) { a.W(0xB3400000u | 56u << 16 | 7u << 10 | (uint32_t)s << 5 | (index - 4)); return; }   // bfi: bits 8..15
        switch (sz) {
            case 1: a.Bfi0(index, s, 8); break;
            case 2: a.Bfi0(index, s, 16); break;
            case 4: a.MovW(index, s); break;
            default: a.Mov(index, s); break;
        }
    }
    void ReadE(const Ins &n, int d, int sz) {
        if (n.isReg) ReadReg(d, n.rm, sz);
        else { Ea(n); Load(d, sz, Stacky(n)); }
    }
    // After ReadE of the same operand: x16 still holds the address.
    void WriteEAgain(const Ins &n, int s, int sz) {
        if (n.isReg) WriteReg(n.rm, sz, s);
        else Store(s, sz, Stacky(n));
    }

    void Record(bool live, int kind, int sz, int aReg, int bReg) {
        if (!live) return;
        int shift = 64 - sz * 8;
        a.Lsl(XA, aReg, shift);
        if (kind >= kShiftBase) a.Mov(XB, bReg);
        else if (bReg >= 0) a.Lsl(XB, bReg, shift);
        a.Imm(XK, (uint64_t)kind | (uint64_t)sz << 8);
        state = kKnown; knownKind = kind; knownSize = sz;
    }
    void SpillFlags() {
        if (state == kKnown) a.Bl(gFlagsThunk);
        else if (state == kUnknown) { a.Cbz(XK, 1); a.Bl(gFlagsThunk); }
        state = kCurrent;
    }
    // Sets the host's flags and says which condition means "x86 condition cc holds".
    int Condition(int cc) {
        int which = cc >> 1, invert = cc & 1, arm = -1;
        if (state == kKnown) {
            switch (knownKind) {
                case kSub: case kDec: {
                    static const int map[] = { VS, CC, EQ, LS, MI, -1, LT, LE };
                    arm = map[which];
                    if (knownKind == kDec && (which == 1 || which == 3)) arm = -1;
                    if (arm >= 0) a.CmpReg(XA, XB);
                    break;
                }
                case kAdd: case kInc: {
                    static const int map[] = { VS, CS, EQ, -1, MI, -1, LT, LE };
                    arm = map[which];
                    if (knownKind == kInc && which == 1) arm = -1;
                    if (arm >= 0) a.CmnReg(XA, XB);
                    break;
                }
                case kLogic: {
                    static const int map[] = { -1, -1, EQ, EQ, MI, -1, MI, LE };
                    arm = map[which];
                    if (arm >= 0) a.TstReg(XA, XA);
                    break;
                }
            }
            if (arm >= 0) return arm ^ invert;
        }
        SpillFlags();
        auto byte = [&](int d, size_t offset) { a.Ldrb(d, XCPU, (uint32_t)offset); };
        switch (which) {
            case 0: byte(X17, offsetof(Cpu, of)); break;
            case 1: byte(X17, offsetof(Cpu, cf)); break;
            case 2: byte(X17, offsetof(Cpu, zf)); break;
            case 3: byte(X17, offsetof(Cpu, cf)); byte(XT2, offsetof(Cpu, zf)); a.Orr(X17, X17, XT2); break;
            case 4: byte(X17, offsetof(Cpu, sf)); break;
            case 5:
                byte(X17, offsetof(Cpu, pfByte));
                a.W(0xCA511231u);   // eor x17, x17, x17, lsr #4
                a.W(0xCA510A31u);   // eor x17, x17, x17, lsr #2
                a.W(0xCA510631u);   // eor x17, x17, x17, lsr #1
                a.W(0x92400231u);   // and x17, x17, #1
                a.W(0xD2400231u);   // eor x17, x17, #1: PF is set for an even count
                break;
            case 6: byte(X17, offsetof(Cpu, sf)); byte(XT2, offsetof(Cpu, of)); a.Eor(X17, X17, XT2); break;
            default:
                byte(X17, offsetof(Cpu, sf)); byte(XT2, offsetof(Cpu, of)); a.Eor(X17, X17, XT2);
                byte(XT2, offsetof(Cpu, zf)); a.Orr(X17, X17, XT2);
                break;
        }
        a.CmpZero(X17);
        return NE ^ invert;
    }

    void Link(uint64_t target) {
        stubs.push_back({ a.at, target });
        a.W(0);
    }
    void Indirect() {   // x17: where to
        a.W(0xCA514230u);               // eor x16, x17, x17, lsr #16
        a.Ubfx0(X16, X16, kFastBits);
        a.W(0xF8707B70u);               // ldr x16, [x27, x16, lsl #3]
        a.Ldur(XT2, X16, -8);
        a.CmpReg(XT2, X17);
        a.BCondSkip(NE, 1);
        a.Br(X16);
        a.B(gMissThunk);
    }

    void Alu(const Ins &n, int which, int sz, bool intoReg) {
        // x23 holds the left operand, x25 the right. The result goes to x26.
        switch (which) {
            case 0: a.Add(XT2, XT0, XT1); break;
            case 1: a.Orr(XT2, XT0, XT1); break;
            case 4: a.And(XT2, XT0, XT1); break;
            case 6: a.Eor(XT2, XT0, XT1); break;
            case 2: a.Ldrb(X17, XCPU, offsetof(Cpu, cf)); a.Add(XT2, XT0, XT1); a.Add(XT2, XT2, X17); break;   // CF went to Cpu before the operands were read
            case 3: a.Ldrb(X17, XCPU, offsetof(Cpu, cf)); a.Sub(XT2, XT0, XT1); a.Sub(XT2, XT2, X17); break;
            default: a.Sub(XT2, XT0, XT1); break;
        }
        if (which == 0) Record(n.flagsLive, kAdd, sz, XT0, XT1);
        else if (which == 2) Record(n.flagsLive, kAdc, sz, XT0, XT1);
        else if (which == 3) Record(n.flagsLive, kSbb, sz, XT0, XT1);
        else if (which == 5 || which == 7) Record(n.flagsLive, kSub, sz, XT0, XT1);
        else Record(n.flagsLive, kLogic, sz, XT2, -1);
        if (!n.flagsLive) state = state == kKnown ? kUnknown : state;
    }

    static uint32_t XOffset(int i) { return (uint32_t)(offsetof(Cpu, xmm) + (size_t)i * 16); }
    void LoadX(int v, int i) { a.W(0x3DC00000u | (XOffset(i) / 16) << 10 | (uint32_t)XCPU << 5 | v); }
    void StoreX(int v, int i) { a.W(0x3D800000u | (XOffset(i) / 16) << 10 | (uint32_t)XCPU << 5 | v); }
    void LoadQ16(int v) { a.W(0x3DC00000u | (uint32_t)X16 << 5 | v); }
    void StoreQ16(int v) { a.W(0x3D800000u | (uint32_t)X16 << 5 | v); }
    void LoadS16(int v) { a.W(0xBD400000u | (uint32_t)X16 << 5 | v); }
    void StoreS16(int v) { a.W(0xBD000000u | (uint32_t)X16 << 5 | v); }
    void LoadD16(int v) { a.W(0xFD400000u | (uint32_t)X16 << 5 | v); }
    void StoreD16(int v) { a.W(0xFD000000u | (uint32_t)X16 << 5 | v); }
    void LoadE16(const Ins &n, int v) { if (n.isReg) LoadX(v, n.rm); else { Ea(n); LoadQ16(v); } }
    // Just the low element, for the scalar forms: a memory operand is only that wide.
    void LoadEScalar(const Ins &n, int v, bool isFloat) {
        if (n.isReg) LoadX(v, n.rm);
        else { Ea(n); if (isFloat) LoadS16(v); else LoadD16(v); }
    }
    void InsS(int d, int i, int s, int j) { a.W(0x6E000400u | (uint32_t)(i << 3 | 4) << 16 | (uint32_t)(j << 2) << 11 | (uint32_t)s << 5 | d); }
    void InsD(int d, int i, int s, int j) { a.W(0x6E000400u | (uint32_t)(i << 4 | 8) << 16 | (uint32_t)(j << 3) << 11 | (uint32_t)s << 5 | d); }
    void InsH(int d, int i, int s, int j) { a.W(0x6E000400u | (uint32_t)(i << 2 | 2) << 16 | (uint32_t)(j << 1) << 11 | (uint32_t)s << 5 | d); }
    void Neon(uint32_t base, int d, int n, int m) { a.W(base | (uint32_t)m << 16 | (uint32_t)n << 5 | d); }

    void Vector(const Ins &n) {
        uint8_t o = n.op2;
        const int x = n.reg;
        bool f3 = n.rep, f2 = n.repne && !n.rep, p66 = n.opsize16 && !f3 && !f2;
        if (uint32_t base = VectorThree(o)) {
            LoadX(0, x); LoadE16(n, 1);
            Neon(base, 0, 0, 1);
            StoreX(0, x);
            return;
        }
        switch (o) {
            case 0xdf: case 0x55:   // ~x & E
                LoadX(0, x); LoadE16(n, 1);
                Neon(0x4E601C00u, 0, 1, 0);
                StoreX(0, x);
                return;
            case 0x54: case 0x56: case 0x57: {
                LoadX(0, x); LoadE16(n, 1);
                Neon(o == 0x54 ? 0x4E201C00u : o == 0x56 ? 0x4EA01C00u : 0x6E201C00u, 0, 0, 1);
                StoreX(0, x);
                return;
            }
            case 0x63: case 0x67: case 0x6b: {   // pack, saturating
                LoadX(0, x); LoadE16(n, 1);
                uint32_t low = o == 0x63 ? 0x0E214800u : o == 0x67 ? 0x2E212800u : 0x0E614800u;
                a.W(low | 0u << 5 | 2);
                a.W(low | 0x40000000u | 1u << 5 | 2);
                StoreX(2, x);
                return;
            }
            case 0xf5: case 0xe5: case 0xe4: {   // widening multiplies
                LoadX(0, x); LoadE16(n, 1);
                uint32_t low = o == 0xe4 ? 0x2E60C000u : 0x0E60C000u;
                Neon(low, 2, 0, 1);
                Neon(low | 0x40000000u, 3, 0, 1);
                if (o == 0xf5) Neon(0x4EA0BC00u, 0, 2, 3);       // addp
                else Neon(0x4E405800u, 0, 2, 3);                  // uzp2: the high halves
                StoreX(0, x);
                return;
            }
            case 0xf4:   // pmuludq
                LoadX(0, x); LoadE16(n, 1);
                Neon(0x4E801800u, 2, 0, 0);
                Neon(0x4E801800u, 3, 1, 1);
                Neon(0x2EA0C000u, 0, 2, 3);
                StoreX(0, x);
                return;
            case 0x28: case 0x6f: case 0xf0:
                LoadE16(n, 0);
                StoreX(0, x);
                return;
            case 0x29: case 0x7f: case 0x2b: case 0xe7:
                LoadX(0, x);
                if (n.isReg) StoreX(0, n.rm); else { Ea(n); StoreQ16(0); }
                return;
            case 0x10:
                if (!f3 && !f2) { LoadE16(n, 0); StoreX(0, x); return; }
                if (n.isReg) {
                    LoadX(0, x); LoadX(1, n.rm);
                    if (f3) InsS(0, 0, 1, 0); else InsD(0, 0, 1, 0);
                    StoreX(0, x);
                } else {
                    Ea(n);
                    if (f3) LoadS16(0); else LoadD16(0);   // these clear the rest
                    StoreX(0, x);
                }
                return;
            case 0x11:
                if (!f3 && !f2) {
                    LoadX(0, x);
                    if (n.isReg) StoreX(0, n.rm); else { Ea(n); StoreQ16(0); }
                    return;
                }
                LoadX(0, x);
                if (n.isReg) {
                    LoadX(1, n.rm);
                    if (f3) InsS(1, 0, 0, 0); else InsD(1, 0, 0, 0);
                    StoreX(1, n.rm);
                } else {
                    Ea(n);
                    if (f3) StoreS16(0); else StoreD16(0);
                }
                return;
            case 0x12:
                LoadX(0, x);
                if (n.isReg) { LoadX(1, n.rm); InsD(0, 0, 1, 1); }
                else { Ea(n); LoadD16(1); InsD(0, 0, 1, 0); }
                StoreX(0, x);
                return;
            case 0x13:
                LoadX(0, x); Ea(n); StoreD16(0);
                return;
            case 0x16:
                LoadX(0, x);
                if (n.isReg) { LoadX(1, n.rm); InsD(0, 1, 1, 0); }
                else { Ea(n); LoadD16(1); InsD(0, 1, 1, 0); }
                StoreX(0, x);
                return;
            case 0x17:
                LoadX(0, x); InsD(0, 0, 0, 1); Ea(n); StoreD16(0);
                return;
            case 0x14: case 0x15:
                LoadX(0, x); LoadE16(n, 1);
                Neon(o == 0x14 ? (p66 ? 0x4EC03800u : 0x4E803800u) : (p66 ? 0x4EC07800u : 0x4E807800u), 0, 0, 1);
                StoreX(0, x);
                return;
            case 0x2a: {
                int sz = (n.rex & 8) ? 8 : 4;
                ReadE(n, XT0, sz);
                if (sz == 4) a.Sbfx0(XT0, XT0, 32);
                LoadX(0, x);
                a.W((f3 ? 0x9E220000u : 0x9E620000u) | (uint32_t)XT0 << 5 | 1);
                if (f3) InsS(0, 0, 1, 0); else InsD(0, 0, 1, 0);
                StoreX(0, x);
                return;
            }
            case 0x51: case 0x58: case 0x59: case 0x5c: case 0x5e: {
                if (f3 || f2) {
                    LoadX(0, x); LoadEScalar(n, 1, f3);
                    uint32_t type = f3 ? 0u : 0x00400000u;
                    switch (o) {
                        case 0x51: a.W(0x1E21C000u | type | 1u << 5 | 2); break;
                        case 0x58: Neon(0x1E202800u | type, 2, 0, 1); break;
                        case 0x59: Neon(0x1E200800u | type, 2, 0, 1); break;
                        case 0x5c: Neon(0x1E203800u | type, 2, 0, 1); break;
                        default:   Neon(0x1E201800u | type, 2, 0, 1); break;
                    }
                    if (f3) InsS(0, 0, 2, 0); else InsD(0, 0, 2, 0);
                    StoreX(0, x);
                    return;
                }
                LoadX(0, x); LoadE16(n, 1);
                uint32_t type = p66 ? 0x00400000u : 0u;
                switch (o) {
                    case 0x51: a.W(0x6EA1F800u | type | 1u << 5 | 0); break;
                    case 0x58: Neon(0x4E20D400u | type, 0, 0, 1); break;
                    case 0x59: Neon(0x6E20DC00u | type, 0, 0, 1); break;
                    case 0x5c: Neon(0x4EA0D400u | type, 0, 0, 1); break;
                    default:   Neon(0x6E20FC00u | type, 0, 0, 1); break;
                }
                StoreX(0, x);
                return;
            }
            case 0x5a:
                if (!f3 && !f2) {
                    if (p66) { LoadE16(n, 1); a.W(0x0E616800u | 1u << 5 | 0); }   // fcvtn: the top half clears
                    else {
                        if (n.isReg) LoadX(1, n.rm); else { Ea(n); LoadD16(1); }
                        a.W(0x0E617800u | 1u << 5 | 0);                            // fcvtl
                    }
                    StoreX(0, x);
                    return;
                }
                LoadX(0, x); LoadEScalar(n, 1, f3);
                if (f3) { a.W(0x1E22C000u | 1u << 5 | 2); InsD(0, 0, 2, 0); }
                else { a.W(0x1E624000u | 1u << 5 | 2); InsS(0, 0, 2, 0); }
                StoreX(0, x);
                return;
            case 0x52: case 0x53: {   // the interpreter's exact answers, not estimates
                LoadX(0, x);
                if (f3) LoadEScalar(n, 1, true); else LoadE16(n, 1);
                if (o == 0x52) a.W(0x6EA1F800u | 1u << 5 | 1);   // fsqrt
                a.W(0x4F03F602u);                                 // fmov v2.4s, #1.0
                Neon(0x6E20FC00u, 2, 2, 1);                       // fdiv
                if (f3) InsS(0, 0, 2, 0); else Neon(0x4EA01C00u, 0, 2, 2);
                StoreX(0, x);
                return;
            }
            case 0xe6:
                if (f3) {   // two int32 to double
                    LoadE16(n, 1);
                    a.W(0x0F20A400u | 1u << 5 | 0);              // sshll v0.2d, v1.2s, #0
                    a.W(0x4E61D800u | 0u << 5 | 0);              // scvtf
                    StoreX(0, x);
                    return;
                }
                LoadE16(n, 1);
                a.W(0x6E201C00u | 0u << 16 | 0u << 5 | 0);       // eor v0, v0, v0: the top half clears
                for (int lane = 0; lane < 2; lane++) {
                    InsD(2, 0, 1, lane);
                    a.W((p66 ? 0x9E780000u : 0x9E600000u) | 2u << 5 | XT0);
                    a.Imm(XT2, 0x80000000ull);
                    a.Sbfx0(XT1, XT0, 32);
                    a.CmpReg(XT0, XT1);
                    a.Csel(XT0, XT0, XT2, EQ);
                    a.W(0x1E602040u | 2u << 16);                  // fcmp d2, d2
                    a.Csel(XT0, XT0, XT2, VC);
                    a.W(0x4E001C00u | (uint32_t)(lane << 3 | 4) << 16 | (uint32_t)XT0 << 5 | 0);
                }
                StoreX(0, x);
                return;
            case 0x5b:
                LoadE16(n, 1);
                if (!f3 && !p66) a.W(0x4E21D800u | 1u << 5 | 0);   // scvtf
                else {
                    a.W((f3 ? 0x4EA1B800u : 0x4E21A800u) | 1u << 5 | 2);   // fcvtzs or fcvtns
                    a.W(0x4F0265E3u);                                      // movi v3.4s, #0x4f, lsl 24: 2^31 as a float
                    a.W(0x6EA0EC00u | 1u << 16 | 3u << 5 | 3);             // facgt: |v1| below it, which NaN is not
                    a.W(0x4F046400u);                                      // movi v0.4s, #0x80, lsl 24: the answer otherwise
                    Neon(0x6E601C00u, 3, 2, 0);                            // bsl
                    Neon(0x4EA01C00u, 0, 3, 3);
                }
                StoreX(0, x);
                return;
            case 0x6e: {
                int sz = (n.rex & 8) ? 8 : 4;
                ReadE(n, XT0, sz);
                a.Str(XT0, XCPU, XOffset(x));
                a.Str(XZR, XCPU, XOffset(x) + 8);
                return;
            }
            case 0x7e:
                if (f3) {
                    if (n.isReg) LoadX(0, n.rm); else { Ea(n); LoadD16(0); }
                    a.W(0x0EA01C00u | 0u << 16 | 0u << 5 | 0);   // mov v0.8b, v0.8b clears the top half
                    StoreX(0, x);
                    return;
                }
                {
                    int sz = (n.rex & 8) ? 8 : 4;
                    a.Ldr(XT0, XCPU, XOffset(x));
                    if (n.isReg) WriteReg(n.rm, sz, XT0);
                    else { Ea(n); Store(XT0, sz, Stacky(n)); }
                }
                return;
            case 0xd6:
                LoadX(0, x);
                if (n.isReg) { a.W(0x0EA01C00u); StoreX(0, n.rm); }
                else { Ea(n); StoreD16(0); }
                return;
            case 0xd1: case 0xd2: case 0xd3: case 0xe1: case 0xe2: case 0xf1: case 0xf2: case 0xf3: {
                // By the low 64 bits of E. ARM shifts a lane by the signed low byte of the count, and any count from the lane's width up comes out the same as the width.
                int esize = (o & 0xf) == 1 ? 16 : (o & 0xf) == 2 ? 32 : 64;
                uint32_t dup = esize == 16 ? 0x4E020C00u : esize == 32 ? 0x4E040C00u : 0x4E080C00u;
                uint32_t size = esize == 16 ? 0x00400000u : esize == 32 ? 0x00800000u : 0x00C00000u;
                bool right = o < 0xf0, arithmetic = (o & 0xf0) == 0xe0;
                LoadE16(n, 1);
                a.W(0x9E660000u | 1u << 5 | XT0);          // fmov x23, d1
                a.Imm(XT1, (uint64_t)esize);
                a.CmpReg(XT0, XT1);
                a.Csel(XT0, XT0, XT1, CC);
                if (right) a.Sub(XT0, XZR, XT0);
                a.W(dup | (uint32_t)XT0 << 5 | 1);
                LoadX(0, x);
                Neon((arithmetic ? 0x4E204400u : 0x6E204400u) | size, 0, 0, 1);
                StoreX(0, x);
                return;
            }
            case 0xf6:   // psadbw
                LoadX(0, x); LoadE16(n, 1);
                Neon(0x6E207400u, 0, 0, 1);
                a.W(0x6E202800u); a.W(0x6E602800u); a.W(0x6EA02800u);
                StoreX(0, x);
                return;
            case 0x38:   // pshufb: TBL gives 0 for an index out of range, so the top bit, kept, does what x86's does
                LoadX(0, x); LoadE16(n, 1);
                a.W(0x4F04E5E3u);                          // movi v3.16b, #0x8f
                Neon(0x4E201C00u, 2, 1, 3);
                Neon(0x4E000000u, 0, 0, 2);
                StoreX(0, x);
                return;
            case 0x3a:   // palignr
                LoadX(0, x); LoadE16(n, 1);
                a.W(0x6E000000u | 0u << 16 | (uint32_t)n.imm << 11 | 1u << 5 | 0);
                StoreX(0, x);
                return;
            case 0x7c:   // haddps haddpd
                LoadX(0, x); LoadE16(n, 1);
                Neon(p66 ? 0x6E60D400u : 0x6E20D400u, 0, 0, 1);
                StoreX(0, x);
                return;
            case 0x5d: case 0x5f: {   // min max: the second operand unless the first is strictly less (more), NaNs included
                bool scalar = f3 || f2, isDouble = f2 || (p66 && !scalar);
                LoadX(0, x);
                if (scalar) LoadEScalar(n, 1, f3); else LoadE16(n, 1);
                uint32_t gt = isDouble ? 0x6EE0E400u : 0x6EA0E400u;
                if (o == 0x5d) Neon(gt, 2, 1, 0); else Neon(gt, 2, 0, 1);
                Neon(0x6E601C00u, 2, 0, 1);                // bsl: mask ? x : E
                if (f3) InsS(0, 0, 2, 0); else if (f2) InsD(0, 0, 2, 0); else Neon(0x4EA01C00u, 0, 2, 2);
                StoreX(0, x);
                return;
            }
            case 0xc2: {
                bool scalar = f3 || f2, isDouble = f2 || (p66 && !scalar);
                unsigned kind = (unsigned)n.imm & 7;
                uint32_t type = isDouble ? 0x00400000u : 0u;
                LoadX(0, x);
                if (scalar) LoadEScalar(n, 1, f3); else LoadE16(n, 1);
                switch (kind & 3) {
                    case 0: Neon(0x4E20E400u | type, 2, 0, 1); break;   // eq
                    case 1: Neon(0x6EA0E400u | type, 2, 1, 0); break;   // lt: E > x
                    case 2: Neon(0x6E20E400u | type, 2, 1, 0); break;   // le: E >= x
                    default:
                        Neon(0x4E20E400u | type, 2, 0, 0);               // ordered: each equals itself
                        Neon(0x4E20E400u | type, 3, 1, 1);
                        Neon(0x4E201C00u, 2, 2, 3);
                        if (kind == 3) a.W(0x6E205800u | 2u << 5 | 2);
                        break;
                }
                if (kind >= 4 && kind != 7) a.W(0x6E205800u | 2u << 5 | 2);   // not
                if (f3) InsS(0, 0, 2, 0); else if (f2) InsD(0, 0, 2, 0); else Neon(0x4EA01C00u, 0, 2, 2);
                StoreX(0, x);
                return;
            }
            case 0x2c: case 0x2d: {
                // To an integer. Saturating as ARM does it, whereas x86 has one answer for anything out of range and NaN.
                int sz = (n.rex & 8) ? 8 : 4;
                LoadEScalar(n, 1, f3);
                if (f3) a.W(0x1E22C000u | 1u << 5 | 1);    // fcvt d1, s1
                a.W((o == 0x2c ? 0x9E780000u : 0x9E600000u) | 1u << 5 | XT0);   // fcvtzs or fcvtns x23, d1
                a.Imm(XT2, sz == 8 ? 0x8000000000000000ull : 0x80000000ull);
                if (sz == 4) { a.Sbfx0(XT1, XT0, 32); a.CmpReg(XT0, XT1); a.Csel(XT0, XT0, XT2, EQ); }
                else { a.W(0x92F00000u | XT1); a.CmpReg(XT0, XT1); a.Csel(XT0, XT0, XT2, NE); }   // movn: the largest, where it saturated
                a.W(0x1E612020u | 1u << 16);               // fcmp d1, d1
                a.Csel(XT0, XT0, XT2, VC);
                WriteReg(n.reg, sz, XT0);
                return;
            }
            case 0x50: {
                a.Ldr(XT0, XCPU, XOffset(n.rm));
                a.Ldr(XT1, XCPU, XOffset(n.rm) + 8);
                if (p66) { a.Lsr(XT0, XT0, 63); a.Lsr(XT1, XT1, 62); a.W(0x927F0000u | (uint32_t)XT1 << 5 | XT1); a.Orr(XT0, XT0, XT1); }
                else {
                    a.Lsr(X17, XT0, 31); a.W(0x92400000u | (uint32_t)X17 << 5 | X17);
                    a.Lsr(XT0, XT0, 63); a.Lsl(XT0, XT0, 1); a.Orr(X17, X17, XT0);
                    a.Lsr(XT2, XT1, 31); a.W(0x92400000u | (uint32_t)XT2 << 5 | XT2); a.Lsl(XT2, XT2, 2); a.Orr(X17, X17, XT2);
                    a.Lsr(XT1, XT1, 63); a.Lsl(XT1, XT1, 3); a.Orr(XT0, X17, XT1);
                }
                a.MovW(n.reg, XT0);
                return;
            }
            case 0xc4: {
                unsigned i = (unsigned)n.imm & 7;
                ReadE(n, XT0, n.isReg ? 4 : 2);
                LoadX(0, x);
                a.W(0x4E001C00u | (i << 2 | 2) << 16 | (uint32_t)XT0 << 5 | 0);
                StoreX(0, x);
                return;
            }
            case 0xc5: {
                unsigned i = (unsigned)n.imm & 7;
                LoadX(1, n.rm);
                a.W(0x0E003C00u | (i << 2 | 2) << 16 | 1u << 5 | XT0);
                a.MovW(n.reg, XT0);
                return;
            }
            case 0xd7:
                LoadX(1, n.rm);
                a.W(0x6F090400u | 1u << 5 | 2);   // ushr v2.16b, v1.16b, #7
                a.W(0x6F191400u | 2u << 5 | 2);   // usra v2.8h, v2.8h, #7
                a.W(0x6F321400u | 2u << 5 | 2);   // usra v2.4s, v2.4s, #14
                a.W(0x6F641400u | 2u << 5 | 2);   // usra v2.2d, v2.2d, #28
                a.W(0x0E013C00u | 2u << 5 | XT0); // umov w23, v2.b[0]
                a.W(0x0E113C00u | 2u << 5 | XT1); // umov w25, v2.b[8]
                a.Lsl(XT1, XT1, 8);
                a.Orr(XT0, XT0, XT1);
                a.MovW(n.reg, XT0);
                return;
            case 0x70: {
                unsigned i = (unsigned)n.imm;
                LoadE16(n, 1);
                if (p66) {
                    for (int k = 0; k < 4; k++) InsS(2, k, 1, (i >> (2 * k)) & 3);
                } else {
                    Neon(0x4EA01C00u, 2, 1, 1);
                    int at = f2 ? 0 : 4;
                    for (int k = 0; k < 4; k++) InsH(2, at + k, 1, at + (int)((i >> (2 * k)) & 3));
                }
                StoreX(2, x);
                return;
            }
            case 0xc6: {
                unsigned i = (unsigned)n.imm;
                LoadX(0, x); LoadE16(n, 1);
                if (p66) { InsD(2, 0, 0, i & 1); InsD(2, 1, 1, (i >> 1) & 1); }
                else { InsS(2, 0, 0, i & 3); InsS(2, 1, 0, (i >> 2) & 3); InsS(2, 2, 1, (i >> 4) & 3); InsS(2, 3, 1, (i >> 6) & 3); }
                StoreX(2, x);
                return;
            }
            case 0x71: case 0x72: case 0x73: {
                unsigned s = (unsigned)n.imm;
                int kind = n.reg & 7, r = n.rm;
                int esize = o == 0x71 ? 16 : o == 0x72 ? 32 : 64;
                LoadX(0, r);
                if (o == 0x73 && (kind == 3 || kind == 7)) {
                    if (s == 0) return;
                    a.W(0x6E211C21u);   // eor v1, v1, v1
                    if (s <= 15) {
                        if (kind == 3) a.W(0x6E000000u | 1u << 16 | s << 11 | 0u << 5 | 0);
                        else a.W(0x6E000000u | 0u << 16 | (16 - s) << 11 | 1u << 5 | 0);
                        StoreX(0, r);
                    } else StoreX(1, r);
                    return;
                }
                if (kind == 4) {   // arithmetic right: the sign, however far
                    if (s > (unsigned)esize - 1) s = esize - 1;
                    if (s) a.W(0x4F000400u | (uint32_t)(2 * esize - s) << 16 | 0u << 5 | 0);
                    StoreX(0, r);
                    return;
                }
                if (s > (unsigned)esize - 1) { a.W(0x6E201C00u); StoreX(0, r); return; }   // eor v0, v0, v0
                if (!s) return;
                if (kind == 2) a.W(0x6F000400u | (uint32_t)(2 * esize - s) << 16 | 0u << 5 | 0);
                else a.W(0x4F005400u | (uint32_t)(esize + s) << 16 | 0u << 5 | 0);
                StoreX(0, r);
                return;
            }
            default: break;
        }
    }

    // x23 by x25, signed, into a register. CF and OF say whether it fitted; the others stay.
    void IMulTo(const Ins &n, int reg, int sz) {
        if (sz == 8) {
            a.Mul(XT2, XT0, XT1);
            if (n.flagsLive) { a.W(0x9B407C00u | (uint32_t)XT1 << 16 | (uint32_t)XT0 << 5 | X17); a.Asr(XT0, XT2, 63); a.CmpReg(X17, XT0); }
        } else {
            a.Sbfx0(XT0, XT0, 32); a.Sbfx0(XT1, XT1, 32);
            a.Mul(XT2, XT0, XT1);
            if (n.flagsLive) { a.Sbfx0(X17, XT2, 32); a.CmpReg(X17, XT2); }
        }
        if (n.flagsLive) { a.Cset(XT0, NE); StrbCpu(XT0, offsetof(Cpu, cf)); StrbCpu(XT0, offsetof(Cpu, of)); }
        WriteReg(reg, sz, XT2);
    }
    void MulDiv(const Ins &n, int sz, int kind) {
        if (kind == 4 || kind == 5) {
            bool isSigned = kind == 5;
            if (n.flagsLive) SpillFlags();
            ReadE(n, XT0, sz);
            if (sz == 8) {
                a.Mul(XT2, RAX, XT0);
                a.W((isSigned ? 0x9B407C00u : 0x9BC07C00u) | (uint32_t)XT0 << 16 | (uint32_t)RAX << 5 | XT1);
                if (n.flagsLive) {
                    if (isSigned) { a.Asr(X17, XT2, 63); a.CmpReg(XT1, X17); } else a.CmpZero(XT1);
                }
            } else {
                if (isSigned) { a.Sbfx0(XT0, XT0, 32); a.Sbfx0(X17, RAX, 32); } else a.MovW(X17, RAX);
                a.Mul(XT2, X17, XT0);
                if (isSigned) a.Asr(XT1, XT2, 32); else a.Lsr(XT1, XT2, 32);
                if (n.flagsLive) {
                    if (isSigned) { a.Sbfx0(X17, XT2, 32); a.CmpReg(X17, XT2); } else a.CmpZero(XT1);
                }
            }
            if (n.flagsLive) { a.Cset(XT0, NE); StrbCpu(XT0, offsetof(Cpu, cf)); StrbCpu(XT0, offsetof(Cpu, of)); }
            WriteReg(RAX, sz, XT2);
            WriteReg(RDX, sz, XT1);
            return;
        }
        // div idiv: by zero, or a dividend too wide for one register, is the interpreter's
        bool isSigned = kind == 7;
        ReadE(n, XT0, sz);
        std::vector<uint32_t *> slow;
        std::vector<uint32_t> how;
        if (sz == 4 && isSigned) a.Sbfx0(XT0, XT0, 32);
        slow.push_back(Later()); how.push_back(0xB4000000u | XT0);
        if (sz == 8) {
            a.Mov(XT1, RAX);
            if (isSigned) { a.Asr(X17, RAX, 63); a.CmpReg(RDX, X17); slow.push_back(Later()); how.push_back(0x54000000u | NE); }
            else { slow.push_back(Later()); how.push_back(0xB5000000u | RDX); }
        } else {
            a.Lsl(XT1, RDX, 32);
            a.MovW(X17, RAX);
            a.Orr(XT1, XT1, X17);
        }
        a.W((isSigned ? 0x9AC00C00u : 0x9AC00800u) | (uint32_t)XT0 << 16 | (uint32_t)XT1 << 5 | XT2);
        a.W(0x9B008000u | (uint32_t)XT0 << 16 | (uint32_t)XT1 << 10 | (uint32_t)XT2 << 5 | X17);   // msub: remainder
        WriteReg(RAX, sz, XT2);
        WriteReg(RDX, sz, X17);
        uint32_t *join = Later();
        for (size_t i = 0; i < slow.size(); i++) BranchHere(slow[i], how[i]);
        StepHere(n);
        JumpHere(join);
    }

    void Fallback(const Ins &n) {
        if (!n.neutral) SpillFlags();
        a.Imm(X16, n.ip);
        a.Str(X16, XCPU, offsetof(Cpu, rip));
        a.Bl(gStepThunk);
        if (n.ends) {
            a.Ldr(X17, XCPU, offsetof(Cpu, rip));
            a.B(gMissThunk);
        }
    }

    // Helpers for what goes round the instruction: a branch filled in later, and the interpreter for the odd case that only shows as it runs.
    uint32_t *Later() { uint32_t *site = a.at; a.W(0); return site; }
    void BranchHere(uint32_t *site, uint32_t base) { int64_t d = a.at - site; *site = base | ((uint32_t)d & 0x7ffff) << 5; }
    void JumpHere(uint32_t *site) { int64_t d = a.at - site; *site = 0x14000000u | ((uint32_t)d & 0x03ffffff); }
    void StrbCpu(int t, size_t offset) { a.W(0x39000000u | (uint32_t)offset << 10 | (uint32_t)XCPU << 5 | t); }
    void StepHere(const Ins &n) {   // leaves registers and the flags as the interpreter did
        a.Imm(X16, n.ip);
        a.Str(X16, XCPU, offsetof(Cpu, rip));
        a.Bl(gStepThunk);
    }
    static uint32_t Log2(int sz) { return sz == 8 ? 3 : sz == 4 ? 2 : sz == 2 ? 1 : 0; }
    void Amo(uint32_t op, int sz, int s, int t) { a.W(Log2(sz) << 30 | 0x38E00000u | op | (uint32_t)s << 16 | (uint32_t)X16 << 5 | t); }
    void Cas(int sz, int s, int t) { a.W(Log2(sz) << 30 | 0x08E0FC00u | (uint32_t)s << 16 | (uint32_t)X16 << 5 | t); }
    enum { kAmoAdd = 0, kAmoClr = 0x1000, kAmoEor = 0x2000, kAmoSet = 0x3000, kAmoSwp = 0x8000 };

    // With the address in x16: an atomic needs natural alignment, x86's does not. Then the interpreter's global lock does it. Returns the branch to fill in at the join; flags are in x22
    // or Cpu by then, whichever way it went, so the caller says kUnknown afterwards.
    uint32_t *AlignedOrStep(const Ins &n, int sz) {
        if (sz == 1) return NULL;
        a.TstMask(X16, sz);
        uint32_t *fast = Later();   // b.eq
        int saved = state;
        SpillFlags();
        StepHere(n);
        uint32_t *join = Later();
        state = (decltype(state))saved;
        BranchHere(fast, 0x54000000u | EQ);
        return join;
    }
    void Locked(const Ins &n) {
        uint8_t op = n.op;
        int sz;
        int reg = n.reg;
        if (op == 0xfe || op == 0xff) {
            sz = op & 1 ? n.OpSize() : 1;
            if (n.flagsLive) SpillFlags();
            Ea(n);
            uint32_t *join = AlignedOrStep(n, sz);
            bool inc = (reg & 7) == 0;
            a.Movz(XT1, 1, 0);
            if (inc) Amo(kAmoAdd, sz, XT1, XT0);
            else { a.W(0x92800000u | X17); Amo(kAmoAdd, sz, X17, XT0); }   // movn x17, #0: minus one
            Record(n.flagsLive, inc ? kInc : kDec, sz, XT0, XT1);
            if (join) JumpHere(join);
            state = kUnknown;
            return;
        }
        if (op == 0xf6 || op == 0xf7) {   // not
            sz = op & 1 ? n.OpSize() : 1;
            Ea(n);
            uint32_t *join = AlignedOrStep(n, sz);
            a.W(0x92800000u | XT1);
            Amo(kAmoEor, sz, XT1, XT0);
            if (join) JumpHere(join);
            state = kUnknown;
            return;
        }
        if (op == 0x86 || op == 0x87) {
            sz = op & 1 ? n.OpSize() : 1;
            Ea(n);
            uint32_t *join = AlignedOrStep(n, sz);
            ReadReg(XT1, reg, sz);
            Amo(kAmoSwp, sz, XT1, XT0);
            WriteReg(reg, sz, XT0);
            if (join) JumpHere(join);
            state = kUnknown;
            return;
        }
        if (op == 0x0f && (n.op2 == 0xc0 || n.op2 == 0xc1)) {   // xadd
            sz = n.op2 & 1 ? n.OpSize() : 1;
            Ea(n);
            uint32_t *join = AlignedOrStep(n, sz);
            ReadReg(XT1, reg, sz);
            Amo(kAmoAdd, sz, XT1, XT0);
            Record(n.flagsLive, kAdd, sz, XT0, XT1);
            WriteReg(reg, sz, XT0);
            if (join) JumpHere(join);
            state = kUnknown;
            return;
        }
        if (op == 0x0f && (n.op2 == 0xb0 || n.op2 == 0xb1)) {   // cmpxchg
            sz = n.op2 & 1 ? n.OpSize() : 1;
            Ea(n);
            uint32_t *join = AlignedOrStep(n, sz);
            ReadReg(XT0, RAX, sz);
            ReadReg(XT1, reg, sz);
            a.Mov(XT2, XT0);
            Cas(sz, XT2, XT1);
            if (sz < 4) a.Ubfx0(XT2, XT2, sz * 8);
            else if (sz == 4) a.MovW(XT2, XT2);
            Record(n.flagsLive, kSub, sz, XT0, XT2);
            a.CmpReg(XT0, XT2);
            a.BCondSkip(EQ, 1);
            WriteReg(RAX, sz, XT2);
            if (join) JumpHere(join);
            state = kUnknown;
            return;
        }
        if (op == 0x0f && n.op2 == 0xba) {   // bt bts btr btc: the byte the bit is in
            if (n.flagsLive) SpillFlags();
            sz = n.OpSize();
            int kind = (reg & 7) - 4;
            unsigned bit = (unsigned)n.imm & (unsigned)(sz * 8 - 1);
            Ea(n);
            AddDisp(bit / 8);
            a.Imm(XT1, 1u << (bit & 7));
            if (kind == 0) a.W(0x38BFC000u | (uint32_t)X16 << 5 | XT0);
            else if (kind == 1) Amo(kAmoSet, 1, XT1, XT0);
            else if (kind == 2) Amo(kAmoClr, 1, XT1, XT0);
            else Amo(kAmoEor, 1, XT1, XT0);
            if (n.flagsLive) { a.TstReg(XT0, XT1); a.Cset(XT2, NE); StrbCpu(XT2, offsetof(Cpu, cf)); }
            return;
        }
        // add or and sub xor, with a register or an immediate
        int which;
        if (op < 0x40) { which = op >> 3; sz = op & 1 ? n.OpSize() : 1; }
        else { which = reg & 7; sz = op == 0x80 ? 1 : n.OpSize(); }
        Ea(n);
        uint32_t *join = AlignedOrStep(n, sz);
        if (op < 0x40) ReadReg(XT1, reg, sz);
        else {
            uint64_t i = op == 0x81 ? (sz == 8 ? (uint64_t)(int64_t)(int32_t)n.imm : n.imm) : (uint64_t)(int64_t)(int8_t)n.imm;
            a.Imm(XT1, i & SizeMask(sz));
        }
        switch (which) {
            case 0: Amo(kAmoAdd, sz, XT1, XT0); a.Add(XT2, XT0, XT1); Record(n.flagsLive, kAdd, sz, XT0, XT1); break;
            case 5: a.Sub(X17, XZR, XT1); Amo(kAmoAdd, sz, X17, XT0); Record(n.flagsLive, kSub, sz, XT0, XT1); break;
            case 1: Amo(kAmoSet, sz, XT1, XT0); a.Orr(XT2, XT0, XT1); Record(n.flagsLive, kLogic, sz, XT2, -1); break;
            case 6: Amo(kAmoEor, sz, XT1, XT0); a.Eor(XT2, XT0, XT1); Record(n.flagsLive, kLogic, sz, XT2, -1); break;
            default: a.Mvn(X17, XT1); Amo(kAmoClr, sz, X17, XT0); a.And(XT2, XT0, XT1); Record(n.flagsLive, kLogic, sz, XT2, -1); break;
        }
        if (join) JumpHere(join);
        state = kUnknown;
    }

    void One(const Ins &n) {
        noRex = !n.hasRex;
        if (!n.translated) { Fallback(n); return; }
        uint8_t op = n.op;
        const int reg = n.reg;
        if (n.lock) { Locked(n); return; }
        // ADC and SBB read CF, which has to be in Cpu before x16 holds an address: working it out may clobber that.
        if ((op < 0x40 && (op & 7) < 6 && ((op >> 3) == 2 || (op >> 3) == 3)) || ((op == 0x80 || op == 0x81 || op == 0x83) && ((reg & 7) == 2 || (reg & 7) == 3))) SpillFlags();

        if (op < 0x40 && (op & 7) < 6) {
            int which = op >> 3, form = op & 7;
            int sz = form == 0 || form == 2 || form == 4 ? 1 : n.OpSize();
            switch (form) {
                case 0: case 1:
                    ReadE(n, XT0, sz); ReadReg(XT1, reg, sz);
                    Alu(n, which, sz, false);
                    if (which != 7) WriteEAgain(n, XT2, sz);
                    break;
                case 2: case 3:
                    ReadReg(XT0, reg, sz); ReadE(n, XT1, sz);
                    Alu(n, which, sz, true);
                    if (which != 7) WriteReg(reg, sz, XT2);
                    break;
                default: {
                    ReadReg(XT0, RAX, sz);
                    a.Imm(XT1, form == 4 ? n.imm : (sz == 8 ? (uint64_t)(int64_t)(int32_t)n.imm : n.imm));
                    Alu(n, which, sz, true);
                    if (which != 7) WriteReg(RAX, sz, XT2);
                    break;
                }
            }
            return;
        }
        switch (op) {
            case 0x50: case 0x51: case 0x52: case 0x53: case 0x54: case 0x55: case 0x56: case 0x57:
                a.Mov(X17, (op & 7) | ((n.rex & 1) << 3));
                a.PushTo(X17, RSP);
                return;
            case 0x58: case 0x59: case 0x5a: case 0x5b: case 0x5c: case 0x5d: case 0x5e: case 0x5f:
                a.PopFrom(X17, RSP);
                a.Mov((op & 7) | ((n.rex & 1) << 3), X17);
                return;
            case 0x63:
                ReadE(n, XT0, 4);
                a.Sbfx0(XT0, XT0, 32);
                WriteReg(reg, n.OpSize(), XT0);
                return;
            case 0x68: a.Imm(X17, (uint64_t)(int64_t)(int32_t)n.imm); a.PushTo(X17, RSP); return;
            case 0x6a: a.Imm(X17, (uint64_t)(int64_t)(int8_t)n.imm); a.PushTo(X17, RSP); return;
            case 0x69: case 0x6b: {
                int sz = n.OpSize();
                if (n.flagsLive) SpillFlags();
                ReadE(n, XT0, sz);
                uint64_t i = op == 0x6b ? (uint64_t)(int64_t)(int8_t)n.imm : (uint64_t)(int64_t)(int32_t)n.imm;
                a.Imm(XT1, i);
                IMulTo(n, reg, sz);
                return;
            }
            case 0x70: case 0x71: case 0x72: case 0x73: case 0x74: case 0x75: case 0x76: case 0x77:
            case 0x78: case 0x79: case 0x7a: case 0x7b: case 0x7c: case 0x7d: case 0x7e: case 0x7f: {
                int cond = Condition(op & 15);
                a.BCondSkip(cond ^ 1, 1);
                Link(n.next + (uint64_t)(int64_t)(int8_t)n.imm);
                return;
            }
            case 0x80: case 0x81: case 0x83: {
                int sz = op == 0x80 ? 1 : n.OpSize();
                int which = reg & 7;
                uint64_t i = op == 0x81 ? (sz == 8 ? (uint64_t)(int64_t)(int32_t)n.imm : n.imm) : (uint64_t)(int64_t)(int8_t)n.imm;
                ReadE(n, XT0, sz);
                a.Imm(XT1, i & SizeMask(sz));
                Alu(n, which, sz, false);
                if (which != 7) WriteEAgain(n, XT2, sz);
                return;
            }
            case 0x84: case 0x85: {
                int sz = op & 1 ? n.OpSize() : 1;
                ReadE(n, XT0, sz); ReadReg(XT1, reg, sz);
                Alu(n, 4, sz, false);
                return;
            }
            case 0x88: case 0x89: {
                int sz = op & 1 ? n.OpSize() : 1;
                if (n.isReg) { ReadReg(XT0, reg, sz); WriteReg(n.rm, sz, XT0); return; }
                Ea(n);
                ReadReg(XT0, reg, sz);
                Store(XT0, sz, Stacky(n));
                return;
            }
            case 0x8a: case 0x8b: {
                int sz = op & 1 ? n.OpSize() : 1;
                ReadE(n, XT0, sz);
                WriteReg(reg, sz, XT0);
                return;
            }
            case 0x8d: {
                Ins lea = n;
                lea.seg = 0;
                Ea(lea);
                WriteReg(reg, n.OpSize(), X16);
                return;
            }
            case 0x90: return;
            case 0x8f:
                a.PopFrom(XT0, RSP);
                if (n.isReg) { a.Mov(n.rm, XT0); return; }
                Ea(n);
                Store(XT0, 8, Stacky(n));
                return;
            case 0xf5: case 0xf8: case 0xf9:
                if (!n.flagsLive) return;
                SpillFlags();
                if (op == 0xf5) { a.Ldrb(XT0, XCPU, offsetof(Cpu, cf)); a.W(0xD2400000u | (uint32_t)XT0 << 5 | XT0); }
                else a.Movz(XT0, op == 0xf9, 0);
                StrbCpu(XT0, offsetof(Cpu, cf));
                return;
            case 0xfc: case 0xfd:
                a.Movz(XT0, op == 0xfd, 0);
                StrbCpu(XT0, offsetof(Cpu, df));
                return;
            case 0x86: case 0x87: {
                int sz = op & 1 ? n.OpSize() : 1;
                if (!n.isReg) { Locked(n); return; }   // XCHG with memory is locked whether it says so or not
                ReadReg(XT0, reg, sz); ReadReg(XT1, n.rm, sz);
                WriteReg(reg, sz, XT1); WriteReg(n.rm, sz, XT0);
                return;
            }
            case 0x91: case 0x92: case 0x93: case 0x94: case 0x95: case 0x96: case 0x97: {
                int sz = n.OpSize(), r = (op & 7) | ((n.rex & 1) << 3);
                ReadReg(XT0, RAX, sz); ReadReg(XT1, r, sz);
                WriteReg(RAX, sz, XT1); WriteReg(r, sz, XT0);
                return;
            }
            case 0xa8: case 0xa9: {
                int sz = op & 1 ? n.OpSize() : 1;
                ReadReg(XT0, RAX, sz);
                a.Imm(XT1, sz == 8 ? (uint64_t)(int64_t)(int32_t)n.imm : n.imm);
                Alu(n, 4, sz, false);
                return;
            }
            case 0x98: {
                int sz = n.OpSize();
                if (sz == 8) a.Sbfx0(X17, RAX, 32);
                else if (sz == 4) a.Sbfx0(X17, RAX, 16);
                else a.Sbfx0(X17, RAX, 8);
                WriteReg(RAX, sz, X17);
                return;
            }
            case 0x99: {
                int sz = n.OpSize();
                a.SignOf(X17, RAX, sz * 8 - 1);
                WriteReg(RDX, sz, X17);
                return;
            }
            case 0xb0: case 0xb1: case 0xb2: case 0xb3: case 0xb4: case 0xb5: case 0xb6: case 0xb7:
                a.Imm(X17, n.imm);
                WriteReg((op & 7) | ((n.rex & 1) << 3), 1, X17);
                return;
            case 0xb8: case 0xb9: case 0xba: case 0xbb: case 0xbc: case 0xbd: case 0xbe: case 0xbf: {
                int sz = n.OpSize();
                a.Imm(X17, n.imm);
                WriteReg((op & 7) | ((n.rex & 1) << 3), sz, X17);
                return;
            }
            case 0xc0: case 0xc1: case 0xd0: case 0xd1: case 0xd2: case 0xd3: {
                int sz = op & 1 ? n.OpSize() : 1;
                int kind = reg & 7;
                bool byCL = op >= 0xd2;
                if (kind < 2) {
                    // CF and OF over what was there, so that has to be in Cpu before x16 is in use.
                    if (n.flagsLive) SpillFlags();
                    ReadE(n, XT0, sz);
                    if (byCL) {
                        a.W(0x92400000u | (sz == 8 ? 5u : 4u) << 10 | (uint32_t)RCX << 5 | XT1);
                        if (kind == 0) a.Sub(X17, XZR, XT1); else a.Mov(X17, XT1);
                        a.W((sz == 8 ? 0x9AC02C00u : 0x1AC02C00u) | (uint32_t)X17 << 16 | (uint32_t)XT0 << 5 | XT2);   // rorv
                        if (n.flagsLive) {
                            uint32_t *skip = Later();
                            Record(true, kShiftBase + kind, sz, XT0, XT1);
                            BranchHere(skip, 0xB4000000u | XT1);
                            state = kUnknown;
                        }
                    } else {
                        int bits = sz * 8;
                        unsigned count = (op >= 0xd0 ? 1 : (unsigned)n.imm) & (sz == 8 ? 63 : 31);
                        unsigned right = kind == 1 ? count : (bits - count) % bits;
                        if (sz == 8) a.W(0x93C00000u | (uint32_t)XT0 << 16 | right << 10 | (uint32_t)XT0 << 5 | XT2);   // extr
                        else a.W(0x13800000u | (uint32_t)XT0 << 16 | right << 10 | (uint32_t)XT0 << 5 | XT2);
                        if (n.flagsLive && count) {
                            a.Imm(XT1, count);
                            Record(true, kShiftBase + kind, sz, XT0, XT1);
                        }
                    }
                    WriteEAgain(n, XT2, sz);
                    return;
                }
                ReadE(n, XT0, sz);
                if (byCL && n.flagsLive) {
                    // A count of zero leaves the flags as they were, whatever form they are in.
                    a.W(0x92400000u | (sz == 8 ? 5u : 4u) << 10 | (uint32_t)RCX << 5 | XT1);
                    if (kind == 7) { a.Sbfx0(X17, XT0, sz * 8); a.Asrv(XT2, X17, XT1); }
                    else if (kind == 5) a.Lsrv(XT2, XT0, XT1);
                    else a.Lslv(XT2, XT0, XT1);
                    uint32_t *skip = Later();
                    Record(true, kShiftBase + kind, sz, XT0, XT1);
                    BranchHere(skip, 0xB4000000u | XT1);
                    state = kUnknown;
                    WriteEAgain(n, XT2, sz);
                    return;
                }
                if (n.defsFlags && n.flagsLive) {
                    unsigned count = (op >= 0xd0 ? 1 : (unsigned)n.imm) & (sz == 8 ? 63 : 31);
                    if (kind == 7) { a.Sbfx0(XT1, XT0, sz * 8); a.Asr(XT2, XT1, count); }
                    else if (kind == 5) a.Lsr(XT2, XT0, count);
                    else a.Lsl(XT2, XT0, count);
                    a.Imm(XT1, count);
                    Record(true, kShiftBase + kind, sz, XT0, XT1);
                    WriteEAgain(n, XT2, sz);
                    return;
                }
                if (op >= 0xd2) {
                    a.W(0x92400000u | (sz == 8 ? 5u : 4u) << 10 | (uint32_t)RCX << 5 | XT1);   // and x25, x1, #63 or #31
                    if (kind == 7) { a.Sbfx0(XT0, XT0, sz * 8); a.Asrv(XT2, XT0, XT1); }
                    else if (kind == 5) a.Lsrv(XT2, XT0, XT1);
                    else a.Lslv(XT2, XT0, XT1);
                } else {
                    unsigned count = (op >= 0xd0 ? 1 : (unsigned)n.imm) & (sz == 8 ? 63 : 31);
                    if (kind == 7) { a.Sbfx0(XT0, XT0, sz * 8); a.Asr(XT2, XT0, count); }
                    else if (kind == 5) a.Lsr(XT2, XT0, count);
                    else a.Lsl(XT2, XT0, count);
                }
                WriteEAgain(n, XT2, sz);
                return;
            }
            case 0xc2:
                a.PopFrom(X17, RSP);
                a.Imm(XT1, n.imm);
                a.Add(RSP, RSP, XT1);
                Indirect();
                return;
            case 0xc3:
                a.PopFrom(X17, RSP);
                Indirect();
                return;
            case 0xc6: case 0xc7: {
                int sz = op & 1 ? n.OpSize() : 1;
                uint64_t i = sz == 8 ? (uint64_t)(int64_t)(int32_t)n.imm : n.imm;
                if (n.isReg) { a.Imm(XT0, i); WriteReg(n.rm, sz, XT0); return; }
                Ea(n);
                a.Imm(XT0, i);
                Store(XT0, sz, Stacky(n));
                return;
            }
            case 0xc9:
                a.Mov(RSP, RBP);
                a.PopFrom(X17, RSP);
                a.Mov(RBP, X17);
                return;
            case 0xe8:
                a.Imm(X17, n.next);
                a.PushTo(X17, RSP);
                Link(n.next + (uint64_t)(int64_t)(int32_t)n.imm);
                return;
            case 0xe9: Link(n.next + (uint64_t)(int64_t)(int32_t)n.imm); return;
            case 0xeb: Link(n.next + (uint64_t)(int64_t)(int8_t)n.imm); return;
            case 0xf6: case 0xf7: {
                int sz = op & 1 ? n.OpSize() : 1;
                int kind = reg & 7;
                if (kind >= 4) { MulDiv(n, sz, kind); return; }
                ReadE(n, XT0, sz);
                if (kind < 2) {
                    uint64_t i = sz == 8 ? (uint64_t)(int64_t)(int32_t)n.imm : n.imm;
                    a.Imm(XT1, i);
                    Alu(n, 4, sz, false);
                } else if (kind == 2) {
                    a.Mvn(XT2, XT0);
                    WriteEAgain(n, XT2, sz);
                } else {
                    a.Mov(XT1, XT0);
                    a.Movz(XT0, 0, 0);
                    a.Sub(XT2, XT0, XT1);
                    Record(n.flagsLive, kSub, sz, XT0, XT1);
                    if (!n.flagsLive) state = state == kKnown ? kUnknown : state;
                    WriteEAgain(n, XT2, sz);
                }
                return;
            }
            case 0xfe: case 0xff: {
                int sz = op & 1 ? n.OpSize() : 1;
                int kind = reg & 7;
                if (kind < 2) {
                    // INC and DEC leave CF as it was, so if anything will read these flags CF has to be in Cpu first.
                    if (n.flagsLive) SpillFlags();
                    ReadE(n, XT0, sz);
                    a.Movz(XT1, 1, 0);
                    if (kind == 0) a.Add(XT2, XT0, XT1); else a.Sub(XT2, XT0, XT1);
                    Record(n.flagsLive, kind == 0 ? kInc : kDec, sz, XT0, XT1);
                    WriteEAgain(n, XT2, sz);
                    return;
                }
                if (kind == 2) {
                    ReadE(n, XT2, 8);
                    a.Imm(XT1, n.next);
                    a.PushTo(XT1, RSP);
                    a.Mov(X17, XT2);
                    Indirect();
                    return;
                }
                if (kind == 4) {
                    ReadE(n, X17, 8);
                    Indirect();
                    return;
                }
                ReadE(n, XT0, 8);
                a.PushTo(XT0, RSP);
                return;
            }
            case 0x0f: break;
            default: Fallback(n); return;
        }
        uint8_t o = n.op2;
        if (VectorForm(n)) { Vector(n); return; }
        if (o == 0x2e || o == 0x2f) {
            if (!n.flagsLive) return;   // the read has no visible effect
            bool isDouble = n.opsize16;
            LoadX(0, reg);
            LoadEScalar(n, 1, !isDouble);
            a.W((isDouble ? 0x1E602000u : 0x1E202000u) | 1u << 16 | 0u << 5);   // fcmp: less N, equal ZC, greater C, unordered CV
            a.Cset(XT0, EQ);
            a.Cset(XT1, VS);
            a.Orr(XT0, XT0, XT1);                      // ZF: equal or unordered
            a.Cset(XT2, LT);                           // CF: less or unordered
            a.W(0x39000000u | (uint32_t)offsetof(Cpu, zf) << 10 | (uint32_t)XCPU << 5 | XT0);
            a.W(0x39000000u | (uint32_t)offsetof(Cpu, cf) << 10 | (uint32_t)XCPU << 5 | XT2);
            a.W(0x39000000u | (uint32_t)offsetof(Cpu, of) << 10 | (uint32_t)XCPU << 5 | XZR);
            a.W(0x39000000u | (uint32_t)offsetof(Cpu, sf) << 10 | (uint32_t)XCPU << 5 | XZR);
            a.W(0x39000000u | (uint32_t)offsetof(Cpu, afByte) << 10 | (uint32_t)XCPU << 5 | XZR);
            a.W(0xD2400000u | (uint32_t)XT1 << 5 | XT1);   // eor x25, x25, #1: the byte PF is worked out from, 0 when unordered
            a.W(0x39000000u | (uint32_t)offsetof(Cpu, pfByte) << 10 | (uint32_t)XCPU << 5 | XT1);
            a.Movz(XK, 0, 0);
            state = kCurrent;
            return;
        }
        if (o >= 0x80 && o <= 0x8f) {
            int cond = Condition(o & 15);
            a.BCondSkip(cond ^ 1, 1);
            Link(n.next + (uint64_t)(int64_t)(int32_t)n.imm);
            return;
        }
        if (o >= 0x90 && o <= 0x9f) {
            int cond = Condition(o & 15);
            a.Cset(XT1, cond);
            if (n.isReg) WriteReg(n.rm, 1, XT1);
            else { Ea(n); Store(XT1, 1, Stacky(n)); }
            return;
        }
        if (o >= 0x40 && o <= 0x4f) {
            int sz = n.OpSize();
            ReadE(n, XT1, sz);
            int cond = Condition(o & 15);
            ReadReg(XT0, reg, sz);
            a.Csel(XT2, XT1, XT0, cond);
            WriteReg(reg, sz, XT2);
            return;
        }
        if (o == 0xb6 || o == 0xb7) {
            if (o == 0xb6 && n.isReg && HighByte(n, n.rm, 1)) a.W(0xD3400000u | 8u << 16 | 15u << 10 | (uint32_t)(n.rm - 4) << 5 | XT0);   // bits 8..15
            else ReadE(n, XT0, o == 0xb6 ? 1 : 2);
            WriteReg(reg, n.OpSize(), XT0);
            return;
        }
        if (o == 0xbe || o == 0xbf) {
            int from = o == 0xbe ? 8 : 16;
            if (o == 0xbe && n.isReg && HighByte(n, n.rm, 1)) a.W(0xD3400000u | 8u << 16 | 15u << 10 | (uint32_t)(n.rm - 4) << 5 | XT0);
            else ReadE(n, XT0, from / 8);
            a.Sbfx0(XT0, XT0, from);
            WriteReg(reg, n.OpSize(), XT0);
            return;
        }
        if (o == 0xaf) {
            int sz = n.OpSize();
            if (n.flagsLive) SpillFlags();
            ReadE(n, XT0, sz);
            ReadReg(XT1, reg, sz);
            IMulTo(n, reg, sz);
            return;
        }
        if (o >= 0xc8 && o <= 0xcf) {
            int r = (o & 7) | ((n.rex & 1) << 3);
            if (n.rex & 8) a.W(0xDAC00C00u | (uint32_t)r << 5 | r);
            else a.W(0x5AC00800u | (uint32_t)r << 5 | r);
            return;
        }
        if (o == 0xbc || o == 0xbd) {   // sets ZF alone; and the destination only if there is a bit to find
            int sz = n.OpSize();
            if (n.flagsLive) SpillFlags();
            ReadE(n, XT0, sz);
            if (n.flagsLive) { a.CmpZero(XT0); a.Cset(XT1, EQ); StrbCpu(XT1, offsetof(Cpu, zf)); }
            uint32_t *none = Later();
            if (o == 0xbc) { a.W(0xDAC00000u | (uint32_t)XT0 << 5 | XT2); a.W(0xDAC01000u | (uint32_t)XT2 << 5 | XT2); }
            else { a.W(0xDAC01000u | (uint32_t)XT0 << 5 | XT2); a.Movz(XT1, 63, 0); a.Sub(XT2, XT1, XT2); }
            WriteReg(reg, sz, XT2);
            BranchHere(none, 0xB4000000u | XT0);
            return;
        }
        if (o == 0xc0 || o == 0xc1) {   // xadd
            int sz = o & 1 ? n.OpSize() : 1;
            if (n.isReg) {
                ReadReg(XT0, n.rm, sz); ReadReg(XT1, reg, sz);
                a.Add(XT2, XT0, XT1);
                Record(n.flagsLive, kAdd, sz, XT0, XT1);
                WriteReg(n.rm, sz, XT2);
                WriteReg(reg, sz, XT0);
                return;
            }
            Locked(n);
            return;
        }
        if (o == 0xb0 || o == 0xb1) { Locked(n); return; }   // the interpreter makes this atomic whether LOCK says so or not
        if (o == 0xa3 || o == 0xab || o == 0xb3 || o == 0xbb || o == 0xba) {
            int sz = n.OpSize(), kind = o == 0xba ? (reg & 7) - 4 : o == 0xa3 ? 0 : o == 0xab ? 1 : o == 0xb3 ? 2 : 3;
            if (n.flagsLive) SpillFlags();
            if (!n.isReg) {   // an immediate, on the byte it falls in
                unsigned bit = (unsigned)n.imm & (unsigned)(sz * 8 - 1);
                Ea(n);
                AddDisp(bit / 8);
                a.W(0x39400000u | (uint32_t)X16 << 5 | XT0);
                a.Imm(XT1, 1u << (bit & 7));
                if (n.flagsLive) { a.TstReg(XT0, XT1); a.Cset(XT2, NE); StrbCpu(XT2, offsetof(Cpu, cf)); }
                if (kind == 1) a.Orr(XT0, XT0, XT1);
                else if (kind == 2) { a.Mvn(XT1, XT1); a.And(XT0, XT0, XT1); }
                else if (kind == 3) a.Eor(XT0, XT0, XT1);
                if (kind) a.W(0x39000000u | (uint32_t)X16 << 5 | XT0);
                return;
            }
            ReadReg(XT0, n.rm, sz);
            if (o == 0xba) a.Imm(XT1, n.imm & (uint64_t)(sz * 8 - 1));
            else { ReadReg(XT1, reg, sz); a.Imm(X17, (uint64_t)(sz * 8 - 1)); a.And(XT1, XT1, X17); }
            if (n.flagsLive) { a.Lsrv(XT2, XT0, XT1); a.W(0x92400000u | (uint32_t)XT2 << 5 | XT2); StrbCpu(XT2, offsetof(Cpu, cf)); }
            if (kind) {
                a.Movz(X17, 1, 0);
                a.Lslv(X17, X17, XT1);
                if (kind == 1) a.Orr(XT0, XT0, X17);
                else if (kind == 2) { a.Mvn(X17, X17); a.And(XT0, XT0, X17); }
                else a.Eor(XT0, XT0, X17);
                WriteReg(n.rm, sz, XT0);
            }
            return;
        }
        // hint nops
    }
};

// The flags an instruction leaves are only worth recording if something can read them. Anything leaving the run can.
void Liveness(std::vector<Ins> &run, bool deadAtEnd) {
    bool live = !deadAtEnd;
    for (size_t i = run.size(); i-- > 0;) {
        Ins &n = run[i];
        bool branch = n.op == 0x0f ? (n.op2 >= 0x80 && n.op2 <= 0x8f) : (n.op >= 0x70 && n.op <= 0x7f);
        if (n.wantsDeadFlags && live) n.translated = false;   // the interpreter has the flag rules for these
        n.flagsLive = live;
        if (branch) { live = true; continue; }
        if (!n.translated) {
            if (n.neutral) continue;
            live = true;
            continue;
        }
        if (n.usesFlags) { live = true; continue; }
        if (n.defsFlags) { live = false; continue; }
        if (n.wantsDeadFlags) continue;   // dead after, so dead before: a zero-count shift leaves them alone
    }
}

void *CompileAt(uint64_t rip, uint64_t limit, bool single, bool *anyTranslated, bool deadAtEnd = false) {
    if (gLookupCount > (3u << 20)) return NULL;
    std::vector<Ins> run;
    uint64_t ip = rip;
    while (run.size() < (single ? 1 : kMaxUnit)) {
        Ins n;
        if (!Decode(ip, limit, n)) {
            if (run.empty()) return NULL;
            break;
        }
        Classify(n);
        if (n.ends && !n.translated && n.op == 0xff) {}   // an odd form of indirect branch: the interpreter does it and it leaves
        run.push_back(n);
        ip = n.next;
        if (n.ends) break;
    }
    Liveness(run, deadAtEnd);
    if (anyTranslated) *anyTranslated = run[0].translated;

    size_t room = run.size() * 192 + 64;
    if ((size_t)(gCache + kCacheSize - gCursor) < room * 4) return NULL;

    Writable w;
    uint8_t *start = (uint8_t *)(((uintptr_t)gCursor + 7) & ~(uintptr_t)7);
    *(uint64_t *)start = rip;
    uint8_t *code = start + 8;
    Emit e;
    e.a.at = (uint32_t *)code;
    bool ended = false;
    for (const Ins &n : run) {
        e.One(n);
        if (n.ends) ended = true;
    }
    if (!ended) e.Link(run.back().next);
    for (const Stub &s : e.stubs) {
        // The branch out, patched to go straight to the target once that has code.
        uint32_t *stub = e.a.at;
        int64_t d = stub - s.site;
        *s.site = 0x14000000u | ((uint32_t)d & 0x03ffffff);
        e.a.Imm(X16, s.target);
        e.a.Imm(X17, (uint64_t)s.site);
        e.a.B(gChainThunk);
    }
    gCursor = (uint8_t *)e.a.at;
    sys_icache_invalidate(code, gCursor - code);
    return code;
}

bool InText(uint64_t rip, uint64_t *limit) {
    for (auto &range : gText) if (rip >= range.first && rip < range.second) { *limit = range.second; return true; }
    return false;
}

void Flush() {
    {
        Writable w;
        for (auto &link : gLinks) { *link.first = link.second; sys_icache_invalidate(link.first, 4); }
    }
    gLinks.clear();
    for (size_t i = 0; i < 1u << kFastBits; i++) gFast[i].store(gMissThunk, std::memory_order_relaxed);
    memset((void *)gLookup, 0, sizeof(Entry) << kLookupBits);
    gLookupCount = 0;
}

} // namespace

bool JitAvailable() {
    static bool ok = Setup();
    return ok;
}

void *JitLookup(uint64_t rip) {
    uint32_t mask = (1u << kLookupBits) - 1;
    for (uint32_t i = LookupHash(rip);; i = (i + 1) & mask) {
        uint64_t found = gLookup[i].rip.load(std::memory_order_acquire);
        if (found == rip) return gLookup[i].code.load(std::memory_order_acquire);
        if (!found) break;
    }
    std::lock_guard<std::mutex> lock(gLock);
    uint64_t limit;
    if (!InText(rip, &limit)) { tColdPage = rip >> 12; return NULL; }
    uint32_t i = LookupHash(rip);
    for (;; i = (i + 1) & mask) {
        uint64_t found = gLookup[i].rip.load(std::memory_order_acquire);
        if (found == rip) return gLookup[i].code.load(std::memory_order_acquire);
        if (!found) break;
    }
    void *code = CompileAt(rip, limit, false, NULL);
    if (!code) return NULL;
    gLookupCount++;
    gLookup[i].code.store(code, std::memory_order_release);
    gLookup[i].rip.store(rip, std::memory_order_release);
    return code;
}

static void JitEnterCode(Cpu &c, void *code) {
    typedef void (*Enter)(Cpu *, void *);
    ((Enter)ptrauth_sign_unauthenticated(gEnter, ptrauth_key_function_pointer, 0))(&c, code);
}

void JitRun(Cpu &c) {
    // Code that is not from a file stays interpreted, and asking about every instruction of it would take the lock each time.
    if ((c.rip >> 12) == tColdPage) { StepInstruction(c); return; }
    void *code = JitLookup(c.rip);
    if (code) {
        gFast[FastHash(c.rip)].store(code, std::memory_order_release);
        JitEnterCode(c, code);
        return;
    }
    StepInstruction(c);   // not translatable, or out of room for code
}

void JitAddText(uint64_t start, uint64_t length) {
    if (!JitAvailable()) return;
    std::lock_guard<std::mutex> lock(gLock);
    gText.push_back({ start, start + length });
}

void JitNoteUnmap(uint64_t start, uint64_t length) {
    if (!gCache) return;
    std::lock_guard<std::mutex> lock(gLock);
    bool hit = false;
    for (size_t i = 0; i < gText.size();) {
        if (start < gText[i].second && start + length > gText[i].first) { gText.erase(gText.begin() + (long)i); hit = true; }
        else i++;
    }
    if (hit) Flush();
}

bool JitFixFault(void *ucontext, Cpu *guest) {
    if (!gCache) return false;
    ucontext_t *uc = (ucontext_t *)ucontext;
    uint64_t pc = (uint64_t)ptrauth_strip((void *)__darwin_arm_thread_state64_get_pc(uc->uc_mcontext->__ss), ptrauth_key_function_pointer);
    if (pc < (uint64_t)gCache || pc >= (uint64_t)gCache + kCacheSize) return false;
    uint64_t address = uc->uc_mcontext->__ss.__x[16];
    if ((address >> 13) == (kCommpageBase >> 13)) {
        uc->uc_mcontext->__ss.__x[16] = (uint64_t)gCommpage + (address - kCommpageBase);
        gFaultFixes++;
        return true;
    }
    if (guest) {
        for (int i = 0; i < 16; i++) guest->r[i] = uc->uc_mcontext->__ss.__x[i];
    }
    return false;
}

void JitDumpStats() {
    if (!gStats) return;
    std::vector<std::pair<uint64_t, std::pair<int, int>>> rows;
    uint64_t total = 0;
    for (int page = 0; page < 2; page++) for (int i = 0; i < 256; i++) {
        uint64_t v = gFallbacks[page][i].load();
        if (v) { rows.push_back({ v, { page, i } }); total += v; }
    }
    std::sort(rows.begin(), rows.end(), [](const auto &a, const auto &b) { return a.first > b.first; });
    fprintf(stderr, "lioness jit: %zu KB of code, %llu instructions fell back, %llu commpage faults\n", (size_t)(gCursor - gCache) / 1024, total, gFaultFixes.load());
    for (size_t i = 0; i < rows.size() && i < 40; i++)
        fprintf(stderr, "  %12llu  %s%02x\n", rows[i].first, rows[i].second.first ? "0f " : "", rows[i].second.second);
}

} // namespace Lioness

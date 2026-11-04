// What the interpreter's three files share: memory access, operand decoding, flag helpers.

#ifndef LIONESS_DECODE_H
#define LIONESS_DECODE_H

#include "Lioness/Cpu.h"

namespace Lioness {

inline uint64_t SizeMask(int sz) { return sz == 8 ? ~0ull : (1ull << (sz * 8)) - 1; }
inline uint64_t SignBit(int sz) { return 1ull << (sz * 8 - 1); }
inline int64_t SignExtend(uint64_t v, int sz) {
    switch (sz) { case 1: return (int8_t)v; case 2: return (int16_t)v; case 4: return (int32_t)v; default: return (int64_t)v; }
}

// Aligned accesses carry TSO's ordering; a misaligned one (legal on x86) is copied bytewise.
inline uint64_t MemRead(uint64_t address, int sz) {
    uint8_t *p = Xlat(address);
    if (__builtin_expect((address & (sz - 1)) == 0, 1)) {
        switch (sz) {
            case 1: return __atomic_load_n(p, __ATOMIC_ACQUIRE);
            case 2: return __atomic_load_n((uint16_t *)p, __ATOMIC_ACQUIRE);
            case 4: return __atomic_load_n((uint32_t *)p, __ATOMIC_ACQUIRE);
            default: return __atomic_load_n((uint64_t *)p, __ATOMIC_ACQUIRE);
        }
    }
    uint64_t v = 0;
    memcpy(&v, p, sz);
    return v;
}

inline void MemWrite(uint64_t address, int sz, uint64_t v) {
    uint8_t *p = Xlat(address);
    if (__builtin_expect((address & (sz - 1)) == 0, 1)) {
        switch (sz) {
            case 1: __atomic_store_n(p, (uint8_t)v, __ATOMIC_RELEASE); return;
            case 2: __atomic_store_n((uint16_t *)p, (uint16_t)v, __ATOMIC_RELEASE); return;
            case 4: __atomic_store_n((uint32_t *)p, (uint32_t)v, __ATOMIC_RELEASE); return;
            default: __atomic_store_n((uint64_t *)p, v, __ATOMIC_RELEASE); return;
        }
    }
    memcpy(p, &v, sz);
}

inline void SetZSP(Cpu &c, uint64_t r, int sz) {
    r &= SizeMask(sz);
    c.zf = r == 0;
    c.sf = (r & SignBit(sz)) != 0;
    c.pfByte = (uint8_t)r;
}

struct Decoder {
    Cpu &c;
    uint64_t ip = 0;
    uint8_t rex = 0;
    bool hasRex = false, opsize16 = false, rep = false, repne = false, lock = false, addr32 = false;
    int seg = 0;   // 1 fs, 2 gs

    int mod = 0, reg = 0, rm = 0;
    bool isReg = false, ripRelative = false;
    uint64_t rawEA = 0;

    explicit Decoder(Cpu &cpu) : c(cpu) {}

    uint8_t Fetch8() { uint8_t v = *(uint8_t *)ip; ip += 1; return v; }
    uint16_t Fetch16() { uint16_t v; memcpy(&v, (void *)ip, 2); ip += 2; return v; }
    uint32_t Fetch32() { uint32_t v; memcpy(&v, (void *)ip, 4); ip += 4; return v; }
    uint64_t Fetch64() { uint64_t v; memcpy(&v, (void *)ip, 8); ip += 8; return v; }

    int OpSize() const { return (rex & 8) ? 8 : opsize16 ? 2 : 4; }

    // An immediate of an operand size: at most 32 bits, sign-extended for a 64-bit operand.
    uint64_t FetchImm(int sz) {
        switch (sz) {
            case 1: return Fetch8();
            case 2: return Fetch16();
            case 4: return Fetch32();
            default: return (uint64_t)(int64_t)(int32_t)Fetch32();
        }
    }

    uint64_t SegBase() const { return seg == 1 ? c.fsBase : seg == 2 ? c.gsBase : 0; }

    // A RIP-relative operand counts from the end of the instruction, which includes any immediate that
    // follows the displacement. Callers that fetch an immediate after a memory operand do it through
    // EAWithTrailing or fetch it after the access; every use in the interpreter fetches first.
    uint64_t EA() const {
        uint64_t ea = rawEA + (ripRelative ? ip : 0);
        if (addr32) ea = (uint32_t)ea;   // 0x67: the address is computed in 32 bits
        return ea + SegBase();
    }

    uint64_t GetReg(int index, int sz) const {
        if (sz == 1 && !hasRex && index >= 4 && index < 8) return (c.r[index - 4] >> 8) & 0xff;
        return c.r[index] & SizeMask(sz);
    }
    void SetReg(int index, int sz, uint64_t v) {
        switch (sz) {
            case 1:
                if (!hasRex && index >= 4 && index < 8) c.r[index - 4] = (c.r[index - 4] & ~0xff00ull) | ((v & 0xff) << 8);
                else c.r[index] = (c.r[index] & ~0xffull) | (v & 0xff);
                break;
            case 2: c.r[index] = (c.r[index] & ~0xffffull) | (v & 0xffff); break;
            case 4: c.r[index] = (uint32_t)v; break;
            default: c.r[index] = v; break;
        }
    }
    uint64_t GetE(int sz) { return isReg ? GetReg(rm, sz) : MemRead(EA(), sz); }
    void SetE(int sz, uint64_t v) { if (isReg) SetReg(rm, sz, v); else MemWrite(EA(), sz, v); }

    // C6/C7: the immediate has to be fetched before a RIP-relative address is computed.
    void SetEImm(int sz) {
        uint64_t i = FetchImm(sz);
        SetE(sz, i);
    }
};

void DecodeModRM(Decoder &d);
uint64_t Alu(Cpu &c, int op, uint64_t a, uint64_t b, int sz);
uint64_t IMul(Cpu &c, uint64_t a, uint64_t b, int sz);
uint64_t Shift(Cpu &c, int op, uint64_t a, unsigned count, int sz);
bool Condition(const Cpu &c, int cc);
uint64_t ReadFlags(const Cpu &c);
void WriteFlags(Cpu &c, uint64_t f);

void SseOp(Decoder &d, uint8_t op);        // InterpreterSSE.cpp: 0F xx that are not integer
void X87Op(Decoder &d, uint8_t op);        // InterpreterX87.cpp: D8..DF
void FxSave(Cpu &c, uint64_t address);
void FxRestore(Cpu &c, uint64_t address);

} // namespace Lioness

#endif

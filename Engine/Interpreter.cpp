// x86-64 interpreter: integer instructions here, SSE and x87 in InterpreterSSE.cpp and InterpreterX87.cpp.
// Ordering: x86 guarantees TSO and arm64 does not. Aligned accesses use acquire loads and release
// stores, which gives TSO's guarantees. LOCK-prefixed read-modify-writes are real compare-and-swap loops.

#include "Decode.h"
#include "Jit.h"
#include <sched.h>
#include "Runtime.h"
#include <stdio.h>
#include <stdlib.h>

namespace Lioness {

static volatile int gMisalignedLock;
static inline void MisalignedLock() { while (__atomic_exchange_n(&gMisalignedLock, 1, __ATOMIC_ACQUIRE)) sched_yield(); }
static inline void MisalignedUnlock() { __atomic_store_n(&gMisalignedLock, 0, __ATOMIC_RELEASE); }

uint8_t gCommpage[kCommpageSize];

uint64_t Alu(Cpu &c, int op, uint64_t a, uint64_t b, int sz) {
    const uint64_t mask = SizeMask(sz), sign = SignBit(sz);
    a &= mask; b &= mask;
    uint64_t r;
    switch (op) {
        case 0: case 2: {   // add adc
            uint64_t in = op == 2 && c.cf;
            unsigned __int128 wide = (unsigned __int128)a + b + in;
            r = (uint64_t)wide & mask;
            c.cf = wide > mask;
            c.of = ((a ^ r) & (b ^ r) & sign) != 0;
            c.afByte = (uint8_t)(a ^ b ^ r);
            break;
        }
        case 3: case 5: case 7: {   // sbb sub cmp
            uint64_t in = op == 3 && c.cf;
            r = (a - b - in) & mask;
            c.cf = (unsigned __int128)a < (unsigned __int128)b + in;
            c.of = ((a ^ b) & (a ^ r) & sign) != 0;
            c.afByte = (uint8_t)(a ^ b ^ r);
            break;
        }
        case 1: r = a | b; c.cf = c.of = false; c.afByte = 0; break;
        case 4: r = a & b; c.cf = c.of = false; c.afByte = 0; break;
        default: r = (a ^ b) & mask; c.cf = c.of = false; c.afByte = 0; break;
    }
    SetZSP(c, r, sz);
    return r;
}

bool Condition(const Cpu &c, int cc) {
    bool v;
    switch (cc >> 1) {
        case 0: v = c.of; break;
        case 1: v = c.cf; break;
        case 2: v = c.zf; break;
        case 3: v = c.cf || c.zf; break;
        case 4: v = c.sf; break;
        case 5: v = !__builtin_parity(c.pfByte); break;
        case 6: v = c.sf != c.of; break;
        default: v = c.zf || c.sf != c.of; break;
    }
    return (cc & 1) ? !v : v;
}

uint64_t ReadFlags(const Cpu &c) {
    return (uint64_t)c.cf | 2 | ((uint64_t)!__builtin_parity(c.pfByte) << 2) | ((uint64_t)((c.afByte >> 4) & 1) << 4) |
           ((uint64_t)c.zf << 6) | ((uint64_t)c.sf << 7) | (1ull << 9) | ((uint64_t)c.df << 10) | ((uint64_t)c.of << 11);
}

void WriteFlags(Cpu &c, uint64_t f) {
    c.cf = f & 1; c.pfByte = (f & 4) ? 0 : 1; c.afByte = (f & 0x10) ? 0x10 : 0;
    c.zf = f & 0x40; c.sf = f & 0x80; c.df = f & 0x400; c.of = f & 0x800;
}

uint64_t Shift(Cpu &c, int op, uint64_t a, unsigned count, int sz) {
    const int bits = sz * 8;
    const uint64_t mask = SizeMask(sz), sign = SignBit(sz);
    a &= mask;
    count &= sz == 8 ? 63 : 31;
    if (!count) return a;
    uint64_t r = a;
    switch (op) {
        case 0: {   // rol
            unsigned n = count % bits;
            r = n ? ((a << n) | (a >> (bits - n))) & mask : a;
            c.cf = r & 1;
            c.of = ((r >> (bits - 1)) & 1) ^ c.cf;
            return r;
        }
        case 1: {   // ror
            unsigned n = count % bits;
            r = n ? ((a >> n) | (a << (bits - n))) & mask : a;
            c.cf = (r >> (bits - 1)) & 1;
            c.of = ((r >> (bits - 1)) ^ (r >> (bits - 2))) & 1;
            return r;
        }
        case 2: {   // rcl
            unsigned n = count % (bits + 1);
            for (unsigned i = 0; i < n; i++) {
                bool top = (r & sign) != 0;
                r = ((r << 1) | (uint64_t)c.cf) & mask;
                c.cf = top;
            }
            c.of = (((r >> (bits - 1)) & 1) != 0) != c.cf;
            return r;
        }
        case 3: {   // rcr
            unsigned n = count % (bits + 1);
            c.of = (((r >> (bits - 1)) & 1) != 0) != c.cf;
            for (unsigned i = 0; i < n; i++) {
                bool low = r & 1;
                r = (r >> 1) | ((uint64_t)c.cf << (bits - 1));
                c.cf = low;
            }
            return r;
        }
        case 4: case 6:   // shl
            c.cf = count <= (unsigned)bits ? (a >> (bits - count)) & 1 : 0;
            r = count < (unsigned)bits ? (a << count) & mask : 0;
            c.of = ((r >> (bits - 1)) & 1) != (uint64_t)c.cf;
            break;
        case 5:   // shr
            c.cf = count <= (unsigned)bits ? (a >> (count - 1)) & 1 : 0;
            r = count < (unsigned)bits ? a >> count : 0;
            c.of = (a & sign) != 0;
            break;
        default: {   // sar
            int64_t s = SignExtend(a, sz);
            c.cf = (s >> (count >= (unsigned)bits ? bits - 1 : count - 1)) & 1;
            r = (uint64_t)(s >> (count >= (unsigned)bits ? bits - 1 : count)) & mask;
            c.of = false;
            break;
        }
    }
    c.afByte = 0;
    SetZSP(c, r, sz);
    return r;
}

void DecodeModRM(Decoder &d) {
    Cpu &c = d.c;
    uint8_t m = d.Fetch8();
    d.mod = m >> 6;
    d.reg = ((m >> 3) & 7) | ((d.rex & 4) << 1);
    int rm = m & 7;
    if (d.mod == 3) { d.rm = rm | ((d.rex & 1) << 3); d.isReg = true; return; }
    d.isReg = false;
    uint64_t ea;
    if (rm == 4) {
        uint8_t sib = d.Fetch8();
        int scale = sib >> 6, index = ((sib >> 3) & 7) | ((d.rex & 2) << 2), base = (sib & 7) | ((d.rex & 1) << 3);
        ea = index == 4 ? 0 : c.r[index] << scale;
        if ((sib & 7) == 5 && d.mod == 0) ea += (int64_t)(int32_t)d.Fetch32();
        else ea += c.r[base];
    } else if (rm == 5 && d.mod == 0) {
        d.ripRelative = true;
        ea = (int64_t)(int32_t)d.Fetch32();   // the end of the instruction is added in EA()
    } else {
        ea = c.r[rm | ((d.rex & 1) << 3)];
    }
    if (d.mod == 1) ea += (int64_t)(int8_t)d.Fetch8();
    else if (d.mod == 2) ea += (int64_t)(int32_t)d.Fetch32();
    d.rawEA = ea;
}

// LOCK: a real CAS loop around one read-modify-write.
template <typename F>
static inline uint64_t ModifyE(Decoder &d, int sz, F &&f) {
    if (d.isReg) {
        uint64_t r = f(d.GetReg(d.rm, sz));
        d.SetReg(d.rm, sz, r);
        return r;
    }
    uint64_t address = d.EA();
    if (!d.lock) {
        uint64_t r = f(MemRead(address, sz));
        MemWrite(address, sz, r);
        return r;
    }
    uint8_t *p = Xlat(address);
    if (__builtin_expect((address & (sz - 1)) != 0, 0)) {   // legal on x86, a fault on arm64: atomic only against other misaligned ones
        MisalignedLock();
        uint64_t r = f(MemRead(address, sz));
        MemWrite(address, sz, r);
        MisalignedUnlock();
        return r;
    }
    switch (sz) {
        case 1: { uint8_t o = __atomic_load_n(p, __ATOMIC_ACQUIRE), n;
            do { n = (uint8_t)f(o); } while (!__atomic_compare_exchange_n(p, &o, n, false, __ATOMIC_SEQ_CST, __ATOMIC_ACQUIRE)); return n; }
        case 2: { uint16_t *q = (uint16_t *)p; uint16_t o = __atomic_load_n(q, __ATOMIC_ACQUIRE), n;
            do { n = (uint16_t)f(o); } while (!__atomic_compare_exchange_n(q, &o, n, false, __ATOMIC_SEQ_CST, __ATOMIC_ACQUIRE)); return n; }
        case 4: { uint32_t *q = (uint32_t *)p; uint32_t o = __atomic_load_n(q, __ATOMIC_ACQUIRE), n;
            do { n = (uint32_t)f(o); } while (!__atomic_compare_exchange_n(q, &o, n, false, __ATOMIC_SEQ_CST, __ATOMIC_ACQUIRE)); return n; }
        default: { uint64_t *q = (uint64_t *)p; uint64_t o = __atomic_load_n(q, __ATOMIC_ACQUIRE), n;
            do { n = f(o); } while (!__atomic_compare_exchange_n(q, &o, n, false, __ATOMIC_SEQ_CST, __ATOMIC_ACQUIRE)); return n; }
    }
}

static void StringOp(Decoder &d, uint8_t op) {
    Cpu &c = d.c;
    int sz = (op & 1) ? d.OpSize() : 1;
    int64_t step = c.df ? -(int64_t)sz : (int64_t)sz;
    bool rep = d.rep || d.repne;
    uint64_t base = d.SegBase();
    int kind = op & 0xfe;
    while (!rep || c.r[RCX]) {
        switch (kind) {
            case 0xa4: MemWrite(c.r[RDI], sz, MemRead(base + c.r[RSI], sz)); c.r[RSI] += step; c.r[RDI] += step; break;
            case 0xa6: Alu(c, 7, MemRead(base + c.r[RSI], sz), MemRead(c.r[RDI], sz), sz); c.r[RSI] += step; c.r[RDI] += step; break;
            case 0xaa: MemWrite(c.r[RDI], sz, c.r[RAX]); c.r[RDI] += step; break;
            case 0xac: d.SetReg(RAX, sz, MemRead(base + c.r[RSI], sz)); c.r[RSI] += step; break;
            default:   Alu(c, 7, c.r[RAX], MemRead(c.r[RDI], sz), sz); c.r[RDI] += step; break;   // scas
        }
        if (!rep) break;
        c.r[RCX]--;
        if (kind == 0xa6 || kind == 0xae) {
            if (d.rep && !c.zf) break;
            if (d.repne && c.zf) break;
        }
    }
}

static void Group3(Decoder &d, int sz) {
    Cpu &c = d.c;
    const uint64_t mask = SizeMask(sz);
    switch (d.reg & 7) {
        case 0: case 1: { uint64_t i = d.FetchImm(sz); Alu(c, 4, d.GetE(sz), i, sz); return; }
        case 2: ModifyE(d, sz, [&](uint64_t v) { return ~v & mask; }); return;
        case 3: { uint64_t cf = 0;
            ModifyE(d, sz, [&](uint64_t v) { cf = (v & mask) != 0; return Alu(c, 5, 0, v, sz); });
            c.cf = cf; return; }
        case 4: case 5: {   // mul imul
            uint64_t a = c.r[RAX] & mask, b = d.GetE(sz) & mask;
            bool signedOp = (d.reg & 7) == 5;
            uint64_t lo, hi;
            if (sz == 8) {
                unsigned __int128 w = signedOp ? (unsigned __int128)((__int128)(int64_t)a * (int64_t)b) : (unsigned __int128)a * b;
                lo = (uint64_t)w; hi = (uint64_t)(w >> 64);
            } else {
                uint64_t w = signedOp ? (uint64_t)(SignExtend(a, sz) * SignExtend(b, sz)) : a * b;
                lo = w & mask; hi = (w >> (sz * 8)) & mask;
            }
            if (sz == 1) d.SetReg(RAX, 2, (hi << 8) | lo);
            else { d.SetReg(RAX, sz, lo); d.SetReg(RDX, sz, hi); }
            c.cf = c.of = signedOp ? (hi != ((SignExtend(lo, sz) < 0) ? mask : 0)) : hi != 0;
            return;
        }
        default: {   // div idiv
            uint64_t b = d.GetE(sz) & mask;
            if (!b) GuestPanic(c, "divide by zero");
            bool signedOp = (d.reg & 7) == 7;
            if (sz == 8) {
                unsigned __int128 n = ((unsigned __int128)c.r[RDX] << 64) | c.r[RAX];
                if (signedOp) {
                    __int128 q = (__int128)n / (int64_t)b, r = (__int128)n % (int64_t)b;
                    c.r[RAX] = (uint64_t)q; c.r[RDX] = (uint64_t)r;
                } else { c.r[RAX] = (uint64_t)(n / b); c.r[RDX] = (uint64_t)(n % b); }
            } else {
                uint64_t n = sz == 1 ? c.r[RAX] & 0xffff : ((c.r[RDX] & mask) << (sz * 8)) | (c.r[RAX] & mask);
                uint64_t q, r;
                if (signedOp) {
                    int64_t sn = sz == 1 ? (int16_t)n : (sz == 2 ? (int32_t)n : (int64_t)n);
                    q = (uint64_t)(sn / SignExtend(b, sz)); r = (uint64_t)(sn % SignExtend(b, sz));
                } else { q = n / b; r = n % b; }
                if (sz == 1) d.SetReg(RAX, 2, ((r & 0xff) << 8) | (q & 0xff));
                else { d.SetReg(RAX, sz, q); d.SetReg(RDX, sz, r); }
            }
            return;
        }
    }
}

static void BitOp(Decoder &d, int kind, uint64_t offset, int sz, bool immediate) {
    Cpu &c = d.c;
    int bits = sz * 8;
    if (d.isReg) {
        unsigned bit = offset & (bits - 1);
        uint64_t v = d.GetReg(d.rm, sz);
        c.cf = (v >> bit) & 1;
        if (kind == 1) d.SetReg(d.rm, sz, v | (1ull << bit));
        else if (kind == 2) d.SetReg(d.rm, sz, v & ~(1ull << bit));
        else if (kind == 3) d.SetReg(d.rm, sz, v ^ (1ull << bit));
        return;
    }
    // A register offset addresses beyond the operand; an immediate one wraps.
    int64_t off = immediate ? (int64_t)(offset & (bits - 1)) : SignExtend(offset, sz);
    uint64_t address = d.EA() + ((off >> 3) & ~(int64_t)(sz - 1));
    unsigned bit = (uint64_t)off & (bits - 1);
    uint8_t *p = Xlat(address + bit / 8);
    uint8_t m = 1u << (bit & 7);
    if (d.lock) {
        uint8_t old = kind == 1 ? __atomic_fetch_or(p, m, __ATOMIC_SEQ_CST)
                    : kind == 2 ? __atomic_fetch_and(p, (uint8_t)~m, __ATOMIC_SEQ_CST)
                    : kind == 3 ? __atomic_fetch_xor(p, m, __ATOMIC_SEQ_CST) : __atomic_load_n(p, __ATOMIC_ACQUIRE);
        c.cf = old & m;
        return;
    }
    c.cf = *p & m;
    if (kind == 1) *p |= m; else if (kind == 2) *p &= (uint8_t)~m; else if (kind == 3) *p ^= m;
}

static void TwoByte(Decoder &d) {
    Cpu &c = d.c;
    uint8_t op = d.Fetch8();
    switch (op) {
        case 0x05: {   // syscall
            uint64_t next = d.ip;
            c.rip = next;
            c.r[RCX] = next;
            c.r[R11] = ReadFlags(c);
            Syscall(c);
            d.ip = c.rip;
            return;
        }
        case 0x0b: {   // ud2: a function replaced by a host call carries its id in the next four bytes
            uint32_t id = d.Fetch32();
            c.rip = d.ip;
            HostCall(c, id);
            d.ip = c.rip;
            return;
        }
        case 0x0d: case 0x18: case 0x19: case 0x1a: case 0x1b: case 0x1c: case 0x1d: case 0x1e: case 0x1f:
            DecodeModRM(d);   // prefetch, hint nop
            return;
        case 0x31: {   // rdtsc
            uint64_t t = GuestTicks();
            c.r[RAX] = (uint32_t)t; c.r[RDX] = t >> 32;
            return;
        }
        case 0x01: {
            uint8_t m = *(uint8_t *)d.ip;
            if (m == 0xd0) { d.ip++; c.r[RAX] = 3; c.r[RDX] = 0; return; }   // xgetbv
            if (m == 0xf9) { d.ip++; uint64_t t = GuestTicks(); c.r[RAX] = (uint32_t)t; c.r[RDX] = t >> 32; c.r[RCX] = 0; return; }   // rdtscp
            DecodeModRM(d);
            if (!d.isReg && (d.reg & 7) == 1) {   // sidt: Darwin encodes the CPU number in the limit, and Lion's malloc reads it
                uint64_t a = d.EA();
                MemWrite(a, 2, 0);
                MemWrite(a + 2, 8, 0);
                return;
            }
            GuestPanic(c, "unknown 0F 01 form");
        }
        case 0xa2: {   // cpuid: a Core 2-class CPU, SSSE3 and nothing newer, matching the commpage
            uint32_t leaf = (uint32_t)c.r[RAX];
            uint32_t a = 0, b = 0, cx = 0, dx = 0;
            if (leaf == 0) { a = 4; b = 'uneG'; dx = 'Ieni'; cx = 'letn'; }
            else if (leaf == 1) { a = 0x000006f6; b = 0x00020800; cx = (1u << 0) | (1u << 9) | (1u << 13); dx = 0x178bfbff; }
            else if (leaf == 0x80000000) { a = 0x80000008; }
            else if (leaf == 0x80000001) { dx = (1u << 29) | (1u << 20) | (1u << 11); cx = 1; }
            else if (leaf == 0x80000008) { a = 0x3030; }
            c.r[RAX] = a; c.r[RBX] = b; c.r[RCX] = cx; c.r[RDX] = dx;
            return;
        }
        case 0xa3: case 0xab: case 0xb3: case 0xbb: {
            DecodeModRM(d);
            int sz = d.OpSize();
            BitOp(d, op == 0xa3 ? 0 : op == 0xab ? 1 : op == 0xb3 ? 2 : 3, d.GetReg(d.reg, sz), sz, false);
            return;
        }
        case 0xba: {
            DecodeModRM(d);
            int sz = d.OpSize();
            uint64_t bit = d.Fetch8();
            BitOp(d, (d.reg & 7) - 4, bit, sz, true);
            return;
        }
        case 0xa4: case 0xa5: case 0xac: case 0xad: {   // shld shrd
            DecodeModRM(d);
            int sz = d.OpSize(), bits = sz * 8;
            unsigned count = op & 1 ? (unsigned)c.r[RCX] : d.Fetch8();
            count &= sz == 8 ? 63 : 31;
            if (!count) return;
            const uint64_t mask = SizeMask(sz);
            uint64_t a = d.GetE(sz) & mask, b = d.GetReg(d.reg, sz) & mask, r;
            if (op < 0xa8) { r = ((a << count) | (b >> (bits - count))) & mask; c.cf = (a >> (bits - count)) & 1; }
            else { r = ((a >> count) | (b << (bits - count))) & mask; c.cf = (a >> (count - 1)) & 1; }
            c.of = ((a ^ r) & SignBit(sz)) != 0;
            SetZSP(c, r, sz);
            d.SetE(sz, r);
            return;
        }
        case 0xae: {
            DecodeModRM(d);
            if (d.isReg) {   // lfence mfence sfence
                __atomic_thread_fence(__ATOMIC_SEQ_CST);
                return;
            }
            uint64_t a = d.EA();
            switch (d.reg & 7) {
                case 0: FxSave(c, a); return;
                case 1: FxRestore(c, a); return;
                case 2: c.mxcsr = (uint32_t)MemRead(a, 4); return;
                case 3: MemWrite(a, 4, c.mxcsr); return;
                default: return;   // clflush
            }
        }
        case 0xaf: {
            DecodeModRM(d);
            int sz = d.OpSize();
            d.SetReg(d.reg, sz, IMul(c, d.GetReg(d.reg, sz), d.GetE(sz), sz));
            return;
        }
        case 0xb0: case 0xb1: {   // cmpxchg
            DecodeModRM(d);
            int sz = op == 0xb0 ? 1 : d.OpSize();
            const uint64_t mask = SizeMask(sz);
            uint64_t expected = c.r[RAX] & mask, desired = d.GetReg(d.reg, sz) & mask, old;
            if (d.isReg) {
                old = d.GetReg(d.rm, sz) & mask;
                if (old == expected) d.SetReg(d.rm, sz, desired);
            } else {
                uint64_t ea = d.EA();
                uint8_t *p = Xlat(ea);
                old = expected;
                if (__builtin_expect((ea & (sz - 1)) != 0, 0)) {
                    MisalignedLock();
                    old = MemRead(ea, sz) & mask;
                    if (old == expected) MemWrite(ea, sz, desired);
                    MisalignedUnlock();
                } else switch (sz) {
                    case 1: { uint8_t e = (uint8_t)expected; __atomic_compare_exchange_n(p, &e, (uint8_t)desired, false, __ATOMIC_SEQ_CST, __ATOMIC_ACQUIRE); old = e; break; }
                    case 2: { uint16_t e = (uint16_t)expected; __atomic_compare_exchange_n((uint16_t *)p, &e, (uint16_t)desired, false, __ATOMIC_SEQ_CST, __ATOMIC_ACQUIRE); old = e; break; }
                    case 4: { uint32_t e = (uint32_t)expected; __atomic_compare_exchange_n((uint32_t *)p, &e, (uint32_t)desired, false, __ATOMIC_SEQ_CST, __ATOMIC_ACQUIRE); old = e; break; }
                    default: { uint64_t e = expected; __atomic_compare_exchange_n((uint64_t *)p, &e, desired, false, __ATOMIC_SEQ_CST, __ATOMIC_ACQUIRE); old = e; break; }
                }
            }
            Alu(c, 7, expected, old, sz);
            if (old != expected) d.SetReg(RAX, sz, old);
            return;
        }
        case 0xb6: case 0xb7: {
            DecodeModRM(d);
            d.SetReg(d.reg, d.OpSize(), d.GetE(op == 0xb6 ? 1 : 2));
            return;
        }
        case 0xbe: case 0xbf: {
            DecodeModRM(d);
            int from = op == 0xbe ? 1 : 2;
            d.SetReg(d.reg, d.OpSize(), (uint64_t)SignExtend(d.GetE(from), from));
            return;
        }
        case 0xbc: case 0xbd: {   // bsf bsr
            DecodeModRM(d);
            int sz = d.OpSize();
            uint64_t v = d.GetE(sz) & SizeMask(sz);
            c.zf = v == 0;
            if (v) d.SetReg(d.reg, sz, op == 0xbc ? __builtin_ctzll(v) : 63 - __builtin_clzll(v));
            return;
        }
        case 0xc0: case 0xc1: {   // xadd
            DecodeModRM(d);
            int sz = op == 0xc0 ? 1 : d.OpSize();
            uint64_t src = d.GetReg(d.reg, sz), old = 0;
            ModifyE(d, sz, [&](uint64_t v) { old = v; return Alu(c, 0, v, src, sz); });
            d.SetReg(d.reg, sz, old);
            return;
        }
        case 0xc3: {   // movnti
            DecodeModRM(d);
            int sz = d.OpSize();
            d.SetE(sz, d.GetReg(d.reg, sz));
            return;
        }
        case 0xc7: {   // cmpxchg8b cmpxchg16b
            DecodeModRM(d);
            uint64_t a = d.EA();
            if (__builtin_expect((a & ((d.rex & 8) ? 15 : 7)) != 0, 0)) {
                MisalignedLock();
                int words = (d.rex & 8) ? 8 : 4;
                uint64_t lo = MemRead(a, words), hi = MemRead(a + words, words);
                uint64_t mask = (d.rex & 8) ? ~0ull : 0xffffffffull;
                c.zf = lo == (c.r[RAX] & mask) && hi == (c.r[RDX] & mask);
                if (c.zf) { MemWrite(a, words, c.r[RBX] & mask); MemWrite(a + words, words, c.r[RCX] & mask); }
                else { c.r[RAX] = lo; c.r[RDX] = hi; }
                MisalignedUnlock();
                return;
            }
            if (d.rex & 8) {
                unsigned __int128 expected = ((unsigned __int128)c.r[RDX] << 64) | c.r[RAX];
                unsigned __int128 desired = ((unsigned __int128)c.r[RCX] << 64) | c.r[RBX];
                c.zf = __atomic_compare_exchange_n((unsigned __int128 *)Xlat(a), &expected, desired, false, __ATOMIC_SEQ_CST, __ATOMIC_ACQUIRE);
                if (!c.zf) { c.r[RAX] = (uint64_t)expected; c.r[RDX] = (uint64_t)(expected >> 64); }
            } else {
                uint64_t expected = ((c.r[RDX] & 0xffffffff) << 32) | (uint32_t)c.r[RAX];
                uint64_t desired = ((c.r[RCX] & 0xffffffff) << 32) | (uint32_t)c.r[RBX];
                c.zf = __atomic_compare_exchange_n((uint64_t *)Xlat(a), &expected, desired, false, __ATOMIC_SEQ_CST, __ATOMIC_ACQUIRE);
                if (!c.zf) { c.r[RAX] = (uint32_t)expected; c.r[RDX] = expected >> 32; }
            }
            return;
        }
        default: break;
    }
    if (op >= 0x40 && op <= 0x4f) {   // cmov
        DecodeModRM(d);
        int sz = d.OpSize();
        uint64_t v = d.GetE(sz);
        if (Condition(c, op & 15)) d.SetReg(d.reg, sz, v);
        else if (sz == 4) d.SetReg(d.reg, 4, d.GetReg(d.reg, 4));   // a 32-bit cmov always clears the top half
        return;
    }
    if (op >= 0x80 && op <= 0x8f) {
        int64_t rel = (int64_t)(int32_t)d.Fetch32();
        if (Condition(c, op & 15)) d.ip += rel;
        return;
    }
    if (op >= 0x90 && op <= 0x9f) { DecodeModRM(d); d.SetE(1, Condition(c, op & 15)); return; }
    if (op >= 0xc8 && op <= 0xcf) {
        int reg = (op & 7) | ((d.rex & 1) << 3);
        if (d.rex & 8) c.r[reg] = __builtin_bswap64(c.r[reg]);
        else c.r[reg] = __builtin_bswap32((uint32_t)c.r[reg]);
        return;
    }
    SseOp(d, op);
}

uint64_t IMul(Cpu &c, uint64_t a, uint64_t b, int sz) {
    uint64_t r; bool over;
    if (sz == 8) {
        __int128 w = (__int128)(int64_t)a * (int64_t)b;
        r = (uint64_t)w; over = w != (__int128)(int64_t)r;
    } else {
        int64_t w = SignExtend(a, sz) * SignExtend(b, sz);
        r = (uint64_t)w & SizeMask(sz); over = w != SignExtend(r, sz);
    }
    c.cf = c.of = over;
    return r;
}

static inline void Push(Cpu &c, uint64_t v) { c.r[RSP] -= 8; MemWrite(c.r[RSP], 8, v); }
static inline uint64_t Pop(Cpu &c) { uint64_t v = MemRead(c.r[RSP], 8); c.r[RSP] += 8; return v; }

static inline void Step(Cpu &c) {
    Decoder d(c);
    d.ip = c.rip;
    // Prefixes
    uint8_t op;
    for (;;) {
        op = d.Fetch8();
        switch (op) {
            case 0x66: d.opsize16 = true; continue;
            case 0x67: d.addr32 = true; continue;
            case 0xf0: d.lock = true; continue;
            case 0xf2: d.repne = true; continue;
            case 0xf3: d.rep = true; continue;
            case 0x64: d.seg = 1; continue;
            case 0x65: d.seg = 2; continue;
            case 0x26: case 0x2e: case 0x36: case 0x3e: continue;
            default: break;
        }
        break;
    }
    if ((op & 0xf0) == 0x40) { d.rex = op; d.hasRex = true; op = d.Fetch8(); }

    if (op < 0x40 && (op & 7) < 6) {   // add or adc sbb and sub xor cmp
        int alu = op >> 3;
        switch (op & 7) {
            case 0: case 1: {
                DecodeModRM(d);
                int sz = op & 1 ? d.OpSize() : 1;
                uint64_t b = d.GetReg(d.reg, sz);
                if (alu == 7) Alu(c, 7, d.GetE(sz), b, sz);
                else ModifyE(d, sz, [&](uint64_t v) { return Alu(c, alu, v, b, sz); });
                break;
            }
            case 2: case 3: {
                DecodeModRM(d);
                int sz = op & 1 ? d.OpSize() : 1;
                uint64_t r = Alu(c, alu, d.GetReg(d.reg, sz), d.GetE(sz), sz);
                if (alu != 7) d.SetReg(d.reg, sz, r);
                break;
            }
            case 4: { uint64_t r = Alu(c, alu, c.r[RAX], d.Fetch8(), 1); if (alu != 7) d.SetReg(RAX, 1, r); break; }
            default: {
                int sz = d.OpSize();
                uint64_t r = Alu(c, alu, c.r[RAX], d.FetchImm(sz), sz);
                if (alu != 7) d.SetReg(RAX, sz, r);
                break;
            }
        }
        c.rip = d.ip;
        return;
    }

    switch (op) {
        case 0x50: case 0x51: case 0x52: case 0x53: case 0x54: case 0x55: case 0x56: case 0x57:
            Push(c, c.r[(op & 7) | ((d.rex & 1) << 3)]);
            break;
        case 0x58: case 0x59: case 0x5a: case 0x5b: case 0x5c: case 0x5d: case 0x5e: case 0x5f:
            c.r[(op & 7) | ((d.rex & 1) << 3)] = Pop(c);
            break;
        case 0x63: {   // movsxd
            DecodeModRM(d);
            d.SetReg(d.reg, d.OpSize(), (uint64_t)(int64_t)(int32_t)d.GetE(4));
            break;
        }
        case 0x68: Push(c, (uint64_t)(int64_t)(int32_t)d.Fetch32()); break;
        case 0x6a: Push(c, (uint64_t)(int64_t)(int8_t)d.Fetch8()); break;
        case 0x69: case 0x6b: {
            DecodeModRM(d);
            int sz = d.OpSize();
            uint64_t i = op == 0x6b ? (uint64_t)(int64_t)(int8_t)d.Fetch8() : d.FetchImm(sz);
            d.SetReg(d.reg, sz, IMul(c, d.GetE(sz), i, sz));
            break;
        }
        case 0x70: case 0x71: case 0x72: case 0x73: case 0x74: case 0x75: case 0x76: case 0x77:
        case 0x78: case 0x79: case 0x7a: case 0x7b: case 0x7c: case 0x7d: case 0x7e: case 0x7f: {
            int64_t rel = (int8_t)d.Fetch8();
            if (Condition(c, op & 15)) d.ip += rel;
            break;
        }
        case 0x80: case 0x81: case 0x83: {
            DecodeModRM(d);
            int sz = op == 0x80 ? 1 : d.OpSize();
            uint64_t i = op == 0x81 ? d.FetchImm(sz) : (uint64_t)(int64_t)(int8_t)d.Fetch8();
            int alu = d.reg & 7;
            if (alu == 7) Alu(c, 7, d.GetE(sz), i, sz);
            else ModifyE(d, sz, [&](uint64_t v) { return Alu(c, alu, v, i, sz); });
            break;
        }
        case 0x84: case 0x85: {
            DecodeModRM(d);
            int sz = op & 1 ? d.OpSize() : 1;
            Alu(c, 4, d.GetE(sz), d.GetReg(d.reg, sz), sz);
            break;
        }
        case 0x86: case 0x87: {   // xchg, always locked on memory
            DecodeModRM(d);
            int sz = op & 1 ? d.OpSize() : 1;
            uint64_t r = d.GetReg(d.reg, sz), old = 0;
            d.lock = true;
            ModifyE(d, sz, [&](uint64_t v) { old = v; return r; });
            d.SetReg(d.reg, sz, old);
            break;
        }
        case 0x88: case 0x89: {
            DecodeModRM(d);
            int sz = op & 1 ? d.OpSize() : 1;
            d.SetE(sz, d.GetReg(d.reg, sz));
            break;
        }
        case 0x8a: case 0x8b: {
            DecodeModRM(d);
            int sz = op & 1 ? d.OpSize() : 1;
            d.SetReg(d.reg, sz, d.GetE(sz));
            break;
        }
        case 0x8d: {   // lea: no segment base
            DecodeModRM(d);
            d.seg = 0;
            d.SetReg(d.reg, d.OpSize(), d.EA());
            break;
        }
        case 0x8f: {
            DecodeModRM(d);
            uint64_t v = Pop(c);
            d.SetE(8, v);
            break;
        }
        case 0x90:
            if (d.rex & 1) { uint64_t t = c.r[RAX]; c.r[RAX] = c.r[R8]; c.r[R8] = t; }
            break;
        case 0x91: case 0x92: case 0x93: case 0x94: case 0x95: case 0x96: case 0x97: {
            int sz = d.OpSize(), reg = (op & 7) | ((d.rex & 1) << 3);
            uint64_t a = d.GetReg(RAX, sz), b = d.GetReg(reg, sz);
            d.SetReg(RAX, sz, b); d.SetReg(reg, sz, a);
            break;
        }
        case 0x98: {
            int sz = d.OpSize();
            d.SetReg(RAX, sz, (uint64_t)SignExtend(c.r[RAX], sz / 2));
            break;
        }
        case 0x99: {
            int sz = d.OpSize();
            d.SetReg(RDX, sz, SignExtend(c.r[RAX], sz) < 0 ? ~0ull : 0);
            break;
        }
        case 0x9b: break;   // fwait
        case 0x9c: Push(c, ReadFlags(c)); break;
        case 0x9d: WriteFlags(c, Pop(c)); break;
        case 0x9e: {
            uint64_t ah = (c.r[RAX] >> 8) & 0xff;
            c.cf = ah & 1; c.pfByte = (ah & 4) ? 0 : 1; c.afByte = ah & 0x10; c.zf = ah & 0x40; c.sf = ah & 0x80;
            break;
        }
        case 0x9f: c.r[RAX] = (c.r[RAX] & ~0xff00ull) | ((ReadFlags(c) & 0xff) << 8); break;
        case 0xa4: case 0xa5: case 0xa6: case 0xa7: case 0xaa: case 0xab: case 0xac: case 0xad: case 0xae: case 0xaf:
            StringOp(d, op);
            break;
        case 0xa8: Alu(c, 4, c.r[RAX], d.Fetch8(), 1); break;
        case 0xa9: { int sz = d.OpSize(); Alu(c, 4, c.r[RAX], d.FetchImm(sz), sz); break; }
        case 0xb0: case 0xb1: case 0xb2: case 0xb3: case 0xb4: case 0xb5: case 0xb6: case 0xb7:
            d.SetReg((op & 7) | ((d.rex & 1) << 3), 1, d.Fetch8());
            break;
        case 0xb8: case 0xb9: case 0xba: case 0xbb: case 0xbc: case 0xbd: case 0xbe: case 0xbf: {
            int sz = d.OpSize();
            uint64_t v = sz == 8 ? d.Fetch64() : sz == 4 ? d.Fetch32() : d.Fetch16();
            d.SetReg((op & 7) | ((d.rex & 1) << 3), sz, v);
            break;
        }
        case 0xc0: case 0xc1: case 0xd0: case 0xd1: case 0xd2: case 0xd3: {
            DecodeModRM(d);
            int sz = op & 1 ? d.OpSize() : 1;
            unsigned count = op < 0xd0 ? d.Fetch8() : op < 0xd2 ? 1 : (unsigned)c.r[RCX];
            int kind = d.reg & 7;
            ModifyE(d, sz, [&](uint64_t v) { return Shift(c, kind, v, count, sz); });
            break;
        }
        case 0xc2: { uint16_t n = d.Fetch16(); d.ip = Pop(c); c.r[RSP] += n; break; }
        case 0xc3: d.ip = Pop(c); break;
        case 0xc6: case 0xc7: {
            DecodeModRM(d);
            int sz = op & 1 ? d.OpSize() : 1;
            d.SetEImm(sz);
            break;
        }
        case 0xc8: {   // enter, nesting level 0 only
            uint16_t size = d.Fetch16();
            if (d.Fetch8()) GuestPanic(c, "enter with a nesting level");
            Push(c, c.r[RBP]);
            c.r[RBP] = c.r[RSP];
            c.r[RSP] -= size;
            break;
        }
        case 0xc9: c.r[RSP] = c.r[RBP]; c.r[RBP] = Pop(c); break;
        case 0xcc: GuestPanic(c, "int3");
        case 0xcd: GuestPanic(c, "software interrupt");
        case 0xd8: case 0xd9: case 0xda: case 0xdb: case 0xdc: case 0xdd: case 0xde: case 0xdf:
            X87Op(d, op);
            break;
        case 0xe3: { int64_t rel = (int8_t)d.Fetch8(); if (!c.r[RCX]) d.ip += rel; break; }
        case 0xe8: { int64_t rel = (int32_t)d.Fetch32(); Push(c, d.ip); d.ip += rel; break; }
        case 0xe9: { int64_t rel = (int32_t)d.Fetch32(); d.ip += rel; break; }
        case 0xeb: { int64_t rel = (int8_t)d.Fetch8(); d.ip += rel; break; }
        case 0xf4: GuestPanic(c, "hlt");
        case 0xf5: c.cf = !c.cf; break;
        case 0xf6: case 0xf7: DecodeModRM(d); Group3(d, op & 1 ? d.OpSize() : 1); break;
        case 0xf8: c.cf = false; break;
        case 0xf9: c.cf = true; break;
        case 0xfc: c.df = false; break;
        case 0xfd: c.df = true; break;
        case 0xfe: case 0xff: {
            DecodeModRM(d);
            int sz = op & 1 ? d.OpSize() : 1, kind = d.reg & 7;
            switch (kind) {
                case 0: case 1: {   // inc dec keep CF
                    bool cf = c.cf;
                    ModifyE(d, sz, [&](uint64_t v) { return Alu(c, kind == 0 ? 0 : 5, v, 1, sz); });
                    c.cf = cf;
                    break;
                }
                case 2: { uint64_t t = d.GetE(8); Push(c, d.ip); d.ip = t; break; }
                case 4: d.ip = d.GetE(8); break;
                case 6: Push(c, d.GetE(8)); break;
                default: GuestPanic(c, "unknown FF form");
            }
            break;
        }
        case 0x0f: TwoByte(d); break;
        default: {
            char why[64];
            snprintf(why, sizeof why, "unknown opcode %02x", op);
            GuestPanic(c, why);
        }
    }
    c.rip = d.ip;
}

static thread_local Cpu *tCurrent;
Cpu *CurrentGuest() { return tCurrent; }

void StepInstruction(Cpu &c) {
    Step(c);
    c.instructions++;
}

int Run(Cpu &c) {
    tCurrent = &c;
    c.running = true;
    // Tracing wants every instruction seen, and only the interpreter sees them.
    bool jit = !(gConfig && gConfig->trace) && JitAvailable();   // the image to trace may not be loaded yet
    while (c.running) {
        if (__builtin_expect((c.rip >> 13) == (kCommpageBase >> 13), 0)) {
            if (!CommpageCall(c)) GuestPanic(c, "call into an unimplemented commpage routine");
            continue;
        }
        if (jit) { JitRun(c); continue; }
        Step(c);
        c.instructions++;
    }
    return c.exitCode;
}

} // namespace Lioness

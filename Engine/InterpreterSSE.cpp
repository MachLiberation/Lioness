// MMX, SSE, SSE2, SSE3 and SSSE3: what cpuid and the commpage advertise, and nothing newer. Rounding
// follows the host's default (nearest), MXCSR is stored but its rounding field is honoured only by the
// explicit truncating conversions, and FP exceptions never trap.

#include "Decode.h"
#include <cmath>
#include <stdio.h>

namespace Lioness {

namespace {

enum Prefix { kNone, k66, kF3, kF2 };

Prefix PrefixOf(const Decoder &d) { return d.rep ? kF3 : d.repne ? kF2 : d.opsize16 ? k66 : kNone; }

int XReg(const Decoder &d) { return d.reg; }

Xmm ReadXE(Decoder &d) {
    if (d.isReg) return d.c.xmm[d.rm];
    Xmm v;
    memcpy(&v, Xlat(d.EA()), 16);
    return v;
}
void ReadBytes(Decoder &d, void *out, size_t n) {
    if (d.isReg) memcpy(out, &d.c.xmm[d.rm], n);
    else memcpy(out, Xlat(d.EA()), n);
}
void WriteXEBytes(Decoder &d, const void *in, size_t n) {
    if (d.isReg) memcpy(&d.c.xmm[d.rm], in, n);
    else memcpy(Xlat(d.EA()), in, n);
}

// Vector integer operand, 8 bytes (MMX, no prefix) or 16 (66).
struct VecOps { Xmm a, b; int bytes; };

VecOps ReadVec(Decoder &d) {
    VecOps v{};
    v.bytes = d.opsize16 ? 16 : 8;
    if (v.bytes == 16) {
        v.a = d.c.xmm[d.reg];
        v.b = ReadXE(d);
    } else {
        v.a.q[0] = d.c.mm[d.reg & 7];
        if (d.isReg) v.b.q[0] = d.c.mm[d.rm & 7];
        else memcpy(&v.b, Xlat(d.EA()), 8);
    }
    return v;
}
void WriteVec(Decoder &d, const Xmm &r, int bytes) {
    if (bytes == 16) d.c.xmm[d.reg] = r;
    else d.c.mm[d.reg & 7] = r.q[0];
}

template <typename T> T Sat(int64_t v);
template <> int8_t Sat(int64_t v) { return v > 127 ? 127 : v < -128 ? -128 : (int8_t)v; }
template <> uint8_t Sat(int64_t v) { return v > 255 ? 255 : v < 0 ? 0 : (uint8_t)v; }
template <> int16_t Sat(int64_t v) { return v > 32767 ? 32767 : v < -32768 ? -32768 : (int16_t)v; }
template <> uint16_t Sat(int64_t v) { return v > 65535 ? 65535 : v < 0 ? 0 : (uint16_t)v; }

int32_t ToInt32(double v, bool truncate) {
    if (std::isnan(v) || v >= 2147483648.0 || v < -2147483649.0) return INT32_MIN;
    return (int32_t)(truncate ? std::trunc(v) : std::nearbyint(v));
}
int64_t ToInt64(double v, bool truncate) {
    if (std::isnan(v) || v >= 9223372036854775808.0 || v < -9223372036854775808.0) return INT64_MIN;
    return (int64_t)(truncate ? std::trunc(v) : std::nearbyint(v));
}

template <typename T>
T Arith(int op, T a, T b) {
    switch (op) {
        case 0x51: return std::sqrt(b);
        case 0x58: return a + b;
        case 0x59: return a * b;
        case 0x5c: return a - b;
        case 0x5d: return a < b ? a : b;   // x86: the second operand unless a is strictly less
        case 0x5e: return a / b;
        default:   return a > b ? a : b;
    }
}

template <typename T>
bool Compare(int kind, T a, T b) {
    bool unordered = std::isnan(a) || std::isnan(b);
    switch (kind & 7) {
        case 0: return !unordered && a == b;
        case 1: return !unordered && a < b;
        case 2: return !unordered && a <= b;
        case 3: return unordered;
        case 4: return unordered || a != b;
        case 5: return unordered || !(a < b);
        case 6: return unordered || !(a <= b);
        default: return !unordered;
    }
}

void Pshufb(Xmm &r, const Xmm &a, const Xmm &b, int bytes) {
    for (int i = 0; i < bytes; i++)
        r.b[i] = (b.b[i] & 0x80) ? 0 : a.b[b.b[i] & (bytes - 1)];
}

void Ssse3(Decoder &d) {
    uint8_t op = d.Fetch8();
    DecodeModRM(d);
    VecOps v = ReadVec(d);
    Xmm r{};
    int n = v.bytes;
    switch (op) {
        case 0x00: Pshufb(r, v.a, v.b, n); break;
        case 0x01: case 0x03: case 0x05: case 0x07: {   // phaddw phaddsw phsubw phsubsw
            int half = n / 4;
            for (int i = 0; i < half; i++) {
                int a0 = v.a.sw[2 * i], a1 = v.a.sw[2 * i + 1], b0 = v.b.sw[2 * i], b1 = v.b.sw[2 * i + 1];
                bool sub = op >= 5, sat = op == 3 || op == 7;
                int x = sub ? a0 - a1 : a0 + a1, y = sub ? b0 - b1 : b0 + b1;
                r.sw[i] = sat ? Sat<int16_t>(x) : (int16_t)x;
                r.sw[half + i] = sat ? Sat<int16_t>(y) : (int16_t)y;
            }
            break;
        }
        case 0x02: case 0x06: {   // phaddd phsubd
            int half = n / 8;
            for (int i = 0; i < half; i++) {
                bool sub = op == 6;
                r.d[i] = sub ? v.a.d[2 * i] - v.a.d[2 * i + 1] : v.a.d[2 * i] + v.a.d[2 * i + 1];
                r.d[half + i] = sub ? v.b.d[2 * i] - v.b.d[2 * i + 1] : v.b.d[2 * i] + v.b.d[2 * i + 1];
            }
            break;
        }
        case 0x04:   // pmaddubsw
            for (int i = 0; i < n / 2; i++)
                r.sw[i] = Sat<int16_t>((int)v.a.b[2 * i] * v.b.sb[2 * i] + (int)v.a.b[2 * i + 1] * v.b.sb[2 * i + 1]);
            break;
        case 0x08: for (int i = 0; i < n; i++) r.sb[i] = v.b.sb[i] < 0 ? -v.a.sb[i] : v.b.sb[i] ? v.a.sb[i] : 0; break;
        case 0x09: for (int i = 0; i < n / 2; i++) r.sw[i] = v.b.sw[i] < 0 ? -v.a.sw[i] : v.b.sw[i] ? v.a.sw[i] : 0; break;
        case 0x0a: for (int i = 0; i < n / 4; i++) r.sd[i] = v.b.sd[i] < 0 ? -v.a.sd[i] : v.b.sd[i] ? v.a.sd[i] : 0; break;
        case 0x0b: for (int i = 0; i < n / 2; i++) r.sw[i] = (int16_t)((((int)v.a.sw[i] * v.b.sw[i]) >> 14) + 1 >> 1); break;
        case 0x1c: for (int i = 0; i < n; i++) r.sb[i] = v.b.sb[i] < 0 ? -v.b.sb[i] : v.b.sb[i]; break;
        case 0x1d: for (int i = 0; i < n / 2; i++) r.sw[i] = v.b.sw[i] < 0 ? -v.b.sw[i] : v.b.sw[i]; break;
        case 0x1e: for (int i = 0; i < n / 4; i++) r.sd[i] = v.b.sd[i] < 0 ? -v.b.sd[i] : v.b.sd[i]; break;
        default: GuestPanic(d.c, "unknown 0F 38 opcode");
    }
    WriteVec(d, r, n);
}

void Palignr(Decoder &d) {
    uint8_t op = d.Fetch8();
    if (op != 0x0f) GuestPanic(d.c, "unknown 0F 3A opcode");
    DecodeModRM(d);
    unsigned imm = d.Fetch8();
    VecOps v = ReadVec(d);
    uint8_t joined[32] = {0};
    memcpy(joined, v.b.b, v.bytes);
    memcpy(joined + v.bytes, v.a.b, v.bytes);
    Xmm r{};
    if (imm < (unsigned)v.bytes * 2) memcpy(r.b, joined + imm, v.bytes * 2 - imm > (unsigned)v.bytes ? v.bytes : v.bytes * 2 - imm);
    WriteVec(d, r, v.bytes);
}

// The 60..FE block whose operands are all vec, vec/mem.
void IntegerOp(Decoder &d, uint8_t op) {
    DecodeModRM(d);
    VecOps v = ReadVec(d);
    const Xmm &a = v.a, &b = v.b;
    Xmm r{};
    int n = v.bytes;
#define LANES8  for (int i = 0; i < n; i++)
#define LANES16 for (int i = 0; i < n / 2; i++)
#define LANES32 for (int i = 0; i < n / 4; i++)
#define LANES64 for (int i = 0; i < n / 8; i++)
    switch (op) {
        case 0x60: LANES8 r.b[i] = i & 1 ? b.b[i / 2] : a.b[i / 2]; break;
        case 0x61: LANES16 r.w[i] = i & 1 ? b.w[i / 2] : a.w[i / 2]; break;
        case 0x62: LANES32 r.d[i] = i & 1 ? b.d[i / 2] : a.d[i / 2]; break;
        case 0x63: for (int i = 0; i < n / 2; i++) { r.sb[i] = Sat<int8_t>(a.sw[i]); r.sb[n / 2 + i] = Sat<int8_t>(b.sw[i]); } break;
        case 0x64: LANES8 r.b[i] = a.sb[i] > b.sb[i] ? 0xff : 0; break;
        case 0x65: LANES16 r.w[i] = a.sw[i] > b.sw[i] ? 0xffff : 0; break;
        case 0x66: LANES32 r.d[i] = a.sd[i] > b.sd[i] ? ~0u : 0; break;
        case 0x67: for (int i = 0; i < n / 2; i++) { r.b[i] = Sat<uint8_t>(a.sw[i]); r.b[n / 2 + i] = Sat<uint8_t>(b.sw[i]); } break;
        case 0x68: LANES8 r.b[i] = i & 1 ? b.b[n / 2 + i / 2] : a.b[n / 2 + i / 2]; break;
        case 0x69: LANES16 r.w[i] = i & 1 ? b.w[n / 4 + i / 2] : a.w[n / 4 + i / 2]; break;
        case 0x6a: LANES32 r.d[i] = i & 1 ? b.d[n / 8 + i / 2] : a.d[n / 8 + i / 2]; break;
        case 0x6b: for (int i = 0; i < n / 4; i++) { r.sw[i] = Sat<int16_t>(a.sd[i]); r.sw[n / 4 + i] = Sat<int16_t>(b.sd[i]); } break;
        case 0x6c: r.q[0] = a.q[0]; r.q[1] = b.q[0]; break;
        case 0x6d: r.q[0] = a.q[1]; r.q[1] = b.q[1]; break;
        case 0x74: LANES8 r.b[i] = a.b[i] == b.b[i] ? 0xff : 0; break;
        case 0x75: LANES16 r.w[i] = a.w[i] == b.w[i] ? 0xffff : 0; break;
        case 0x76: LANES32 r.d[i] = a.d[i] == b.d[i] ? ~0u : 0; break;
        case 0xd1: { uint64_t s = b.q[0]; LANES16 r.w[i] = s > 15 ? 0 : a.w[i] >> s; break; }
        case 0xd2: { uint64_t s = b.q[0]; LANES32 r.d[i] = s > 31 ? 0 : a.d[i] >> s; break; }
        case 0xd3: { uint64_t s = b.q[0]; LANES64 r.q[i] = s > 63 ? 0 : a.q[i] >> s; break; }
        case 0xd4: LANES64 r.q[i] = a.q[i] + b.q[i]; break;
        case 0xd5: LANES16 r.sw[i] = (int16_t)(a.sw[i] * b.sw[i]); break;
        case 0xd8: LANES8 r.b[i] = Sat<uint8_t>((int)a.b[i] - b.b[i]); break;
        case 0xd9: LANES16 r.w[i] = Sat<uint16_t>((int)a.w[i] - b.w[i]); break;
        case 0xda: LANES8 r.b[i] = a.b[i] < b.b[i] ? a.b[i] : b.b[i]; break;
        case 0xdb: LANES64 r.q[i] = a.q[i] & b.q[i]; break;
        case 0xdc: LANES8 r.b[i] = Sat<uint8_t>((int)a.b[i] + b.b[i]); break;
        case 0xdd: LANES16 r.w[i] = Sat<uint16_t>((int)a.w[i] + b.w[i]); break;
        case 0xde: LANES8 r.b[i] = a.b[i] > b.b[i] ? a.b[i] : b.b[i]; break;
        case 0xdf: LANES64 r.q[i] = ~a.q[i] & b.q[i]; break;
        case 0xe0: LANES8 r.b[i] = (uint8_t)(((int)a.b[i] + b.b[i] + 1) >> 1); break;
        case 0xe1: { uint64_t s = b.q[0] > 15 ? 15 : b.q[0]; LANES16 r.sw[i] = a.sw[i] >> s; break; }
        case 0xe2: { uint64_t s = b.q[0] > 31 ? 31 : b.q[0]; LANES32 r.sd[i] = a.sd[i] >> s; break; }
        case 0xe3: LANES16 r.w[i] = (uint16_t)(((int)a.w[i] + b.w[i] + 1) >> 1); break;
        case 0xe4: LANES16 r.w[i] = (uint16_t)(((uint32_t)a.w[i] * b.w[i]) >> 16); break;
        case 0xe5: LANES16 r.sw[i] = (int16_t)(((int)a.sw[i] * b.sw[i]) >> 16); break;
        case 0xe8: LANES8 r.sb[i] = Sat<int8_t>((int)a.sb[i] - b.sb[i]); break;
        case 0xe9: LANES16 r.sw[i] = Sat<int16_t>((int)a.sw[i] - b.sw[i]); break;
        case 0xea: LANES16 r.sw[i] = a.sw[i] < b.sw[i] ? a.sw[i] : b.sw[i]; break;
        case 0xeb: LANES64 r.q[i] = a.q[i] | b.q[i]; break;
        case 0xec: LANES8 r.sb[i] = Sat<int8_t>((int)a.sb[i] + b.sb[i]); break;
        case 0xed: LANES16 r.sw[i] = Sat<int16_t>((int)a.sw[i] + b.sw[i]); break;
        case 0xee: LANES16 r.sw[i] = a.sw[i] > b.sw[i] ? a.sw[i] : b.sw[i]; break;
        case 0xef: LANES64 r.q[i] = a.q[i] ^ b.q[i]; break;
        case 0xf1: { uint64_t s = b.q[0]; LANES16 r.w[i] = s > 15 ? 0 : (uint16_t)(a.w[i] << s); break; }
        case 0xf2: { uint64_t s = b.q[0]; LANES32 r.d[i] = s > 31 ? 0 : a.d[i] << s; break; }
        case 0xf3: { uint64_t s = b.q[0]; LANES64 r.q[i] = s > 63 ? 0 : a.q[i] << s; break; }
        case 0xf4: LANES64 r.q[i] = (uint64_t)a.d[2 * i] * b.d[2 * i]; break;
        case 0xf5: LANES32 r.sd[i] = (int)a.sw[2 * i] * b.sw[2 * i] + (int)a.sw[2 * i + 1] * b.sw[2 * i + 1]; break;
        case 0xf6: LANES64 {
                uint32_t sum = 0;
                for (int j = 0; j < 8; j++) sum += a.b[8 * i + j] > b.b[8 * i + j] ? a.b[8 * i + j] - b.b[8 * i + j] : b.b[8 * i + j] - a.b[8 * i + j];
                r.q[i] = sum;
            }
            break;
        case 0xf8: LANES8 r.b[i] = a.b[i] - b.b[i]; break;
        case 0xf9: LANES16 r.w[i] = a.w[i] - b.w[i]; break;
        case 0xfa: LANES32 r.d[i] = a.d[i] - b.d[i]; break;
        case 0xfb: LANES64 r.q[i] = a.q[i] - b.q[i]; break;
        case 0xfc: LANES8 r.b[i] = a.b[i] + b.b[i]; break;
        case 0xfd: LANES16 r.w[i] = a.w[i] + b.w[i]; break;
        case 0xfe: LANES32 r.d[i] = a.d[i] + b.d[i]; break;
        default: GuestPanic(d.c, "unknown vector integer opcode");
    }
    WriteVec(d, r, n);
}

void ShiftImm(Decoder &d, uint8_t op) {
    DecodeModRM(d);
    unsigned s = d.Fetch8();
    int kind = d.reg & 7, n = d.opsize16 ? 16 : 8;
    Xmm a{};
    if (n == 16) a = d.c.xmm[d.rm];
    else a.q[0] = d.c.mm[d.rm & 7];
    Xmm r{};
    if (op == 0x71) {
        for (int i = 0; i < n / 2; i++)
            r.w[i] = kind == 2 ? (s > 15 ? 0 : a.w[i] >> s) : kind == 4 ? (uint16_t)(a.sw[i] >> (s > 15 ? 15 : s)) : (s > 15 ? 0 : (uint16_t)(a.w[i] << s));
    } else if (op == 0x72) {
        for (int i = 0; i < n / 4; i++)
            r.d[i] = kind == 2 ? (s > 31 ? 0 : a.d[i] >> s) : kind == 4 ? (uint32_t)(a.sd[i] >> (s > 31 ? 31 : s)) : (s > 31 ? 0 : a.d[i] << s);
    } else if (kind == 3 || kind == 7) {   // psrldq pslldq: bytes
        if (s > 15) s = 16;
        for (int i = 0; i < 16; i++) {
            int from = kind == 3 ? i + (int)s : i - (int)s;
            r.b[i] = from >= 0 && from < 16 ? a.b[from] : 0;
        }
    } else {
        for (int i = 0; i < n / 8; i++)
            r.q[i] = kind == 2 ? (s > 63 ? 0 : a.q[i] >> s) : (s > 63 ? 0 : a.q[i] << s);
    }
    if (n == 16) d.c.xmm[d.rm] = r;
    else d.c.mm[d.rm & 7] = r.q[0];
}

} // namespace

void SseOp(Decoder &d, uint8_t op) {
    Cpu &c = d.c;
    Prefix p = PrefixOf(d);
    if (op == 0x38) { Ssse3(d); return; }
    if (op == 0x3a) { Palignr(d); return; }
    if (op == 0x77) return;   // emms
    if (op >= 0x71 && op <= 0x73) { ShiftImm(d, op); return; }
    if ((op >= 0x60 && op <= 0x6b) || op == 0x6c || op == 0x6d || (op >= 0x74 && op <= 0x76) ||
        (op >= 0xd1 && op <= 0xd5) || (op >= 0xd8 && op <= 0xdf) || (op >= 0xe0 && op <= 0xe5) ||
        (op >= 0xe8 && op <= 0xef) || (op >= 0xf1 && op <= 0xf6) || (op >= 0xf8 && op <= 0xfe)) {
        IntegerOp(d, op);
        return;
    }

    DecodeModRM(d);
    Xmm &x = c.xmm[XReg(d)];
    switch (op) {
        case 0x10:
            if (p == kF3) { uint32_t v; ReadBytes(d, &v, 4); if (d.isReg) x.d[0] = v; else { x = Xmm{}; x.d[0] = v; } }
            else if (p == kF2) { uint64_t v; ReadBytes(d, &v, 8); if (d.isReg) x.q[0] = v; else { x.q[0] = v; x.q[1] = 0; } }
            else x = ReadXE(d);
            return;
        case 0x11:
            if (p == kF3) WriteXEBytes(d, &x, 4);
            else if (p == kF2) WriteXEBytes(d, &x, 8);
            else WriteXEBytes(d, &x, 16);
            return;
        case 0x12:
            if (p == kF2) { uint64_t v; ReadBytes(d, &v, 8); x.q[0] = x.q[1] = v; }
            else if (p == kF3) { Xmm s = ReadXE(d); x.d[0] = x.d[1] = s.d[0]; x.d[2] = x.d[3] = s.d[2]; }
            else if (d.isReg) x.q[0] = c.xmm[d.rm].q[1];   // movhlps
            else memcpy(&x.q[0], Xlat(d.EA()), 8);
            return;
        case 0x13: memcpy(Xlat(d.EA()), &x.q[0], 8); return;
        case 0x14: {
            Xmm b = ReadXE(d), a = x;
            if (p == k66) { x.q[0] = a.q[0]; x.q[1] = b.q[0]; }
            else { x.d[0] = a.d[0]; x.d[1] = b.d[0]; x.d[2] = a.d[1]; x.d[3] = b.d[1]; }
            return;
        }
        case 0x15: {
            Xmm b = ReadXE(d), a = x;
            if (p == k66) { x.q[0] = a.q[1]; x.q[1] = b.q[1]; }
            else { x.d[0] = a.d[2]; x.d[1] = b.d[2]; x.d[2] = a.d[3]; x.d[3] = b.d[3]; }
            return;
        }
        case 0x16:
            if (p == kF3) { Xmm s = ReadXE(d); x.d[0] = x.d[1] = s.d[1]; x.d[2] = x.d[3] = s.d[3]; }
            else if (d.isReg) x.q[1] = c.xmm[d.rm].q[0];   // movlhps
            else memcpy(&x.q[1], Xlat(d.EA()), 8);
            return;
        case 0x17: memcpy(Xlat(d.EA()), &x.q[1], 8); return;
        case 0x28: x = ReadXE(d); return;
        case 0x29: case 0x2b: case 0xe7: WriteXEBytes(d, &x, 16); return;
        case 0x2a:
            if (p == kF3 || p == kF2) {
                int64_t v = (d.rex & 8) ? (int64_t)d.GetE(8) : (int64_t)(int32_t)d.GetE(4);
                if (p == kF3) x.f[0] = (float)v; else x.g[0] = (double)v;
            } else {   // cvtpi2ps / cvtpi2pd
                uint64_t m; if (d.isReg) m = c.mm[d.rm & 7]; else memcpy(&m, Xlat(d.EA()), 8);
                int32_t lo = (int32_t)m, hi = (int32_t)(m >> 32);
                if (p == k66) { x.g[0] = lo; x.g[1] = hi; } else { x.f[0] = (float)lo; x.f[1] = (float)hi; }
            }
            return;
        case 0x2c: case 0x2d: {
            bool truncate = op == 0x2c;
            if (p == kF3 || p == kF2) {
                double v;
                if (p == kF3) { float f; ReadBytes(d, &f, 4); v = f; } else ReadBytes(d, &v, 8);
                if (d.rex & 8) d.SetReg(d.reg, 8, (uint64_t)ToInt64(v, truncate));
                else d.SetReg(d.reg, 4, (uint32_t)ToInt32(v, truncate));
            } else GuestPanic(c, "cvt to mm");
            return;
        }
        case 0x2e: case 0x2f: {
            double a, b;
            if (p == k66) { a = x.g[0]; ReadBytes(d, &b, 8); }
            else { a = x.f[0]; float f; ReadBytes(d, &f, 4); b = f; }
            bool un = std::isnan(a) || std::isnan(b);
            c.zf = un || a == b; c.pfByte = un ? 0 : 1; c.cf = un || a < b;
            c.of = c.sf = false; c.afByte = 0;
            return;
        }
        case 0x50: {
            Xmm s = c.xmm[d.rm];
            uint32_t m = p == k66 ? (uint32_t)((s.q[0] >> 63) | ((s.q[1] >> 63) << 1))
                                  : (s.d[0] >> 31) | ((s.d[1] >> 31) << 1) | ((s.d[2] >> 31) << 2) | ((s.d[3] >> 31) << 3);
            d.SetReg(d.reg, 4, m);
            return;
        }
        case 0x51: case 0x58: case 0x59: case 0x5c: case 0x5d: case 0x5e: case 0x5f: {
            if (p == kF3) { float b; ReadBytes(d, &b, 4); x.f[0] = Arith<float>(op, x.f[0], b); }
            else if (p == kF2) { double b; ReadBytes(d, &b, 8); x.g[0] = Arith<double>(op, x.g[0], b); }
            else if (p == k66) { Xmm b = ReadXE(d); for (int i = 0; i < 2; i++) x.g[i] = Arith<double>(op, x.g[i], b.g[i]); }
            else { Xmm b = ReadXE(d); for (int i = 0; i < 4; i++) x.f[i] = Arith<float>(op, x.f[i], b.f[i]); }
            return;
        }
        case 0x52: case 0x53: {
            bool root = op == 0x52;
            auto f = [&](float v) { return root ? 1.0f / std::sqrt(v) : 1.0f / v; };
            if (p == kF3) { float b; ReadBytes(d, &b, 4); x.f[0] = f(b); }
            else { Xmm b = ReadXE(d); for (int i = 0; i < 4; i++) x.f[i] = f(b.f[i]); }
            return;
        }
        case 0x54: { Xmm b = ReadXE(d); x.q[0] &= b.q[0]; x.q[1] &= b.q[1]; return; }
        case 0x55: { Xmm b = ReadXE(d); x.q[0] = ~x.q[0] & b.q[0]; x.q[1] = ~x.q[1] & b.q[1]; return; }
        case 0x56: { Xmm b = ReadXE(d); x.q[0] |= b.q[0]; x.q[1] |= b.q[1]; return; }
        case 0x57: { Xmm b = ReadXE(d); x.q[0] ^= b.q[0]; x.q[1] ^= b.q[1]; return; }
        case 0x5a:
            if (p == kF3) { float b; ReadBytes(d, &b, 4); x.g[0] = b; }
            else if (p == kF2) { double b; ReadBytes(d, &b, 8); x.f[0] = (float)b; }
            else if (p == k66) { Xmm b = ReadXE(d); x.f[0] = (float)b.g[0]; x.f[1] = (float)b.g[1]; x.q[1] = 0; }
            else { float b[2]; ReadBytes(d, b, 8); x.g[0] = b[0]; x.g[1] = b[1]; }
            return;
        case 0x5b: {
            Xmm b = ReadXE(d);
            if (p == kNone) for (int i = 0; i < 4; i++) x.f[i] = (float)b.sd[i];
            else for (int i = 0; i < 4; i++) x.sd[i] = ToInt32(b.f[i], p == kF3);
            return;
        }
        case 0x6e: {
            uint64_t v = d.GetE((d.rex & 8) ? 8 : 4);
            if (p == k66) { x.q[0] = v; x.q[1] = 0; } else c.mm[d.reg & 7] = v;
            return;
        }
        case 0x6f:
            if (p == kF3 || p == k66) x = ReadXE(d);
            else if (d.isReg) c.mm[d.reg & 7] = c.mm[d.rm & 7];
            else memcpy(&c.mm[d.reg & 7], Xlat(d.EA()), 8);
            return;
        case 0x70: {
            unsigned i = d.Fetch8();
            if (p == kNone) {
                uint64_t m; if (d.isReg) m = c.mm[d.rm & 7]; else memcpy(&m, Xlat(d.EA()), 8);
                Xmm s{}; s.q[0] = m; Xmm r{};
                for (int k = 0; k < 4; k++) r.w[k] = s.w[(i >> (2 * k)) & 3];
                c.mm[d.reg & 7] = r.q[0];
                return;
            }
            Xmm s = ReadXE(d), r = s;
            if (p == k66) for (int k = 0; k < 4; k++) r.d[k] = s.d[(i >> (2 * k)) & 3];
            else if (p == kF2) for (int k = 0; k < 4; k++) r.w[k] = s.w[(i >> (2 * k)) & 3];
            else for (int k = 0; k < 4; k++) r.w[4 + k] = s.w[4 + ((i >> (2 * k)) & 3)];
            x = r;
            return;
        }
        case 0x7c: case 0x7d: {
            Xmm b = ReadXE(d), a = x;
            bool sub = op == 0x7d;
            if (p == k66) { x.g[0] = sub ? a.g[0] - a.g[1] : a.g[0] + a.g[1]; x.g[1] = sub ? b.g[0] - b.g[1] : b.g[0] + b.g[1]; }
            else {
                x.f[0] = sub ? a.f[0] - a.f[1] : a.f[0] + a.f[1]; x.f[1] = sub ? a.f[2] - a.f[3] : a.f[2] + a.f[3];
                x.f[2] = sub ? b.f[0] - b.f[1] : b.f[0] + b.f[1]; x.f[3] = sub ? b.f[2] - b.f[3] : b.f[2] + b.f[3];
            }
            return;
        }
        case 0x7e:
            if (p == kF3) { uint64_t v; ReadBytes(d, &v, 8); x.q[0] = v; x.q[1] = 0; }
            else if (p == k66) d.SetE((d.rex & 8) ? 8 : 4, (d.rex & 8) ? x.q[0] : x.d[0]);
            else d.SetE((d.rex & 8) ? 8 : 4, c.mm[d.reg & 7]);
            return;
        case 0x7f:
            if (p == kF3 || p == k66) WriteXEBytes(d, &x, 16);
            else if (d.isReg) c.mm[d.rm & 7] = c.mm[d.reg & 7];
            else memcpy(Xlat(d.EA()), &c.mm[d.reg & 7], 8);
            return;
        case 0xc2: {
            unsigned kind = d.Fetch8();
            if (p == kF3) { float b; ReadBytes(d, &b, 4); x.d[0] = Compare<float>(kind, x.f[0], b) ? ~0u : 0; }
            else if (p == kF2) { double b; ReadBytes(d, &b, 8); x.q[0] = Compare<double>(kind, x.g[0], b) ? ~0ull : 0; }
            else if (p == k66) { Xmm b = ReadXE(d); for (int i = 0; i < 2; i++) x.q[i] = Compare<double>(kind, x.g[i], b.g[i]) ? ~0ull : 0; }
            else { Xmm b = ReadXE(d); for (int i = 0; i < 4; i++) x.d[i] = Compare<float>(kind, x.f[i], b.f[i]) ? ~0u : 0; }
            return;
        }
        case 0xc4: {
            unsigned i = d.Fetch8();
            uint16_t v = (uint16_t)(d.isReg ? d.GetReg(d.rm, 4) : MemRead(d.EA(), 2));
            if (p == k66) x.w[i & 7] = v;
            else { Xmm m{}; m.q[0] = c.mm[d.reg & 7]; m.w[i & 3] = v; c.mm[d.reg & 7] = m.q[0]; }
            return;
        }
        case 0xc5: {
            unsigned i = d.Fetch8();
            if (p == k66) d.SetReg(d.reg, 4, c.xmm[d.rm].w[i & 7]);
            else { Xmm m{}; m.q[0] = c.mm[d.rm & 7]; d.SetReg(d.reg, 4, m.w[i & 3]); }
            return;
        }
        case 0xc6: {
            unsigned i = d.Fetch8();
            Xmm b = ReadXE(d), a = x;
            if (p == k66) { x.q[0] = a.q[i & 1]; x.q[1] = b.q[(i >> 1) & 1]; }
            else { x.d[0] = a.d[i & 3]; x.d[1] = a.d[(i >> 2) & 3]; x.d[2] = b.d[(i >> 4) & 3]; x.d[3] = b.d[(i >> 6) & 3]; }
            return;
        }
        case 0xd0: {
            Xmm b = ReadXE(d);
            if (p == k66) { x.g[0] -= b.g[0]; x.g[1] += b.g[1]; }
            else { x.f[0] -= b.f[0]; x.f[1] += b.f[1]; x.f[2] -= b.f[2]; x.f[3] += b.f[3]; }
            return;
        }
        case 0xd6: WriteXEBytes(d, &x.q[0], 8); if (d.isReg) c.xmm[d.rm].q[1] = 0; return;
        case 0xd7: {
            uint32_t m = 0;
            if (p == k66) { for (int i = 0; i < 16; i++) m |= (uint32_t)(c.xmm[d.rm].b[i] >> 7) << i; }
            else { Xmm s{}; s.q[0] = c.mm[d.rm & 7]; for (int i = 0; i < 8; i++) m |= (uint32_t)(s.b[i] >> 7) << i; }
            d.SetReg(d.reg, 4, m);
            return;
        }
        case 0xe6: {
            Xmm b = ReadXE(d);
            if (p == kF3) { x.g[0] = (double)b.sd[0]; x.g[1] = (double)b.sd[1]; }
            else { int32_t r0 = ToInt32(b.g[0], p == k66), r1 = ToInt32(b.g[1], p == k66); x.sd[0] = r0; x.sd[1] = r1; x.q[1] = 0; }
            return;
        }
        case 0xf0: x = ReadXE(d); return;   // lddqu
        case 0xf7: {
            uint8_t *to = Xlat(c.r[RDI]);
            const Xmm &mask = c.xmm[d.rm];
            for (int i = 0; i < 16; i++) if (mask.b[i] & 0x80) to[i] = x.b[i];
            return;
        }
        default: {
            char why[64];
            snprintf(why, sizeof why, "unknown 0F %02x", op);
            GuestPanic(c, why);
        }
    }
}

// FXSAVE: only what round-trips matters (Lion's dyld stub binder saves and restores through it).
void FxSave(Cpu &c, uint64_t address) {
    uint8_t *p = Xlat(address);
    memset(p, 0, 512);
    memcpy(p + 0, &c.fpuControl, 2);
    memcpy(p + 2, &c.fpuStatus, 2);
    memcpy(p + 24, &c.mxcsr, 4);
    for (int i = 0; i < 8; i++) memcpy(p + 32 + i * 16, &c.st[i], 8);
    memcpy(p + 32 + 8 * 16 - 16 + 8, &c.top, 4);   // top of stack kept in a reserved slot of st7's record
    memcpy(p + 160, c.xmm, 16 * 16);
}

void FxRestore(Cpu &c, uint64_t address) {
    const uint8_t *p = Xlat(address);
    memcpy(&c.fpuControl, p + 0, 2);
    memcpy(&c.fpuStatus, p + 2, 2);
    memcpy(&c.mxcsr, p + 24, 4);
    for (int i = 0; i < 8; i++) memcpy(&c.st[i], p + 32 + i * 16, 8);
    memcpy(&c.top, p + 32 + 8 * 16 - 16 + 8, 4);
    c.top &= 7;
    memcpy(c.xmm, p + 160, 16 * 16);
}

} // namespace Lioness

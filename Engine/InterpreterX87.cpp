// x87, at double precision: arm64 has no 80-bit float, and on x86-64 Lion only long double code and a
// few libm paths use this unit. An 80-bit load or store converts, so a long double round-trip keeps 53
// bits of mantissa. The registers are c.st[], addressed relative to c.top like the real stack.

#include "Decode.h"
#include <cmath>

namespace Lioness {

static inline double &St(Cpu &c, int i) { return c.st[(c.top + i) & 7]; }
static inline void FPush(Cpu &c, double v) { c.top = (c.top - 1) & 7; c.st[c.top] = v; }
static inline double FPop(Cpu &c) { double v = c.st[c.top]; c.top = (c.top + 1) & 7; return v; }

static double Load80(const uint8_t *p) {
    uint64_t mantissa; uint16_t se;
    memcpy(&mantissa, p, 8); memcpy(&se, p + 8, 2);
    int exponent = se & 0x7fff;
    double sign = (se & 0x8000) ? -1.0 : 1.0;
    if (exponent == 0 && mantissa == 0) return sign * 0.0;
    if (exponent == 0x7fff) return (mantissa << 1) ? NAN : sign * INFINITY;
    return sign * std::ldexp((double)mantissa, exponent - 16383 - 63);
}

static void Store80(uint8_t *p, double v) {
    uint64_t mantissa = 0; uint16_t se = std::signbit(v) ? 0x8000 : 0;
    if (std::isnan(v)) { mantissa = 0xc000000000000000ull; se |= 0x7fff; }
    else if (std::isinf(v)) { mantissa = 0x8000000000000000ull; se |= 0x7fff; }
    else if (v != 0) {
        int e;
        double m = std::frexp(std::fabs(v), &e);   // m in [0.5, 1)
        mantissa = (uint64_t)std::ldexp(m, 64);
        se |= (uint16_t)(e + 16382);
    }
    memcpy(p, &mantissa, 8); memcpy(p + 8, &se, 2);
}

static double Rounded(Cpu &c, double v) {
    switch ((c.fpuControl >> 10) & 3) {
        case 0: return std::nearbyint(v);
        case 1: return std::floor(v);
        case 2: return std::ceil(v);
        default: return std::trunc(v);
    }
}

static double Arith(int kind, double a, double b) {
    switch (kind & 7) {
        case 0: return a + b;
        case 1: return a * b;
        case 4: return a - b;
        case 5: return b - a;
        case 6: return a / b;
        case 7: return b / a;
        default: return a;
    }
}

static void FCompare(Cpu &c, double a, double b) {
    bool un = std::isnan(a) || std::isnan(b);
    c.c0 = un || a < b; c.c2 = un; c.c3 = un || a == b; c.c1 = false;
}
static void FComi(Cpu &c, double a, double b) {
    bool un = std::isnan(a) || std::isnan(b);
    c.zf = un || a == b; c.pfByte = un ? 0 : 1; c.cf = un || a < b;
    c.of = c.sf = false; c.afByte = 0;
}

static uint16_t Status(const Cpu &c) {
    return (uint16_t)((c.fpuStatus & 0x3f) | ((c.top & 7) << 11) | ((uint16_t)c.c0 << 8) | ((uint16_t)c.c1 << 9) |
                      ((uint16_t)c.c2 << 10) | ((uint16_t)c.c3 << 14));
}

static void Constant(Cpu &c, int which) {
    static const double values[] = { 1.0, 3.321928094887362, 1.4426950408889634, 3.141592653589793,
                                     0.3010299956639812, 0.6931471805599453, 0.0 };
    FPush(c, values[which]);
}

// D9 with a register operand: the one-operand instructions.
static void D9Reg(Decoder &d, int reg, int rm) {
    Cpu &c = d.c;
    switch (reg) {
        case 0: { double v = St(c, rm); FPush(c, v); return; }
        case 1: { double t = St(c, 0); St(c, 0) = St(c, rm); St(c, rm) = t; return; }
        case 2: return;   // fnop
        case 4:
            switch (rm) {
                case 0: St(c, 0) = -St(c, 0); return;
                case 1: St(c, 0) = std::fabs(St(c, 0)); return;
                case 4: FCompare(c, St(c, 0), 0.0); return;
                case 5: {
                    double v = St(c, 0);
                    c.c1 = std::signbit(v);
                    if (std::isnan(v)) { c.c3 = false; c.c2 = false; c.c0 = true; }
                    else if (std::isinf(v)) { c.c3 = false; c.c2 = true; c.c0 = true; }
                    else if (v == 0) { c.c3 = true; c.c2 = false; c.c0 = false; }
                    else { c.c3 = false; c.c2 = true; c.c0 = false; }
                    return;
                }
                default: break;
            }
            break;
        case 5: if (rm < 7) { Constant(c, rm); return; } break;
        case 6:
            switch (rm) {
                case 0: St(c, 0) = std::exp2(St(c, 0)) - 1; return;
                case 1: { double x = FPop(c); St(c, 0) = St(c, 0) * std::log2(x); return; }
                case 2: St(c, 0) = std::tan(St(c, 0)); FPush(c, 1.0); c.c2 = false; return;
                case 3: { double x = FPop(c); St(c, 0) = std::atan2(St(c, 0), x); return; }
                case 4: { double v = St(c, 0); int e; double m = std::frexp(v, &e); St(c, 0) = (double)(e - 1); FPush(c, m * 2); return; }
                case 5: St(c, 0) = std::remainder(St(c, 0), St(c, 1)); c.c2 = false; return;
                case 6: c.top = (c.top - 1) & 7; return;
                case 7: c.top = (c.top + 1) & 7; return;
                default: break;
            }
            break;
        default:
            switch (rm) {
                case 0: St(c, 0) = std::fmod(St(c, 0), St(c, 1)); c.c2 = false; return;
                case 1: { double x = FPop(c); St(c, 0) = St(c, 0) * std::log2(x + 1); return; }
                case 2: St(c, 0) = std::sqrt(St(c, 0)); return;
                case 3: { double v = St(c, 0); St(c, 0) = std::sin(v); FPush(c, std::cos(v)); c.c2 = false; return; }
                case 4: St(c, 0) = Rounded(c, St(c, 0)); return;
                case 5: St(c, 0) = std::ldexp(St(c, 0), (int)std::trunc(St(c, 1))); return;
                case 6: St(c, 0) = std::sin(St(c, 0)); c.c2 = false; return;
                default: St(c, 0) = std::cos(St(c, 0)); c.c2 = false; return;
            }
    }
    GuestPanic(c, "unknown D9 register form");
}

void X87Op(Decoder &d, uint8_t op) {
    Cpu &c = d.c;
    DecodeModRM(d);
    int reg = d.reg & 7;   // REX.R has no meaning here
    int rm = d.isReg ? d.rm & 7 : 0;

    if (!d.isReg) {
        uint64_t a = d.EA();
        uint8_t *p = Xlat(a);
        switch (op) {
            case 0xd8: { float f; memcpy(&f, p, 4);
                if (reg == 2) FCompare(c, St(c, 0), f);
                else if (reg == 3) { FCompare(c, St(c, 0), f); FPop(c); }
                else St(c, 0) = Arith(reg, St(c, 0), f);
                return; }
            case 0xdc: { double f; memcpy(&f, p, 8);
                if (reg == 2) FCompare(c, St(c, 0), f);
                else if (reg == 3) { FCompare(c, St(c, 0), f); FPop(c); }
                else St(c, 0) = Arith(reg, St(c, 0), f);
                return; }
            case 0xda: case 0xde: {
                int32_t v = op == 0xda ? (int32_t)MemRead(a, 4) : (int16_t)MemRead(a, 2);
                if (reg == 2) FCompare(c, St(c, 0), v);
                else if (reg == 3) { FCompare(c, St(c, 0), v); FPop(c); }
                else St(c, 0) = Arith(reg, St(c, 0), v);
                return;
            }
            case 0xd9:
                switch (reg) {
                    case 0: { float f; memcpy(&f, p, 4); FPush(c, f); return; }
                    case 2: case 3: { float f = (float)St(c, 0); memcpy(p, &f, 4); if (reg == 3) FPop(c); return; }
                    case 4: {   // fldenv
                        uint32_t e[7]; memcpy(e, p, 28);
                        c.fpuControl = (uint16_t)e[0];
                        c.fpuStatus = (uint16_t)e[1];
                        c.top = (e[1] >> 11) & 7;
                        return;
                    }
                    case 5: c.fpuControl = (uint16_t)MemRead(a, 2); return;
                    case 6: {   // fnstenv
                        uint32_t e[7] = { c.fpuControl, Status(c), 0xffff, 0, 0, 0, 0xffff0000 };
                        memcpy(p, e, 28);
                        return;
                    }
                    case 7: MemWrite(a, 2, c.fpuControl); return;
                    default: break;
                }
                break;
            case 0xdb:
                switch (reg) {
                    case 0: FPush(c, (int32_t)MemRead(a, 4)); return;
                    case 1: MemWrite(a, 4, (uint32_t)(int32_t)std::trunc(FPop(c))); return;
                    case 2: case 3: { MemWrite(a, 4, (uint32_t)(int32_t)Rounded(c, St(c, 0))); if (reg == 3) FPop(c); return; }
                    case 5: FPush(c, Load80(p)); return;
                    case 7: Store80(p, FPop(c)); return;
                    default: break;
                }
                break;
            case 0xdd:
                switch (reg) {
                    case 0: { double f; memcpy(&f, p, 8); FPush(c, f); return; }
                    case 1: MemWrite(a, 8, (uint64_t)(int64_t)std::trunc(FPop(c))); return;
                    case 2: case 3: { double f = St(c, 0); memcpy(p, &f, 8); if (reg == 3) FPop(c); return; }
                    case 7: MemWrite(a, 2, Status(c)); return;
                    default: break;
                }
                break;
            default:   // df
                switch (reg) {
                    case 0: FPush(c, (int16_t)MemRead(a, 2)); return;
                    case 1: MemWrite(a, 2, (uint16_t)(int16_t)std::trunc(FPop(c))); return;
                    case 2: case 3: { MemWrite(a, 2, (uint16_t)(int16_t)Rounded(c, St(c, 0))); if (reg == 3) FPop(c); return; }
                    case 5: FPush(c, (double)(int64_t)MemRead(a, 8)); return;
                    case 7: MemWrite(a, 8, (uint64_t)(int64_t)Rounded(c, FPop(c))); return;
                    default: break;
                }
                break;
        }
        GuestPanic(c, "unknown x87 memory form");
    }

    switch (op) {
        case 0xd8:
            if (reg == 2) FCompare(c, St(c, 0), St(c, rm));
            else if (reg == 3) { FCompare(c, St(c, 0), St(c, rm)); FPop(c); }
            else St(c, 0) = Arith(reg, St(c, 0), St(c, rm));
            return;
        case 0xd9: D9Reg(d, reg, rm); return;
        case 0xda:
            if (reg <= 3) {
                bool take = reg == 0 ? c.cf : reg == 1 ? c.zf : reg == 2 ? (c.cf || c.zf) : !__builtin_parity(c.pfByte);
                if (take) St(c, 0) = St(c, rm);
                return;
            }
            if (reg == 5 && rm == 1) { FCompare(c, St(c, 0), St(c, 1)); FPop(c); FPop(c); return; }
            break;
        case 0xdb:
            if (reg <= 3) {
                bool take = reg == 0 ? !c.cf : reg == 1 ? !c.zf : reg == 2 ? !(c.cf || c.zf) : !!__builtin_parity(c.pfByte);
                if (take) St(c, 0) = St(c, rm);
                return;
            }
            if (reg == 4) { if (rm == 2) { c.fpuStatus &= 0x7f00; } else if (rm == 3) { c.fpuControl = 0x37f; c.top = 0; c.fpuStatus = 0; } return; }
            if (reg == 5 || reg == 6) { FComi(c, St(c, 0), St(c, rm)); return; }
            break;
        case 0xdc: {   // the reversed pairs swap: DC E0 is fsubr with ST(i) as destination
            double a = St(c, rm), b = St(c, 0);
            if (reg == 2) { FCompare(c, b, a); return; }
            if (reg == 3) { FCompare(c, b, a); FPop(c); return; }
            int kind = reg >= 4 ? (reg ^ 1) : reg;
            St(c, rm) = Arith(kind, a, b);
            return;
        }
        case 0xdd:
            switch (reg) {
                case 0: return;   // ffree
                case 2: St(c, rm) = St(c, 0); return;
                case 3: St(c, rm) = St(c, 0); FPop(c); return;
                case 4: FCompare(c, St(c, 0), St(c, rm)); return;
                case 5: FCompare(c, St(c, 0), St(c, rm)); FPop(c); return;
                default: break;
            }
            break;
        case 0xde: {
            if (reg == 3 && rm == 1) { FCompare(c, St(c, 0), St(c, 1)); FPop(c); FPop(c); return; }
            if (reg == 2 || reg == 3) break;
            double a = St(c, rm), b = St(c, 0);
            int kind = reg >= 4 ? (reg ^ 1) : reg;
            St(c, rm) = Arith(kind, a, b);
            FPop(c);
            return;
        }
        default:   // df
            if (reg == 4 && rm == 0) { d.SetReg(RAX, 2, Status(c)); return; }
            if (reg == 5 || reg == 6) { FComi(c, St(c, 0), St(c, rm)); FPop(c); return; }
            if (reg == 0) { c.top = (c.top + 1) & 7; return; }   // ffreep
            break;
    }
    GuestPanic(c, "unknown x87 register form");
}

} // namespace Lioness

/* mcpcheck: checks mcp_model against independent references.
 *
 *   mcpcheck <testfloat_gen> [level]
 *
 * 1. Every operation the model takes from SoftFloat, against TestFloat's
 *    vectors (testfloat_gen, -tininessafter), in all four rounding modes:
 *    FADD, FSUB, FSUBR, FMUL, FDIV, FDIVR, FSQRT, FRINT, FTRUNC, FTOI, FILD,
 *    FCMP (against f32_eq, f32_lt_quiet, f32_le_quiet). This checks the
 *    model's glue: operand order, the rounding modes, the flags.
 * 2. The operations SoftFloat has no function for, against the host's own
 *    floating point (fesetround, double arithmetic, exact where it says so):
 *    FTOX, FTOI16, FXLD, FMIN, FMAX, FCLASS, FCONST, FRECIP.
 * 3. The stream port: random command lists as bytes against the same
 *    commands given to mcp_exec directly, at every stage; MPLOAD and
 *    MPREAD likewise.
 * MCP-2 (MCP2.md):
 * 4. The fused multiply-add against TestFloat's f32_mulAdd, all modes.
 * 5. Every wide form (FADD3 ... MMUL, stage 3) against the host's own
 *    floating point (fmaf, fesetround), step by step as MCP2.md defines them:
 *    an implementation independent of SoftFloat.
 * 6. Programs (PRUN, PEND, PEXIT, MPLIMIT, the aborts) against a separately
 *    written interpreter of MCP2.md's rules.
 * Exit status 0 = no differences. */
#include <fenv.h>
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "mcp_model.h"

#pragma STDC FENV_ACCESS ON

static long nfail, ntest;
static void fail(const char *what, uint32_t a, uint32_t b, int rm, uint32_t got, uint32_t want,
                 int gotf, int wantf)
{
    if (nfail++ < 20)
        fprintf(stderr, "%s rm %d: a %08X b %08X: %08X flags %02X, expected %08X flags %02X\n",
                what, rm, a, b, got, gotf, want, wantf);
}

/* TestFloat's flags as MFLAGS bits (inexact 1, underflow 2, overflow 4, infinite 8, invalid 16) */
static int tf_flags(unsigned f)
{
    return (f & 16 ? MCP_FL_INVALID : 0) | (f & 8 ? MCP_FL_DIVZERO : 0) | (f & 4 ? MCP_FL_OVERFLOW : 0)
         | (f & 2 ? MCP_FL_UNDERFLOW : 0) | (f & 1 ? MCP_FL_INEXACT : 0);
}

static const char *tf_mode[4] = {"-rnear_even", "-rmin", "-rmax", "-rminMag"};

/* kind: 0 two operands (op a b), 1 swapped (op b a), 2 one operand (b), 3 to MINT,
 * 4 int to float, 5 compare (eq), 6 (lt), 7 (le), 8 three (a x b + c: mcp_fma) */
static void tf_run(const char *gen, const char *level, const char *func, const char *extra,
                   int op, int kind)
{
    for (int rm = 0; rm < 4; rm++) {
        if (kind >= 5 && kind <= 7 && rm) continue;            /* (compares: no rounding) */
        int gen_rm = op == MCP_FTRUNC ? MCP_RM_ZERO : rm;      /* (FTRUNC: toward 0 in every mode) */
        char cmd[1024];
        snprintf(cmd, sizeof cmd, "%s -level %s -tininessafter %s %s %s", gen, level,
                 kind >= 5 && kind <= 7 ? "" : tf_mode[gen_rm], extra, func);
        FILE *p = popen(cmd, "r");
        if (!p) { perror(cmd); exit(2); }
        unsigned a, b, r, fl;
        char line[128];
        long n = 0;
        while (fgets(line, sizeof line, p)) {
            unsigned c3 = 0;
            int two = kind == 0 || kind == 1 || (kind >= 5 && kind <= 7);
            if (kind == 8 ? sscanf(line, "%x %x %x %x %x", &a, &b, &c3, &r, &fl) != 5
                : two ? sscanf(line, "%x %x %x %x", &a, &b, &r, &fl) != 4
                      : sscanf(line, "%x %x %x", &a, &r, &fl) != 3)
                continue;
            mcp_res m;
            uint32_t got;
            switch (kind) {
            case 0: m = mcp_core(op, a, b, rm); got = m.r; break;
            case 1: m = mcp_core(op, b, a, rm); got = m.r; break;
            case 2: case 4: m = mcp_core(op, 0, a, rm); got = m.r; break;
            case 3: m = mcp_core(op, 0, a, rm); got = m.mint; break;
            case 8:
                memset(&m, 0, sizeof m);
                got = mcp_fma(a, b, c3, rm, &m.flags);
                break;
            default:
                m = mcp_core(MCP_FCMP, a, b, rm);
                got = kind == 5 ? m.cond == 0x02 : kind == 6 ? m.cond == 0x01 : (m.cond & 0x03) != 0;
            }
            ntest++;
            n++;
            if (got != r || m.flags != tf_flags(fl)) {
                char what[96];
                snprintf(what, sizeof what, "%s%s (op %02X)", func, kind == 1 ? " swapped" : "", op);
                fail(what, a, kind >= 5 || kind <= 1 ? b : 0, rm, got, r, m.flags, tf_flags(fl));
            }
        }
        pclose(p);
        if (!n) { fprintf(stderr, "no vectors from: %s\n", cmd); exit(2); }
    }
}

/* ---- host references ---- */

static uint64_t g = 0x9E3779B97F4A7C15ull;
static uint32_t rnd32(void)
{
    g ^= g << 13; g ^= g >> 7; g ^= g << 17;
    return (uint32_t)(g >> 16);
}

static float fb(uint32_t v) { float f; memcpy(&f, &v, 4); return f; }
static uint32_t bf(float f) { uint32_t v; memcpy(&v, &f, 4); return v; }
static int isn(uint32_t v) { return (v & 0x7F800000) == 0x7F800000 && (v & 0x7FFFFF); }
static int issn(uint32_t v) { return isn(v) && !(v & 0x400000); }

/* an operand from the interesting places: anything, small, near integers and
 * halves, near the int16 / int32 / s15.16 limits, subnormal, zero, inf, NaN */
static uint32_t pick(void)
{
    switch (rnd32() % 10) {
    case 0: return rnd32();
    case 1: return bf((float)((int32_t)rnd32() % 100000) / (float)(1 + rnd32() % 64));
    case 2: return bf((float)((int32_t)(rnd32() % 200001) - 100000) + 0.5f);
    case 3: {                                   /* near +-32768, +-2^31, +-2^15 (s15.16's limit) */
        static const float lim[] = {32767.0f, 32768.0f, 2147483520.0f, 2147483648.0f, 32767.99f};
        float f = lim[rnd32() % 5];
        uint32_t v = bf(f) + (rnd32() % 5) - 2;
        return v ^ (rnd32() & 0x80000000);
    }
    case 4: return rnd32() & 0x807FFFFF;        /* subnormal or zero */
    case 5: return (rnd32() & 0x80000000) | (rnd32() % 2 ? 0x7F800000 : 0);
    case 6: return 0x7F800000 | (rnd32() & 0x807FFFFF) | 1;   /* NaN, quiet or signalling */
    case 7: return (rnd32() & 0x80000000) | ((uint32_t)(127 + rnd32() % 40) << 23) | (rnd32() & 0x7FFFFF);
    case 8: return (rnd32() & 0x80000000) | ((uint32_t)(100 + rnd32() % 27) << 23) | (rnd32() & 0x7FFFFF);
    default: return bf((float)(int32_t)rnd32() / 65536.0f);
    }
}

static const int host_mode[4] = {FE_TONEAREST, FE_DOWNWARD, FE_UPWARD, FE_TOWARDZERO};

/* round(x) to an integer in [lo, hi] the IEEE way: NaN -> 0 and invalid,
 * outside -> saturated and invalid, else inexact when rounding changed it */
static int32_t host_toint(double x, int rm, long lo, long hi, int *fl)
{
    *fl = 0;
    if (isnan(x)) { *fl = MCP_FL_INVALID; return 0; }
    fesetround(host_mode[rm]);
    volatile double y = nearbyint(x);
    fesetround(FE_TONEAREST);
    if (y > (double)hi) { *fl = MCP_FL_INVALID; return (int32_t)hi; }
    if (y < (double)lo) { *fl = MCP_FL_INVALID; return (int32_t)lo; }
    if (y != x) *fl = MCP_FL_INEXACT;
    return (int32_t)y;
}

static void host_checks(long n)
{
    for (long i = 0; i < n; i++) {
        int rm = (int)(rnd32() % 4), fl;
        uint32_t a = pick(), b = pick();
        mcp_res m;
        int32_t want;
        /* FTOX: round(b * 2^16) */
        want = host_toint((double)fb(b) * 65536.0, rm, -2147483648L, 2147483647L, &fl);
        m = mcp_core(MCP_FTOX, 0, b, rm);
        ntest++;
        if (m.mint != (uint32_t)want || m.flags != fl || !m.wr_mint || m.wr_f)
            fail("FTOX", 0, b, rm, m.mint, (uint32_t)want, m.flags, fl);
        /* FTOI16 */
        want = host_toint((double)fb(b), rm, -32768L, 32767L, &fl);
        m = mcp_core(MCP_FTOI16, 0, b, rm);
        ntest++;
        if (m.mint != (uint32_t)want || m.flags != fl)
            fail("FTOI16", 0, b, rm, m.mint, (uint32_t)want, m.flags, fl);
        /* FXLD: float(v / 2^16), v / 2^16 exact in double, one rounding to float */
        {
            int32_t v = (int32_t)(rnd32() % 4 ? rnd32() : (rnd32() % 0x1000000) << (rnd32() % 8));
            volatile double x = (double)v / 65536.0;
            fesetround(host_mode[rm]);
            volatile float y = (float)x;
            fesetround(FE_TONEAREST);
            int wf = (double)y != x ? MCP_FL_INEXACT : 0;
            m = mcp_core(MCP_XLD, 0, (uint32_t)v, rm);
            ntest++;
            if (m.r != bf(y) || m.flags != wf)
                fail("FXLD", 0, (uint32_t)v, rm, m.r, bf(y), m.flags, wf);
        }
        /* FMIN, FMAX (minNum, maxNum; -0 below +0) */
        for (int mx = 0; mx < 2; mx++) {
            uint32_t w;
            int wf = 0;
            if (issn(a) || issn(b)) { w = MCP_DEFAULT_NAN; wf = MCP_FL_INVALID; }
            else if (isn(a) && isn(b)) w = MCP_DEFAULT_NAN;
            else if (isn(a)) w = b;
            else if (isn(b)) w = a;
            else {
                double da = fb(a), db = fb(b);
                if (da == db) w = mx ? ((a >> 31) ? b : a) : ((a >> 31) ? a : b);  /* (zeros: by sign) */
                else w = (da < db) == !mx ? a : b;
            }
            m = mcp_core(mx ? MCP_FMAX : MCP_FMIN, a, b, rm);
            ntest++;
            if (m.r != w || m.flags != wf)
                fail(mx ? "FMAX" : "FMIN", a, b, rm, m.r, w, m.flags, wf);
        }
        /* FCLASS */
        {
            float f = fb(b);
            int c = (b >> 31) ? 1 : 0;
            switch (fpclassify(f)) {
            case FP_ZERO: c |= 0x02; break;
            case FP_SUBNORMAL: c |= 0x04; break;
            case FP_NORMAL: c |= 0x08; break;
            case FP_INFINITE: c |= 0x10; break;
            default: c |= issn(b) ? 0x40 : 0x20;
            }
            m = mcp_core(MCP_FCLASS, 0, b, rm);
            ntest++;
            if (m.cond != c || m.flags || !m.wr_cond || m.wr_f)
                fail("FCLASS", 0, b, rm, m.cond, (uint32_t)c, m.flags, 0);
        }
        /* FRECIP = FDIV of 1.0 (one rounding): the host's float division */
        if (!isn(b)) {
            fesetround(host_mode[rm]);
            feclearexcept(FE_ALL_EXCEPT);
            volatile float y = 1.0f / fb(b);
            int e = fetestexcept(FE_ALL_EXCEPT);
            fesetround(FE_TONEAREST);
            int wf = (e & FE_INVALID ? MCP_FL_INVALID : 0) | (e & FE_DIVBYZERO ? MCP_FL_DIVZERO : 0)
                   | (e & FE_OVERFLOW ? MCP_FL_OVERFLOW : 0)
                   | (e & FE_UNDERFLOW && e & FE_INEXACT ? MCP_FL_UNDERFLOW : 0)
                   | (e & FE_INEXACT ? MCP_FL_INEXACT : 0);
            m = mcp_core(MCP_FRECIP, 0, b, rm);
            ntest++;
            if ((bf(y) & 0x7FFFFFFF) == 0x00800000)    /* (the host detects tininess before rounding) */
                wf = (wf & ~MCP_FL_UNDERFLOW) | (m.flags & MCP_FL_UNDERFLOW);
            if (m.r != bf(y) || m.flags != wf)
                fail("FRECIP", 0, b, rm, m.r, bf(y), m.flags, wf);
        }
    }
    /* FCONST: the table against the host's constants, rounded to nearest */
    static const double c[16] = {0, 1, 2, 0.5, 10, M_PI, M_PI / 2, 2 * M_PI, M_E, M_LN2, M_LOG2E,
                                 0.30102999566398119521, M_SQRT2, M_SQRT1_2, INFINITY, NAN};
    for (int k = 0; k < 16; k++) {
        mcp_res m = mcp_core(MCP_FCONST, 0, (uint32_t)k, MCP_RM_UP);
        uint32_t w = k == 15 ? MCP_DEFAULT_NAN : bf((float)c[k]);
        ntest++;
        if (m.r != w || m.flags) fail("FCONST", 0, (uint32_t)k, 2, m.r, w, m.flags, 0);
    }
}

/* ---- MCP-2: the wide forms against the host ---- */

static int hostfl(void)
{
    int e = fetestexcept(FE_ALL_EXCEPT);
    return (e & FE_INVALID ? MCP_FL_INVALID : 0) | (e & FE_DIVBYZERO ? MCP_FL_DIVZERO : 0)
         | (e & FE_OVERFLOW ? MCP_FL_OVERFLOW : 0) | (e & FE_INEXACT ? MCP_FL_INEXACT : 0);
}
static int same(uint32_t a, uint32_t b) { return a == b || (isn(a) && isn(b)); }

/* the host's version of a wide form on f[16], m[16] (MCP2.md, step by step) */
static void host_wide(int op, int d, int sr, int t, int rm, uint32_t *f, uint32_t *m)
{
    volatile float x[16], y[16], r[16];
    for (int k = 0; k < 16; k++) { x[k] = fb(f[k]); y[k] = fb(m[k]); }
    int vd = 4 * (d & 3), vs = 4 * (sr & 3), vt = 4 * (t & 3);
    fesetround(host_mode[rm]);
    switch (op) {
    case MCPW_FADD3: f[d] = bf(x[sr] + x[t]); break;
    case MCPW_FSUB3: f[d] = bf(x[sr] - x[t]); break;
    case MCPW_FMUL3: f[d] = bf(x[sr] * x[t]); break;
    case MCPW_FMA: f[d] = bf(fmaf(x[sr], x[t], x[d])); break;
    case MCPW_FMS: f[d] = bf(fmaf(-x[sr], x[t], x[d])); break;
    case MCPW_VMOVE: for (int k = 0; k < 4; k++) r[k] = x[vs + k]; goto vstore;
    case MCPW_VADD: for (int k = 0; k < 4; k++) r[k] = x[vs + k] + x[vt + k]; goto vstore;
    case MCPW_VSUB: for (int k = 0; k < 4; k++) r[k] = x[vs + k] - x[vt + k]; goto vstore;
    case MCPW_VMUL: for (int k = 0; k < 4; k++) r[k] = x[vs + k] * x[vt + k]; goto vstore;
    case MCPW_VSCALE: for (int k = 0; k < 4; k++) r[k] = x[vs + k] * x[t]; goto vstore;
    case MCPW_VDOT3: case MCPW_VDOT4: {
        float a = x[vs] * x[vt];
        for (int k = 1; k < (op == MCPW_VDOT4 ? 4 : 3); k++) a = fmaf(x[vs + k], x[vt + k], a);
        f[d] = bf(a);
        break;
    }
    case MCPW_VCROSS:
        r[0] = fmaf(x[vs + 1], x[vt + 2], -(x[vs + 2] * x[vt + 1]));
        r[1] = fmaf(x[vs + 2], x[vt + 0], -(x[vs + 0] * x[vt + 2]));
        r[2] = fmaf(x[vs + 0], x[vt + 1], -(x[vs + 1] * x[vt + 0]));
        r[3] = 0.0f;
        goto vstore;
    case MCPW_VNORM3: {
        float n = x[vs] * x[vs];
        n = fmaf(x[vs + 1], x[vs + 1], n);
        n = fmaf(x[vs + 2], x[vs + 2], n);
        float q = 1.0f / sqrtf(n);
        for (int k = 0; k < 3; k++) r[k] = x[vs + k] * q;
        r[3] = x[vs + 3];
        goto vstore;
    }
    case MCPW_MLOAD: for (int k = 0; k < 16; k++) m[k] = f[k]; break;
    case MCPW_MSTORE: for (int k = 0; k < 16; k++) f[k] = m[k]; break;
    case MCPW_MXV: case MCPW_MTXV:
        for (int row = 0; row < 4; row++) {
            int e0 = op == MCPW_MXV ? 4 * row : row, st = op == MCPW_MXV ? 1 : 4;
            float a = y[e0] * x[vs];
            for (int k = 1; k < 4; k++) a = fmaf(y[e0 + k * st], x[vs + k], a);
            r[row] = a;
        }
        goto vstore;
    case MCPW_MMUL:
        for (int row = 0; row < 4; row++)
            for (int c = 0; c < 4; c++) {
                float a = y[4 * row] * x[c];
                for (int k = 1; k < 4; k++) a = fmaf(y[4 * row + k], x[4 * k + c], a);
                r[4 * row + c] = a;
            }
        for (int k = 0; k < 16; k++) m[k] = bf(r[k]);
        break;
    }
    fesetround(FE_TONEAREST);
    return;
vstore:
    fesetround(FE_TONEAREST);
    for (int k = 0; k < 4; k++) f[vd + k] = bf(r[k]);
}

static void wide_checks(long n)
{
    static const int ops[] = {MCPW_FADD3, MCPW_FSUB3, MCPW_FMUL3, MCPW_FMA, MCPW_FMS, MCPW_VMOVE, MCPW_VADD,
                              MCPW_VSUB, MCPW_VMUL, MCPW_VSCALE, MCPW_VDOT3, MCPW_VDOT4, MCPW_VCROSS,
                              MCPW_VNORM3, MCPW_MLOAD, MCPW_MSTORE, MCPW_MXV, MCPW_MTXV, MCPW_MMUL};
    static mcp_state s;
    for (long i = 0; i < n; i++) {
        memset(&s, 0, sizeof s);
        s.stage = 3;
        mcp_reset(&s);
        for (int k = 0; k < 16; k++) {
            /* (mostly ordinary values: NaN-free vectors exercise the arithmetic) */
            s.f[k] = rnd32() % 8 ? bf((float)((int32_t)rnd32() % 20000) / (float)(1 + rnd32() % 256)) : pick();
            s.m[k] = rnd32() % 8 ? bf((float)((int32_t)rnd32() % 20000) / (float)(1 + rnd32() % 256)) : pick();
        }
        int op = ops[rnd32() % (sizeof ops / sizeof ops[0])], rm = (int)(rnd32() % 4);
        int d = (int)(rnd32() % 16), sr = (int)(rnd32() % 16), t = (int)(rnd32() % 16);
        uint32_t hf[16], hm[16];
        memcpy(hf, s.f, sizeof hf);
        memcpy(hm, s.m, sizeof hm);
        s.mctrl = (uint8_t)rm;
        feclearexcept(FE_ALL_EXCEPT);
        host_wide(op, d, sr, t, rm, hf, hm);
        int wf = hostfl();
        mcp_exec_wide(&s, op, d << 4 | sr, t << 4);
        int ok = (s.mflags & ~MCP_FL_UNDERFLOW) == wf && !(s.sticky & 0x08);
        for (int k = 0; k < 16; k++) ok = ok && same(s.f[k], hf[k]) && same(s.m[k], hm[k]);
        ntest++;
        if (!ok) {
            char what[64];
            snprintf(what, sizeof what, "wide op %02X d %d s %d t %d", op, d, sr, t);
            fail(what, s.f[sr & 15], s.f[t], rm, s.mflags, (uint32_t)wf, s.mflags, wf);
        }
    }
    /* each stage has only its own forms */
    for (int stage = 0; stage <= 3; stage++)
        for (int k = 0; k < (int)(sizeof ops / sizeof ops[0]); k++) {
            memset(&s, 0, sizeof s);
            s.stage = stage;
            mcp_reset(&s);
            mcp_exec_wide(&s, ops[k], 0x12, 0x30);
            int want = stage < 2 || (stage < 3 && ops[k] > MCPW_FMS);
            ntest++;
            if (!!(s.sticky & 0x08) != want)
                fail("wide form in the wrong stage", (uint32_t)stage, (uint32_t)ops[k], 0, s.sticky, 0, 0, 0);
        }
}

/* ---- MCP-2: programs against a separate interpreter of MCP2.md's rules ---- */

static mcp_cmd rnd_cmd(int stage)
{
    mcp_cmd c;
    static const int safe[] = {MCP_FADD, MCP_FSUB, MCP_FMUL, MCP_FMOVE, MCP_FCMP, MCP_FMIN, MCP_FMAX,
                               MCP_FABS, MCP_FNEG, MCP_FCONST, MCP_FDIV, MCP_FSQRT, MCP_FXCHG, MCP_FTOI};
    memset(&c, 0, sizeof c);
    c.regs = (uint8_t)rnd32();
    int k = (int)(rnd32() % 100);
    if (stage >= 5 && k < 12) {                                  /* (stage 5: clip codes and skips) */
        if (k < 5) { c.form = 0; c.op = MCP_VCLIP; }
        else { c.form = 2; c.op = MCPW_PSKIP; c.regs = (uint8_t)(1u << (rnd32() % 8) | (rnd32() % 4 ? 0 : rnd32()));
               c.v = (rnd32() % 16) << 4; }
        return c;
    }
    if (k < 55) { c.form = 0; c.op = (uint8_t)safe[rnd32() % (sizeof safe / sizeof safe[0])]; }
    else if (k < 65) { c.form = 0; c.op = MCP_PEXIT; c.regs = (uint8_t)(1 << (rnd32() % 4)); }
    else if (k < 77) { c.form = 0; c.op = MCP_PEND; }
    else if (k < 87) { c.form = 1; c.op = (uint8_t)(0x80 + rnd32() % 11); c.v = pick(); }
    else if (k < 93 && stage >= 2) { c.form = 2; c.op = (uint8_t)(rnd32() % 5); c.v = (rnd32() % 16) << 4; }
    else if (k < 96) { c.form = 1; c.op = 0x80 + MCPM_PRUN; c.v = rnd32(); }       /* (nesting: an abort) */
    else if (k < 98) { c.form = 0; c.op = (uint8_t)(MCP_NREGOPS2 + rnd32() % 10); }  /* (reserved: an abort) */
    else { c.form = 2; c.op = 0x7F; }                                                /* (reserved wide) */
    return c;
}

static int is_bad(const mcp_state *s, const mcp_cmd *c)
{
    if (c->form == 3) return 1;
    if (c->form == 0)
        return c->op >= MCP_NREGOPS2 && !(s->stage >= 4 && (c->op == MCP_VNEXT || c->op == MCP_VPASS
                                                             || c->op == MCP_VEND))
               && !(s->stage >= 5 && c->op == MCP_VCLIP);
    if (c->form == 1) return (c->op & 15) >= 14;
    if (s->stage < 2) return 1;
    return !(c->op <= MCPW_FMS || (s->stage >= 3 && ((c->op >= MCPW_VMOVE && c->op <= MCPW_VNORM3)
                                                     || (c->op >= MCPW_MLOAD && c->op <= MCPW_MMUL)))
             || (s->stage >= 4 && c->op >= MCPW_VIN && c->op <= MCPW_VOUTC));
}

/* MCP2.md "Programs", written again from the text */
static void interpret(mcp_state *s, int start, uint32_t count)
{
    uint32_t total = count ? count : 65536, passes = 0, steps = 0, limit = s->mplimit & 0xFFFFFF;
    int pc = start, err = 0;
    s->mperr = 0;
    while (1) {
        if (pc >= 512) { err = MCP_ERR_END; break; }
        if (limit != 0 && steps >= limit) { err = MCP_ERR_LIMIT; break; }
        const mcp_cmd *c = &s->prog[pc];
        steps++;
        if (c->form == 0 && c->op == MCP_PEXIT) {
            if (s->mcond & c->regs) break;
            pc++;
        } else if (s->stage >= 5 && c->form == 2 && c->op == MCPW_PSKIP) {
            pc += 1 + ((s->mcond & c->regs) ? (int)((c->v >> 4) & 15) : 0);
        } else if (c->form == 0 && c->op == MCP_PEND) {
            passes++;
            if (passes >= total) break;
            pc = start;
        } else if (is_bad(s, c)) {
            err = MCP_ERR_BADOP;
            break;
        } else {
            if (c->form == 2) mcp_exec_wide(s, c->op, c->regs, (int)c->v);
            else mcp_exec(s, c->op, c->regs, c->v);
            pc++;
        }
    }
    s->mpcnt = (uint16_t)passes;
    if (err) { s->mperr = (uint8_t)err; s->sticky |= 0x20; }
}

static void program_checks(long n)
{
    static mcp_state x, y;
    for (long i = 0; i < n; i++) {
        memset(&x, 0, sizeof x);
        x.stage = 1 + (int)(rnd32() % 5);
        mcp_reset(&x);
        for (int k = 0; k < 16; k++) x.f[k] = pick();
        x.mctrl = (uint8_t)(rnd32() % 4);
        int start = (int)(rnd32() % 512), len = 1 + (int)(rnd32() % 24);
        if (rnd32() % 4 == 0) start = 512 - len + (int)(rnd32() % 3);   /* (near the end: running past it) */
        if (start > 511) start = 511;
        for (int k = 0; k < len && start + k < 512; k++) x.prog[start + k] = rnd_cmd(x.stage);
        if (rnd32() % 3 && start + len - 1 < 512) {                       /* (mostly ending a pass) */
            x.prog[start + len - 1].form = 0;
            x.prog[start + len - 1].op = MCP_PEND;
        }
        uint32_t count = rnd32() % 5 ? 1 + rnd32() % 40 : 0;
        x.mplimit = rnd32() % 4 ? (uint32_t)(rnd32() % 200) : 0;         /* (small: the limit's edge) */
        y = x;
        mcp_exec(&x, 0x80 + MCPM_PRUN, 0, (uint32_t)start | (count & 0xFFFF) << 16);
        interpret(&y, start, count & 0xFFFF);
        ntest++;
        if (memcmp(x.f, y.f, sizeof x.f) || memcmp(x.m, y.m, sizeof x.m) || x.mint != y.mint
            || x.mcond != y.mcond || x.mflags != y.mflags || x.mctrl != y.mctrl || x.sticky != y.sticky
            || x.mpcnt != y.mpcnt || x.mperr != y.mperr || memcmp(x.vout, y.vout, sizeof x.vout))
            fail("program", (uint32_t)start, count, x.stage, x.mpcnt, y.mpcnt, x.mperr, y.mperr);
    }
}

/* the stream and MPLOAD ports against the commands given directly, every stage */
static void stream_checks(long n)
{
    static mcp_state x, y, z;
    for (long t = 0; t < n; t++) {
        memset(&x, 0, sizeof x);
        memset(&y, 0, sizeof y);
        x.stage = y.stage = (int)(t % 4);
        mcp_reset(&x);
        mcp_reset(&y);
        z = x;
        int len = 1 + (int)(rnd32() % 40), np = 0;
        mcp_cmd want[40];
        for (int i = 0; i < len; i++) {
            int op, regs = (int)(rnd32() & 0xFF), r2 = (int)(rnd32() & 0xF0);
            uint32_t v = pick();
            int k = (int)(rnd32() % 10);
            if (k < 4) op = (int)(rnd32() % MCP_NREGOPS2);
            else if (k < 7) op = 0x80 + (int)(rnd32() % 16);
            else if (k < 9) op = 0x90;
            else op = (int)(rnd32() & 0xFF);                 /* reserved ones too */
            if (op == 0x80 + MCPM_PRUN) op = 0x80 + MCPM_PRUN - 1;   /* (programs: program_checks) */
            if (op == MCP_SETCTRL) regs &= 3;
            uint8_t bytes[6];
            int nb;
            if (op == 0x90 && x.stage >= 1) {
                int wop = (int)(rnd32() % 0x30);
                mcp_exec_wide(&x, wop, regs, r2);
                bytes[0] = 0x90; bytes[1] = (uint8_t)wop; bytes[2] = (uint8_t)regs; bytes[3] = (uint8_t)r2;
                nb = 4;
                want[np].form = 2; want[np].op = (uint8_t)wop; want[np].regs = (uint8_t)regs; want[np].v = (uint32_t)r2;
            } else {
                mcp_exec(&x, op, regs, v);
                bytes[0] = (uint8_t)op; bytes[1] = (uint8_t)regs; bytes[2] = (uint8_t)v;
                bytes[3] = (uint8_t)(v >> 8); bytes[4] = (uint8_t)(v >> 16); bytes[5] = (uint8_t)(v >> 24);
                nb = op >= 0x80 && op <= 0x8F ? 6 : 2;
                want[np].form = (uint8_t)(op < 0x80 ? 0 : nb == 6 ? 1 : 3);
                want[np].op = (uint8_t)op;
                want[np].regs = (uint8_t)regs;
                want[np].v = nb == 6 ? v : 0;
            }
            np++;
            for (int j = 0; j < nb; j++) {
                mcp_stream(&y, bytes[j]);
                if (z.stage >= 1) mcp_mpload(&z, bytes[j]);
            }
        }
        ntest++;
        if (memcmp(x.f, y.f, sizeof x.f) || memcmp(x.m, y.m, sizeof x.m) || x.mint != y.mint
            || x.mcond != y.mcond || x.mflags != y.mflags || x.mctrl != y.mctrl || x.sticky != y.sticky || y.sn)
            fail("stream", (uint32_t)x.stage, 0, 0, 0, 0, 0, 0);
        if (z.stage >= 1) {                                  /* MPLOAD stored them, MPREAD gives them back */
            ntest++;
            int ok = z.mpptr == np && z.ln == 0;
            for (int i = 0; i < np && ok; i++) {
                uint8_t rb[8];
                z.mpptr = (uint16_t)i;
                mcp_mpread(&z, rb);
                ok = rb[0] == want[i].form && rb[1] == want[i].op && rb[2] == want[i].regs
                     && (rb[3] | rb[4] << 8 | rb[5] << 16 | (uint32_t)rb[6] << 24) == want[i].v && rb[7] == 0;
            }
            if (!ok) fail("MPLOAD", (uint32_t)z.stage, (uint32_t)np, 0, z.mpptr, 0, 0, 0);
        }
    }
}

/* ---- MCP-3 stage 1: the vertex path against the host ---- */

/* the host's VOUT conversion (MCP3.md): v x 2^k, rounded by rm, NaN 0,
 * saturated */
static uint32_t host_vconv(uint32_t v, int fmt, int rm, int *fl)
{
    static const struct { int k; long lo, hi; } c[8] = {
        [MCPV_S12_4] = {4, -32768, 32767}, [MCPV_U16] = {16, 0, 65535}, [MCPV_S16] = {0, -32768, 32767},
        [MCPV_S16_16] = {16, -2147483648L, 2147483647L}, [MCPV_U8] = {8, 0, 255}
    };
    *fl = 0;
    if (fmt == MCPV_F32 || fmt == MCPV_F32HI) return v;
    return (uint32_t)host_toint(ldexp((double)fb(v), c[fmt].k), rm, c[fmt].lo, c[fmt].hi, fl);
}

/* random vertex-path commands on the model and on the host, the state
 * compared after each: VIN, VNEXT, VOUT, VOUTC, VPASS, VEND */
static void vertex_checks(long n)
{
    static mcp_state x;
    static uint8_t vout[32768];
    uint32_t f[16];
    memset(&x, 0, sizeof x);
    x.stage = 5;
    mcp_reset(&x);
    for (int i = 0; i < 16384; i++) x.vin[i] = (uint8_t)rnd32();
    for (int i = 0; i < 16; i++) x.f[i] = pick();
    for (long it = 0; it < n; it++) {
        if (rnd32() % 64 == 0) {                             /* a new format, place, entry */
            x.vfmt = (uint8_t)(rnd32() & 0x1F);
            x.vposexp = (uint8_t)(rnd32() & 15);
            x.vinidx = (uint16_t)(rnd32() & 0x3FFC);
            x.vtxidx = (uint16_t)(rnd32() & 1023);
            for (int i = 0; i < 64; i++) {                   /* some FP32 values worth reading */
                uint32_t w = pick();
                memcpy(&x.vin[(x.vinidx + 4 * (i % 8)) & 0x3FFC], &w, 4);
            }
        }
        if (rnd32() % 8 == 0) x.f[rnd32() % 16] = pick();
        memcpy(f, x.f, sizeof f);
        memcpy(vout, x.vout, sizeof vout);
        int fmt = x.vfmt, rm = (int)(rnd32() % 4), hfl = 0;
        uint16_t vinidx = x.vinidx, vtxidx = x.vtxidx;
        uint8_t mflags0 = x.mflags, sticky0 = x.sticky, mcond = x.mcond;
        x.mctrl = (uint8_t)rm;
        int k = (int)(rnd32() % 7), d = (int)(rnd32() % 16), sr = (int)(rnd32() % 16), t = (int)(rnd32() % 16);
        if (k == 6 && rnd32() % 2) {                         /* (VCLIP: values near the planes) */
            float w = fb(pick()), c[3];
            for (int j = 0; j < 3; j++) c[j] = rnd32() % 2 ? w * (float)((int)(rnd32() % 5) - 2) / 2.0f : fb(pick());
            for (int j = 0; j < 3; j++) x.f[4 * (sr & 3) + j] = bf(c[j]);
            x.f[4 * (sr & 3) + 3] = bf(w);
            memcpy(f, x.f, sizeof f);
        }
        int bad = 0, base = vtxidx * 32;
        if (k == 0) {                                        /* VIN Vd, t (t 0-3) */
            t &= 3;
            mcp_exec_wide(&x, MCPW_VIN, d << 4 | sr, t << 4);
            int off = mcp_vfmt_offset(fmt, t);
            if (t == 3 || off < 0) bad = 1;
            else {
                int a = vinidx + off;
                #define VB(j) x.vin[(a + (j)) & 0x3FFF]
                uint32_t *vd = &f[4 * (d & 3)];
                for (int c = 0; c < 4; c++) {
                    float r;
                    if (t == 0 && (fmt & 1)) {
                        uint32_t w = c < 3 ? (uint32_t)VB(4 * c) | (uint32_t)VB(4 * c + 1) << 8
                                             | (uint32_t)VB(4 * c + 2) << 16 | (uint32_t)VB(4 * c + 3) << 24
                                           : bf(1.0f);
                        vd[c] = w;
                        continue;
                    }
                    if (t == 0) r = c < 3 ? ldexpf((float)(int16_t)(VB(2 * c) | VB(2 * c + 1) << 8), -x.vposexp) : 1.0f;
                    else if (t == 1) r = c < 3 ? (float)(int8_t)VB(c) / 128.0f : 0.0f;
                    else r = (float)VB(c) / 256.0f;
                    vd[c] = bf(r);
                }
                #undef VB
            }
        } else if (k == 1) {                                 /* VNEXT */
            mcp_exec(&x, MCP_VNEXT, 0, 0);
            vinidx = (uint16_t)((vinidx + mcp_vfmt_size(fmt)) & 0x3FFC);
        } else if (k == 2) {                                 /* VOUT Fs, format d, byte 2t */
            static const int width[6] = {4, 2, 2, 2, 2, 4};
            d %= 8;
            mcp_exec_wide(&x, MCPW_VOUT, d << 4 | sr, t << 4);
            if (d >= MCPV_NFMT || (width[d] == 4 && (t & 1))) bad = 1;
            else {
                uint32_t v = host_vconv(f[sr], d, rm, &hfl);
                if (d == MCPV_F32HI) v = f[sr] >> 16;
                for (int j = 0; j < width[d]; j++) vout[base + ((2 * t + j) & 31)] = (uint8_t)(v >> (8 * j));
            }
        } else if (k == 3) {                                 /* VOUTC Vs, byte 2t */
            mcp_exec_wide(&x, MCPW_VOUTC, d << 4 | sr, t << 4);
            if (t & 1) bad = 1;
            else for (int j = 0; j < 4; j++) {
                int fl;
                vout[base + ((2 * t + j) & 31)] = (uint8_t)host_vconv(f[4 * (sr & 3) + j], MCPV_U8, rm, &fl);
                hfl |= fl;
            }
        } else if (k == 4) {                                 /* VPASS w */
            int w = (int)(rnd32() & 0xFF), na = (fmt >> 3) & 3, a = vinidx + mcp_vfmt_offset(fmt, 3);
            mcp_exec(&x, MCP_VPASS, w, 0);
            for (int j = 0; j < na; j++)
                for (int b = 0; b < 4; b++)
                    vout[base + 4 * ((w + j) & 7) + b] = x.vin[(a + 4 * j + b) & 0x3FFF];
        } else if (k == 5) {                                 /* VEND */
            mcp_exec(&x, MCP_VEND, 0, 0);
            vtxidx = (uint16_t)((vtxidx + 1) & 1023);
        } else {                                             /* VCLIP Vs: the host's compares */
            mcp_exec(&x, MCP_VCLIP, sr, 0);
            const uint32_t *v = &f[4 * (sr & 3)];
            float vx = fb(v[0]), vy = fb(v[1]), vz = fb(v[2]), vw = fb(v[3]);
            if (isn(v[0]) || isn(v[1]) || isn(v[2]) || isn(v[3])) mcond = 0x80;
            else mcond = (uint8_t)((vx < -vw) | (vx > vw) << 1 | (vy < -vw) << 2 | (vy > vw) << 3
                                   | (vz < 0.0f) << 4 | (vz > vw) << 5 | !(vw > 0.0f) << 6);
            vout[base + 30] = mcond;
        }
        ntest++;
        uint8_t wflags = (uint8_t)(mflags0 | hfl), wsticky = (uint8_t)(sticky0 | (bad ? 0x08 : 0));
        if (memcmp(f, x.f, sizeof f) || memcmp(vout, x.vout, sizeof vout) || vinidx != x.vinidx
            || vtxidx != x.vtxidx || wflags != x.mflags || wsticky != x.sticky || mcond != x.mcond)
            fail("vertex", (uint32_t)k, (uint32_t)fmt, rm, x.mflags, wflags, x.sticky, wsticky);
        x.mflags = 0;
        x.sticky = 0;
    }
}

int main(int argc, char **argv)
{
    if (argc < 2) {
        fprintf(stderr, "usage: mcpcheck <testfloat_gen> [level]\n");
        return 2;
    }
    const char *gen = argv[1], *level = argc > 2 ? argv[2] : "1";
    tf_run(gen, level, "f32_add", "", MCP_FADD, 0);
    tf_run(gen, level, "f32_sub", "", MCP_FSUB, 0);
    tf_run(gen, level, "f32_sub", "", MCP_FSUBR, 1);
    tf_run(gen, level, "f32_mul", "", MCP_FMUL, 0);
    tf_run(gen, level, "f32_div", "", MCP_FDIV, 0);
    tf_run(gen, level, "f32_div", "", MCP_FDIVR, 1);
    tf_run(gen, level, "f32_sqrt", "", MCP_FSQRT, 2);
    tf_run(gen, level, "f32_roundToInt", "-notexact", MCP_FRINT, 2);
    tf_run(gen, level, "f32_roundToInt", "-notexact", MCP_FTRUNC, 2);
    tf_run(gen, level, "f32_to_i32", "-exact", MCP_FTOI, 3);
    tf_run(gen, level, "i32_to_f32", "", MCP_ILD, 4);
    tf_run(gen, level, "f32_eq", "", MCP_FCMP, 5);
    tf_run(gen, level, "f32_lt_quiet", "", MCP_FCMP, 6);
    tf_run(gen, level, "f32_le_quiet", "", MCP_FCMP, 7);
    tf_run(gen, level, "f32_mulAdd", "", -1, 8);
    long ntf = ntest;
    host_checks(2000000);
    long nhost = ntest - ntf;
    wide_checks(1000000);
    long nwide = ntest - ntf - nhost;
    program_checks(200000);
    long nprog = ntest - ntf - nhost - nwide;
    stream_checks(20000);
    long nstream = ntest - ntf - nhost - nwide - nprog;
    vertex_checks(1000000);
    printf("mcpcheck: %ld TestFloat vectors, %ld host checks, %ld wide forms, %ld programs, "
           "%ld streams, %ld vertex commands: %ld differences\n", ntf, nhost, nwide, nprog, nstream,
           ntest - ntf - nhost - nwide - nprog - nstream, nfail);
    return nfail != 0;
}

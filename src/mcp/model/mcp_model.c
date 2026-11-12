/* mcp_model: the reference for the M65-MCP (spec in mcp_model.h, src/mcp/MCP1.md, MCP2.md). */
#include <string.h>
#include "softfloat.h"
#include "mcp_model.h"

const uint32_t mcp_const[16] = {
    0x00000000, 0x3F800000, 0x40000000, 0x3F000000,   /* 0, 1, 2, 0.5 */
    0x41200000, 0x40490FDB, 0x3FC90FDB, 0x40C90FDB,   /* 10, pi, pi/2, 2pi */
    0x402DF854, 0x3F317218, 0x3FB8AA3B, 0x3E9A209B,   /* e, ln 2, log2 e, log10 2 */
    0x3FB504F3, 0x3F3504F3, 0x7F800000, MCP_DEFAULT_NAN  /* sqrt 2, 1/sqrt 2, +inf, NaN */
};

static float32_t F(uint32_t v) { float32_t f; f.v = v; return f; }

static int is_nan(uint32_t v) { return (v & 0x7F800000) == 0x7F800000 && (v & 0x007FFFFF); }
static int is_snan(uint32_t v) { return is_nan(v) && !(v & 0x00400000); }

/* SoftFloat's rounding mode for MCTRL's */
static uint_fast8_t sf_mode(int rm)
{
    static const uint_fast8_t m[4] = {
        softfloat_round_near_even, softfloat_round_min, softfloat_round_max, softfloat_round_minMag
    };
    return m[rm & 3];
}

/* SoftFloat's flags as MFLAGS bits */
static uint8_t mflags_of(uint_fast8_t f)
{
    return (uint8_t)((f & softfloat_flag_invalid ? MCP_FL_INVALID : 0)
                   | (f & softfloat_flag_infinite ? MCP_FL_DIVZERO : 0)
                   | (f & softfloat_flag_overflow ? MCP_FL_OVERFLOW : 0)
                   | (f & softfloat_flag_underflow ? MCP_FL_UNDERFLOW : 0)
                   | (f & softfloat_flag_inexact ? MCP_FL_INEXACT : 0));
}

/* minNum / maxNum (IEEE 754-2008) with -0 below +0 */
static uint32_t minmax(uint32_t a, uint32_t b, int max, uint8_t *fl)
{
    if (is_snan(a) || is_snan(b)) {
        *fl |= MCP_FL_INVALID;
        return MCP_DEFAULT_NAN;
    }
    if (is_nan(a) && is_nan(b)) return MCP_DEFAULT_NAN;
    if (is_nan(a)) return b;
    if (is_nan(b)) return a;
    if (((a | b) & 0x7FFFFFFF) == 0)              /* two zeros: by sign */
        return max ? (a & b) : (a | b);
    int a_lt_b = f32_lt_quiet(F(a), F(b));
    return (a_lt_b != max) ? a : b;
}

static uint8_t class_of(uint32_t v)
{
    uint8_t c = (uint8_t)(v >> 31);
    uint32_t e = (v >> 23) & 0xFF, m = v & 0x007FFFFF;
    if (e == 0) c |= m ? 0x04 : 0x02;             /* subnormal / zero */
    else if (e < 0xFF) c |= 0x08;                 /* normal */
    else if (!m) c |= 0x10;                       /* infinity */
    else c |= (m & 0x00400000) ? 0x20 : 0x40;     /* quiet / signalling NaN */
    return c;
}

mcp_res mcp_core(int op, uint32_t a, uint32_t b, int rmode)
{
    mcp_res res;
    memset(&res, 0, sizeof res);
    softfloat_roundingMode = sf_mode(rmode);
    softfloat_detectTininess = softfloat_tininess_afterRounding;
    softfloat_exceptionFlags = 0;
    uint8_t extra = 0;                            /* flags not raised through SoftFloat */
    res.wr_f = 1;
    switch (op) {
    case MCP_FMOVE: res.r = b; break;
    case MCP_FADD:  res.r = f32_add(F(a), F(b)).v; break;
    case MCP_FSUB:  res.r = f32_sub(F(a), F(b)).v; break;
    case MCP_FSUBR: res.r = f32_sub(F(b), F(a)).v; break;
    case MCP_FMUL:  res.r = f32_mul(F(a), F(b)).v; break;
    case MCP_FDIV:  res.r = f32_div(F(a), F(b)).v; break;
    case MCP_FDIVR: res.r = f32_div(F(b), F(a)).v; break;
    case MCP_FRECIP: res.r = f32_div(F(0x3F800000), F(b)).v; break;
    case MCP_FSQRT: res.r = f32_sqrt(F(b)).v; break;
    case MCP_FABS:  res.r = b & 0x7FFFFFFF; break;
    case MCP_FNEG:  res.r = b ^ 0x80000000; break;
    case MCP_FRINT: res.r = f32_roundToInt(F(b), sf_mode(rmode), false).v; break;
    case MCP_FTRUNC: res.r = f32_roundToInt(F(b), softfloat_round_minMag, false).v; break;
    case MCP_FMIN:  res.r = minmax(a, b, 0, &extra); break;
    case MCP_FMAX:  res.r = minmax(a, b, 1, &extra); break;
    case MCP_FCONST: res.r = mcp_const[b & 15]; break;
    case MCP_FCMP:
        res.wr_f = 0;
        res.wr_cond = 1;
        if (is_nan(a) || is_nan(b)) {
            res.cond = 0x08;
            if (is_snan(a) || is_snan(b)) extra |= MCP_FL_INVALID;
        } else if (f32_eq(F(a), F(b))) res.cond = 0x02;
        else if (f32_lt_quiet(F(a), F(b))) res.cond = 0x01;
        else res.cond = 0x04;
        softfloat_exceptionFlags = 0;             /* (the quiet compares raise nothing here) */
        break;
    case MCP_FCLASS:
        res.wr_f = 0;
        res.wr_cond = 1;
        res.cond = class_of(b);
        break;
    case MCP_FTOI:
        res.wr_f = 0;
        res.wr_mint = 1;
        res.mint = (uint32_t)f32_to_i32(F(b), sf_mode(rmode), true);
        break;
    case MCP_FTOX:                                /* round(b * 2^16), the product exact in f64 */
        res.wr_f = 0;
        res.wr_mint = 1;
        res.mint = (uint32_t)f64_to_i32(f64_mul(f32_to_f64(F(b)), (float64_t){0x40F0000000000000ull}),
                                        sf_mode(rmode), true);
        break;
    case MCP_FTOI16: {
        res.wr_f = 0;
        res.wr_mint = 1;
        int32_t v = f32_to_i32(F(b), sf_mode(rmode), true);
        if (softfloat_exceptionFlags & softfloat_flag_invalid) {
            v = is_nan(b) ? 0 : (b >> 31) ? -32768 : 32767;
        } else if (v > 32767 || v < -32768) {     /* the rounded integer does not fit */
            v = v > 0 ? 32767 : -32768;
            softfloat_exceptionFlags = softfloat_flag_invalid;
        }
        res.mint = (uint32_t)v;
        break;
    }
    case MCP_ILD: res.r = i32_to_f32((int32_t)b).v; break;
    case MCP_XLD: {                               /* round(v) * 2^-16: exact scaling, |result| >= 2^-16 */
        uint32_t r = i32_to_f32((int32_t)b).v;
        res.r = (r & 0x7FFFFFFF) ? r - (16u << 23) : r;
        break;
    }
    default:                                      /* (not a core operation) */
        res.wr_f = 0;
        break;
    }
    res.flags = (uint8_t)(mflags_of(softfloat_exceptionFlags) | extra);
    return res;
}

uint32_t mcp_fma(uint32_t a, uint32_t b, uint32_t c, int rmode, uint8_t *flags)
{
    softfloat_roundingMode = sf_mode(rmode);
    softfloat_detectTininess = softfloat_tininess_afterRounding;
    softfloat_exceptionFlags = 0;
    uint32_t r = f32_mulAdd(F(a), F(b), F(c)).v;
    *flags |= mflags_of(softfloat_exceptionFlags);
    return r;
}

void mcp_reset(mcp_state *s)
{
    static mcp_cmd keep[512];                       /* (MRESET keeps the program memory) */
    int stage = s->stage;
    memcpy(keep, s->prog, sizeof keep);
    memset(s, 0, sizeof *s);
    memcpy(s->prog, keep, sizeof keep);
    s->stage = stage;
    s->mplimit = 0x100000;
}

/* ---- commands ---- */

enum { X_OK, X_EXIT, X_END, X_BAD };      /* exec_cmd: go on, PEXIT taken, PEND, a bad command */

static uint32_t op2(mcp_state *s, int op, uint32_t a, uint32_t b, uint8_t *fl)
{
    mcp_res r = mcp_core(op, a, b, s->mctrl & 3);
    *fl |= r.flags;
    return r.r;
}

/* a . b over n components, a[k], b[k] at the given strides: the first a
 * product, the rest fused, left to right (MCP2.md "Arithmetic") */
static uint32_t dot(mcp_state *s, const uint32_t *a, int sa, const uint32_t *b, int sb, int n, uint8_t *fl)
{
    uint32_t d = op2(s, MCP_FMUL, a[0], b[0], fl);
    for (int k = 1; k < n; k++)
        d = mcp_fma(a[k * sa], b[k * sb], d, s->mctrl & 3, fl);
    return d;
}

/* a wide form: X_OK, or X_BAD for a reserved one (or one the stage lacks) */
static int exec_wide(mcp_state *s, int op, int r1, int r2)
{
    int d = (r1 >> 4) & 15, a = r1 & 15, t = (r2 >> 4) & 15, rm = s->mctrl & 3;
    uint32_t *vd = &s->f[4 * (d & 3)], *vs = &s->f[4 * (a & 3)], *vt = &s->f[4 * (t & 3)];
    uint32_t tmp[16];
    uint8_t fl = 0;
    if (s->stage >= 2 && op <= MCPW_FMS) {
        switch (op) {
        case MCPW_FADD3: s->f[d] = op2(s, MCP_FADD, s->f[a], s->f[t], &fl); break;
        case MCPW_FSUB3: s->f[d] = op2(s, MCP_FSUB, s->f[a], s->f[t], &fl); break;
        case MCPW_FMUL3: s->f[d] = op2(s, MCP_FMUL, s->f[a], s->f[t], &fl); break;
        case MCPW_FMA:   s->f[d] = mcp_fma(s->f[a], s->f[t], s->f[d], rm, &fl); break;
        default:         s->f[d] = mcp_fma(s->f[a] ^ 0x80000000u, s->f[t], s->f[d], rm, &fl); break;
        }
    } else if (s->stage >= 3 && op >= MCPW_VMOVE && op <= MCPW_VNORM3) {
        switch (op) {
        case MCPW_VMOVE:
            memcpy(tmp, vs, 16);
            memcpy(vd, tmp, 16);
            break;
        case MCPW_VADD: case MCPW_VSUB: case MCPW_VMUL: {
            int o = op == MCPW_VADD ? MCP_FADD : op == MCPW_VSUB ? MCP_FSUB : MCP_FMUL;
            for (int k = 0; k < 4; k++) tmp[k] = op2(s, o, vs[k], vt[k], &fl);
            memcpy(vd, tmp, 16);
            break;
        }
        case MCPW_VSCALE:
            for (int k = 0; k < 4; k++) tmp[k] = op2(s, MCP_FMUL, vs[k], s->f[t], &fl);
            memcpy(vd, tmp, 16);
            break;
        case MCPW_VDOT3: s->f[d] = dot(s, vs, 1, vt, 1, 3, &fl); break;
        case MCPW_VDOT4: s->f[d] = dot(s, vs, 1, vt, 1, 4, &fl); break;
        case MCPW_VCROSS:
            tmp[0] = mcp_fma(vs[1], vt[2], op2(s, MCP_FMUL, vs[2], vt[1], &fl) ^ 0x80000000u, rm, &fl);
            tmp[1] = mcp_fma(vs[2], vt[0], op2(s, MCP_FMUL, vs[0], vt[2], &fl) ^ 0x80000000u, rm, &fl);
            tmp[2] = mcp_fma(vs[0], vt[1], op2(s, MCP_FMUL, vs[1], vt[0], &fl) ^ 0x80000000u, rm, &fl);
            tmp[3] = 0;
            memcpy(vd, tmp, 16);
            break;
        default: {                                      /* VNORM3 */
            uint32_t n = dot(s, vs, 1, vs, 1, 3, &fl);
            uint32_t r = op2(s, MCP_FSQRT, 0, n, &fl);
            uint32_t q = op2(s, MCP_FDIV, 0x3F800000u, r, &fl);
            for (int k = 0; k < 3; k++) tmp[k] = op2(s, MCP_FMUL, vs[k], q, &fl);
            tmp[3] = vs[3];
            memcpy(vd, tmp, 16);
            break;
        }
        }
    } else if (s->stage >= 3 && op >= MCPW_MLOAD && op <= MCPW_MMUL) {
        switch (op) {
        case MCPW_MLOAD: memcpy(s->m, s->f, sizeof s->m); break;
        case MCPW_MSTORE: memcpy(s->f, s->m, sizeof s->f); break;
        case MCPW_MXV:                                   /* row r . Vs */
            for (int r = 0; r < 4; r++) tmp[r] = dot(s, &s->m[4 * r], 1, vs, 1, 4, &fl);
            memcpy(vd, tmp, 16);
            break;
        case MCPW_MTXV:                                  /* column r . Vs */
            for (int r = 0; r < 4; r++) tmp[r] = dot(s, &s->m[r], 4, vs, 1, 4, &fl);
            memcpy(vd, tmp, 16);
            break;
        default:                                         /* MMUL: M = M x F */
            for (int r = 0; r < 4; r++)
                for (int c = 0; c < 4; c++)
                    tmp[4 * r + c] = dot(s, &s->m[4 * r], 1, &s->f[c], 4, 4, &fl);
            memcpy(s->m, tmp, sizeof s->m);
            break;
        }
    } else {
        return X_BAD;
    }
    s->mflags |= fl;
    return X_OK;
}

static void run_program(mcp_state *s, uint32_t v);

/* one command; in_prog: from a program. X_BAD outside a program sets
 * MSTATUS bit 3 and is otherwise ignored; in a program it aborts it. */
static int exec_cmd(mcp_state *s, const mcp_cmd *c, int in_prog)
{
    int d = (c->regs >> 4) & 15, src = c->regs & 15, core = -1;
    uint32_t b = 0;
    int r = X_OK;
    if (c->form == 0) {
        int op = c->op;
        if (op == MCP_SETCTRL) { s->mctrl = (uint8_t)(c->regs & 0x03); return X_OK; }
        if (op == MCP_SETFLAGS) { s->mflags = (uint8_t)(c->regs & 0x1F); return X_OK; }
        if (op == MCP_FXCHG) {
            uint32_t t = s->f[d];
            s->f[d] = s->f[src];
            s->f[src] = t;
            return X_OK;
        }
        if (s->stage >= 1 && op == MCP_PEXIT)
            return in_prog && (s->mcond & c->regs) ? X_EXIT : X_OK;
        if (s->stage >= 1 && op == MCP_PEND)
            return in_prog ? X_END : X_OK;
        if (op >= (s->stage >= 1 ? MCP_NREGOPS2 : MCP_NREGOPS)) r = X_BAD;
        else {
            core = op;
            b = op == MCP_FCONST ? (uint32_t)src : s->f[src];
        }
    } else if (c->form == 1) {
        static const int mem_core[16] = {
            MCP_FMOVE, MCP_FADD, MCP_FSUB, MCP_FSUBR, MCP_FMUL, MCP_FDIV, MCP_FDIVR, MCP_FCMP,
            MCP_FMIN, MCP_FMAX, MCP_FSQRT, MCP_FRECIP, MCP_ILD, MCP_XLD, -1, -1
        };
        int m = c->op & 15;
        if (s->stage >= 1 && m == MCPM_PRUN) {
            if (in_prog) r = X_BAD;                          /* (no nesting) */
            else run_program(s, c->v);
        } else if (mem_core[m] < 0) r = X_BAD;
        else {
            core = mem_core[m];
            b = c->v;
        }
    } else if (c->form == 2) {
        r = s->stage >= 1 ? exec_wide(s, c->op, c->regs, (int)(c->v & 0xFF)) : X_BAD;
    } else {
        r = X_BAD;
    }
    if (r == X_BAD) {
        if (in_prog) return X_BAD;
        s->sticky |= 0x08;
        return X_OK;
    }
    if (core >= 0) {
        mcp_res res = mcp_core(core, s->f[d], b, s->mctrl & 3);
        if (res.wr_f) s->f[d] = res.r;
        if (res.wr_mint) s->mint = res.mint;
        if (res.wr_cond) s->mcond = res.cond;
        s->mflags |= res.flags;
    }
    return X_OK;
}

/* PRUN v: the program at v bits 0-8, at most v bits 16-31 passes (0: 65,536) */
static void run_program(mcp_state *s, uint32_t v)
{
    int start = (int)(v & 511), pc = start, code = 0;
    uint32_t total = v >> 16, done = 0, executed = 0, limit = s->mplimit & 0xFFFFFF;
    if (!total) total = 65536;
    s->mperr = 0;
    for (;;) {
        if (pc > 511) { code = MCP_ERR_END; break; }
        if (limit && executed == limit) { code = MCP_ERR_LIMIT; break; }
        executed++;
        int r = exec_cmd(s, &s->prog[pc], 1);
        if (r == X_BAD) { code = MCP_ERR_BADOP; break; }
        if (r == X_EXIT) break;
        if (r == X_END) {
            if (++done == total) break;
            pc = start;
            continue;
        }
        pc++;
    }
    s->mpcnt = (uint16_t)done;
    if (code) {
        s->mperr = (uint8_t)code;
        s->sticky |= 0x20;
    }
}

void mcp_exec(mcp_state *s, int op, int regs, uint32_t v)
{
    mcp_cmd c;
    c.form = op >= 0 && op < 0x80 ? 0 : op >= 0x80 && op <= 0x8F ? 1 : 3;
    c.op = (uint8_t)op;
    c.regs = (uint8_t)regs;
    c.v = v;
    exec_cmd(s, &c, 0);
}

void mcp_exec_wide(mcp_state *s, int op, int regs1, int regs2)
{
    mcp_cmd c;
    c.form = 2;
    c.op = (uint8_t)op;
    c.regs = (uint8_t)regs1;
    c.v = (uint8_t)regs2;
    exec_cmd(s, &c, 0);
}

/* the stream's format: the command's length from its first byte, and the
 * command once collected */
static int cmd_len(const mcp_state *s, uint8_t first)
{
    if (first >= 0x80 && first <= 0x8F) return 6;
    if (first == 0x90 && s->stage >= 1) return 4;
    return 2;
}

static mcp_cmd cmd_of(const uint8_t *b, int n)
{
    mcp_cmd c;
    c.op = b[0];
    c.regs = b[1];
    c.v = 0;
    if (n == 6) {
        c.form = 1;
        c.v = (uint32_t)b[2] | (uint32_t)b[3] << 8 | (uint32_t)b[4] << 16 | (uint32_t)b[5] << 24;
    } else if (n == 4) {
        c.form = 2;
        c.op = b[1];
        c.regs = b[2];
        c.v = b[3];
    } else {
        c.form = b[0] < 0x80 ? 0 : 3;
    }
    return c;
}

void mcp_stream(mcp_state *s, uint8_t byte)
{
    s->sbuf[s->sn++] = byte;
    int n = cmd_len(s, s->sbuf[0]);
    if (s->sn < n) return;
    s->sn = 0;
    mcp_cmd c = cmd_of(s->sbuf, n);
    exec_cmd(s, &c, 0);
}

void mcp_stream_restart(mcp_state *s)
{
    s->sn = 0;
}

void mcp_mpload(mcp_state *s, uint8_t byte)
{
    s->lbuf[s->ln++] = byte;
    int n = cmd_len(s, s->lbuf[0]);
    if (s->ln < n) return;
    s->ln = 0;
    s->prog[s->mpptr & 511] = cmd_of(s->lbuf, n);
    s->mpptr = (uint16_t)((s->mpptr + 1) & 511);
}

void mcp_mpload_restart(mcp_state *s)
{
    s->ln = 0;
}

void mcp_mpread(const mcp_state *s, uint8_t out[8])
{
    const mcp_cmd *c = &s->prog[s->mpptr & 511];
    out[0] = c->form;
    out[1] = c->op;
    out[2] = c->regs;
    for (int k = 0; k < 4; k++) out[3 + k] = (uint8_t)(c->v >> (8 * k));
    out[7] = 0;
}

uint8_t mcp_status(const mcp_state *s)
{
    return (uint8_t)((s->mflags ? 0x80 : 0) | s->sticky);
}

/* mcpvec: test vectors for the arithmetic core (src/vhdl/mcp_fpu.vhdl), with
 * the results mcp_model's mcp_core gives (checked against TestFloat and the
 * host by mcpcheck).
 *
 *   mcpvec <testfloat_gen> <level> <random per op> [seed] > vectors
 *
 * One line a vector, hex: op rm a b c r mint cond flags wr (c: FMA's addend)
 *   wr: bit 0 r is written (Fd), bit 1 mint, bit 2 cond
 * First TestFloat's cases for every function the core implements, in all
 * four rounding modes; then random operands from the interesting places
 * for every core operation and mode, the operations mixed. */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "mcp_model.h"

static long nvec;

#define OP_FMA 0x1E                 /* the core's fused multiply-add: a x b + c */
/* the converter's operations (MCP-3), $16-$1B: VOUT's formats */
#define OP_CV0 0x16
static const int cv_fmt[6] = {MCPV_F32, MCPV_S12_4, MCPV_U16, MCPV_S16, MCPV_S16_16, MCPV_U8};

static void emit3(int op, int rm, uint32_t a, uint32_t b, uint32_t c)
{
    mcp_res m;
    if (op == OP_FMA) {
        memset(&m, 0, sizeof m);
        m.r = mcp_fma(a, b, c, rm, &m.flags);
        m.wr_f = 1;
    } else if (op >= OP_CV0 && op < OP_CV0 + 6) {
        memset(&m, 0, sizeof m);
        m.r = mcp_vout_conv(b, cv_fmt[op - OP_CV0], rm, &m.flags);
        m.wr_f = 1;
    } else {
        m = mcp_core(op, a, b, rm);
    }
    printf("%02X %X %08X %08X %08X %08X %08X %02X %02X %X\n", op, rm, a, b, c, m.r, m.mint, m.cond,
           m.flags, m.wr_f | m.wr_mint << 1 | m.wr_cond << 2);
    nvec++;
}
static void emit(int op, int rm, uint32_t a, uint32_t b) { emit3(op, rm, a, b, 0); }

static const char *tf_mode[4] = {"-rnear_even", "-rmin", "-rmax", "-rminMag"};

/* kind: 0 two operands, 1 swapped, 2 one (b), 3 compare, 4 three (a x b + c) */
static void tf(const char *gen, const char *level, const char *func, const char *extra, int op, int kind)
{
    for (int rm = 0; rm < 4; rm++) {
        if (kind == 3 && rm) continue;
        char cmd[1024];
        snprintf(cmd, sizeof cmd, "%s -level %s -tininessafter %s %s %s", gen, level,
                 kind == 3 ? "" : tf_mode[op == MCP_FTRUNC ? MCP_RM_ZERO : rm], extra, func);
        FILE *p = popen(cmd, "r");
        if (!p) { perror(cmd); exit(2); }
        char line[128];
        unsigned a, b, c3, r, fl;
        while (fgets(line, sizeof line, p)) {
            if (kind == 4) {
                if (sscanf(line, "%x %x %x %x %x", &a, &b, &c3, &r, &fl) == 5) emit3(op, rm, a, b, c3);
            } else if (kind == 2) {
                if (sscanf(line, "%x %x %x", &a, &r, &fl) == 3) emit(op, rm, 0, a);
            } else if (sscanf(line, "%x %x %x %x", &a, &b, &r, &fl) == 4) {
                if (kind == 1) emit(op, rm, b, a); else emit(op, rm, a, b);
            }
        }
        pclose(p);
    }
}

static uint64_t g = 0x9E3779B97F4A7C15ull;
static uint32_t rnd32(void)
{
    g ^= g << 13; g ^= g >> 7; g ^= g << 17;
    return (uint32_t)(g >> 16);
}
static uint32_t bf(float f) { uint32_t v; memcpy(&v, &f, 4); return v; }

static uint32_t pick(void)
{
    switch (rnd32() % 11) {
    case 0: return rnd32();
    case 1: return bf((float)((int32_t)rnd32() % 100000) / (float)(1 + rnd32() % 64));
    case 2: return bf((float)((int32_t)(rnd32() % 200001) - 100000) + 0.5f);
    case 3: {
        static const float lim[] = {32767.0f, 32768.0f, 2147483520.0f, 2147483648.0f, 32767.99f, 8388608.0f};
        uint32_t v = bf(lim[rnd32() % 6]) + (rnd32() % 5) - 2;
        return v ^ (rnd32() & 0x80000000);
    }
    case 4: return rnd32() & 0x807FFFFF;
    case 5: return (rnd32() & 0x80000000) | (rnd32() % 2 ? 0x7F800000 : 0);
    case 6: return 0x7F800000 | (rnd32() & 0x807FFFFF) | 1;
    case 7: return (rnd32() & 0x80000000) | ((uint32_t)(127 + rnd32() % 40) << 23) | (rnd32() & 0x7FFFFF);
    case 8: return (rnd32() & 0x80000000) | ((uint32_t)(rnd32() % 30) << 23) | (rnd32() & 0x7FFFFF);
    case 9: return (rnd32() & 0x80000000) | ((uint32_t)(225 + rnd32() % 30) << 23) | (rnd32() & 0x7FFFFF);
    default: return bf((float)(int32_t)rnd32() / 65536.0f);
    }
}

int main(int argc, char **argv)
{
    if (argc < 4) {
        fprintf(stderr, "usage: mcpvec <testfloat_gen> <level> <random per op> [seed]\n");
        return 2;
    }
    const char *gen = argv[1], *level = argv[2];
    long nr = atol(argv[3]);
    if (argc > 4) g ^= (uint64_t)atol(argv[4]) * 0x2545F4914F6CDD1Dull;
    tf(gen, level, "f32_add", "", MCP_FADD, 0);
    tf(gen, level, "f32_sub", "", MCP_FSUB, 0);
    tf(gen, level, "f32_sub", "", MCP_FSUBR, 1);
    tf(gen, level, "f32_mul", "", MCP_FMUL, 0);
    tf(gen, level, "f32_div", "", MCP_FDIV, 0);
    tf(gen, level, "f32_div", "", MCP_FDIVR, 1);
    tf(gen, level, "f32_sqrt", "", MCP_FSQRT, 2);
    tf(gen, level, "f32_roundToInt", "-notexact", MCP_FRINT, 2);
    tf(gen, level, "f32_roundToInt", "-notexact", MCP_FTRUNC, 2);
    tf(gen, level, "f32_to_i32", "-exact", MCP_FTOI, 2);
    tf(gen, level, "i32_to_f32", "", MCP_ILD, 2);
    tf(gen, level, "f32_eq", "", MCP_FCMP, 3);
    if (!getenv("MCP_FPU_QUICK")) tf(gen, level, "f32_mulAdd", "", OP_FMA, 4);   /* (6 M a mode: the quick runs leave it out) */
    long ntf = nvec;
    static const int ops[] = {
        MCP_FMOVE, MCP_FADD, MCP_FSUB, MCP_FSUBR, MCP_FMUL, MCP_FDIV, MCP_FDIVR, MCP_FCMP,
        MCP_FMIN, MCP_FMAX, MCP_FSQRT, MCP_FABS, MCP_FNEG, MCP_FRINT, MCP_FTRUNC, MCP_FCLASS,
        MCP_FTOI, MCP_FTOX, MCP_FTOI16, MCP_FRECIP, MCP_FCONST, MCP_ILD, MCP_XLD,
        MCP_FXCHG, 0x1F,                                 /* (not core operations: nothing written) */
        OP_FMA, OP_CV0, OP_CV0 + 1, OP_CV0 + 2, OP_CV0 + 3, OP_CV0 + 4, OP_CV0 + 5
    };
    /* (mixed: the core's units get them interleaved, as a program would) */
    const long nops = (long)(sizeof ops / sizeof ops[0]);
    for (long i = 0; i < nr * nops; i++) {
        int o = ops[rnd32() % nops];
        uint32_t a = pick(), b = pick();
        if (o == MCP_ILD || o == MCP_XLD)
            b = rnd32() % 3 ? rnd32() : (rnd32() % 0x1000000) << (rnd32() % 9);
        if (o == MCP_FCONST) b = rnd32() % 16;
        if (o > OP_CV0 && o < OP_CV0 + 6 && rnd32() % 3 == 0) {   /* (near the format's bounds) */
            static const float lim[6] = {0, 32767.5f / 16, 65535.5f / 65536, 32767.5f, 32768.0f, 255.5f / 256};
            b = bf(lim[o - OP_CV0]) + (rnd32() % 9) - 4;
            if (rnd32() % 2) b ^= 0x80000000u;
        }
        emit3(o, (int)(rnd32() % 4), a, b, o == OP_FMA ? pick() : 0);
    }
    fprintf(stderr, "mcpvec: %ld TestFloat vectors, %ld random\n", ntf, nvec - ntf);
    return 0;
}

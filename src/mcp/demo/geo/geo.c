/* geo: the M65-MCP's standard vertex program (MCP3.md) on a demo mesh,
 * prepared on the host: the data geo.asm loads into the MCP, and the
 * result buffer the model says the MCP must leave.
 *
 *   geo [--unlit] <outdir>
 *
 * Writes into outdir:
 *   geo_vtx.bin   the vertices: s16 x, y, z and a pad (x 2^-12), the normal
 *                 (s8 x 2^-7; lit only), the colour, two attribute words:
 *                 24 bytes each (VFMT $16), or 20 unlit (VFMT $14)
 *   geo_regs.bin  F0-F15 for MLOAD (the matrix: projection x view x model,
 *                 by rows), then F12-F15 (kx, ky, cx, cy): 20 x 4 bytes
 *   geo_prog.bin  the standard program, in the stream's format, the light
 *                 in its constants
 *   geo_exp.bin   the result buffer's first NVTX x 32 bytes, as the model
 *                 leaves them
 *   geo.inc       NVTX, VFMT, VSIZE, VPOSEXP, the program's length, LIT and
 *                 the light's constants (LX, LY, LZ, KA: FP32 bits), for
 *                 ACME: geo.asm takes the program from mcp.inc's macros
 *
 * The mesh: a torus (32 x 16 vertices) close enough to the camera that some
 * vertices are behind the near plane, and 16 vertices behind the camera
 * (w <= 0: the program skips their projection). The light: one
 * directional light from the upper left, in front, and an ambient term. */
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "mcp_model.h"

#define NU 32
#define NV 16
#define NBEHIND 16
#define NVTX (NU * NV + NBEHIND)
#define VPOSEXP 12
#define KD 0.85                         /* the light's diffuse term */
#define KA 0.2                          /*   and the ambient one */

static uint32_t bf(float f) { uint32_t v; memcpy(&v, &f, 4); return v; }

/* the program as it is built */
static uint8_t prog[256];
static int plen;

static void b2(int a, int b) { prog[plen++] = (uint8_t)a; prog[plen++] = (uint8_t)b; }
static void w4(int op, int ds, int t) { b2(0x90, op); b2(ds, t << 4); }
static void m6(int m, int d, uint32_t v)        /* a memory form (m: as the register form): Fd = Fd op v */
{
    b2(0x80 + m, d << 4);
    for (int k = 0; k < 4; k++) prog[plen++] = (uint8_t)(v >> (8 * k));
}

/* the standard program: per vertex, V0 the input, V1 clip space, F8 1/w,
 * F9-F11 x/w, y/w, z/w, F12-F15 kx, ky, cx, cy; M the matrix.
 *
 * Its order is for the issue: a command a clock in order, a sequence (VIN,
 * MXV, VOUTC, VPASS) holding the issue until its result is in, any other
 * command waiting only for its operands (an FMA-pipeline result can be
 * used 5 clocks after its command issued). So the divide starts as soon as
 * w is known, and the commands that don't need it run while it does; in
 * the projection, each result's consumer comes 5 commands later (1/w is
 * computed for every vertex: for w = 0 that sets the divide-by-zero flag,
 * nothing else).
 *
 * Lit (one directional light and an ambient term): the normal first, its
 * products with the light running while VIN fetches the position, the
 * intensity max(N . L + ka, ka) = max(N . L, 0) + ka. The light is in the
 * program's constants (memory forms): L, turned into object space and
 * scaled by the diffuse term, in entries 1-3, and the ambient term in
 * entries 6 and 13; the CPU rewrites them once per object. (Not VDOT3:
 * its three steps depend on each other and, a sequence, it would hold the
 * issue all the while.) */
static void build_prog(int lit, const float l[3], float ka)
{
    if (lit) {
        w4(MCPW_VIN, 0x20, 1);         /*  0 VIN    V2, normal             */
        m6(MCP_FMUL, 8, bf(l[0]));     /*  1 FMUL   F8, #Lx                nx * Lx (L x kd) */
        m6(MCP_FMUL, 9, bf(l[1]));     /*  2 FMUL   F9, #Ly                */
        m6(MCP_FMUL, 10, bf(l[2]));    /*  3 FMUL   F10, #Lz               */
        w4(MCPW_VIN, 0x00, 0);         /*  4 VIN    V0, position           */
        w4(MCPW_FADD3, 0xB8, 9);       /*  5 FADD3  F11, F8, F9            */
        m6(MCP_FADD, 10, bf(ka));      /*  6 FADD   F10, #ka               */
        w4(MCPW_MXV, 0x10, 0);         /*  7 MXV    V1, V0                 clip space */
        b2(MCP_FADD, 0xBA);            /*  8 FADD   F11, F10               N . L + ka */
        b2(MCP_FRECIP, 0x87);          /*  9 FRECIP F8, F7                 q = 1 / w */
        w4(MCPW_VOUT, 0x04, 10);       /* 10 VOUT   F4, FP32, byte 20      clip x */
        w4(MCPW_VOUT, 0x05, 12);       /* 11 VOUT   F5, FP32, byte 24      clip y */
        w4(MCPW_VOUT, 0x17, 14);       /* 12 VOUT   F7, top half, 28       clip w */
        m6(MCP_FMAX, 11, bf(ka));      /* 13 FMAX   F11, #ka               the intensity */
        b2(MCP_VCLIP, 0x01);           /* 14 VCLIP  V1                     codes: MCOND, byte 30 */
        w4(MCPW_VIN, 0x00, 2);         /* 15 VIN    V0, colour             */
        b2(MCP_FMUL, 0x0B);            /* 16 FMUL   F0, F11                r, g, b lit (a as it is) */
        b2(MCP_FMUL, 0x1B);            /* 17 FMUL   F1, F11                */
        b2(MCP_FMUL, 0x2B);            /* 18 FMUL   F2, F11                */
        b2(MCP_VPASS, 0x03);           /* 19 VPASS  3                      the attributes: bytes 12-19 */
        w4(MCPW_VOUTC, 0x00, 4);       /* 20 VOUTC  V0, byte 8             */
    } else {
        w4(MCPW_VIN, 0x00, 0);         /*  0 VIN    V0, position           */
        w4(MCPW_MXV, 0x10, 0);         /*  1 MXV    V1, V0                 clip space */
        b2(MCP_FRECIP, 0x87);          /*  2 FRECIP F8, F7                 q = 1 / w */
        w4(MCPW_VOUT, 0x04, 10);       /*  3 VOUT   F4, FP32, byte 20      clip x */
        w4(MCPW_VOUT, 0x05, 12);       /*  4 VOUT   F5, FP32, byte 24      clip y */
        w4(MCPW_VOUT, 0x17, 14);       /*  5 VOUT   F7, top half, 28       clip w */
        b2(MCP_VCLIP, 0x01);           /*  6 VCLIP  V1                     codes: MCOND, byte 30 */
        w4(MCPW_VIN, 0x00, 2);         /*  7 VIN    V0, colour             */
        w4(MCPW_VOUTC, 0x00, 4);       /*  8 VOUTC  V0, byte 8             */
        b2(MCP_VPASS, 0x03);           /*  9 VPASS  3                      the attributes: bytes 12-19 */
    }
    /* (unlit: entries 10-24) */
    w4(MCPW_PSKIP, 0xC0, 11);          /* 21 PSKIP  w <= 0 or NaN: 11      */
    w4(MCPW_FMUL3, 0x94, 8);           /* 22 FMUL3  F9, F4, F8             x / w */
    w4(MCPW_FMUL3, 0xA5, 8);           /* 23 FMUL3  F10, F5, F8            y / w */
    w4(MCPW_FMUL3, 0xB6, 8);           /* 24 FMUL3  F11, F6, F8            z / w */
    b2(MCP_FMOVE, 0x4E);               /* 25 FMOVE  F4, F14                cx */
    b2(MCP_FMOVE, 0x5F);               /* 26 FMOVE  F5, F15                cy */
    w4(MCPW_FMA, 0x49, 12);            /* 27 FMA    F4, F9, F12            cx + kx * x / w */
    w4(MCPW_FMS, 0x5A, 13);            /* 28 FMS    F5, F10, F13           cy - ky * y / w */
    w4(MCPW_VOUT, 0x18, 3);            /* 29 VOUT   F8, top half, 6        1 / w */
    w4(MCPW_VOUT, 0x3B, 2);            /* 30 VOUT   F11, u16, byte 4       depth */
    w4(MCPW_VOUT, 0x24, 0);            /* 31 VOUT   F4, 12.4, byte 0       screen x */
    w4(MCPW_VOUT, 0x25, 1);            /* 32 VOUT   F5, 12.4, byte 2       screen y */
    b2(MCP_VEND, 0x00);                /* 33 VEND                          */
    b2(MCP_VNEXT, 0x00);               /* 34 VNEXT                         */
    b2(MCP_PEND, 0x00);                /* 35 PEND                          */
}

static void put16(uint8_t *p, int v) { p[0] = (uint8_t)v; p[1] = (uint8_t)(v >> 8); }

static void write_file(const char *dir, const char *name, const void *p, size_t n)
{
    char path[4096];
    snprintf(path, sizeof path, "%s/%s", dir, name);
    FILE *f = fopen(path, "wb");
    if (!f || fwrite(p, 1, n, f) != n || fclose(f)) { perror(path); exit(1); }
}

int main(int argc, char **argv)
{
    int lit = 1;
    if (argc > 1 && !strcmp(argv[1], "--unlit")) { lit = 0; argc--; argv++; }
    const char *dir = argc > 1 ? argv[1] : ".";
    const int vfmt = lit ? 0x16 : 0x14;   /* s16 position, (normal,) colour, two attribute words */
    const int vsize = lit ? 24 : 20;
    static uint8_t vtx[NVTX * 24];

    /* the torus, then the vertices behind the camera */
    for (int i = 0; i < NVTX; i++) {
        double x, y, z, nx = 0, ny = 0, nz = 1;
        if (i < NU * NV) {
            double u = 2 * M_PI * (i % NU) / NU, v = 2 * M_PI * (i / NU) / NV;
            x = (1.0 + 0.4 * cos(v)) * cos(u);
            y = 0.4 * sin(v);
            z = (1.0 + 0.4 * cos(v)) * sin(u);
            nx = cos(v) * cos(u);
            ny = sin(v);
            nz = cos(v) * sin(u);
        } else {
            int k = i - NU * NV;
            x = (k % 4) * 0.5 - 0.75;
            y = (k / 4) * 0.5 - 0.75;
            z = -6.0;                   /* (after the view: behind the camera) */
        }
        uint8_t *p = &vtx[i * vsize];
        put16(p, (int)lround(x * (1 << VPOSEXP)));
        put16(p + 2, (int)lround(y * (1 << VPOSEXP)));
        put16(p + 4, (int)lround(z * (1 << VPOSEXP)));
        put16(p + 6, 0);
        p += 8;
        if (lit) {                      /* the normal, s8 x 2^-7 */
            p[0] = (uint8_t)(int8_t)lround(nx * 127);
            p[1] = (uint8_t)(int8_t)lround(ny * 127);
            p[2] = (uint8_t)(int8_t)lround(nz * 127);
            p[3] = 0;
            p += 4;
        }
        p[0] = (uint8_t)(i * 7);        /* colour */
        p[1] = (uint8_t)(255 - i);
        p[2] = (uint8_t)(i * 3 + 64);
        p[3] = 0xFF;
        for (int k = 0; k < 8; k++) p[4 + k] = (uint8_t)(i + 31 * k);    /* attributes */
    }

    /* the matrix: projection (60 degrees, 320 x 200, near 1, far 10, z in
     * [0, w]) x view (1.6 units away: part of the torus behind the near
     * plane, the torus tipped) x model (turned). Eye space = rot x object
     * space + (0, 0, tz), the camera looking along +z. */
    double a = 0.6, b = 0.9, fy = 1.0 / tan(M_PI / 6), fx = fy / 1.6, n = 1.0, f = 10.0, tz = 1.6;
    double rot[3][3] = {
        { cos(a), 0, sin(a)},
        { sin(a) * sin(b), cos(b), -cos(a) * sin(b)},
        {-sin(a) * cos(b), sin(b), cos(a) * cos(b)}
    };
    double m[4][4] = {{0}};
    for (int j = 0; j < 3; j++) {
        m[0][j] = fx * rot[0][j];
        m[1][j] = fy * rot[1][j];
        m[2][j] = f / (f - n) * rot[2][j];
        m[3][j] = rot[2][j];
    }
    m[0][3] = 0;
    m[1][3] = 0;
    m[2][3] = f / (f - n) * tz - f * n / (f - n);
    m[3][3] = tz;
    uint32_t regs[20];
    for (int r = 0; r < 4; r++)
        for (int c = 0; c < 4; c++) regs[4 * r + c] = bf((float)m[r][c]);
    regs[16] = bf(160.0f);              /* kx, ky, cx, cy: a 320 x 200 screen */
    regs[17] = bf(100.0f);
    regs[18] = bf(160.0f);
    regs[19] = bf(100.0f);

    /* the light, toward it from the surface: up, left and toward the
     * camera in eye space; into object space (rot's transpose: rot is a
     * rotation), scaled by the diffuse term - the CPU's work once per
     * object */
    double le[3] = {-0.5, 0.6, -0.62}, len = sqrt(le[0] * le[0] + le[1] * le[1] + le[2] * le[2]);
    float lo[3];
    for (int j = 0; j < 3; j++)
        lo[j] = (float)(KD * (rot[0][j] * le[0] + rot[1][j] * le[1] + rot[2][j] * le[2]) / len);
    build_prog(lit, lo, (float)KA);

    /* the model, in geo.asm's order */
    static mcp_state s;
    s.stage = 5;
    mcp_reset(&s);
    for (int k = 0; k < 16; k++) mcp_exec(&s, 0x80 + 0, k << 4, regs[k]);       /* FMOVE (memory form) */
    mcp_exec_wide(&s, MCPW_MLOAD, 0, 0);
    for (int k = 0; k < 4; k++) mcp_exec(&s, 0x80 + 0, (12 + k) << 4, regs[16 + k]);
    mcp_vreg_write(&s, 0x04, 0);
    mcp_vreg_write(&s, 0x05, 0);
    for (int i = 0; i < NVTX * vsize; i++) mcp_vin_write(&s, vtx[i]);
    for (int i = 0; i < plen; i++) mcp_mpload(&s, prog[i]);
    mcp_vreg_write(&s, 0x08, vfmt);
    mcp_vreg_write(&s, 0x09, VPOSEXP);
    mcp_exec(&s, 0x80 + MCPM_PRUN, 0, (uint32_t)NVTX << 16);                    /* PRUN 0, NVTX passes */
    if (s.mperr || s.mpcnt != NVTX) {
        fprintf(stderr, "geo: the program ended early (MPERR %d, %d passes)\n", s.mperr, s.mpcnt);
        return 1;
    }

    int nbehind = 0, nnear = 0, ndark = 0;
    for (int i = 0; i < NVTX; i++) {
        const uint8_t *e = &s.vout[i * 32];
        nbehind += (e[30] & 0x40) != 0;
        nnear += (e[30] & 0x50) == 0x10;
        if (lit) {                      /* N . L <= 0: the ambient term alone */
            const int8_t *nq = (const int8_t *)&vtx[i * vsize + 8];
            ndark += nq[0] * (double)lo[0] + nq[1] * (double)lo[1] + nq[2] * (double)lo[2] <= 0;
        }
    }
    write_file(dir, "geo_vtx.bin", vtx, (size_t)NVTX * vsize);
    uint8_t rb[80];
    for (int k = 0; k < 20; k++) memcpy(&rb[4 * k], &regs[k], 4);
    write_file(dir, "geo_regs.bin", rb, sizeof rb);
    write_file(dir, "geo_prog.bin", prog, (size_t)plen);
    write_file(dir, "geo_exp.bin", s.vout, NVTX * 32);
    char inc[512];
    snprintf(inc, sizeof inc, "NVTX = %d\nVFMT = $%02X\nVSIZE = %d\nVPOSEXP = %d\nPROGLEN = %d\n"
             "LIT = %d\nLX = $%08X\nLY = $%08X\nLZ = $%08X\nKA = $%08X\n",
             NVTX, vfmt, vsize, VPOSEXP, plen, lit, bf(lo[0]), bf(lo[1]), bf(lo[2]), bf((float)KA));
    write_file(dir, "geo.inc", inc, strlen(inc));
    printf("geo: %d vertices (%d behind the camera, %d more behind the near plane), %s, "
           "a %d-byte program, MFLAGS $%02X\n", NVTX, nbehind, nnear,
           lit ? "lit" : "unlit", plen, s.mflags);
    if (lit)
        printf("geo: %d vertices facing away from the light (the ambient term alone)\n", ndark);
    return 0;
}

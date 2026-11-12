/* geo: the M65-MCP's standard vertex program (MCP3.md) on a demo mesh,
 * prepared on the host: the data geo.asm loads into the MCP, and the
 * result buffer the model says the MCP must leave.
 *
 *   geo <outdir>
 *
 * Writes into outdir:
 *   geo_vtx.bin   the vertices (VFMT $14: s16 x, y, z and a pad, x 2^-12;
 *                 colour; two attribute words: 20 bytes each)
 *   geo_regs.bin  F0-F15 for MLOAD (the matrix: projection x view x model,
 *                 by rows), then F12-F15 (kx, ky, cx, cy): 20 x 4 bytes
 *   geo_prog.bin  the standard program, in the stream's format
 *   geo_exp.bin   the result buffer's first NVTX x 32 bytes, as the model
 *                 leaves them
 *   geo.inc       NVTX, VFMT, VPOSEXP and the program's length, for ACME
 *
 * The mesh: a torus (32 x 16 vertices) close enough to the camera that some
 * vertices are behind the near plane, and 16 vertices behind the camera
 * (w <= 0: the program skips their projection). */
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "mcp_model.h"

#define NU 32
#define NV 16
#define NBEHIND 16
#define NVTX (NU * NV + NBEHIND)
#define VFMT 0x14                       /* s16 position, colour, two attribute words */
#define VPOSEXP 12
#define VSIZE 20

static uint32_t bf(float f) { uint32_t v; memcpy(&v, &f, 4); return v; }

/* the standard program: per vertex, V0 the input, V1 clip space, F8 1/w,
 * F9-F11 x/w, y/w, z/w, F12-F15 kx, ky, cx, cy; M the matrix. The divide
 * starts first: the clip-space stores, the codes, the colour and the
 * attributes go on while it runs (1/w is computed for every vertex; for
 * w = 0 that sets the divide-by-zero flag, nothing else) */
static const uint8_t prog[] = {
    0x90, MCPW_VIN, 0x00, 0x00,        /*  0 VIN    V0, position        */
    0x90, MCPW_MXV, 0x10, 0x00,        /*  1 MXV    V1, V0              */
    MCP_FRECIP, 0x87,                  /*  2 FRECIP F8, F7              q = 1 / w */
    0x90, MCPW_VOUT, 0x04, 0xA0,       /*  3 VOUT   F4, FP32, byte 20    clip x */
    0x90, MCPW_VOUT, 0x05, 0xC0,       /*  4 VOUT   F5, FP32, byte 24    clip y */
    0x90, MCPW_VOUT, 0x17, 0xE0,       /*  5 VOUT   F7, top half, 28    clip w */
    MCP_VCLIP, 0x01,                   /*  6 VCLIP  V1                  codes: MCOND, byte 30 */
    0x90, MCPW_VIN, 0x00, 0x20,        /*  7 VIN    V0, colour          */
    0x90, MCPW_VOUTC, 0x00, 0x40,      /*  8 VOUTC  V0, byte 8          */
    MCP_VPASS, 0x03,                   /*  9 VPASS  3                   the attributes: bytes 12-19 */
    0x90, MCPW_PSKIP, 0xC0, 0xB0,      /* 10 PSKIP  w <= 0 or NaN: 11   */
    0x90, MCPW_FMUL3, 0x94, 0x80,      /* 11 FMUL3  F9, F4, F8          x / w */
    0x90, MCPW_FMUL3, 0xA5, 0x80,      /* 12 FMUL3  F10, F5, F8         y / w */
    0x90, MCPW_FMUL3, 0xB6, 0x80,      /* 13 FMUL3  F11, F6, F8         z / w */
    MCP_FMOVE, 0x4E,                   /* 14 FMOVE  F4, F14             cx */
    0x90, MCPW_FMA, 0x49, 0xC0,        /* 15 FMA    F4, F9, F12         cx + kx * x / w */
    MCP_FMOVE, 0x5F,                   /* 16 FMOVE  F5, F15             cy */
    0x90, MCPW_FMS, 0x5A, 0xD0,        /* 17 FMS    F5, F10, F13        cy - ky * y / w */
    0x90, MCPW_VOUT, 0x24, 0x00,       /* 18 VOUT   F4, 12.4, byte 0    screen x */
    0x90, MCPW_VOUT, 0x25, 0x10,       /* 19 VOUT   F5, 12.4, byte 2    screen y */
    0x90, MCPW_VOUT, 0x3B, 0x20,       /* 20 VOUT   F11, u16, byte 4    depth */
    0x90, MCPW_VOUT, 0x18, 0x30,       /* 21 VOUT   F8, top half, 6     1 / w */
    MCP_VEND, 0x00,                    /* 22 VEND                       */
    MCP_VNEXT, 0x00,                   /* 23 VNEXT                      */
    MCP_PEND, 0x00                     /* 24 PEND                       */
};

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
    const char *dir = argc > 1 ? argv[1] : ".";
    static uint8_t vtx[NVTX * VSIZE];
    /* the torus, then the vertices behind the camera */
    for (int i = 0; i < NVTX; i++) {
        double x, y, z;
        if (i < NU * NV) {
            double u = 2 * M_PI * (i % NU) / NU, v = 2 * M_PI * (i / NU) / NV;
            x = (1.0 + 0.4 * cos(v)) * cos(u);
            y = 0.4 * sin(v);
            z = (1.0 + 0.4 * cos(v)) * sin(u);
        } else {
            int k = i - NU * NV;
            x = (k % 4) * 0.5 - 0.75;
            y = (k / 4) * 0.5 - 0.75;
            z = -6.0;                   /* (after the view: behind the camera) */
        }
        uint8_t *p = &vtx[i * VSIZE];
        put16(p, (int)lround(x * (1 << VPOSEXP)));
        put16(p + 2, (int)lround(y * (1 << VPOSEXP)));
        put16(p + 4, (int)lround(z * (1 << VPOSEXP)));
        put16(p + 6, 0);
        p[8] = (uint8_t)(i * 7);         /* colour */
        p[9] = (uint8_t)(255 - i);
        p[10] = (uint8_t)(i * 3 + 64);
        p[11] = 0xFF;
        for (int k = 0; k < 8; k++) p[12 + k] = (uint8_t)(i + 31 * k);   /* attributes */
    }

    /* the matrix: projection (60 degrees, 320 x 200, near 1, far 10, z in
     * [0, w]) x view (1.6 units away: part of the torus behind the near
     * plane, the torus tipped) x model (turned) */
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

    /* the model, in geo.asm's order */
    static mcp_state s;
    s.stage = 5;
    mcp_reset(&s);
    for (int k = 0; k < 16; k++) mcp_exec(&s, 0x80 + 0, k << 4, regs[k]);       /* FMOVE (memory form) */
    mcp_exec_wide(&s, MCPW_MLOAD, 0, 0);
    for (int k = 0; k < 4; k++) mcp_exec(&s, 0x80 + 0, (12 + k) << 4, regs[16 + k]);
    mcp_vreg_write(&s, 0x04, 0);
    mcp_vreg_write(&s, 0x05, 0);
    for (size_t i = 0; i < sizeof vtx; i++) mcp_vin_write(&s, vtx[i]);
    for (size_t i = 0; i < sizeof prog; i++) mcp_mpload(&s, prog[i]);
    mcp_vreg_write(&s, 0x08, VFMT);
    mcp_vreg_write(&s, 0x09, VPOSEXP);
    mcp_exec(&s, 0x80 + MCPM_PRUN, 0, (uint32_t)NVTX << 16);                    /* PRUN 0, NVTX passes */
    if (s.mperr || s.mpcnt != NVTX) {
        fprintf(stderr, "geo: the program ended early (MPERR %d, %d passes)\n", s.mperr, s.mpcnt);
        return 1;
    }

    int nbehind = 0, nnear = 0;
    for (int i = 0; i < NVTX; i++) {
        uint8_t c = s.vout[i * 32 + 30];
        nbehind += (c & 0x40) != 0;
        nnear += (c & 0x50) == 0x10;
    }
    write_file(dir, "geo_vtx.bin", vtx, sizeof vtx);
    uint8_t rb[80];
    for (int k = 0; k < 20; k++) memcpy(&rb[4 * k], &regs[k], 4);
    write_file(dir, "geo_regs.bin", rb, sizeof rb);
    write_file(dir, "geo_prog.bin", prog, sizeof prog);
    write_file(dir, "geo_exp.bin", s.vout, NVTX * 32);
    char inc[512];
    snprintf(inc, sizeof inc, "NVTX = %d\nVFMT = $%02X\nVPOSEXP = %d\nPROGLEN = %d\n",
             NVTX, VFMT, VPOSEXP, (int)sizeof prog);
    write_file(dir, "geo.inc", inc, strlen(inc));
    printf("geo: %d vertices (%d behind the camera, %d more behind the near plane), MFLAGS $%02X\n",
           NVTX, nbehind, nnear, s.mflags);
    return 0;
}

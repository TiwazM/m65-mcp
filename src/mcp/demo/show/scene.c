/* scene: the 3D scene's data (scene.asm), prepared on the host, and its
 * frames as the MEGA65 must draw them.
 *
 *   scene [--pal | --ntsc] <outdir> [frame ...]         (default: --ntsc, frame 0)
 *
 * A torus (24 x 10 vertices, 480 triangles, a checker of two colours) turns
 * in front of the camera, lit by one light, flat shaded. The MCP does all
 * of its arithmetic, in two programs run back to back each frame over one
 * array of 16-byte records (s16 position, s8 normal, colour: VFMT $06):
 *
 *   the vertex program, a pass a vertex (240): the position through
 *     projection x view x model, the divide, the viewport, and the pixel
 *     it lands on as two s16 (result bytes 0-3)
 *   the face program, a pass a triangle (480), its record the triangle's
 *     centroid C, its normal N and its colour's base: three result bytes
 *       0  the palette index: base + 1 + 120 (max(N . L, 0) kd + ka)
 *       1  the depth bucket: the centroid's distance, 0 near to 255 far
 *       2  facing the eye: 0 if not (N . (E - C) <= 0), else > 0
 *     with D the view direction in object space (row 3 of the matrix, so
 *     MSTORE leaves it in F12-F14): the eye is E = -tz D, the distance is
 *     C . D + tz. The light, turned into object space (MTXV), is in the
 *     program's constants (entries FLIGHT to FLIGHT + 2), rewritten a frame.
 *
 * The DMA then scatters those bytes out of the result window into the
 * CPU's tables (a source step of 32, one chained list), and the CPU links
 * the visible faces into their depth buckets and draws them far to near,
 * a column of pixels at a time (show.inc), every column one DMA fill.
 *
 * Here the model (mcp_model.c) plays each frame as scene.asm drives the
 * MCP, and the drawing below does scene.asm's integer steps, so the frame
 * buffers are the ones the board must show. Every frame of the turn (256)
 * is checked: all vertices on the screen, and the drawing against a depth
 * buffer over all triangles, computed apart from the MCP's results (what
 * is drawn must be the nearest surface, but for the edges' pixels).
 *
 * --pal, --ntsc: the video mode the frames are for. Its pixels are not
 * square (720 x 576 or 720 x 480 shown 4:3), so kx differs; scene.asm
 * takes the mode from $D06F and patches kx (entry VKX).
 *
 * Writes into outdir: scene.inc (constants for ACME), scene_rec.bin (the
 * records: the vertices, then the faces), scene_prog.bin (both programs),
 * scene_tri.bin (the triangles' vertices as three planes of 512 bytes),
 * scene_sin.bin (256 FP32 sines as four planes), scene_pv.bin (projection
 * x view, F0-F15), scene_le.bin (the light, eye space, scaled, w 0),
 * scene_pal.bin and, per frame asked for, scene_res<n>.bin (the result
 * buffer, 720 entries: the emulator's stand-in for the MCP) and
 * scene_fb<n>.bin (the frame buffer).
 */
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "mcp_model.h"

#define NU 24
#define NV 10
#define NVTX (NU * NV)
#define NTRI (2 * NU * NV)
#define NREC (NVTX + NTRI)
#define RSIZE 16
#define VFMT 0x06                       /* s16 position, normal, colour */
#define VPOSEXP 12
#define KD 0.85
#define KA 0.2
#define LEVELS 120.0                    /* the palette's steps for a light of 1 */
#define TZ 4.5                          /* the camera's distance */
#define FOV 40.0                        /* degrees, top to bottom */
#define REACH 1.45                      /* the depth buckets: TZ - REACH to TZ + REACH */
#define RY0 0                           /* frame 0's angles (sine-table steps) */
#define RX0 32
#define VPROG 0                         /* the programs' first entries */
#define VKX 5                           /*   the vertex program's kx */
#define FPROG 14
#define FLIGHT (FPROG + 12)             /*   the face program's light */

static uint32_t bf(float f) { uint32_t v; memcpy(&v, &f, 4); return v; }
static double fb2d(uint32_t v) { float f; memcpy(&f, &v, 4); return f; }

static void write_file(const char *dir, const char *name, const void *p, size_t n)
{
    char path[4096];
    snprintf(path, sizeof path, "%s/%s", dir, name);
    FILE *f = fopen(path, "wb");
    if (!f || fwrite(p, 1, n, f) != n || fclose(f)) { perror(path); exit(1); }
}

static void put16(uint8_t *p, int v) { p[0] = (uint8_t)v; p[1] = (uint8_t)(v >> 8); }

/* ---- the programs, in the stream's format ---- */
static uint8_t prog[512];
static int plen, nentry;
static void b2(int a, int b) { prog[plen++] = (uint8_t)a; prog[plen++] = (uint8_t)b; nentry++; }
static void w4(int op, int ds, int t) { b2(0x90, op); nentry--; b2(ds, t << 4); }
static void m6(int m, int d, uint32_t v)        /* a memory form (m: as the register form): Fd = Fd op v */
{
    b2(0x80 + m, d << 4);
    for (int k = 0; k < 4; k++) prog[plen++] = (uint8_t)(v >> (8 * k));
}

static void build_progs(float kx)
{
    /* the vertex program: V0 the position, V1 clip space, F8 1/w */
    w4(MCPW_VIN, 0x00, 0);              /*  0 VIN    V0, position          */
    w4(MCPW_MXV, 0x10, 0);              /*  1 MXV    V1, V0                clip space (F4-F7) */
    b2(MCP_FRECIP, 0x87);               /*  2 FRECIP F8, F7                1 / w */
    w4(MCPW_FMUL3, 0x94, 8);            /*  3 FMUL3  F9, F4, F8            x / w */
    w4(MCPW_FMUL3, 0xA5, 8);            /*  4 FMUL3  F10, F5, F8           y / w */
    m6(MCP_FMUL, 9, bf(kx));            /*  5 FMUL   F9, #kx               (VKX: the video mode's) */
    m6(MCP_FMUL, 10, bf(-100.0f));      /*  6 FMUL   F10, #-ky             */
    m6(MCP_FADD, 9, bf(160.0f));        /*  7 FADD   F9, #cx               */
    m6(MCP_FADD, 10, bf(100.0f));       /*  8 FADD   F10, #cy              */
    w4(MCPW_VOUT, 0x49, 0);             /*  9 VOUT   F9, s16, byte 0       the pixel's x */
    w4(MCPW_VOUT, 0x4A, 1);             /* 10 VOUT   F10, s16, byte 2      y */
    b2(MCP_VEND, 0x00);                 /* 11 VEND                         */
    b2(MCP_VNEXT, 0x00);                /* 12 VNEXT                        */
    b2(MCP_PEND, 0x00);                 /* 13 PEND                         */
    if (nentry != FPROG) { fprintf(stderr, "scene: FPROG is not the vertex program's length\n"); exit(1); }

    /* the face program: V0 the centroid C, V1 the normal N, V2 the result
     * (the colour's base in F8), F12-F14 the view direction D; the
     * products first (a clock each), their sums behind them */
    w4(MCPW_VIN, 0x20, 2);              /*  0 VIN    V2, colour            F8 = base / 256, F9-F11 = 0 */
    w4(MCPW_VIN, 0x00, 0);              /*  1 VIN    V0, position          F0-F2 = C */
    w4(MCPW_VIN, 0x10, 1);              /*  2 VIN    V1, normal            F4-F6 = N */
    w4(MCPW_FMUL3, 0x90, 12);           /*  3 FMUL3  F9, F0, F12           C . D */
    w4(MCPW_FMUL3, 0x31, 13);           /*  4 FMUL3  F3, F1, F13           */
    w4(MCPW_FMUL3, 0x72, 14);           /*  5 FMUL3  F7, F2, F14           */
    w4(MCPW_FMUL3, 0xA4, 12);           /*  6 FMUL3  F10, F4, F12          N . D */
    w4(MCPW_FMUL3, 0xB5, 13);           /*  7 FMUL3  F11, F5, F13          */
    w4(MCPW_FMUL3, 0xF6, 14);           /*  8 FMUL3  F15, F6, F14          */
    b2(MCP_FMUL, 0x04);                 /*  9 FMUL   F0, F4                N . C (C not needed again) */
    b2(MCP_FMUL, 0x15);                 /* 10 FMUL   F1, F5                */
    b2(MCP_FMUL, 0x26);                 /* 11 FMUL   F2, F6                */
    if (nentry != FLIGHT) { fprintf(stderr, "scene: FLIGHT is not the light's entry\n"); exit(1); }
    m6(MCP_FMUL, 4, 0);                 /* 12 FMUL   F4, #lx               N . L (FLIGHT: a frame's light) */
    m6(MCP_FMUL, 5, 0);                 /* 13 FMUL   F5, #ly               */
    m6(MCP_FMUL, 6, 0);                 /* 14 FMUL   F6, #lz               */
    b2(MCP_FADD, 0x93);                 /* 15 FADD   F9, F3                */
    b2(MCP_FADD, 0xAB);                 /* 16 FADD   F10, F11              */
    b2(MCP_FADD, 0x01);                 /* 17 FADD   F0, F1                */
    b2(MCP_FADD, 0x45);                 /* 18 FADD   F4, F5                */
    b2(MCP_FADD, 0x97);                 /* 19 FADD   F9, F7                C . D */
    b2(MCP_FADD, 0xAF);                 /* 20 FADD   F10, F15              N . D */
    b2(MCP_FADD, 0x02);                 /* 21 FADD   F0, F2                N . C */
    b2(MCP_FADD, 0x46);                 /* 22 FADD   F4, F6                N . L */
    m6(MCP_FADD, 9, bf((float)REACH));  /* 23 FADD   F9, #reach            the distance - (tz - reach) */
    m6(MCP_FMUL, 10, bf((float)-TZ));   /* 24 FMUL   F10, #-tz             N . E */
    m6(MCP_FMAX, 4, 0);                 /* 25 FMAX   F4, #0                */
    m6(MCP_FMUL, 9, bf((float)(1 / (2 * REACH))));          /* 26 FMUL F9, #1 / (2 reach): the bucket / 256 */
    b2(MCP_FSUB, 0xA0);                 /* 27 FSUB   F10, F0               N . (E - C): facing */
    m6(MCP_FADD, 4, bf((float)((1 + LEVELS * KA) / 256)));  /* 28 FADD F4, #ambient */
    b2(MCP_FADD, 0x84);                 /* 29 FADD   F8, F4                the palette index / 256 */
    w4(MCPW_VOUTC, 0x02, 0);            /* 30 VOUTC  V2, byte 0            index, bucket, facing (x 256, 0-255) */
    b2(MCP_VEND, 0x00);                 /* 31 VEND                         */
    b2(MCP_VNEXT, 0x00);                /* 32 VNEXT                        */
    b2(MCP_PEND, 0x00);                 /* 33 PEND                         */
}

/* ---- the scene ---- */
static uint8_t rec[NREC * RSIZE];       /* the records: vertices, then faces */
static uint8_t ta[512], tb[512], tc[512];   /* a triangle's vertices */
static uint32_t sintab[256], pvb[16], leb[4];

static void rot_y(uint32_t *f, int a)
{
    uint32_t s = sintab[a & 255], c = sintab[(a + 64) & 255], one = 0x3F800000;
    uint32_t r[16] = {c, 0, s, 0,  0, one, 0, 0,  s ^ 0x80000000u, 0, c, 0,  0, 0, 0, one};
    memcpy(f, r, sizeof r);
}
static void rot_x(uint32_t *f, int b)
{
    uint32_t s = sintab[b & 255], c = sintab[(b + 64) & 255], one = 0x3F800000;
    uint32_t r[16] = {one, 0, 0, 0,  0, c, s ^ 0x80000000u, 0,  0, s, c, 0,  0, 0, 0, one};
    memcpy(f, r, sizeof r);
}
static void fregs(mcp_state *s, const uint32_t *v, int first, int n)
{
    for (int k = 0; k < n; k++) mcp_exec(s, 0x80 + MCP_FMOVE, (first + k) << 4, v[k]);
}

/* a frame through the model, as scene.asm drives the MCP */
static mcp_state st;
static uint32_t ry[16], rx[16];
static int run_frame(int frame)
{
    rot_y(ry, RY0 + frame);
    rot_x(rx, RX0 + 2 * frame);
    fregs(&st, ry, 0, 16);                                  /* M = Ry x Rx */
    mcp_exec_wide(&st, MCPW_MLOAD, 0, 0);
    fregs(&st, rx, 0, 16);
    mcp_exec_wide(&st, MCPW_MMUL, 0, 0);
    fregs(&st, leb, 0, 4);                                  /* V0 = transpose(M) x the light */
    mcp_exec_wide(&st, MCPW_MTXV, 0x00, 0);
    uint32_t lo[3] = {st.f[0], st.f[1], st.f[2]};
    st.mpptr = FLIGHT;                                      /* into the face program */
    mcp_mpload_restart(&st);
    for (int k = 0; k < 3; k++) {
        mcp_mpload(&st, 0x80 + MCP_FMUL);
        mcp_mpload(&st, (uint8_t)((4 + k) << 4));
        for (int b = 0; b < 4; b++) mcp_mpload(&st, (uint8_t)(lo[k] >> (8 * b)));
    }
    fregs(&st, pvb, 0, 16);                                 /* M = PV x Ry x Rx */
    mcp_exec_wide(&st, MCPW_MLOAD, 0, 0);
    fregs(&st, ry, 0, 16);
    mcp_exec_wide(&st, MCPW_MMUL, 0, 0);
    fregs(&st, rx, 0, 16);
    mcp_exec_wide(&st, MCPW_MMUL, 0, 0);
    mcp_vreg_write(&st, 0x06, 0);                           /* the first record, the first entry */
    mcp_vreg_write(&st, 0x07, 0);
    mcp_vreg_write(&st, 0x0C, 0);
    mcp_vreg_write(&st, 0x0D, 0);
    mcp_exec_wide(&st, MCPW_MSTORE, 0, 0);                  /* F12-F14 = the matrix's row 3: D */
    mcp_exec(&st, 0x80 + MCPM_PRUN, 0, (uint32_t)NVTX << 16 | VPROG);
    if (st.mperr || st.mpcnt != NVTX) return 1;
    mcp_exec(&st, 0x80 + MCPM_PRUN, 0, (uint32_t)NTRI << 16 | FPROG);
    if (st.mperr || st.mpcnt != NTRI) return 1;
    return 0;
}

/* ---- the drawing, as scene.asm does it ---- */
static int vx[NVTX], vy[NVTX];
static uint8_t fb[64000];

static int32_t slope(int dy, int dx)
{
    uint32_t q = ((uint32_t)abs(dy) << 16) / (uint32_t)dx;
    return dy < 0 ? -(int32_t)q : (int32_t)q;
}

/* (the edges run between vertices on the screen, so their rows are 0-199:
 * a byte each) */
static void span(int x, int32_t a, int32_t b, int colour)
{
    int ya = (a >> 16) & 255, yb = (b >> 16) & 255;
    int top = ya < yb ? ya : yb, bot = ya < yb ? yb : ya;
    for (int y = top; y < bot; y++) fb[(x >> 3) * 1600 + y * 8 + (x & 7)] = (uint8_t)colour;
}

static void triangle(int a, int b, int c, int colour)
{
    int t;
    if (vx[a] > vx[b]) { t = a; a = b; b = t; }
    if (vx[b] > vx[c]) { t = b; b = c; c = t; }
    if (vx[a] > vx[b]) { t = a; a = b; b = t; }
    if (vx[c] == vx[a]) return;
    int32_t sac = slope(vy[c] - vy[a], vx[c] - vx[a]);
    int32_t yl = (int32_t)((uint32_t)vy[a] << 16) + 0x8000, ys = yl;
    if (vx[b] > vx[a]) {
        int32_t sab = slope(vy[b] - vy[a], vx[b] - vx[a]);
        for (int x = vx[a]; x < vx[b]; x++) {
            span(x, yl, ys, colour);
            yl += sac;
            ys += sab;
        }
    }
    if (vx[c] > vx[b]) {
        int32_t sbc = slope(vy[c] - vy[b], vx[c] - vx[b]);
        ys = (int32_t)((uint32_t)vy[b] << 16) + 0x8000;
        for (int x = vx[b]; x < vx[c]; x++) {
            span(x, yl, ys, colour);
            yl += sac;
            ys += sbc;
        }
    }
}

/* the frame's drawing from the result buffer; returns the faces drawn */
static int draw_frame(void)
{
    static int head[256], next[NTRI];
    int nvis = 0;
    memset(fb, 0, sizeof fb);
    for (int v = 0; v < NVTX; v++) {
        const uint8_t *e = &st.vout[v * 32];
        vx[v] = (int16_t)(e[0] | e[1] << 8);
        vy[v] = (int16_t)(e[2] | e[3] << 8);
    }
    for (int k = 0; k < 256; k++) head[k] = -1;
    for (int f = 0; f < NTRI; f++) {                        /* (the last in is the first out) */
        const uint8_t *e = &st.vout[(NVTX + f) * 32];
        if (!e[2]) continue;
        next[f] = head[e[1]];
        head[e[1]] = f;
        nvis++;
    }
    for (int k = 255; k >= 0; k--)
        for (int f = head[k]; f >= 0; f = next[f])
            triangle(ta[f], tb[f], tc[f], st.vout[(NVTX + f) * 32]);
    return nvis;
}

/* a check of the drawing, by other means: per pixel the nearest triangle
 * of all of them (a depth buffer, no culling; the depths from the host's
 * own rotation, in double) against what the MCP's culling and the
 * painter's order left. The two differ along edges (another fill rule);
 * the wrong faces culled, or a wrong order, differ everywhere. Returns the
 * differing pixels in 1/10 percent of those covered. */
static int depth_check(void)
{
    static float zb[200][320];
    static uint8_t zc[200][320];
    double R[9], vz[NVTX];
    for (int r = 0; r < 3; r++)
        for (int c = 0; c < 3; c++)
            R[3 * r + c] = fb2d(ry[4 * r]) * fb2d(rx[c]) + fb2d(ry[4 * r + 1]) * fb2d(rx[4 + c])
                           + fb2d(ry[4 * r + 2]) * fb2d(rx[8 + c]);
    for (int v = 0; v < NVTX; v++) {
        const uint8_t *p = &rec[v * RSIZE];
        vz[v] = TZ + (R[6] * (int16_t)(p[0] | p[1] << 8) + R[7] * (int16_t)(p[2] | p[3] << 8)
                      + R[8] * (int16_t)(p[4] | p[5] << 8)) / 4096.0;
    }
    for (int y = 0; y < 200; y++)
        for (int x = 0; x < 320; x++) zb[y][x] = 1e30f;
    for (int t = 0; t < NTRI; t++) {
        int a = ta[t], b = tb[t], c = tc[t];
        long area = (long)(vx[b] - vx[a]) * (vy[c] - vy[a]) - (long)(vy[b] - vy[a]) * (vx[c] - vx[a]);
        if (area == 0) continue;
        double sg = area > 0 ? 1 : -1;
        int x0 = vx[a] < vx[b] ? vx[a] : vx[b], x1 = vx[a] > vx[b] ? vx[a] : vx[b];
        int y0 = vy[a] < vy[b] ? vy[a] : vy[b], y1 = vy[a] > vy[b] ? vy[a] : vy[b];
        if (vx[c] < x0) x0 = vx[c];
        if (vx[c] > x1) x1 = vx[c];
        if (vy[c] < y0) y0 = vy[c];
        if (vy[c] > y1) y1 = vy[c];
        for (int y = y0; y <= y1; y++)
            for (int x = x0; x <= x1; x++) {
                double px = x + 0.5, py = y + 0.5;
                double w0 = sg * ((vx[b] - vx[a]) * (py - vy[a]) - (vy[b] - vy[a]) * (px - vx[a]));
                double w1 = sg * ((vx[c] - vx[b]) * (py - vy[b]) - (vy[c] - vy[b]) * (px - vx[b]));
                double w2 = sg * ((vx[a] - vx[c]) * (py - vy[c]) - (vy[a] - vy[c]) * (px - vx[c]));
                if (w0 < 0 || w1 < 0 || w2 < 0) continue;
                float z = (float)((w1 * vz[a] + w2 * vz[b] + w0 * vz[c]) / labs(area));
                if (z < zb[y][x]) { zb[y][x] = z; zc[y][x] = st.vout[(NVTX + t) * 32]; }
            }
    }
    int covered = 0, differ = 0;
    for (int y = 0; y < 200; y++)
        for (int x = 0; x < 320; x++) {
            if (zb[y][x] > 1e29f) continue;
            covered++;
            differ += fb[(x >> 3) * 1600 + y * 8 + (x & 7)] != zc[y][x];
        }
    return covered ? differ * 1000 / covered : 0;
}

int main(int argc, char **argv)
{
    int ntsc = 1;
    while (argc > 1 && argv[1][0] == '-') {
        if (!strcmp(argv[1], "--pal")) ntsc = 0;
        else if (!strcmp(argv[1], "--ntsc")) ntsc = 1;
        else { fprintf(stderr, "scene [--pal | --ntsc] <outdir> [frame ...]\n"); return 1; }
        argc--;
        argv++;
    }
    const char *dir = argc > 1 ? argv[1] : ".";
    static uint8_t want[256];                               /* the frames to write */
    if (argc <= 2) want[0] = 1;
    for (int k = 2; k < argc; k++) want[atoi(argv[k]) & 255] = 1;
    /* a pixel's width over its height: 720 x 576 (16:15) or 720 x 480 (8:9)
     * shown 4:3; kx = 160 over it */
    const float kx_pal = (float)(160 / (16.0 / 15)), kx_ntsc = (float)(160 / (8.0 / 9));
    for (int k = 0; k < 256; k++) sintab[k] = bf((float)sin(2 * M_PI * k / 256));

    /* the torus: ring radius 1, tube 0.4; quads of 2 x 2 in a checker of
     * two colours. A vertex's record: its position (its normal is there,
     * not used). A face's: its centroid, its own normal (pointing out of
     * the surface), and its colour's base in the palette (0 or 127) */
    static double pos[NVTX][3], nrm[NVTX][3];
    for (int j = 0; j < NV; j++)
        for (int i = 0; i < NU; i++) {
            double u = 2 * M_PI * i / NU, v = 2 * M_PI * j / NV;
            int n = j * NU + i;
            double p[3] = {(1.0 + 0.4 * cos(v)) * cos(u), 0.4 * sin(v), (1.0 + 0.4 * cos(v)) * sin(u)};
            double q[3] = {cos(v) * cos(u), sin(v), cos(v) * sin(u)};
            uint8_t *r = &rec[n * RSIZE];
            for (int k = 0; k < 3; k++) {
                int fixed = (int)lround(p[k] * (1 << VPOSEXP));
                put16(r + 2 * k, fixed);
                pos[n][k] = fixed / (double)(1 << VPOSEXP);
                nrm[n][k] = q[k];
                r[8 + k] = (uint8_t)(int8_t)lround(q[k] * 127);
            }
            int v00 = n, v10 = j * NU + (i + 1) % NU;
            int v01 = ((j + 1) % NV) * NU + i, v11 = ((j + 1) % NV) * NU + (i + 1) % NU;
            int t = 2 * n;
            ta[t] = (uint8_t)v00; tb[t] = (uint8_t)v10; tc[t] = (uint8_t)v11;
            ta[t + 1] = (uint8_t)v00; tb[t + 1] = (uint8_t)v11; tc[t + 1] = (uint8_t)v01;
        }
    for (int t = 0; t < NTRI; t++) {
        const double *a = pos[ta[t]], *b = pos[tb[t]], *c = pos[tc[t]];
        double e1[3], e2[3], n[3], out = 0, len;
        for (int k = 0; k < 3; k++) { e1[k] = b[k] - a[k]; e2[k] = c[k] - a[k]; }
        n[0] = e1[1] * e2[2] - e1[2] * e2[1];
        n[1] = e1[2] * e2[0] - e1[0] * e2[2];
        n[2] = e1[0] * e2[1] - e1[1] * e2[0];
        for (int k = 0; k < 3; k++) out += n[k] * (nrm[ta[t]][k] + nrm[tb[t]][k] + nrm[tc[t]][k]);
        len = sqrt(n[0] * n[0] + n[1] * n[1] + n[2] * n[2]) * (out < 0 ? -1 : 1);   /* (out of the surface) */
        uint8_t *r = &rec[(NVTX + t) * RSIZE];
        for (int k = 0; k < 3; k++) {
            put16(r + 2 * k, (int)lround((a[k] + b[k] + c[k]) / 3 * (1 << VPOSEXP)));
            r[8 + k] = (uint8_t)(int8_t)lround(n[k] / len * 127);
        }
        int quad = t / 2, i = quad % NU, j = quad / NU;
        r[12] = ((i / 2 + j / 2) & 1) ? 127 : 0;
    }

    /* projection (FOV, 320 x 200, near and far around the torus, z in
     * [0, w]) x view (TZ away); square pixels here, the video mode's in kx */
    double fy = 1.0 / tan(FOV / 2 * M_PI / 180), fx = fy / 1.6, n = TZ - 1.6, f = TZ + 1.6;
    double A = f / (f - n), B = -f * n / (f - n);
    double pv[16] = {fx, 0, 0, 0,  0, fy, 0, 0,  0, 0, A, A * TZ + B,  0, 0, 1, TZ};
    for (int k = 0; k < 16; k++) pvb[k] = bf((float)pv[k]);
    /* the light, toward it from the surface (eye space), times the diffuse
     * term and the palette's scale: the face program's N . L is in steps */
    double le[3] = {-0.45, 0.55, -0.70}, len = sqrt(le[0] * le[0] + le[1] * le[1] + le[2] * le[2]);
    for (int k = 0; k < 3; k++) leb[k] = bf((float)(KD * LEVELS / 256 * le[k] / len));
    leb[3] = 0;
    build_progs(ntsc ? kx_ntsc : kx_pal);

    /* the model: set up as scene.asm does */
    st.stage = 5;
    mcp_reset(&st);
    mcp_vreg_write(&st, 0x04, 0);
    mcp_vreg_write(&st, 0x05, 0);
    for (size_t i = 0; i < sizeof rec; i++) mcp_vin_write(&st, rec[i]);
    st.mpptr = 0;
    mcp_mpload_restart(&st);
    for (int i = 0; i < plen; i++) mcp_mpload(&st, prog[i]);
    mcp_vreg_write(&st, 0x08, VFMT);
    mcp_vreg_write(&st, 0x09, VPOSEXP);

    /* every frame of the turn: checked; those asked for: written */
    int worst = 0, worst_at = 0, minvis = NTRI, maxvis = 0;
    for (int frame = 0; frame < 256; frame++) {
        if (run_frame(frame)) {
            fprintf(stderr, "scene: frame %d: a program ended early (MPERR %d, %d passes)\n", frame, st.mperr, st.mpcnt);
            return 1;
        }
        for (int v = 0; v < NVTX; v++) {
            const uint8_t *e = &st.vout[v * 32];
            int x = (int16_t)(e[0] | e[1] << 8), y = (int16_t)(e[2] | e[3] << 8);
            if (x < 0 || x > 319 || y < 0 || y > 199) {
                fprintf(stderr, "scene: frame %d: vertex %d is off the screen (%d, %d)\n", frame, v, x, y);
                return 1;
            }
        }
        int nvis = draw_frame(), d = depth_check();
        if (d > worst) { worst = d; worst_at = frame; }
        if (nvis < minvis) minvis = nvis;
        if (nvis > maxvis) maxvis = nvis;
        if (want[frame]) {
            char name[64];
            snprintf(name, sizeof name, "scene_res%d.bin", frame);
            write_file(dir, name, st.vout, NREC * 32);
            snprintf(name, sizeof name, "scene_fb%d.bin", frame);
            write_file(dir, name, fb, sizeof fb);
        }
    }
    printf("scene: %d vertices, %d triangles (%d-%d drawn a frame), %s; all 256 frames against a depth buffer: "
           "at most %.1f%% of the pixels differ (frame %d)\n",
           NVTX, NTRI, minvis, maxvis, ntsc ? "NTSC" : "PAL", worst / 10.0, worst_at);
    if (worst > 150) {
        fprintf(stderr, "scene: the drawing is not the nearest surface (the wrong faces culled, or a wrong order)\n");
        return 1;
    }

    /* the palette: 0 black; 1-127 gold, 128-254 sky blue, each from dark to
     * full; 255 unused */
    uint8_t pal[768] = {0};
    for (int k = 0; k < 127; k++) {
        double g = pow((k + 1) / 127.0, 0.8);
        int c0[3] = {255, 196, 72}, c1[3] = {80, 176, 255};
        for (int ch = 0; ch < 3; ch++) {
            int a = (int)lround(c0[ch] * g), b = (int)lround(c1[ch] * g);
            pal[256 * ch + 1 + k] = (uint8_t)(((a & 15) << 4) | (a >> 4));
            pal[256 * ch + 128 + k] = (uint8_t)(((b & 15) << 4) | (b >> 4));
        }
    }

    uint8_t le16[16], pv64[64], sin1k[1024], tri[1536];
    memcpy(le16, leb, 16);
    memcpy(pv64, pvb, 64);
    for (int k = 0; k < 256; k++)                           /* four planes: byte 0 of each sine, ... */
        for (int j = 0; j < 4; j++) sin1k[256 * j + k] = (uint8_t)(sintab[k] >> (8 * j));
    memcpy(tri, ta, 512);
    memcpy(tri + 512, tb, 512);
    memcpy(tri + 1024, tc, 512);
    char inc[768];
    snprintf(inc, sizeof inc,
             "NVTX = %d\nNTRI = %d\nNREC = %d\nRSIZE = %d\nVFMT = $%02X\nVPOSEXP = %d\n"
             "VPROG = %d\nVKX = %d\nFPROG = %d\nFLIGHT = %d\nPROGLEN = %d\n"
             "KX_PAL = $%08X\nKX_NTSC = $%08X\nRY0 = %d\nRX0 = %d\n",
             NVTX, NTRI, NREC, RSIZE, VFMT, VPOSEXP, VPROG, VKX, FPROG, FLIGHT, plen,
             bf(kx_pal), bf(kx_ntsc), RY0, RX0);
    write_file(dir, "scene.inc", inc, strlen(inc));
    write_file(dir, "scene_rec.bin", rec, sizeof rec);
    write_file(dir, "scene_prog.bin", prog, (size_t)plen);
    write_file(dir, "scene_tri.bin", tri, sizeof tri);
    write_file(dir, "scene_sin.bin", sin1k, sizeof sin1k);
    write_file(dir, "scene_pv.bin", pv64, sizeof pv64);
    write_file(dir, "scene_le.bin", le16, sizeof le16);
    write_file(dir, "scene_pal.bin", pal, sizeof pal);
    return 0;
}

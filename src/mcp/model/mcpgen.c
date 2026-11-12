/* mcpgen: a random bus script for the M65-MCP (src/vhdl/mcp.vhdl) and the
 * state the model (mcp_exec) says it must leave.
 *
 *   mcpgen [seed] [commands] [stage] > script
 *
 * stage (mcp_model.h): 0 MCP-1, 1 MCP-2's programs, 2 + the wide forms
 * FADD3-FMS (also through their window, $200 + op * 2), 3 + the vector and
 * matrix forms VMOVE-VNORM3, MLOAD-MMUL (half the wide forms at stage 3,
 * by every path, programs too), 4 + MCP-3 stage 1 (the default): vertex
 * uploads through VINDATA, the vertex registers, VIN, VOUT, VOUTC, VNEXT,
 * VPASS, VEND by every path, the result buffer read through its window,
 * 5 + VCLIP and PSKIP (the default; PSKIP mostly in programs, where it
 * acts). Stage
 * 1 adds programs: loaded through MPLOAD (now and then cut off by
 * MPLOADRST), read back through MPREAD, run by PRUN (the memory-form window
 * or the stream) with random counts and MPLIMIT values; the checkpoints read
 * MPPTR, MPCNT, MPERR and MPLIMIT too, and the script ends with the
 * MPABORT test (A, the bench's own).
 *
 * Script lines (hex, register offsets from $FFDF000):
 *   W aaa vv   write byte vv to aaa
 *   R aaa vv   read aaa, expect vv
 *   I          wait until MSTATUS bit 0 (busy) is clear
 *   O          the overrun test (the bench's own: 40 divides back to back)
 *   A          the MPABORT test (the bench's own, stage 1 on)
 * Commands go in by all three paths: register forms ($180 + opcode), memory
 * forms (four byte writes to $400 + m * 64 + d * 4, now and then only the
 * last one, reusing the bytes held from before) and the stream port
 * ($120-$123, its bytes interleaved with the other paths', now and then cut
 * off by MSTREAMRST). Also MCTRL and MFLAGS writes (queued), MSTATUS writes
 * (the sticky bits) and MRESET. Reserved opcodes and forms appear too. The
 * script waits for the unit at least every 8 commands (the queue holds 16)
 * and, at every checkpoint, reads back F0-F15, MINT, MCOND, MFLAGS, MCTRL,
 * MSTATUS, MQLEN, MID and MVER. */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "mcp_model.h"

static uint64_t g = 0x9E3779B97F4A7C15ull;
static uint32_t rnd32(void)
{
    g ^= g << 13; g ^= g >> 7; g ^= g << 17;
    return (uint32_t)(g >> 16);
}
#define R(n) (rnd32() % (uint32_t)(n))

static uint32_t bf(float f) { uint32_t v; memcpy(&v, &f, 4); return v; }
static uint32_t pick(void)
{
    switch (R(9)) {
    case 0: return rnd32();
    case 1: return bf((float)((int32_t)rnd32() % 100000) / (float)(1 + R(64)));
    case 2: return bf((float)((int32_t)R(200001) - 100000) + 0.5f);
    case 3: return rnd32() & 0x807FFFFF;
    case 4: return (rnd32() & 0x80000000) | (R(2) ? 0x7F800000 : 0);
    case 5: return 0x7F800000 | (rnd32() & 0x807FFFFF) | 1;
    case 6: return (rnd32() & 0x80000000) | ((uint32_t)(120 + R(20)) << 23) | (rnd32() & 0x7FFFFF);
    case 7: return R(2) ? rnd32() : (R(0x1000000) << R(9));
    default: return bf((float)(int32_t)rnd32() / 65536.0f);
    }
}

static mcp_state m;
static int stage = 5;

/* (stage 3) a vector or matrix form */
static int vector_op(void)
{
    static const int ops[] = {
        MCPW_VMOVE, MCPW_VADD, MCPW_VSUB, MCPW_VMUL, MCPW_VSCALE, MCPW_VDOT3, MCPW_VDOT4,
        MCPW_VCROSS, MCPW_VNORM3, MCPW_MLOAD, MCPW_MSTORE, MCPW_MXV, MCPW_MTXV, MCPW_MMUL
    };
    return ops[R(sizeof ops / sizeof ops[0])];
}

/* (stage 4) a vertex wide form and arguments that mostly make sense: VIN's
 * field 0-2, VOUT's format 0-5, VOUTC's and the 4-byte formats' even offset */
static int vertex_wide(int *regs, int *r2)
{
    int op = MCPW_VIN + (int)R(3);
    if (op == MCPW_VIN && R(6)) *r2 = (int)(R(3) << 4);
    if (op == MCPW_VOUT && R(6)) *regs = (int)(R(6) << 4 | (*regs & 15));
    if (op != MCPW_VIN && R(4)) *r2 &= 0xE0;
    return op;
}

/* (stage 4) a vertex register form (stage 5: VCLIP too) */
static int vertex_reg(void)
{
    static const int ops[] = {MCP_VNEXT, MCP_VPASS, MCP_VEND, MCP_VEND, MCP_VCLIP, MCP_VCLIP};
    return ops[R(stage >= 5 ? 6 : 4)];
}
static uint8_t mbuf[3];                     /* the memory forms' held bytes 0-2 */
static uint8_t wbuf;                        /* the wide forms' held first byte */
static uint8_t sq[64];                      /* stream bytes not written yet */
static int sqn, since_wait;

static long nprun, nerr[5], npasses;
static void note_prun(void) { nprun++; nerr[m.mperr < 5 ? m.mperr : 0]++; npasses += m.mpcnt; }
static void W(int a, int v) { printf("W %03X %02X\n", a, v & 255); }
static void Rd(int a, int v) { printf("R %03X %02X\n", a, v & 255); }
static void I(void) { printf("I\n"); since_wait = 0; }
/* before a write that puts a command into the unit's queue: at most 8
 * between waits (the queue holds 16; a divide takes 33 clocks) */
static void before_cmd(void) { if (since_wait >= 8) I(); }

static int len_of(uint8_t first)
{
    if (first >= 0x80 && first <= 0x8F) return 6;
    if (first == 0x90 && stage >= 1) return 4;
    return 2;
}

/* a stream byte: written now, into the model at the same moment; the byte
 * that completes a command counts as that command */
static void stream_byte(void)
{
    uint8_t b = sq[0];
    int need = len_of(m.sn ? m.sbuf[0] : b);
    int completes = m.sn == need - 1;
    memmove(sq, sq + 1, (size_t)--sqn);
    if (completes) before_cmd();
    W(0x120 + (int)R(4), b);
    mcp_stream(&m, b);
    if (completes) since_wait++;
}

/* a command's bytes in the stream's format: a register form, a memory form
 * (not PRUN: programs are run on purpose), now and then a wide form or a
 * reserved one */
static int cmd_bytes(uint8_t *b, int for_prog)
{
    int r = (int)R(100), regs = (int)R(256);
    if (for_prog && r >= 88 && R(10)) r = (int)R(60);     /* (in programs: bad commands rare) */
    uint32_t v = pick();
    if (for_prog && stage >= 3 && R(6) == 0) {             /* (stage 3: vectors and matrices in programs) */
        b[0] = 0x90; b[1] = (uint8_t)vector_op(); b[2] = (uint8_t)regs; b[3] = (uint8_t)(R(16) << 4);
        return 4;
    }
    if (stage >= 5 && R(for_prog ? 8 : 30) == 0) {         /* (stage 5: PSKIP; in a program it acts) */
        b[0] = 0x90; b[1] = MCPW_PSKIP; b[2] = (uint8_t)(R(3) ? 1u << R(8) : (uint32_t)regs);
        b[3] = (uint8_t)(R(16) << 4);
        return 4;
    }
    if (stage >= 4 && R(6) == 0) {                         /* (stage 4: the vertex path, by every path) */
        int r2 = (int)(R(16) << 4);
        b[0] = 0x90; b[1] = (uint8_t)vertex_wide(&regs, &r2); b[2] = (uint8_t)regs; b[3] = (uint8_t)r2;
        return 4;
    }
    if (for_prog && r < 12) { b[0] = MCP_PEXIT; b[1] = (uint8_t)(1 << R(4)); return 2; }
    if (for_prog && r < 22) { b[0] = MCP_PEND; b[1] = (uint8_t)regs; return 2; }
    if (r < 60) {
        int op = R(15) ? (int)R(MCP_NREGOPS) : (int)R(0x80);
        if (for_prog && op >= MCP_NREGOPS2 && R(10)) op = MCP_FADD;
        if (stage >= 4 && R(4) == 0) op = vertex_reg();
        if (op == MCP_SETCTRL) regs &= 3;
        b[0] = (uint8_t)op;
        b[1] = (uint8_t)regs;
        return 2;
    }
    if (r < 88) {
        int mf = (int)R(14);
        if (stage >= 1 && mf == MCPM_PRUN) mf = 13;
        if (for_prog && R(60) == 0) { mf = MCPM_PRUN; v = (uint32_t)R(512) | (1 + R(4)) << 16; }  /* (nesting) */
        b[0] = (uint8_t)(0x80 + mf);
        b[1] = (uint8_t)regs;
        for (int k = 0; k < 4; k++) b[2 + k] = (uint8_t)(v >> (8 * k));
        return 6;
    }
    if (r < 94 && stage >= 1) {
        b[0] = 0x90; b[1] = (uint8_t)(stage >= 3 && R(2) ? vector_op()
                                      : stage >= 2 && R(5) ? R(5) : R(2) ? 5 + R(12) : R(0x30));   /* (stage 2: mostly FADD3-FMS; reserved ones near them) */
        b[2] = (uint8_t)regs; b[3] = (uint8_t)(R(16) << 4);
        return 4;
    }
    b[0] = (uint8_t)(0x91 + R(0x6F));
    if (stage < 1) b[0] = (uint8_t)(0x90 + R(0x70));
    b[1] = (uint8_t)regs;
    return 2;
}

static void checkpoint(void)
{
    I();
    for (int d = 0; d < 16; d++)
        for (int k = 0; k < 4; k++)
            Rd(0x400 + 4 * d + k, (int)(m.f[d] >> (8 * k)));
    for (int k = 0; k < 4; k++)
        Rd(0x108 + k, (int)(m.mint >> (8 * k)));
    Rd(0x106, m.mcond);
    Rd(0x105, m.mflags);
    Rd(0x104, m.mctrl);
    Rd(0x100, mcp_status(&m));
    Rd(0x103, 0);
    Rd(0x101, 0x4D);
    Rd(0x102, stage >= 4 ? 0x03 : stage >= 1 ? 0x02 : 0x01);   /* (stage 5: MVER still $03) */
    if (stage >= 1) {
        Rd(0x10C, m.mpptr & 255);
        Rd(0x10D, m.mpptr >> 8);
        Rd(0x10E, m.mpcnt & 255);
        Rd(0x10F, m.mpcnt >> 8);
        Rd(0x110, m.mperr);
        for (int k = 0; k < 3; k++) Rd(0x114 + k, (int)(m.mplimit >> (8 * k)));
    }
    if (stage >= 4) {                                     /* the vertex registers, the current entry */
        static const int regs[] = {0x04, 0x05, 0x06, 0x07, 0x08, 0x09, 0x0C, 0x0D, 0x0E};
        for (int k = 0; k < 9; k++) Rd(regs[k], mcp_vreg_read(&m, regs[k]));
        int e = m.vtxidx & 1023;
        W(0x00E, e >> 6);
        mcp_vreg_write(&m, 0x0E, (uint8_t)(e >> 6));
        for (int k = 0; k < 32; k++) Rd(0x800 + (e & 63) * 32 + k, mcp_window_read(&m, (e & 63) * 32 + k));
    }
}

/* a program into program memory at a random place, through MPLOAD */
static void load_program(void)
{
    I();
    int at = (int)R(512), len = 1 + (int)R(30);
    int at_end = R(5) == 0;
    if (at_end) at = 512 - (int)R(8);                     /* (near the end: running past it) */
    W(0x10C, at & 255);
    W(0x10D, at >> 8);
    m.mpptr = (uint16_t)(at & 511);
    int swapped = -1;                                     /* (the regs of an FXCHG just loaded) */
    for (int i = 0; i < len; i++) {
        uint8_t b[6];
        int n = cmd_bytes(b, 1);
        if (stage >= 3 && swapped >= 0 && R(2)) {         /* (stage 3: right after an FXCHG, a read of */
            b[0] = (uint8_t)(R(2) ? MCP_FADD : MCP_FMOVE);  /*  what it swapped, in the clock it lands) */
            b[1] = (uint8_t)(R(2) ? swapped : (swapped >> 4 | (swapped & 15) << 4));
            n = 2;
        }
        swapped = n == 2 && b[0] == MCP_FXCHG ? b[1] : -1;
        if (i == len - 1 && R(4) && !at_end) { b[0] = MCP_PEND; n = 2; }   /* (mostly ending a pass) */
        if (at_end && (b[0] == MCP_PEND || b[0] == MCP_PEXIT)) { b[0] = MCP_FADD; n = 2; }
        if (R(40) == 0) {                                 /* cut off by MPLOADRST */
            int part = (int)R((uint32_t)n);
            for (int k = 0; k < part; k++) { W(0x128 + (int)R(4), b[k]); mcp_mpload(&m, b[k]); }
            W(0x12C, 0);
            mcp_mpload_restart(&m);
        }
        for (int k = 0; k < n; k++) { W(0x128 + (int)R(4), b[k]); mcp_mpload(&m, b[k]); }
    }
}

static void read_program(void)
{
    I();
    int at = (int)R(512), n = 1 + (int)R(6);
    W(0x10C, at & 255);
    W(0x10D, at >> 8);
    m.mpptr = (uint16_t)at;
    for (int i = 0; i < n; i++) {
        uint8_t b[8];
        mcp_mpread(&m, b);
        for (int k = 0; k < 8; k++) Rd(0x130 + k, b[k]);
        m.mpptr = (uint16_t)((m.mpptr + 1) & 511);         /* (reading $137 advances MPPTR) */
    }
}

int main(int argc, char **argv)
{
    long seed = argc > 1 ? atol(argv[1]) : 1, ncmd = argc > 2 ? atol(argv[2]) : 4000;
    stage = argc > 3 ? atoi(argv[3]) : 3;
    g ^= (uint64_t)seed * 0x2545F4914F6CDD1Dull;
    m.stage = stage;
    mcp_reset(&m);
    checkpoint();
    for (long c = 0; c < ncmd; c++) {
        int k = (int)R(stage >= 4 ? 132 : stage >= 2 ? 120 : stage >= 1 ? 112 : 100);
        int op, regs = (int)R(256);
        uint32_t v = pick();
        if (k < 38) {                                     /* a register form */
            op = R(12) ? (int)R(MCP_NREGOPS) : (int)R(0x80);
            if (stage >= 4 && R(5) == 0) op = vertex_reg();
            before_cmd();
            W(0x180 + op, regs);
            mcp_exec(&m, op, regs, 0);
            since_wait++;
        } else if (k < 68) {                              /* a memory form (not PRUN) */
            int mf = R(10) ? (int)R(14) : (int)R(16), d = (int)R(16);
            if (stage >= 1 && mf == MCPM_PRUN) mf = 15;
            int a = 0x400 + mf * 64 + d * 4;
            if (R(8)) {
                for (int b = 0; b < 3; b++) {
                    mbuf[b] = (uint8_t)(v >> (8 * b));
                    W(a + b, mbuf[b]);
                }
            }
            v = (v & 0xFF000000u) | (uint32_t)mbuf[2] << 16 | (uint32_t)mbuf[1] << 8 | mbuf[0];
            before_cmd();
            W(a + 3, (int)(v >> 24));
            mcp_exec(&m, 0x80 + mf, d << 4, v);
            since_wait++;
        } else if (k < 88) {                              /* a command into the stream's queue */
            if (sqn <= 40) {
                uint8_t b[6];
                int n = cmd_bytes(b, 0);
                for (int j = 0; j < n; j++) sq[sqn++] = b[j];
            }
        } else if (k < 92) {                              /* MCTRL (queued) */
            before_cmd();
            W(0x104, regs);
            mcp_exec(&m, MCP_SETCTRL, regs & 3, 0);
            since_wait++;
        } else if (k < 95) {                              /* MFLAGS (queued) */
            before_cmd();
            W(0x105, regs);
            mcp_exec(&m, MCP_SETFLAGS, regs, 0);
            since_wait++;
        } else if (k < 97) {                              /* MSTATUS: the sticky bits (at once: wait first) */
            I();
            W(0x100, regs);
            m.sticky = 0;
        } else if (k < 98 && sqn) {                       /* the stream cut off and restarted */
            int n = 1 + (int)R(sqn < 5 ? sqn : 5);
            if (n >= sqn) n = sqn - 1;
            for (int b = 0; b < n; b++) stream_byte();
            W(0x124, 0);
            mcp_stream_restart(&m);
            sqn = 0;
        } else if (k < 99) {                              /* MRESET */
            if (stage >= 4) I();                          /* (the result buffer outlives it: what is */
            W(0x107, regs);                               /*  queued or in flight, it drops) */
            mcp_reset(&m);
            sqn = 0;
            since_wait = 0;
        } else if (k < 102) {                             /* (stage 1) a program loaded */
            load_program();
        } else if (k < 108) {                             /* (stage 1) PRUN */
            int at = R(3) ? (int)m.mpptr - 1 - (int)R(30) : (int)R(512);
            uint32_t count = 1 + R(20);
            if (at < 0) at = (int)R(512);
            if (R(10) == 0 && m.mplimit && m.mplimit <= 400) count = 0;   /* (65,536 passes: the limit ends it) */
            v = (uint32_t)at | count << 16;
            int d = (int)R(16);
            before_cmd();
            if (R(2)) {                                   /* the memory-form window */
                for (int b = 0; b < 4; b++) {
                    if (b < 3) mbuf[b] = (uint8_t)(v >> (8 * b));
                    W(0x400 + MCPM_PRUN * 64 + d * 4 + b, (int)(v >> (8 * b)));
                }
                mcp_exec(&m, 0x80 + MCPM_PRUN, d << 4, v);
                note_prun();
                since_wait++;
            } else if (sqn <= 40) {                       /* the stream */
                sq[sqn++] = 0x80 + MCPM_PRUN;
                sq[sqn++] = (uint8_t)(d << 4);
                for (int b = 0; b < 4; b++) sq[sqn++] = (uint8_t)(v >> (8 * b));
            }
        } else if (k < 110) {                             /* (stage 1) MPLIMIT, while idle */
            uint32_t lim = R(3) == 0 ? 0 : R(2) ? 1 + R(300) : 0x100000;
            I();
            for (int b = 0; b < 3; b++) W(0x114 + b, (int)(lim >> (8 * b)));
            m.mplimit = lim;
        } else if (k < 112) {                             /* (stage 1) MPREAD */
            read_program();
        } else if (k < 120) {                             /* (stage 2) a wide form through its window */
            int wop = stage >= 3 && R(2) ? vector_op() : R(4) ? (int)R(5) : R(2) ? 5 + (int)R(4) : (int)R(0x80);
            int r2 = (int)(R(16) << 4);
            if (stage >= 4 && R(3) == 0) wop = vertex_wide(&regs, &r2);
            int a = 0x200 + wop * 2;
            if (R(10)) {
                wbuf = (uint8_t)regs;
                W(a, wbuf);
            }
            before_cmd();
            W(a + 1, r2);
            uint8_t sticky0 = m.sticky;
            m.sticky = 0;
            mcp_exec_wide(&m, wop, wbuf, r2);
            int bad = m.sticky & 0x08;
            m.sticky |= sticky0;
            since_wait++;
            if (bad) {                                    /* a reserved one: checked at once */
                int d = wbuf >> 4;
                I();
                Rd(0x100, mcp_status(&m));
                for (int k = 0; k < 4; k++) Rd(0x400 + 4 * d + k, (int)(m.f[d] >> (8 * k)));
                W(0x100, 0);
                m.sticky = 0;
            }
        } else if (k < 126) {                             /* (stage 4) vertex data through VINDATA */
            I();
            int at = (int)R(16384), n = 1 + (int)R(64);
            W(0x004, at & 255);
            W(0x005, at >> 8);
            mcp_vreg_write(&m, 0x04, (uint8_t)at);
            mcp_vreg_write(&m, 0x05, (uint8_t)(at >> 8));
            for (int i = 0; i < n; i += 4) {
                uint32_t w = R(3) ? pick() : rnd32();
                for (int j = 0; j < 4 && i + j < n; j++) {
                    W((int)R(4), (int)(w >> (8 * j)));
                    mcp_vin_write(&m, (uint8_t)(w >> (8 * j)));
                }
            }
        } else if (k < 129) {                             /* (stage 4) a vertex register */
            static const int regs4[] = {0x06, 0x07, 0x08, 0x08, 0x09, 0x0C, 0x0D, 0x0E, 0x05};
            int a = regs4[R(9)];
            I();
            W(a, regs);
            mcp_vreg_write(&m, a, (uint8_t)regs);
        } else {                                          /* (stage 4) the result buffer, some of it */
            I();
            int bank = (int)R(16), at = (int)R(2048), n = 1 + (int)R(32);
            W(0x00E, bank);
            mcp_vreg_write(&m, 0x0E, (uint8_t)bank);
            for (int i = 0; i < n; i++) Rd(0x800 + ((at + i) & 2047), mcp_window_read(&m, at + i));
        }
        /* the stream's bytes, a few at a time, between the other paths' */
        for (int b = (int)R(7); b > 0 && sqn; b--) stream_byte();
        if (R(30) == 0) checkpoint();
    }
    while (sqn) stream_byte();
    checkpoint();
    printf("O\n");
    if (stage >= 1) printf("A\n");
    if (stage >= 1)
        fprintf(stderr, "mcpgen: %ld PRUN by the window (as many by the stream): %ld ended, %ld past the end, "
                "%ld MPLIMIT, %ld bad commands; %ld passes\n", nprun, nerr[0], nerr[1], nerr[2], nerr[4], npasses);
    return 0;
}

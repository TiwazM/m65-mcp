/* mandel.c: the benchmark's Mandelbrot (mandelref.c) in C, float, with
 * llvm-mos's soft-float on the 45GS02.
 *
 *   ~/llvm-mos/bin/mos-mega65-clang -Os -o mandel_c.prg mandel.c
 *   ~/llvm-mos/bin/mos-mega65-clang -Os -DBIG -o mandel_c_80x50.prg mandel.c
 * BIG: 80 x 50 points over the same region (steps 1/32, 1/16).
 *
 * Same points, iterations and operation order as mandelref.c and
 * mandel_mcp.asm; timed the same way (CIA 2's timers cascaded, A counting
 * the 1 MHz phase, B A's underflows). The counts go to a static array whose
 * address is left at $0345.
 *   $0340        $A5 when done
 *   $0341-$0344  CIA 2 timer A, timer B (stopped; from $FFFF each)
 *   $0345-$0346  the counts' address (COLS x ROWS bytes, row by row) */
#include <stdint.h>

#define MAXIT 32
#define REG(a) (*(volatile uint8_t *)(a))
#ifdef BIG
#define COLS 80
#define ROWS 50
#define DX 0.03125f
#define DY 0.0625f
#else
#define COLS 40
#define ROWS 25
#define DX 0.0625f
#define DY 0.125f
#endif

static uint8_t counts[COLS * ROWS];

int main(void)
{
    __asm__ volatile("sei");
    REG(0xD02F) = 0x47;                          /* VIC-IV registers, 40.5 MHz */
    REG(0xD02F) = 0x53;
    REG(0xD031) |= 0x40;
    REG(0xD054) |= 0x40;
    REG(0x0340) = 0;

    REG(0xDD0D) = 0x7F;                          /* CIA 2: no interrupts, latches $FFFF */
    REG(0xDD0E) = 0;
    REG(0xDD0F) = 0;
    REG(0xDD04) = 0xFF;
    REG(0xDD05) = 0xFF;
    REG(0xDD06) = 0xFF;
    REG(0xDD07) = 0xFF;
    REG(0xDD0F) = 0x51;                          /* B: A's underflows */
    REG(0xDD0E) = 0x11;                          /* A: the 1 MHz phase */

    uint8_t *out = counts;
    float y0 = -1.5f;
    for (uint8_t r = 0; r < ROWS; r++) {
        float x0 = -2.0f;
        for (uint8_t c = 0; c < COLS; c++) {
            float x = 0.0f, y = 0.0f;
            uint8_t i = 0;
            for (; i < MAXIT; i++) {
                float x2 = x * x, y2 = y * y;
                if (x2 + y2 > 4.0f) break;
                float t = x * y;
                y = (t + t) + y0;
                x = (x2 - y2) + x0;
            }
            *out++ = i;
            x0 += DX;
        }
        y0 += DY;
    }

    REG(0xDD0E) = 0;                             /* the timer stopped */
    REG(0x0341) = REG(0xDD04);
    REG(0x0342) = REG(0xDD05);
    REG(0x0343) = REG(0xDD06);
    REG(0x0344) = REG(0xDD07);
    REG(0x0345) = (uint8_t)((uintptr_t)counts);
    REG(0x0346) = (uint8_t)((uintptr_t)counts >> 8);
    REG(0x0340) = 0xA5;
    REG(0xD020) = 5;
    for (;;)
        ;
}

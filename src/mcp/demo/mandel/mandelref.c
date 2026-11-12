/* mandelref: the benchmark's Mandelbrot on the host, the reference for the
 * MEGA65 versions (mandel_mcp.asm, mandel.c, mandel.bas).
 *
 *   mandelref <dir>          writes ref32.bin (IEEE single) and ref64.bin (double)
 *   mandelref <dir> 80x50    ref32_80x50.bin, ref64_80x50.bin
 *
 * 40 x 25 points (a text screen): x0 = -2 + col / 16, y0 = -1.5 + row / 8 -
 * every input exact in every format. 80 x 50: the same region at twice the
 * resolution, x0 = -2 + col / 32, y0 = -1.5 + row / 16. Per point at most
 * MAXIT iterations of
 *   x2 = x * x; y2 = y * y; stop when x2 + y2 > 4
 *   t = x * y; y = (t + t) + y0; x = (x2 - y2) + x0
 * in exactly this order; the result is the number of iterations done.
 * Build with -ffp-contract=off: every operation rounded on its own, as the
 * MCP and llvm-mos's soft-float do. */
#include <stdio.h>
#include <string.h>

#define MAXIT 32

#define MANDEL(T, out)                                                   \
    for (int r = 0; r < rows; r++)                                       \
        for (int c = 0; c < cols; c++) {                                 \
            T x0 = (T)-2 + (T)c / (T)xd, y0 = (T)-1.5 + (T)r / (T)yd;    \
            T x = 0, y = 0;                                              \
            int i = 0;                                                   \
            for (; i < MAXIT; i++) {                                     \
                T x2 = x * x, y2 = y * y;                                \
                if (x2 + y2 > (T)4) break;                               \
                T t = x * y;                                             \
                y = (t + t) + y0;                                        \
                x = (x2 - y2) + x0;                                      \
            }                                                            \
            out[r * cols + c] = (unsigned char)i;                        \
        }

int main(int argc, char **argv)
{
    static unsigned char r32[4000], r64[4000];
    int big = argc > 2 && strcmp(argv[2], "80x50") == 0;
    int cols = big ? 80 : 40, rows = big ? 50 : 25, xd = big ? 32 : 16, yd = big ? 16 : 8, n = cols * rows;
    const char *sfx = big ? "_80x50" : "";
    MANDEL(float, r32)
    MANDEL(double, r64)
    char path[4096];
    long sum = 0;
    int diff = 0;
    for (int k = 0; k < n; k++) {
        sum += r32[k];
        diff += r32[k] != r64[k];
    }
    snprintf(path, sizeof path, "%s/ref32%s.bin", argc > 1 ? argv[1] : ".", sfx);
    FILE *f = fopen(path, "wb");
    if (!f || fwrite(r32, 1, (size_t)n, f) != (size_t)n || fclose(f)) { perror(path); return 1; }
    snprintf(path, sizeof path, "%s/ref64%s.bin", argc > 1 ? argv[1] : ".", sfx);
    f = fopen(path, "wb");
    if (!f || fwrite(r64, 1, (size_t)n, f) != (size_t)n || fclose(f)) { perror(path); return 1; }
    printf("mandelref: %d x %d: %ld iterations (FP32); FP32 and double differ at %d of %d points\n",
           cols, rows, sum, diff, n);
    return 0;
}

/* mandel: the displayed Mandelbrot's data (mandel.asm), prepared on the
 * host, and the frame buffer the MCP must leave.
 *
 *   mandel <outdir>
 *
 * 320 x 200 points, x0 = -2.2 + col * 0.01, y0 = -1.0 + row * 0.01, each
 * an FP32 sum accumulated as the MCP does it (x0 += dx a column, y0 from
 * -1.0 again each column, += dy a point), at most MAXIT iterations in the
 * order of mandel_prog.asm's pipelined program. Build with
 * -ffp-contract=off: every operation rounded on its own, as the MCP's.
 *
 * Writes into outdir:
 *   mandel.inc         MAXIT and the constants (FP32 bits), for ACME
 *   mandel_pal.bin     the palette: 256 red, green, blue (nybbles swapped)
 *   mandel_counts.bin  the counts, a column after another (col * 200 + row):
 *                      the emulator's stand-in for the MCP (TEST=1)
 *   mandel_fb.bin      the frame buffer (show.inc's layout), 64,000 bytes
 */
#include <math.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define W 320
#define H 200
#define MAXIT 128

static uint32_t bits(float f) { uint32_t v; memcpy(&v, &f, 4); return v; }

static void write_file(const char *dir, const char *name, const void *p, size_t n)
{
    char path[4096];
    snprintf(path, sizeof path, "%s/%s", dir, name);
    FILE *f = fopen(path, "wb");
    if (!f || fwrite(p, 1, n, f) != n || fclose(f)) { perror(path); exit(1); }
}

/* the colour for a count: 0 inside, else 1 + the count */
static int colour(int n) { return n == MAXIT ? 0 : n + 1; }

int main(int argc, char **argv)
{
    const char *dir = argc > 1 ? argv[1] : ".";
    const float x0s = -2.2f, y0s = -1.0f, dx = 0.01f, dy = 0.01f;
    static uint8_t counts[W * H], fb[W * H];
    long iters = 0, inside = 0;
    float x0 = x0s;
    for (int col = 0; col < W; col++) {
        float y0 = y0s;
        for (int row = 0; row < H; row++) {
            float x = 0, y = 0;
            int n = 0;
            while (n < MAXIT) {
                float y2 = y * y, x2 = x * x, s = x2 + y2;
                if (s > 4.0f) break;            /* PEXIT: this pass isn't counted */
                float t = y * x, xn = x2 - y2;
                t = t + t;
                x = xn + x0;
                y = t + y0;
                n++;
            }
            counts[col * H + row] = (uint8_t)n;
            fb[(col >> 3) * 1600 + row * 8 + (col & 7)] = (uint8_t)colour(n);
            iters += n;
            inside += n == MAXIT;
            y0 = y0 + dy;
        }
        x0 = x0 + dx;
    }

    /* the palette: 0 black; 1 + n a gradient through deep blue, light blue,
     * white, orange and near black that repeats every 32 counts, faded
     * toward black for the first few (far from the set) */
    static const double stop[6][4] = {
        {0.0, 0, 7, 100}, {0.16, 32, 107, 203}, {0.42, 237, 255, 255},
        {0.6425, 255, 170, 0}, {0.8575, 0, 2, 0}, {1.0, 0, 7, 100}
    };
    uint8_t pal[768] = {0};
    for (int n = 0; n < MAXIT; n++) {
        double t = (n % 32) / 32.0, fade = n < 8 ? (n + 2) / 10.0 : 1.0;
        int s = 0;
        while (t > stop[s + 1][0]) s++;
        double f = (t - stop[s][0]) / (stop[s + 1][0] - stop[s][0]);
        for (int k = 0; k < 3; k++) {
            int v = (int)lround(fade * (stop[s][1 + k] + f * (stop[s + 1][1 + k] - stop[s][1 + k])));
            v = v < 0 ? 0 : v > 255 ? 255 : v;
            pal[256 * k + 1 + n] = (uint8_t)(((v & 15) << 4) | (v >> 4));
        }
    }

    char inc[512];
    snprintf(inc, sizeof inc,
             "MAXIT = %d\nX0START = $%08X\nY0START = $%08X\nDX = $%08X\nDY = $%08X\n",
             MAXIT, bits(x0s), bits(y0s), bits(dx), bits(dy));
    write_file(dir, "mandel.inc", inc, strlen(inc));
    write_file(dir, "mandel_pal.bin", pal, sizeof pal);
    write_file(dir, "mandel_counts.bin", counts, sizeof counts);
    write_file(dir, "mandel_fb.bin", fb, sizeof fb);
    printf("mandel: %d x %d points, %ld iterations (%ld points inside, at %d each)\n",
           W, H, iters, inside, MAXIT);
    return 0;
}

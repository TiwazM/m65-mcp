; mandel - the Mandelbrot on the screen: 320 x 200 points in 256 colours,
; each computed by the M65-MCP (mandel_prog.asm's pipelined inner loop as a
; program) and drawn as it comes, a column after another.
;
; Assemble with ACME 0.97+ (show.py does it), out/ holding mandel.c's files:
;   acme -f cbm -I ../../include -I out -o out/mandel.prg mandel.asm
; -DTEST=1: no MCP; the counts come from mandel_counts.bin, loaded at
; $50000 (column after column) - the display alone, for an emulator.
;
; x0 = -2.2 + col * 0.01, y0 = -1.0 + row * 0.01, at most MAXIT
; iterations; colour 0 (black) inside, else 1 + the count. The frame buffer
; at $40000 (show.inc's layout), the screen RAM at $C000. Timed by CIA 2.
;   $0340        $A5 when done
;   $0341-$0344  CIA 2 timer A, timer B (stopped; from $FFFF each)
; Registers: F0 x0, F1 y0, F2 x, F3 y, F4 x*x, F5 y*y, F6 x*x + y*y,
; F7 4.0, F8 dx, F9 dy, F10 y0's start.

!cpu m65
!source "mcp.inc"
!source "show.inc"
!source "mandel.inc"
!ifndef TEST { TEST = 0 }

FB      = $40000
SCREEN  = $c000
COUNTS  = $50000            ; (TEST)
STATS   = $0340
ctrl    = $02               ; (4) the MCP's control page
fp      = $06               ; (4) $FFDF4xx: F registers (memory forms)
prun    = $0a               ; (4) $FFDF780: PRUN
pix     = $0e               ; (4) the next pixel
cnt     = $12               ; (4) (TEST) the next count
colbase = $16               ; (4) the column's pixel at row 0
v_col   = $1a               ; (2) the column
v_row   = $1c

* = $2001
        !word +, 10
        !byte $9e
        !text "8208"        ; SYS $2010
        !byte 0
+       !word 0

* = $2010
start:
        +show_machine
        lda #0
        sta STATS
        +show_screen SCREEN, FB
        +show_palette palette

!if TEST = 0 {
        +mcp_ptr ctrl, MCP_CTRLPAGE
        +mcp_ptr fp, MCP_FREGS
        +mcp_ptr prun, MCP + $400 + MCPM_PRUN * 64
        ldz #MCP_RESET
        lda #0
        sta [ctrl],z        ; MRESET
        +mcp_op ctrl, MCP_FCONST, 7, MCPC_TWO
        +mcp_op ctrl, MCP_FADD, 7, 7            ; F7 = 4.0
        lda #0 * 4
        sta fp
        ldq c_x0
        stq [fp]                                ; F0 = x0's start
        lda #8 * 4
        sta fp
        ldq c_dx
        stq [fp]                                ; F8 = dx
        lda #9 * 4
        sta fp
        ldq c_dy
        stq [fp]                                ; F9 = dy
        lda #10 * 4
        sta fp
        ldq c_y0
        stq [fp]                                ; F10 = y0's start
        +mcp_wait ctrl
        lda #0                                  ; the program at entry 0
        ldz #MCP_MPPTR
        sta [ctrl],z
        inz
        sta [ctrl],z
        ldx #0
-       lda program,x
        ldz #MCP_MPLOAD
        sta [ctrl],z
        inx
        cpx #program_end - program
        bne -
} else {
        +mcp_ptr cnt, COUNTS
}

        ; CIA 2: no interrupts, both latches $FFFF, then B (A's underflows) and A (1 MHz)
        lda #$7f
        sta $dd0d
        lda #0
        sta $dd0e
        sta $dd0f
        lda #$ff
        sta $dd04
        sta $dd05
        sta $dd06
        sta $dd07
        lda #$51
        sta $dd0f
        lda #$11
        sta $dd0e

        +mcp_ptr colbase, FB
        lda #0
        sta v_col
        sta v_col+1
colloop:
        ldq colbase         ; the column's first pixel: colbase + (col & 7)
        stq pix
        lda v_col
        and #7
        clc
        adc pix
        sta pix
!if TEST = 0 {
        +mcp_op ctrl, MCP_FMOVE, 1, 10          ; y0 = its start
}
        lda #200
        sta v_row
rowloop:
!if TEST = 0 {
        +mcp_op ctrl, MCP_FCONST, 2, MCPC_ZERO  ; x = 0
        +mcp_op ctrl, MCP_FCONST, 3, MCPC_ZERO  ; y = 0
        ldq c_prun
        stq [prun]                              ; PRUN 0, MAXIT passes
        +mcp_op ctrl, MCP_FADD, 1, 9            ; y0 += dy (after the program)
        +mcp_wait ctrl
        ldz #MCP_MPCNT
        lda [ctrl],z                            ; the passes completed: the iterations
} else {
        ldz #0
        lda [cnt],z
        inw cnt
        bne +
        inc cnt+2
+
}
        cmp #MAXIT
        bne +
        lda #$ff            ; inside: colour 0
+       inc                 ; else 1 + the count
        ldz #0
        sta [pix],z
        clc                 ; the next row: 8 bytes on
        lda pix
        adc #8
        sta pix
        bcc +
        inw pix+1
+       dec v_row
        bne rowloop

!if TEST = 0 {
        +mcp_op ctrl, MCP_FADD, 0, 8            ; x0 += dx
}
        inw v_col
        lda v_col
        and #7
        bne +
        clc                 ; a new column of characters: 1,600 bytes on
        lda colbase
        adc #<1600
        sta colbase
        lda colbase+1
        adc #>1600
        sta colbase+1
        bcc +
        inc colbase+2
+       lda v_col
        cmp #<320
        bne +
        lda v_col+1
        cmp #>320
        beq ++
+       jmp colloop
++

        lda #0
        sta $dd0e           ; the timer stopped
        lda $dd04
        sta STATS+1
        lda $dd05
        sta STATS+2
        lda $dd06
        sta STATS+3
        lda $dd07
        sta STATS+4
        lda #$a5
        sta STATS
-       jmp -

c_x0:   !32 X0START
c_y0:   !32 Y0START
c_dx:   !32 DX
c_dy:   !32 DY
c_prun: !32 MAXIT << 16     ; PRUN: entry 0, MAXIT passes

; the inner loop (mandel_prog.asm's PIPE=1 program): y's chain first
program:
        !byte $90, MCPW_FMUL3, $53, $30         ; y2 = y * y
        !byte $90, MCPW_FMUL3, $42, $20         ; x2 = x * x
        !byte $90, MCPW_FADD3, $64, $50         ; x2 + y2
        !byte MCP_FCMP, $67                     ; > 4 ?
        !byte MCP_PEXIT, 4                      ; greater: leave
        !byte MCP_FMUL, $32                     ; t = y * x
        !byte $90, MCPW_FSUB3, $24, $50         ; x2 - y2
        !byte MCP_FADD, $33                     ; t + t
        !byte MCP_FADD, $20                     ; x = (x2 - y2) + x0
        !byte MCP_FADD, $31                     ; y = (t + t) + y0
        !byte MCP_PEND, 0
program_end:

        +show_data
palette: !binary "mandel_pal.bin"

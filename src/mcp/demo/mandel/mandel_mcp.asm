; mandel_mcp - the benchmark's Mandelbrot (mandelref.c) in FP32 on MCP-1.
;
; Assemble with ACME 0.97+ (bench.sh does it):
;   acme -f cbm -I ../../include -o mandel_mcp.prg mandel_mcp.asm
;
; 40 x 25 points, x0 = -2 + col / 16, y0 = -1.5 + row / 8, at most 32
; iterations; every point's count goes to chip RAM $40000 + row * 40 + col.
; -DBIG=1: 80 x 50 points over the same region, x0 = -2 + col / 32,
; y0 = -1.5 + row / 16, the counts at $40000 + row * 80 + col.
; Timed by CIA 2's timers cascaded (A counts the 1 MHz phase, B counts A's
; underflows), started before the first point and stopped after the last.
;   $0340        $A5 when done
;   $0341-$0344  CIA 2 timer A, timer B (stopped; from $FFFF each)
; Registers: F0 x0, F1 y0, F2 x, F3 y, F4 x*x, F5 y*y, F6 x*x + y*y,
; F7 4.0, F8 the x step (1/16), F9 the y step (1/8), F10 -2.0. An
; iteration is 13 register-form commands; the compare goes before the
; update, so the CPU waits once an iteration (an escaped point has computed
; one update it doesn't use).

!cpu m65
!source "mcp.inc"

MAXIT   = 32
!ifndef BIG { BIG = 0 }
!if BIG {                   ; (BIG=1: 80 x 50 points over the same region)
COLS    = 80
ROWS    = 50
XSTEP   = $3d000000         ; 1/32
YSTEP   = $3d800000         ; 1/16
} else {
COLS    = 40
ROWS    = 25
XSTEP   = $3d800000         ; 1/16
YSTEP   = $3e000000         ; 1/8
}
OUT     = $40000
STATS   = $0340
ctrl    = $02              ; (4) the MCP's control page
fp      = $06              ; (4) $FFDF4xx: F registers (memory forms)
outp    = $0a              ; (4) the next count
v_row     = $0e
v_col     = $0f
v_it      = $10

* = $2001
        !word +, 10
        !byte $9e
        !text "8208"        ; SYS $2010
        !byte 0
+       !word 0

* = $2010
start:
        sei
        lda #0
        tab
        lda #$47
        sta $d02f
        lda #$53
        sta $d02f
        lda $d031
        ora #$40
        sta $d031
        lda $d054
        ora #$40
        sta $d054           ; 40.5 MHz
        lda #0
        sta $d020
        sta STATS

        +mcp_ptr ctrl, MCP_CTRLPAGE
        +mcp_ptr fp, MCP_FREGS
        +mcp_ptr outp, OUT
        ldz #MCP_RESET
        sta [ctrl],z        ; (A = 0) MRESET

        ; the constants, as memory forms (FMOVE: $400 + d * 4)
        +mcp_op ctrl, MCP_FCONST, 7, MCPC_TWO
        +mcp_op ctrl, MCP_FADD, 7, 7            ; F7 = 4.0
        lda #8 * 4
        sta fp
        ldq c_dx
        stq [fp]                                ; F8 = the x step (1/16)
        lda #9 * 4
        sta fp
        ldq c_dy
        stq [fp]                                ; F9 = the y step (1/8)
        lda #10 * 4
        sta fp
        ldq c_m2
        stq [fp]                                ; F10 = -2.0
        lda #1 * 4
        sta fp
        ldq c_m15
        stq [fp]                                ; F1 = -1.5
        +mcp_wait ctrl

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

        lda #ROWS
        sta v_row
rowloop:
        +mcp_op ctrl, MCP_FMOVE, 0, 10          ; x0 = -2
        lda #COLS
        sta v_col
colloop:
        +mcp_op ctrl, MCP_FCONST, 2, MCPC_ZERO  ; x = 0
        +mcp_op ctrl, MCP_FCONST, 3, MCPC_ZERO  ; y = 0
        lda #0
        sta v_it
iter:
        +mcp_op ctrl, MCP_FMOVE, 4, 2
        +mcp_op ctrl, MCP_FMUL, 4, 2            ; x2 = x * x
        +mcp_op ctrl, MCP_FMOVE, 5, 3
        +mcp_op ctrl, MCP_FMUL, 5, 3            ; y2 = y * y
        +mcp_op ctrl, MCP_FMOVE, 6, 4
        +mcp_op ctrl, MCP_FADD, 6, 5            ; x2 + y2
        +mcp_op ctrl, MCP_FCMP, 6, 7            ; > 4 ?
        +mcp_op ctrl, MCP_FMUL, 3, 2            ; t = x * y
        +mcp_op ctrl, MCP_FADD, 3, 3            ; t + t
        +mcp_op ctrl, MCP_FADD, 3, 1            ; y = (t + t) + y0
        +mcp_op ctrl, MCP_FMOVE, 2, 4
        +mcp_op ctrl, MCP_FSUB, 2, 5            ; x2 - y2
        +mcp_op ctrl, MCP_FADD, 2, 0            ; x = (x2 - y2) + x0
        +mcp_wait ctrl
        ldz #MCP_COND
        lda [ctrl],z
        and #4                                  ; greater: escaped
        bne done
        inc v_it
        lda v_it
        cmp #MAXIT
        bne iter
done:
        lda v_it
        ldz #0
        sta [outp],z
        inw outp
        +mcp_op ctrl, MCP_FADD, 0, 8            ; x0 += the x step
        dec v_col
        beq +
        jmp colloop
+       +mcp_op ctrl, MCP_FADD, 1, 9            ; y0 += the y step
        dec v_row
        beq +
        jmp rowloop
+
        lda #0
        sta $dd0e                               ; the timer stopped
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
        lda #5
        sta $d020
-       jmp -

c_dx:   !32 XSTEP
c_dy:   !32 YSTEP
c_m2:   !32 $c0000000       ; -2.0
c_m15:  !32 $bfc00000       ; -1.5

; mandel_prog - the benchmark's Mandelbrot (mandelref.c) in FP32 on MCP-2:
; mandel_mcp.asm with the inner loop as a program in the MCP.
;
; Assemble with ACME 0.97+ (bench.py does it):
;   acme -f cbm -I ../../include -o mandel_prog.prg mandel_prog.asm
;   acme -f cbm -I ../../include -DWIDE=1 -o mandel_wide.prg mandel_prog.asm
; WIDE=1 (MCP-2 stage 2 on): the program with the three-register forms,
; 11 entries instead of 15, the same operations and the same results.
;   acme -f cbm -I ../../include -DWIDE=1 -DPIPE=1 -o mandel_pipe.prg mandel_prog.asm
; PIPE=1 (with WIDE=1; for MCP-2 stage 3a's pipeline): the same 11 entries
; in another order, independent commands between dependent ones; the same
; operations on the same operands, so the same results.
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
; F7 4.0, F8 the x step (1/16), F9 the y step (1/8), F10 -2.0. The inner
; loop is a 15-entry program (MCP-1's two-register forms, PEXIT, PEND),
; loaded once through MPLOAD at entry 0; per point the CPU queues x = 0,
; y = 0, PRUN 0 (32 passes) and x0 += the x step, waits, and reads MPCNT:
; the iterations, the same count as mandel_mcp.asm's (an escaped pass is
; not counted).

!cpu m65
!source "mcp.inc"
!ifndef WIDE { WIDE = 0 }
!ifndef PIPE { PIPE = 0 }

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
prun    = $12              ; (4) $FFDF780: PRUN (memory form 14, F0)
outp    = $0a              ; (4) the next count
v_row     = $0e
v_col     = $0f
v_it      = $10              ; (unused here)

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
        +mcp_ptr prun, MCP + $400 + MCPM_PRUN * 64
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

        ; the program, at entry 0
        lda #0
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
        ldq c_prun
        stq [prun]                              ; PRUN 0, MAXIT passes
        +mcp_op ctrl, MCP_FADD, 0, 8            ; x0 += the x step (after the program)
        +mcp_wait ctrl
        ldz #MCP_MPCNT
        lda [ctrl],z                            ; the passes completed: the iterations
        ldz #0
        sta [outp],z
        inw outp
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
c_prun: !32 MAXIT << 16     ; PRUN: entry 0, MAXIT passes

; the inner loop, in the stream's format: register forms (opcode, regs),
; wide forms ($90, op, (d << 4) | s, t << 4)
program:
!if PIPE {
        ; y's chain is the longest (y2, the sum, the compare, then x * y, t + t,
        ; + y0): it goes first, and x's commands fill its waits
        !byte $90, MCPW_FMUL3, $53, $30         ; y2 = y * y
        !byte $90, MCPW_FMUL3, $42, $20         ; x2 = x * x
        !byte $90, MCPW_FADD3, $64, $50         ; x2 + y2
        !byte MCP_FCMP, $67                     ; > 4 ?
        !byte MCP_PEXIT, 4                      ; greater: leave
        !byte MCP_FMUL, $32                     ; t = x * y
        !byte $90, MCPW_FSUB3, $24, $50         ; x2 - y2 (x was read just above)
        !byte MCP_FADD, $33                     ; t + t
        !byte MCP_FADD, $20                     ; x = (x2 - y2) + x0
        !byte MCP_FADD, $31                     ; y = (t + t) + y0
        !byte MCP_PEND, 0
} else {
!if WIDE {
        !byte $90, MCPW_FMUL3, $42, $20         ; x2 = x * x
        !byte $90, MCPW_FMUL3, $53, $30         ; y2 = y * y
        !byte $90, MCPW_FADD3, $64, $50         ; x2 + y2
} else {
        !byte MCP_FMOVE, $42, MCP_FMUL, $42     ; x2 = x * x
        !byte MCP_FMOVE, $53, MCP_FMUL, $53     ; y2 = y * y
        !byte MCP_FMOVE, $64, MCP_FADD, $65     ; x2 + y2
}
        !byte MCP_FCMP, $67                     ; > 4 ?
        !byte MCP_PEXIT, 4                      ; greater: leave
        !byte MCP_FMUL, $32, MCP_FADD, $33      ; t = x * y; t + t
        !byte MCP_FADD, $31                     ; y = (t + t) + y0
!if WIDE {
        !byte $90, MCPW_FSUB3, $24, $50         ; x2 - y2
} else {
        !byte MCP_FMOVE, $24, MCP_FSUB, $25     ; x2 - y2
}
        !byte MCP_FADD, $20                     ; x = (x2 - y2) + x0
        !byte MCP_PEND, 0
}
program_end:

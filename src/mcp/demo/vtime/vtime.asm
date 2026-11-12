; vtime - MCP-2's commands timed on the board: each test is a program of
; one command and PEND, run 1,000 passes by one PRUN and timed by CIA 2
; (as the Mandelbrot bench times). Test 0 is PEND alone: the passes' own
; cost, which vtime.py takes off the others.
;
; Assemble with ACME 0.97+ (vtime.py does it):
;   acme -f cbm -I ../../include -o vtime.prg vtime.asm
;
; F0-F15 start as 1.25 + i / 4 and M as a copy (MLOAD); the tests run in
; the table's order, MMUL last (its products grow each pass).
;   $3000         $A5 when done
;   $3001 + 4 i   test i: CIA 2 timer A, timer B (stopped; from $FFFF each)

!cpu m65
!source "mcp.inc"

STATS   = $3000            ; (past the program: BASIC never runs again)
PASSES  = 1000
ctrl    = $02              ; (4) the MCP's control page
fp      = $06              ; (4) F0-F15
prun    = $12              ; (4) PRUN (memory form 14, F0)
wide    = $16              ; (4) the wide forms' window
v_test  = $0e              ; the test running
v_out   = $0f              ; its offset in STATS

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
        +mcp_ptr prun, MCP + $400 + MCPM_PRUN * 64
        +mcp_ptr wide, MCP_WIDE
        ldz #MCP_RESET
        sta [ctrl],z        ; (A = 0) MRESET

        ; F0-F15 (memory forms FMOVE, $400 + d * 4: the fourth byte issues)
        ldx #0
-       txa
        taz
        lda fvals,x
        sta [fp],z
        inx
        cpx #64
        bne -
        ldz #MCPW_MLOAD * 2
        lda #0
        sta [wide],z
        inz
        sta [wide],z        ; MLOAD: M = F
        +mcp_wait ctrl

        lda #0
        sta v_test
        lda #1
        sta v_out
testloop:
        ; the test's program at entry 0: MPLOAD restarted, MPPTR 0, its 6 bytes
        ldz #MCP_MPLOADRST
        sta [ctrl],z
        lda #0
        ldz #MCP_MPPTR
        sta [ctrl],z
        inz
        sta [ctrl],z
        lda v_test
        asl
        sta v_out+0         ; (scratch: test * 6 = test * 2 + test * 4)
        asl
        clc
        adc v_out+0
        tax
        ldy #6
-       lda tests,x
        ldz #MCP_MPLOAD
        sta [ctrl],z
        inx
        dey
        bne -
        lda v_test
        asl
        asl
        clc
        adc #1
        sta v_out           ; (the stats offset again: 1 + test * 4)
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

        ldq c_prun
        stq [prun]                              ; PRUN 0, PASSES passes
        +mcp_wait ctrl

        lda #0
        sta $dd0e                               ; the timer stopped
        ldx v_out
        lda $dd04
        sta STATS,x
        lda $dd05
        sta STATS+1,x
        lda $dd06
        sta STATS+2,x
        lda $dd07
        sta STATS+3,x

        inc v_test
        lda v_test
        cmp #NTESTS
        beq +
        jmp testloop
+       lda #$a5
        sta STATS
        lda #5
        sta $d020
-       jmp -

c_prun: !32 PASSES << 16    ; PRUN: entry 0, PASSES passes

; F0-F15 = 1.25 + i / 4
fvals:
!for i, 0, 15 {
        !32 $3fa00000 + i * $40000
}

; the tests: six bytes each, in the stream's format (wide forms: $90, op,
; (d << 4) | s, t << 4); the order vtime.py names them in
tests:
        !byte MCP_PEND, 0, MCP_PEND, 0, MCP_PEND, 0      ; PEND alone
        !byte $90, MCPW_FADD3, $12, $30, MCP_PEND, 0     ; FADD3 F1, F2, F3
        !byte MCP_FDIV, $11, MCP_PEND, 0, MCP_PEND, 0    ; FDIV F1, F1 (1 / 1 from the second pass)
        !byte $90, MCPW_VMOVE, $12, $00, MCP_PEND, 0     ; VMOVE V1, V2
        !byte $90, MCPW_VADD, $12, $30, MCP_PEND, 0      ; VADD V1, V2, V3
        !byte $90, MCPW_VSCALE, $12, $30, MCP_PEND, 0    ; VSCALE V1, V2, F3
        !byte $90, MCPW_VDOT3, $42, $30, MCP_PEND, 0     ; VDOT3 F4, V2, V3
        !byte $90, MCPW_VDOT4, $42, $30, MCP_PEND, 0     ; VDOT4 F4, V2, V3
        !byte $90, MCPW_VCROSS, $12, $30, MCP_PEND, 0    ; VCROSS V1, V2, V3
        !byte $90, MCPW_VNORM3, $12, $00, MCP_PEND, 0    ; VNORM3 V1, V2
        !byte $90, MCPW_MLOAD, $00, $00, MCP_PEND, 0     ; MLOAD
        !byte $90, MCPW_MSTORE, $00, $00, MCP_PEND, 0    ; MSTORE
        !byte $90, MCPW_MXV, $12, $00, MCP_PEND, 0       ; MXV V1, V2
        !byte $90, MCPW_MTXV, $12, $00, MCP_PEND, 0      ; MTXV V1, V2
        !byte $90, MCPW_MMUL, $00, $00, MCP_PEND, 0      ; MMUL
tests_end:
NTESTS = (tests_end - tests) / 6

; vtime - the M65-MCP's commands timed on the board. vtime.py lists the
; tests and writes their table (out/vtime_tests.bin, out/vtime.inc): each
; is a program, run PASSES passes by one PRUN and timed by CIA 2 (as the
; Mandelbrot bench times). Test 0 is PEND alone: the passes' own cost,
; which vtime.py takes off the others. After them, what a command costs the
; CPU: six loops of 1,024 turns (the first the loop alone). Everything is
; timed REPS times, one after the other: the CIA's clock (from the video
; timing) now and then reads about 30 us short, and vtime.py takes the
; longest.
;
; Assemble with ACME 0.97+ (vtime.py does it):
;   acme -f cbm -I ../../include -I out -o out/vtime.prg vtime.asm
;
; A test's record is 32 bytes: VFMT, a spare byte, 30 bytes of program.
; Before each: F0-F15 = 1.25 + i / 4, M a copy (MLOAD), VINIDX and VTXIDX 0;
; the vertex array holds one vertex's worth of data.
;   STATS         $A5 when done
;   STATS + 1 + 4 (REPS i + r)   test i's run r: CIA 2 timer A, timer B
;                                (stopped; from $FFFF each)

!cpu m65
!source "mcp.inc"
!source "vtime.inc"         ; NTESTS, STATS, PASSES, REPS

ctrl    = $02              ; (4) the MCP's control page
fp      = $06              ; (4) F0-F15
tp      = $0a              ; (2) the test's record
v_out   = $0c              ; (2) where its timers go
v_cnt   = $0e              ; tests to go
v_rep   = $0f              ; this test's runs to go
prun    = $12              ; (4) PRUN (memory form 14, F0)
wide    = $16              ; (4) the wide forms' window
vpage   = $1a              ; (4) the vertex page
cn      = $20              ; (2) a CPU loop's turns

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
        +mcp_ptr vpage, MCP_VINDATA
        ldz #MCP_RESET
        sta [ctrl],z        ; (A = 0) MRESET

        ; one vertex's worth into the vertex array, from 0
        lda #0
        ldz #4
        sta [vpage],z       ; VINPTR
        inz
        sta [vpage],z
        ldx #0
        ldz #0
-       lda vertex,x
        sta [vpage],z       ; VINDATA
        inx
        cpx #64
        bne -
        lda #12
        ldz #9
        sta [vpage],z       ; VPOSEXP

        lda #<tests
        sta tp
        lda #>tests
        sta tp+1
        lda #<(STATS + 1)
        sta v_out
        lda #>(STATS + 1)
        sta v_out+1
        lda #NTESTS
        sta v_cnt
nexttest:
        lda #REPS
        sta v_rep
testloop:
        +mcp_wait ctrl
        ldy #0              ; the test's VFMT; the first vertex and entry
        lda (tp),y
        ldz #8
        sta [vpage],z
        lda #0
        ldz #6
        sta [vpage],z
        inz
        sta [vpage],z
        ldz #$0c
        sta [vpage],z
        inz
        sta [vpage],z
        ; F0-F15 (memory forms FMOVE, $400 + d * 4: the fourth byte issues), M = F
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
        sta [wide],z
        +mcp_wait ctrl
        ; the test's program at entry 0
        ldz #MCP_MPLOADRST
        sta [ctrl],z
        lda #0
        ldz #MCP_MPPTR
        sta [ctrl],z
        inz
        sta [ctrl],z
        ldy #2
-       lda (tp),y
        ldz #MCP_MPLOAD
        sta [ctrl],z
        iny
        cpy #32
        bne -
        +mcp_wait ctrl

        jsr clock_start
        ldq c_prun
        stq [prun]          ; PRUN 0, PASSES passes
        +mcp_wait ctrl
        jsr clock_stop

        dec v_rep
        beq +
        jmp testloop
+       clc
        lda tp
        adc #32
        sta tp
        bcc +
        inc tp+1
+       dec v_cnt
        beq +
        jmp nexttest
+
        ; ---- the CPU's side: 1,024 turns each
!for .r, 1, REPS {
        jsr turns           ; the loop alone
-       dew cn
        bne -
        jsr clock_stop
}
!for .r, 1, REPS {
        jsr turns           ; a register form: FMOVE F0, F0 (Z and A stay)
        ldz #MCP_REGFORM + MCP_FMOVE
        lda #$00
-       sta [ctrl],z
        dew cn
        bne -
        jsr clock_stop
        +mcp_wait ctrl
}
!for .r, 1, REPS {
        jsr turns           ; the same with its LDZ and LDA
-       ldz #MCP_REGFORM + MCP_FMOVE
        lda #$00
        sta [ctrl],z
        dew cn
        bne -
        jsr clock_stop
        +mcp_wait ctrl
}
!for .r, 1, REPS {
        jsr turns           ; a memory form: FMOVE F0, #1.0 (Q stays)
        lda #$00
        tax
        ldy #$80
        ldz #$3f
-       stq [fp]
        dew cn
        bne -
        jsr clock_stop
        +mcp_wait ctrl
}
!for .r, 1, REPS {
        jsr turns           ; reading F0
-       ldz #0
        ldq [fp]
        dew cn
        bne -
        jsr clock_stop
}
!for .r, 1, REPS {
        jsr turns           ; a poll of MSTATUS (the unit idle)
-       ldz #MCP_STATUS
        lda [ctrl],z
        and #1
        bne +
+       dew cn
        bne -
        jsr clock_stop
}

        lda #$a5
        sta STATS
        lda #5
        sta $d020
-       jmp -

; CIA 2: no interrupts, both latches $FFFF, then B (A's underflows) and A (1 MHz)
clock_start:
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
        rts

; 1,024 turns to go, and the clock
turns:
        lda #<1024
        sta cn
        lda #>1024
        sta cn+1
        jmp clock_start

; the clock stopped, its timers to (v_out), which moves on
clock_stop:
        lda #0
        sta $dd0e
        ldy #0
        lda $dd04
        sta (v_out),y
        iny
        lda $dd05
        sta (v_out),y
        iny
        lda $dd06
        sta (v_out),y
        iny
        lda $dd07
        sta (v_out),y
        clc
        lda v_out
        adc #4
        sta v_out
        bcc +
        inc v_out+1
+       rts

c_prun: !32 PASSES << 16    ; PRUN: entry 0, PASSES passes

; F0-F15 = 1.25 + i / 4
fvals:
!for i, 0, 15 {
        !32 $3fa00000 + i * $40000
}

; a vertex with every field (VFMT $1F: 32 bytes), and as much again
vertex:
        !32 $3f800000, $40000000, $40400000     ; the position: 1, 2, 3
        !byte 64, 32, 16, 0                     ; the normal
        !byte 255, 128, 64, 255                 ; the colour
        !32 $11111111, $22222222, $33333333     ; three attribute words
        !fill 32, $40

tests:  !binary "vtime_tests.bin"
tests_end:
!if tests_end > STATS {
        !error "the tests run into STATS"
}

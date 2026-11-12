; geo - the M65-MCP's standard vertex program (MCP3.md) on the demo mesh
; geo.c prepares: the matrix and the viewport into the MCP, the vertices
; through VINDATA, the program (mcp.inc's, lit or not, the light from geo.c)
; through MPLOAD, then one PRUN with a pass a vertex, timed by CIA 2. The result buffer is then copied through the
; window ($FFDF800, bank by bank) to chip RAM for geo.py to compare.
;
; Assemble with ACME 0.97+ (geo.py does it), out/ holding geo.c's files:
;   acme -f cbm -I ../../include -I out -o out/geo.prg geo.asm
;
;   $0340        $A5 when done
;   $0341-$0344  CIA 2 timer A, timer B over the PRUN (from $FFFF each)
;   $0345-$0346  MPCNT (the passes done)
;   $0347        MPERR
;   $40000-      the result buffer, NVTX entries of 32 bytes

!cpu m65
!source "mcp.inc"
!source "geo.inc"

STATS   = $0340
OUT     = $40000
ctrl    = $02              ; (4) the MCP's control page
fp      = $06              ; (4) F0-F15 (memory forms: FMOVE)
wide    = $0a              ; (4) the wide forms' window
vpage   = $0e              ; (4) the vertex page ($FFDF000)
prun    = $12              ; (4) PRUN (memory form 14, F0)
src     = $16              ; (4) the copy's source
dst     = $1a              ; (4) the copy's destination
data    = $1e              ; (2) the vertices, as they go
v_bank  = $20
v_cnt   = $21              ; (2)

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
        +mcp_ptr wide, MCP_WIDE
        +mcp_ptr vpage, MCP_VINDATA
        +mcp_ptr prun, MCP + $400 + MCPM_PRUN * 64
        ldz #MCP_RESET
        sta [ctrl],z        ; (A = 0) MRESET

        ; F0-F15 = the matrix (FMOVE memory forms: the fourth byte issues), MLOAD
        ldx #0
-       txa
        taz
        lda regs,x
        sta [fp],z
        inx
        cpx #64
        bne -
        ldz #MCPW_MLOAD * 2
        lda #0
        sta [wide],z
        inz
        sta [wide],z
        ; F12-F15 = kx, ky, cx, cy
        ldx #0
-       txa
        clc
        adc #48
        taz
        lda regs+64,x
        sta [fp],z
        inx
        cpx #16
        bne -
        +mcp_wait ctrl

        ; the vertices into the vertex array from 0
        lda #0
        ldz #4
        sta [vpage],z       ; VINPTR
        inz
        sta [vpage],z
        lda #<vertices
        sta data
        lda #>vertices
        sta data+1
        lda #<(NVTX * VSIZE)
        sta v_cnt
        lda #>(NVTX * VSIZE)
        sta v_cnt+1
        ldy #0
        ldz #0
-       lda (data),y
        sta [vpage],z       ; VINDATA
        inw data
        lda v_cnt
        bne +
        dec v_cnt+1
+       dec v_cnt
        lda v_cnt
        ora v_cnt+1
        bne -

        ; the program at entry 0
        ldz #MCP_MPLOADRST
        sta [ctrl],z
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
        cpx #PROGLEN
        bne -

        ; the format, the scale, the first vertex and entry
        lda #VFMT
        ldz #8
        sta [vpage],z
        lda #VPOSEXP
        inz
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
        stq [prun]          ; PRUN 0, NVTX passes
        +mcp_wait ctrl

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
        ldz #MCP_MPCNT
        lda [ctrl],z
        sta STATS+5
        inz
        lda [ctrl],z
        sta STATS+6
        ldz #MCP_MPERR
        lda [ctrl],z
        sta STATS+7

        ; the result buffer, 2 KB a bank, to OUT
        +mcp_ptr dst, OUT
        lda #0
        sta v_bank
bankloop:
        lda v_bank
        ldz #$0e
        sta [vpage],z       ; VBANK
        +mcp_ptr src, MCP_VOUTWIN
        ldx #8
pageloop:
        ldz #0
-       lda [src],z
        sta [dst],z
        inz
        bne -
        inc src+1
        inc dst+1
        bne +
        inc dst+2
+       dex
        bne pageloop
        inc v_bank
        lda v_bank
        cmp #(NVTX * 32 + 2047) / 2048
        bne bankloop

        lda #$a5
        sta STATS
        lda #5
        sta $d020
-       jmp -

c_prun: !32 NVTX << 16      ; PRUN: entry 0, NVTX passes
regs:   !binary "geo_regs.bin"
program:                    ; the standard program, as mcp.inc ships it
!if LIT {
        +mcp_stdprog_lit LX, LY, LZ, KA
} else {
        +mcp_stdprog
}
program_end:
!if program_end - program != PROGLEN {
        !error "mcp.inc's standard program is not geo.c's length"
}
vertices: !binary "geo_vtx.bin"

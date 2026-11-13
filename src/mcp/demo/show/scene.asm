; scene - a turning, lit torus on the screen. The M65-MCP does all of its
; arithmetic, the DMA moves the data and fills the pixels, and the CPU only
; links lists and sets up triangles (scene.c has the design and the two
; MCP programs, and plays the same frames on the host).
;
; Assemble with ACME 0.97+ (show.py does it), out/ holding scene.c's files:
;   acme -f cbm -I ../../include -I out -o out/scene.prg scene.asm
; -DTEST=1: no MCP; the frame's result buffer comes from attic RAM
; ($8100000, show.py loads scene_res<n>.bin there) - the display alone, for
; an emulator.
;
; Per frame:
;   the MCP: M = Ry x Rx (the rotations built from a sine table, DMA'd into
;     F0-F15 as memory forms; MLOAD, MMUL); the light into object space
;     (MTXV) and into the face program's constants (MPLOAD); M = PV x Ry x
;     Rx; MSTORE (the view direction into F12-F14); then two PRUNs queued
;     back to back: the vertex program over the 240 vertices (each one's
;     pixel), the face program over the 480 triangles (each one's colour,
;     depth bucket and whether it faces the eye)
;   meanwhile the DMA clears the frame buffer not shown
;   the DMA, one chained list: those bytes out of the result window
;     ($FFDF800, a source step of 32) into tables by vertex and by face
;   the CPU: the visible faces linked into their depth buckets, then each
;     drawn far to near, a column at a time, every column one DMA fill (a
;     step of 8: show.inc's layout); the slopes from the hardware divider
;   at the bottom border, the screen RAM swapped (two frame buffers)
; The first frame is drawn, shown, and then the demo holds: $0340 = $A5
; until a key is pressed or $0340 is written 0. Then it turns, forever.
;   $0341-$0344  CIA 2 timer A, timer B at the last frame's end (counting
;                down from $FFFF each since the start)
;   $0345-$0346  frames since the first hold
;   $0348-$0363  frame 64's timestamps (7 of 4 bytes, as $0341): the start,
;                the MCP's work issued, the frame buffer cleared, the MCP
;                done, the results scattered, the faces linked, drawn
;   $0370        written nonzero: hold after every frame ($0340 = $A5 until
;                it is written 0), and draw frame number $0371 (frame n is
;                Ry by RY0 + n steps, Rx by RX0 + 2n)
;   $0372        the frame buffer on the screen: its bank (4 or 5)
; Frame buffers $40000 and $50000.

!cpu m65
!source "mcp.inc"
!source "show.inc"
!source "scene.inc"
!ifndef TEST { TEST = 0 }
!if (NVTX != 240) | (NTRI != 480) {
        !error "the scatter list below is laid out for 240 vertices and 480 triangles"
}

FB0     = $40000
FB1     = $50000
SCR0    = $c000
SCR1    = $c800
STATS   = $0340
STAMPS  = $0348
STEP    = $0370
STEPN   = $0371
SHOWN   = $0372
PACE    = 89                ; x 256 of the clock's ticks between swaps, at least

VXL     = $8000             ; per vertex: its pixel's x (9 bits), y
VXH     = $8100
VY      = $8200
FCOL    = $8300             ; per face (two pages each): the palette index,
FKEY    = $8500             ;   the depth bucket,
FVIS    = $8700             ;   facing the eye (0: not)
NEXTL   = $8900             ;   the next face in its bucket
NEXTH   = $8b00             ;   ($FF: none)
HEADL   = $8d00             ; per bucket: its first face
HEADH   = $8e00
MUL8L   = $8f00             ; y x 8
MUL8H   = $9000
RYBUF   = $9100             ; Ry and Rx as F0-F15
RXBUF   = $9140
PATCH   = $9180             ; the face program's light: FMUL F4-F6 by it
COLL    = $91a0             ; a column of characters' offset (c x 1,600)
COLH    = $91d0
SCRATCH = $91ff

ctrl    = $02               ; (4) the MCP's control page
fp      = $06               ; (4) F0-F15 (memory forms)
wide    = $0a               ; (4) the wide forms
vpage   = $0e               ; (4) the vertex page
prun    = $12               ; (4) PRUN
yl      = $20               ; (4) 16.16: the long edge's y
ys      = $24               ; (4)   the short edge's
sl      = $28               ; (4)   their slopes
ss      = $2c               ; (4)
va      = $30               ; the triangle's vertices
vb      = $31
vc      = $32
key     = $33
colptr  = $34               ; (2) the column's pixel at row 0 (in the frame buffer's bank)
sub     = $36               ; columns left in this character
n       = $37               ; (2) columns to go
t0      = $39               ; (2) scratch
t1      = $3b
flo     = $3c               ; the face
fhi     = $3d
nlo     = $3e               ; the next one
nhi     = $3f
frame   = $40               ; (2)
ia      = $42               ; the angles (sine-table steps)
ib      = $43
back    = $44               ; the frame buffer not shown: 0 FB0, 1 FB1
stamp   = $45               ; frame 64: timestamps wanted
first   = $46               ; the first frame: hold after it
swapped = $47               ; the clock (timer A's high byte) at the last swap

!macro mcp_wide .op, .ds, .t {      ; a wide form: .op d, s, t
        ldz #.op * 2
        lda #.ds
        sta [wide],z
        inz
        lda #.t << 4
        sta [wide],z
}

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
        sta STEP
        sta stamp
        sta frame
        sta frame+1
        +show_screen SCR1, FB1
        +show_screen SCR0, FB0      ; (shown: FB0, cleared)
        +show_palette palette
        ldx #0                      ; COLL/COLH: c x 1,600
        lda #0
        sta t0
        sta t0+1
-       lda t0
        sta COLL,x
        lda t0+1
        sta COLH,x
        clc
        lda t0
        adc #<1600
        sta t0
        lda t0+1
        adc #>1600
        sta t0+1
        inx
        cpx #40
        bne -
        ldx #0                      ; MUL8: y x 8
-       txa
        asl
        asl
        asl
        sta MUL8L,x
        txa
        lsr
        lsr
        lsr
        lsr
        lsr
        sta MUL8H,x
        inx
        bne -
        ldx #5                      ; PATCH: FMUL F4, F5, F6 (memory forms), the values a frame
-       lda patch_ops,x
        ldy patch_at,x
        sta PATCH,y
        dex
        bpl -
        lda #0                      ; the divider: MULTINA = |dy| << 16, MULTINB = dx (16 bits)
        sta $d770
        sta $d771
        sta $d773
        sta $d776
        sta $d777
        lda #$7f                    ; the clock: CIA 2, both latches $FFFF, B counts A's underflows
        sta $dd0d
        lda #0
        sta $dd0e
        sta $dd0f
        lda #$ff
        sta $dd04
        sta $dd05
        sta $dd06
        sta $dd07
        sta swapped
        lda #$51
        sta $dd0f
        lda #$11
        sta $dd0e
        lda #1
        sta back                    ; the first frame into FB1
        sta first
        lda #RY0
        sta ia
        lda #RX0
        sta ib

        +mcp_ptr ctrl, MCP_CTRLPAGE
        +mcp_ptr fp, MCP_FREGS
        +mcp_ptr wide, MCP_WIDE
        +mcp_ptr vpage, MCP_VINDATA
        +mcp_ptr prun, MCP + $400 + MCPM_PRUN * 64
!if TEST = 0 {
        ldz #MCP_RESET
        lda #0
        sta [ctrl],z                ; MRESET
        ldz #4
        sta [vpage],z               ; VINPTR = 0
        inz
        sta [vpage],z
        +dma dma_rec                ; the records into VINDATA (one port: the address held)
        ldz #MCP_MPLOADRST
        sta [ctrl],z
        lda #0
        ldz #MCP_MPPTR
        sta [ctrl],z
        inz
        sta [ctrl],z
        +dma dma_prog               ; both programs into MPLOAD, from entry 0
        ldz #MCP_MPLOADRST          ; the vertex program's kx: the video mode's
        sta [ctrl],z
        lda #VKX
        ldz #MCP_MPPTR
        sta [ctrl],z
        lda #0
        inz
        sta [ctrl],z
        ldx #0                      ; (PAL)
        bit $d06f
        bpl +
        ldx #6                      ; (NTSC)
+       ldy #6
-       lda kx_tab,x
        ldz #MCP_MPLOAD
        sta [ctrl],z
        inx
        dey
        bne -
        lda #VFMT
        ldz #8
        sta [vpage],z
        lda #VPOSEXP
        inz
        sta [vpage],z
        +mcp_wait ctrl
}

; ---------------------------------------------------------------- a frame
frame_loop:
        lda STEP                    ; stepping: the frame asked for
        beq +
        clc
        lda STEPN
        adc #RY0
        sta ia
        lda STEPN
        asl
        clc
        adc #RX0
        sta ib
+       ldx #0
        jsr timestamp
!if TEST = 0 {
        jsr rotations
        ; M = Ry x Rx, then V0 = transpose(M) x the light
        +dma dma_ry
        +mcp_wide MCPW_MLOAD, 0, 0
        +mcp_wait ctrl
        +dma dma_rx
        +mcp_wide MCPW_MMUL, 0, 0
        +mcp_wait ctrl
        +dma dma_le
        +mcp_wide MCPW_MTXV, $00, 0
        +mcp_wait ctrl
        ; the light (F0-F2) into the face program
        ldz #0
        ldq [fp]
        stq PATCH+2
        ldz #4
        ldq [fp]
        stq PATCH+8
        ldz #8
        ldq [fp]
        stq PATCH+14
        ldz #MCP_MPLOADRST
        sta [ctrl],z
        lda #FLIGHT
        ldz #MCP_MPPTR
        sta [ctrl],z
        lda #0
        inz
        sta [ctrl],z
        ldx #0
-       lda PATCH,x
        ldz #MCP_MPLOAD
        sta [ctrl],z
        inx
        cpx #18
        bne -
        ; M = PV x Ry x Rx
        +dma dma_pv
        +mcp_wide MCPW_MLOAD, 0, 0
        +mcp_wait ctrl
        +dma dma_ry
        +mcp_wide MCPW_MMUL, 0, 0
        +mcp_wait ctrl
        +dma dma_rx
        +mcp_wide MCPW_MMUL, 0, 0
        +mcp_wait ctrl
        lda #0                      ; the first record and entry
        ldz #6
        sta [vpage],z               ; VINIDX
        inz
        sta [vpage],z
        ldz #$0c
        sta [vpage],z               ; VTXIDX
        inz
        sta [vpage],z
        ; F12-F14 = M's row 3 (the view direction); the vertices, the faces
        +mcp_wide MCPW_MSTORE, 0, 0
        ldq c_prun_v
        stq [prun]
        ldq c_prun_f
        stq [prun]
}
        ldx #4
        jsr timestamp
        ; the frame buffer not shown, cleared while the MCP works
        lda back
        clc
        adc #^FB0
        sta show_dma_clear_dst+2
        sta span_bank
        lda #0
        sta show_dma_clear_dst
        sta show_dma_clear_dst+1
        +dma show_dma_clear
        +dma dma_heads              ; every bucket empty
        ldx #8
        jsr timestamp
!if TEST = 0 {
        +mcp_wait ctrl
}
        ldx #12
        jsr timestamp
        +dma scatter                ; the results into the tables
        ldx #16
        jsr timestamp

; ------------------------------- the visible faces into their buckets
!macro link .p {
        ldx #0
-       lda FVIS + .p * 256,x
        beq +
        ldy FKEY + .p * 256,x
        lda HEADL,y                 ; (the last in is the first out)
        sta NEXTL + .p * 256,x
        lda HEADH,y
        sta NEXTH + .p * 256,x
        txa
        sta HEADL,y
        lda #.p
        sta HEADH,y
+       inx
!if .p = 0 {
        bne -
} else {
        cpx #<(NTRI - 256)
        bne -
}
}
        +link 0
        +link 1
        ldx #20
        jsr timestamp

; ------------------------------------------- far to near, each drawn
!macro face .p {                    ; face X of page .p: its vertices, colour and successor
        lda TA + .p * 256,x
        sta va
        lda TB + .p * 256,x
        sta vb
        lda TC + .p * 256,x
        sta vc
        lda FCOL + .p * 256,x
        sta span_val
        lda NEXTL + .p * 256,x
        sta nlo
        lda NEXTH + .p * 256,x
        sta nhi
}
        lda #0                      ; the fills' list: its bank, megabyte and page once
        sta $d702
        sta $d704
        lda #>span_job
        sta $d701
        lda #255
        sta key
kloop:
        ldx key
        lda HEADH,x
        bpl +
        jmp knext                   ; ($FF: empty)
+       sta fhi
        lda HEADL,x
        sta flo
nloop:
        ldx flo
        lda fhi
        bne +
        +face 0
        jmp ++
+       +face 1
++      jsr triangle
        lda nhi
        bmi knext
        sta fhi
        lda nlo
        sta flo
        jmp nloop
knext:
        dec key
        lda key
        cmp #$ff
        beq +
        jmp kloop
+       ldx #24
        jsr timestamp

; ------------------------------------------- shown at the bottom border
; (an even pace: a frame's work is a little over or under one refresh, so
; each is shown for two - not before PACE x 256 ticks of the clock, 22 ms,
; since the last one)
-       sec
        lda swapped
        sbc $dd05
        cmp #PACE
        bcc -
-       lda $d012
        cmp #251
        bne -
        lda $dd05
        sta swapped
        lda back
        beq +
        +show_scrnptr SCR1
        lda #^FB1
        sta SHOWN
        lda #0
        sta back
        jmp ++
+       +show_scrnptr SCR0
        lda #^FB0
        sta SHOWN
        lda #1
        sta back
++
        lda first                   ; the first frame, or stepping: hold
        bne hold
        lda STEP
        beq running
hold:
        lda #$a5
        sta STATS
        sta $d610                   ; (a key waiting: dropped)
-       lda STATS
        beq +
        lda STEP
        bne -                       ; (stepping: $0340 alone)
        lda $d610
        beq -
+       lda #0
        sta STATS
        sta first
running:
        lda $dd04                   ; the clock at the frame's end, the count
        sta STATS+1
        lda $dd05
        sta STATS+2
        lda $dd06
        sta STATS+3
        lda $dd07
        sta STATS+4
        lda frame
        sta STATS+5
        lda frame+1
        sta STATS+6
        inw frame
        lda #0
        sta stamp
        lda frame+1
        bne +
        lda frame
        cmp #64
        bne +
        inc stamp                   ; frame 64: its timestamps
+       inc ia                      ; turning: Ry a step a frame, Rx two
        inc ib
        inc ib
        jmp frame_loop

; ------------------------------------------------------------ subroutines

; the CIA's clock into STAMPS + X (frame 64 only)
timestamp:
        lda stamp
        beq +
        lda $dd04
        sta STAMPS,x
        lda $dd05
        sta STAMPS+1,x
        lda $dd06
        sta STAMPS+2,x
        lda $dd07
        sta STAMPS+3,x
+       rts

; Ry (ia) and Rx (ib) as F0-F15 from the sine table (cos = sin + 64 steps)
!macro fput .dst, .neg {
        lda SIN0,x
        sta .dst
        lda SIN1,x
        sta .dst+1
        lda SIN2,x
        sta .dst+2
        lda SIN3,x
!if .neg {
        eor #$80
}
        sta .dst+3
}
rotations:
        ldx #63
-       lda rot_id,x                ; the identity, then the four entries
        sta RYBUF,x
        sta RXBUF,x
        dex
        bpl -
        ldx ia                      ; Ry: [c 0 s 0][0 1 0 0][-s 0 c 0][0 0 0 1]
        +fput RYBUF + 8, 0
        +fput RYBUF + 32, 1
        txa
        clc
        adc #64
        tax
        +fput RYBUF + 0, 0
        +fput RYBUF + 40, 0
        ldx ib                      ; Rx: [1 0 0 0][0 c -s 0][0 s c 0][0 0 0 1]
        +fput RXBUF + 24, 1
        +fput RXBUF + 36, 0
        txa
        clc
        adc #64
        tax
        +fput RXBUF + 20, 0
        +fput RXBUF + 40, 0
        rts

; the triangle va, vb, vc in the colour in span_val: sorted by x, then a
; column at a time from the leftmost, the long edge (a to c) against the
; short ones (a to b, then b to c). Every vertex is on the screen (scene.c
; checks every frame), so an edge's rows are 0-199: a byte.
!macro xcmp_swap .u, .v {           ; if x[.u] > x[.v]: swap them
        ldx .u
        ldy .v
        sec
        lda VXL,y
        sbc VXL,x
        lda VXH,y
        sbc VXH,x
        bpl +                       ; x[.v] >= x[.u]: in order
        stx .v
        sty .u
+
}
!macro columns_xy {                 ; n = x[Y] - x[X]; the Z flag: none
        sec
        lda VXL,y
        sbc VXL,x
        sta n
        lda VXH,y
        sbc VXH,x
        sta n+1
        ora n
}
triangle:
        +xcmp_swap va, vb
        +xcmp_swap vb, vc
        +xcmp_swap va, vb
        ldx va
        ldy vc
        +columns_xy
        bne +
        rts                         ; no width
+       jsr slope                   ; the long edge: a to c
        stq sl
        ldx va
        lda #0
        sta yl
        sta yl+3
        lda #$80
        sta yl+1
        lda VY,x
        sta yl+2                    ; yl = ya + 1/2
        ldq yl
        stq ys
        ldx va                      ; (LDQ loads A, X, Y and Z)
        lda VXL,x                   ; the column's pixel at row 0: COL[xa >> 3] + (xa & 7)
        and #7
        sta t1
        eor #7
        sta sub
        lda VXH,x
        lsr
        lda VXL,x
        ror
        lsr
        lsr
        tay
        clc
        lda COLL,y
        adc t1
        sta colptr
        lda COLH,y
        adc #0
        sta colptr+1
        ldy vb                      ; a to b
        +columns_xy
        beq +                       ; xb = xa: no first half
        jsr slope
        stq ss
        jsr columns
+       ldx vb                      ; b to c
        ldy vc
        +columns_xy
        bne +
        rts                         ; xc = xb: done
+       jsr slope
        stq ss
        ldx vb
        lda #0
        sta ys
        sta ys+3
        lda #$80
        sta ys+1
        lda VY,x
        sta ys+2                    ; ys = yb + 1/2
        ; (fall through)

; n columns from colptr: in each the rows between the two edges, one DMA
; fill with a step of 8; then both edges a step on, and the next column
columns:
        lda yl+2
        cmp ys+2
        beq ++                      ; no rows
        bcc +
        sbc ys+2                    ; (carry set) from ys, yl - ys rows
        sta span_cnt
        ldx ys+2
        bra cfill
+       lda ys+2                    ; from yl, ys - yl rows
        sec
        sbc yl+2
        sta span_cnt
        ldx yl+2
cfill:  clc
        lda colptr
        adc MUL8L,x
        sta span_dst
        lda colptr+1
        adc MUL8H,x
        sta span_dst+1
        lda #<span_job
        sta $d705                   ; the fill
++      clc
        ldq yl
        adcq sl
        stq yl
        clc
        ldq ys
        adcq ss
        stq ys
        inw colptr
        dec sub
        bpl +
        lda #7                      ; a new character: 1,600 bytes on from its first pixel
        sta sub
        clc
        lda colptr
        adc #<1592
        sta colptr
        lda colptr+1
        adc #>1592
        sta colptr+1
+       dew n
        bne columns
        rts

; the slope from vertex X to vertex Y (x[Y] > x[X]) into Q, 16.16:
; (|dy| << 16) / dx, negated for dy < 0. The hardware divider: MULTINA =
; |dy| << 16 (its other bytes stay 0), MULTINB = dx
slope:
        sec
        lda VXL,y
        sbc VXL,x
        sta $d774
        lda VXH,y
        sbc VXH,x
        sta $d775
        sec
        lda VY,y
        sbc VY,x
        bcc +                       ; dy < 0
        sta $d772
        lda t0                      ; (the divider's busy flag may be a cycle or two
        lda t0                      ;   behind the inputs)
-       bit $d70f
        bmi -
        ldq $d76c                   ; the whole part
        rts
+       eor #$ff
        adc #1                      ; (carry clear) |dy|
        sta $d772
        lda t0
        lda t0
-       bit $d70f
        bmi -
        lda #0
        tax
        tay
        taz
        sec
        sbcq $d76c                  ; negated
        rts

; ------------------------------------------------------------------ data

c_prun_v: !32 (NVTX << 16) | VPROG  ; PRUN: the vertex program, a pass a vertex
c_prun_f: !32 (NTRI << 16) | FPROG  ;   the face program, a pass a triangle
patch_ops: !byte $84, $40, $84, $50, $84, $60
patch_at:  !byte 0, 1, 6, 7, 12, 13
kx_tab: !byte $84, $90              ; the vertex program's entry VKX: FMUL F9, #kx
        !32 KX_PAL
        !byte $84, $90
        !32 KX_NTSC
rot_id: !32 $3f800000, 0, 0, 0
        !32 0, $3f800000, 0, 0
        !32 0, 0, $3f800000, 0
        !32 0, 0, 0, $3f800000

        !align 31, 0                ; (so the list is in one page: its address's
span_job:                           ;   other bytes are set once a frame)
        !byte $0b, $85, $08, $00    ; a column: a fill, a step of 8
        !byte $03
span_cnt: !word 0
span_val: !word 0
        !byte 0
span_dst: !word 0
span_bank: !byte 0
        !byte 0
        !word 0

dma_heads:                          ; HEADH = $FF: every bucket empty
        !byte $0b, $00
        !byte $03
        !word 256
        !word $00ff
        !byte 0
        !word HEADH
        !byte 0
        !byte 0
        !word 0

!macro to_fregs .src, .n, .first {  ; .n bytes into F(.first)... as FMOVE memory forms
        !byte $0b, $81, $ff, $00
        !byte $00
        !word .n
        !word .src
        !byte 0
        !word $f400 + .first * 4
        !byte $0d                   ; $FFDF400
        !byte 0
        !word 0
}
dma_ry: +to_fregs RYBUF, 64, 0
dma_rx: +to_fregs RXBUF, 64, 0
dma_pv: +to_fregs pv, 64, 0
dma_le: +to_fregs le, 16, 0

!macro to_port .src, .n, .port {    ; .n bytes into a port of the MCP, its address held
        !byte $0b, $81, $ff, $00
        !byte $00
        !word .n
        !word .src
        !byte 0
        !word .port
        !byte $0d
        !byte $08                   ; the destination held
        !word 0
}
dma_rec:  +to_port records, NREC * RSIZE, $f000         ; VINDATA
dma_prog: +to_port program, PROGLEN, $f128              ; MPLOAD

; the results into the tables, one chained list: per 2 KB of the result
; buffer VBANK set (a byte through the DMA too), then a byte of every
; entry there (a source step of 32) into its table. Entries 0-239 are the
; vertices (bytes 0-2: x, its high byte, y), 240-719 the faces (bytes 0-2:
; colour, bucket, facing).
!if TEST {
S_MB    = $81               ; the results: attic RAM $8100000, the 2 KB one after another
S_BANK  = $00
S_ADDR  = $0000
S_STEP  = 2048
B_MB    = $00               ; VBANK: a scratch byte
B_BANK  = $00
B_ADDR  = SCRATCH
} else {
S_MB    = $ff               ; the result window, $FFDF800
S_BANK  = $0d
S_ADDR  = $f800
S_STEP  = 0
B_MB    = $ff               ; VBANK, $FFDF00E
B_BANK  = $0d
B_ADDR  = $f00e
}
!macro sc_bank .b {                 ; VBANK = .b
        !byte $0b, $80, $00, $81, B_MB, $82, $00, $83, $01, $00
        !byte $04                   ; copy, chained
        !word 1
        !word bank_bytes + .b
        !byte 0
        !word B_ADDR
        !byte B_BANK
        !byte 0
        !word 0
}
!macro sc_field .b, .first, .n, .field, .dst, .cmd {    ; byte .field of .n entries from .first
        !byte $0b, $80, S_MB, $81, $00, $82, $00, $83, $20, $00
        !byte .cmd                  ; copy ($04: chained)
        !word .n
        !word S_ADDR + .b * S_STEP + .first * 32 + .field
        !byte S_BANK
        !word .dst
        !byte 0
        !byte 0
        !word 0
}
!macro sc_vtx .b, .n {              ; bank .b's .n vertices
        +sc_bank .b
        +sc_field .b, 0, .n, 0, VXL + .b * 64, $04
        +sc_field .b, 0, .n, 1, VXH + .b * 64, $04
        +sc_field .b, 0, .n, 2, VY + .b * 64, $04
}
!macro sc_face .b, .first, .n, .f, .cmd {   ; bank .b's .n faces from entry .first: faces .f on
        +sc_field .b, .first, .n, 0, FCOL + .f, $04
        +sc_field .b, .first, .n, 1, FKEY + .f, $04
        +sc_field .b, .first, .n, 2, FVIS + .f, .cmd
}
scatter:
        +sc_vtx 0, 64
        +sc_vtx 1, 64
        +sc_vtx 2, 64
        +sc_vtx 3, 48               ; (entries 192-239)
        +sc_face 3, 48, 16, 0, $04  ; (entries 240-255: faces 0-15)
!for .k, 0, 6 {
        +sc_bank 4 + .k
        +sc_face 4 + .k, 0, 64, 16 + .k * 64, $04
}
        +sc_bank 11
        +sc_face 11, 0, 16, 464, $00    ; (entries 704-719: the last)
bank_bytes: !byte 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11

        +show_data
program:  !binary "scene_prog.bin"
SIN0 = sines
SIN1 = sines + 256
SIN2 = sines + 512
SIN3 = sines + 768
sines:    !binary "scene_sin.bin"
pv:       !binary "scene_pv.bin"
le:       !binary "scene_le.bin"
palette:  !binary "scene_pal.bin"
TA = tris                           ; a face's vertices
TB = tris + 512
TC = tris + 1024
tris:     !binary "scene_tri.bin"
records:  !binary "scene_rec.bin"
data_end:
!if data_end > VXL {
        !error "the program runs into the tables at VXL"
}

; mcptest - MCP-1 on the MEGA65: replays an mcpgen script (the one the
; bench plays) from attic RAM and stores every read it makes, in order, in
; chip RAM, where hwtest.sh reads them back and compares them with the
; model's values.
;
; Assemble with ACME 0.97+ (build.sh does it):
;   acme -f cbm -DNREC=<records> -o mcptest.prg mcptest.asm
;
; Before it runs, hwtest.sh puts build.sh's records.bin into attic RAM at
; RECS: 4 bytes a record - type (1 write, 2 read, 3 wait until the unit is
; idle), the offset from $FFDF000 (low, high), the value to write. MEGA65
; mode: LOAD and RUN (it takes the machine over, no way back but reset).
;   $0340        $A5 once every record is done
;   $0341        MID ($4D)
;   $0342        MVER ($02 on MCP-2)
;   $40000-      the reads, a byte each, in the script's order
; Border colour: black = running, green = done, red = no MCP at $FFDF100.

!cpu m65
!ifndef NREC { !error "NREC (the script's records) is not set: use build.sh" }

RECS    = $8100000         ; attic RAM: records.bin
OUT     = $40000           ; chip RAM: the reads
STATS   = $0340
ptr     = $02              ; (4) the register a record names
rp      = $06              ; (4) the next record
op      = $0a              ; (4) where the next read goes
st      = $0e              ; (4) MSTATUS
cnt     = $12              ; (2) records left
rtype   = $14

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
        tab                 ; base page 0
        lda #$47
        sta $d02f
        lda #$53
        sta $d02f           ; VIC-IV registers visible
        lda $d031
        ora #$40
        sta $d031
        lda $d054
        ora #$40
        sta $d054           ; 40.5 MHz, whatever mode we were started from
        lda #0
        sta $d020
        sta STATS

        ; the pointers: ptr's upper bytes stay $0FFD, its lower two come from a record
        lda #$fd
        sta ptr+2
        sta st+2
        lda #$0f
        sta ptr+3
        sta st+3
        lda #$00
        sta st
        lda #$f1
        sta st+1            ; st = $0FFDF100: MSTATUS
        lda #<RECS
        sta rp
        lda #>RECS
        sta rp+1
        lda #^RECS
        sta rp+2
        lda #(RECS >> 24)
        sta rp+3
        lda #<OUT
        sta op
        lda #>OUT
        sta op+1
        lda #^OUT
        sta op+2
        lda #0
        sta op+3
        lda #<NREC
        sta cnt
        lda #>NREC
        sta cnt+1

        ldz #1
        lda [st],z          ; MID
        sta STATS+1
        ldz #2
        lda [st],z          ; MVER
        sta STATS+2
        lda STATS+1
        cmp #$4d
        beq loop
        lda #2              ; no MCP: red border, stop
        sta $d020
-       jmp -

loop:
        ldz #0
        lda [rp],z          ; the type
        sta rtype
        inz
        lda [rp],z          ; the offset
        sta ptr
        inz
        lda [rp],z
        ora #$f0
        sta ptr+1
        inz
        lda [rp],z          ; the value
        ldz #0
        ldx rtype
        cpx #1
        bne +
        sta [ptr],z         ; a write
        bra next
+       cpx #2
        bne +
        lda [ptr],z         ; a read, kept
        sta [op],z
        inc op
        bne next
        inc op+1
        bne next
        inc op+2
        bra next
+       jsr wait_idle       ; a wait
next:
        lda rp
        clc
        adc #4
        sta rp
        bcc +
        inc rp+1
        bne +
        inc rp+2
+       dew cnt
        lda cnt
        ora cnt+1
        bne loop

        lda #$a5
        sta STATS
        lda #5              ; done: green border
        sta $d020
-       jmp -

wait_idle:
        ldz #0
-       lda [st],z          ; MSTATUS bit 0: the unit busy
        and #1
        bne -
        rts

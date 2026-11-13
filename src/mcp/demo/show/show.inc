; show.inc - a 320 x 200, 256-colour screen for the M65-MCP's display demos
; (ACME, !cpu m65), and a DMA job macro.
;
; The screen is VIC-IV full-colour text: 40 x 25 characters of 8 x 8 pixels,
; a byte a pixel, 16-bit character numbers. The characters are numbered by
; column (the one at column c, row r is FB / 64 + c * 25 + r), so a frame
; buffer FB of 64,000 bytes holds the pixel at (x, y) at
;     FB + (x >> 3) * 1600 + y * 8 + (x & 7)
; and the pixel below one is 8 bytes on: a vertical run is a DMA fill with a
; step of 8. Pixel value 0 shows the background colour ($D021 = 0, black);
; 255 would show the colour RAM's colour (0), so palettes leave it unused.

; the machine to ourselves: no interrupts, no ROM, no MAP, the MEGA65's
; I/O at $D000, 40.5 MHz. (Never returns to BASIC 65.)
!macro show_machine {
        sei
        lda #$35
        sta $01             ; the CPU port: I/O at $D000, no ROM at $A000 or $E000
        lda #0
        tax
        tay
        taz
        map                 ; no MAP: $0000-$FFFF is bank 0, I/O at $D000
        eom
        lda #$47
        sta $d02f
        lda #$53
        sta $d02f           ; the VIC-IV's registers (MEGA65 I/O)
        lda #$04
        sta $d030           ; VIC-III: no C65 ROM at $8000-$FFFF; colours 0-15
                            ;   from the palette RAM, not the VIC-III's palette ROM
        lda #0
        tab                 ; base page at $0000
}

; a DMA job (an enhanced F018B list at .list, in bank 0); the CPU waits for it
!macro dma .list {
        lda #0
        sta $d702           ; the list's bank
        sta $d704           ; its megabyte
        lda #>.list
        sta $d701
        lda #<.list
        sta $d705           ; start (enhanced: options first)
}

; the screen: .screen 2,000 bytes of screen RAM in bank 0, .fb the frame
; buffer (chip RAM, 64-byte aligned, below $80000); the frame buffer cleared
!macro show_screen .screen, .fb {
        lda #$40
        sta $d031           ; 320 x 200 (no H640, V400, bit planes, attributes); FAST
        lda $d05d
        and #$7f
        sta $d05d           ; no hot registers: what follows stays as written
        lda $d054
        ora #$47
        sta $d054           ; 16-bit character numbers, full colour, 40.5 MHz
        lda #80
        sta $d058           ; 80 bytes a row of screen RAM
        lda #0
        sta $d059
        lda #40
        sta $d05e           ; 40 characters a row
        lda #25
        sta $d07b           ; 25 rows
        lda #0
        sta $d064           ; colour RAM from its start
        sta $d065
        sta $d070           ; palette bank 0, edited and shown
        sta $d020
        sta $d021           ; black border and background
        +show_scrnptr .screen
        ; the screen RAM: row r, column c = .fb / 64 + c * 25 + r
        lda #<.screen
        sta show_p
        lda #>.screen
        sta show_p+1
        lda #<(.fb / 64)
        sta show_rowbase
        lda #>(.fb / 64)
        sta show_rowbase+1
        ldx #25
--      ldy #0
        lda show_rowbase
        sta show_v
        lda show_rowbase+1
        sta show_v+1
-       lda show_v
        sta (show_p),y
        iny
        lda show_v+1
        sta (show_p),y
        iny
        clc
        lda show_v
        adc #25
        sta show_v
        bcc +
        inc show_v+1
+       cpy #80
        bne -
        clc
        lda show_p
        adc #80
        sta show_p
        bcc +
        inc show_p+1
+       inw show_rowbase
        dex
        bne --
        +dma show_dma_colram
        lda #<.fb
        sta show_dma_clear_dst
        lda #>.fb
        sta show_dma_clear_dst+1
        lda #^.fb
        sta show_dma_clear_dst+2
        +dma show_dma_clear
}

; show the screen RAM at .screen (bank 0)
!macro show_scrnptr .screen {
        lda #<.screen
        sta $d060
        lda #>.screen
        sta $d061
        lda #0
        sta $d062
        sta $d063           ; (bits 4-5: CHRCOUNT's high bits, 0)
}

; the palette: 256 red, 256 green, 256 blue bytes at .pal (nybbles already
; swapped, as the registers want them)
!macro show_palette .pal {
        ldx #0
-       lda .pal,x
        sta $d100,x
        lda .pal+256,x
        sta $d200,x
        lda .pal+512,x
        sta $d300,x
        inx
        bne -
}

; the data the macros use (once, anywhere in bank 0)
!macro show_data {
show_dma_colram:                    ; colour RAM ($FF80000), 2,000 bytes = 0
        !byte $0b, $81, $ff, $00
        !byte $03                   ; fill
        !word 2000
        !word 0                     ; (the value)
        !byte 0
        !word 0
        !byte $08                   ; $FF80000
        !byte 0
        !word 0
show_dma_clear:                     ; a frame buffer, 64,000 bytes = 0
        !byte $0b, $81, $00, $00
        !byte $03
        !word 64000
        !word 0
        !byte 0
show_dma_clear_dst:
        !word 0
        !byte 0
        !byte 0
        !word 0
}

show_p       = $f0              ; (2) the macros' base-page bytes
show_v       = $f2              ; (2)
show_rowbase = $f4              ; (2)

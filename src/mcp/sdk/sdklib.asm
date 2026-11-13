; sdklib.asm - the SDK examples' routines: the pointers, and printing
; through the KERNAL. !source it after the example's own code (it is code),
; with mcp.inc and sdk.inc before. Call these outside +mcp_enter /
; +mcp_leave; all of them change A, X, Y and Z.
;
;   sdk_init     the pointers into the SDK's base page; carry set (and a
;                message) if the core has no MCP
;   print_str    the zero-terminated text at A (low), X (high); +print does it
;   print_cr     a new line
;   print_freg   F(X) as a decimal number, six places (correctly rounded)
;   print_vec    V(X)'s first A components: (x, y, z)
;   print_u32    the unsigned 32-bit number in sdk_num, A digits at least
;   print_s32    the signed one
;   print_hex    A as two hex digits

CHROUT  = $ffd2

sdk_init:
        ldx #23
-       lda sdk_ptrs,x
        sta SDK_BP * 256,x
        dex
        bpl -
        +mcp_enter
        ldz #MCP_ID
        lda [p_ctl],z
        tax
        +mcp_leave
        cpx #$4d
        beq +
        +print sdk_nomcp
        sec
        rts
+       clc
        rts
sdk_ptrs:
        !32 MCP_CTRLPAGE, MCP_WIDE, MCP_FREGS, MCP_MEMFORM, MCP_VINDATA, MCP + $400 + MCPM_PRUN * 64
sdk_nomcp:
        !text "NO M65-MCP IN THIS CORE", 13, 0

print_str:
        sta ps_at+1
        stx ps_at+2
        ldx #0
ps_at:  lda $ffff,x
        beq +
        stx ps_x
        jsr CHROUT
        ldx ps_x
        inx
        bne ps_at
+       rts
ps_x:   !byte 0

print_cr:
        lda #13
        jmp CHROUT

print_hex:
        pha
        lsr
        lsr
        lsr
        lsr
        jsr +
        pla
        and #15
+       cmp #10
        bcc +
        adc #6              ; (carry set: 'A' - '9' - 1)
+       adc #'0'
        jmp CHROUT

; F(X) as a decimal number: the sign, the whole part, a point and six
; places, the last rounded to nearest from the exact value (ties to even).
; 2^31 and more prints as 2147483647; an infinity as INF, a NaN as NAN; a
; value that rounds to 0 prints without a sign. F0-F15, MCTRL and MFLAGS are
; left as they were (F14 and F15 are used and put back); MINT and MCOND are
; not.
;
; The six places are the fraction times 1,000,000 as an integer. For that
; to round once, the product is taken toward 0 and its inexact flag kept:
; with what is left of it against 1/2, that says which way the exact
; product lies.
print_freg:
        txa
        asl
        asl
        sta pf_z
        +mcp_enter
        +f_wait
        ldz #MCP_FLAGS
        lda [p_ctl],z
        sta pf_flags
        ldz #MCP_CTRL
        lda [p_ctl],z
        sta pf_ctrl
        ldz pf_z
        ldq [p_f]
        stq pf_v            ; the value
        ldz #14 * 4
        ldq [p_f]
        stq pf_s14
        ldz #15 * 4
        ldq [p_f]
        stq pf_s15
        lda pf_v+3          ; the exponent all ones: an infinity or a NaN
        and #$7f
        cmp #$7f
        bne +
        lda pf_v+2
        bpl +
        jmp pf_special
+       ldq pf_v            ; F15 = |value|
        stq pf_a
        lda pf_a+3
        and #$7f
        sta pf_a+3
        +f_load 15, pf_a
        +f_op MCP_FTRUNC, 14, 15        ; F14 = its whole part
        +f_op MCP_FTOI, 0, 14
        +f_wait
        ldz #MCP_INT
        ldq [p_ctl]
        stq pf_int
        +f_op MCP_FSUB, 15, 14          ; F15 = the fraction (exact)
        +f_data MCP_SETCTRL, MCP_RZ     ; toward 0, the flags clear
        +f_data MCP_SETFLAGS, 0
        +f_mem MCPM_FMUL, 15, pf_1e6    ; times 1,000,000
        +f_op MCP_FTRUNC, 14, 15        ; F14 = the places
        +f_op MCP_FTOI, 0, 14
        +f_op MCP_FSUB, 15, 14          ; what is left, against 1/2
        +f_mem MCPM_FCMP, 15, pf_half
        +f_wait
        ldz #MCP_INT
        ldq [p_ctl]
        stq pf_frac
        ldz #MCP_FLAGS
        lda [p_ctl],z
        and #$10
        sta pf_inx          ; the product was cut short: the exact one is more
        ldz #MCP_COND
        lda [p_ctl],z
        sta pf_cond
        jsr pf_restore
        +mcp_leave
        lda pf_cond
        and #$04            ; more than 1/2: up
        bne pf_up
        lda pf_cond
        and #$02            ; less: as it is
        beq pf_done
        lda pf_inx          ; 1/2 and a bit: up
        bne pf_up
        lda pf_frac         ; 1/2 exactly: to the even one
        lsr
        bcc pf_done
pf_up:  inc pf_frac
        bne +
        inc pf_frac+1
        bne +
        inc pf_frac+2
+       lda pf_frac         ; 1,000,000: the whole part one more
        cmp #<1000000
        bne pf_done
        lda pf_frac+1
        cmp #>1000000
        bne pf_done
        lda pf_frac+2
        cmp #^1000000
        bne pf_done
        lda #0
        sta pf_frac
        sta pf_frac+1
        sta pf_frac+2
        inc pf_int
        bne pf_done
        inc pf_int+1
        bne pf_done
        inc pf_int+2
        bne pf_done
        inc pf_int+3
pf_done:
        lda pf_v+3          ; the sign, unless every digit is 0
        bpl +
        lda pf_int
        ora pf_int+1
        ora pf_int+2
        ora pf_int+3
        ora pf_frac
        ora pf_frac+1
        ora pf_frac+2
        beq +
        lda #'-'
        jsr CHROUT
+       ldq pf_int
        stq sdk_num
        lda #1
        jsr print_u32
        lda #'.'
        jsr CHROUT
        ldq pf_frac
        stq sdk_num
        lda #6
        jmp print_u32
pf_special:
        jsr pf_restore
        +mcp_leave
        lda pf_v+2          ; a NaN: the significand not 0
        and #$7f
        ora pf_v+1
        ora pf_v
        beq +
        +print pf_nan
        rts
+       lda pf_v+3
        bpl +
        lda #'-'
        jsr CHROUT
+       +print pf_inf
        rts
; F14, F15, the rounding mode and the flags as they were (in the SDK's base page)
pf_restore:
        +f_load 14, pf_s14
        +f_load 15, pf_s15
        ldz #MCP_REGFORM + MCP_SETCTRL
        lda pf_ctrl
        sta [p_ctl],z
        ldz #MCP_REGFORM + MCP_SETFLAGS
        lda pf_flags
        sta [p_ctl],z
        +f_wait
        rts
pf_z:     !byte 0
pf_flags: !byte 0
pf_ctrl:  !byte 0
pf_inx:   !byte 0
pf_cond:  !byte 0
pf_v:     !32 0
pf_a:     !32 0
pf_s14:   !32 0
pf_s15:   !32 0
pf_int:   !32 0
pf_frac:  !32 0
pf_1e6:   !32 $49742400     ; 1,000,000.0
pf_half:  !32 $3f000000     ; 0.5
pf_nan:   !text "NAN", 0
pf_inf:   !text "INF", 0

; V(X)'s first A components
print_vec:
        sta pv_n
        txa
        asl
        asl
        sta pv_r
        lda #'('
        jsr CHROUT
-       ldx pv_r
        jsr print_freg
        inc pv_r
        dec pv_n
        beq +
        lda #','
        jsr CHROUT
        lda #' '
        jsr CHROUT
        jmp -
+       lda #')'
        jmp CHROUT
pv_n:   !byte 0
pv_r:   !byte 0

; the signed number in sdk_num
print_s32:
        lda sdk_num+3
        bpl +
        lda #'-'
        jsr CHROUT
        sec                 ; negated
        lda #0
        sbc sdk_num
        sta sdk_num
        lda #0
        sbc sdk_num+1
        sta sdk_num+1
        lda #0
        sbc sdk_num+2
        sta sdk_num+2
        lda #0
        sbc sdk_num+3
        sta sdk_num+3
+       lda #1
        ; (fall through)

; the unsigned number in sdk_num, A digits at least (zeros in front)
print_u32:
        sta pu_min
        ldy #0
-       jsr pu_div10        ; the digits, the last first
        ora #'0'
        sta pu_buf,y
        iny
        lda sdk_num
        ora sdk_num+1
        ora sdk_num+2
        ora sdk_num+3
        bne -
-       cpy pu_min
        bcs +
        lda #'0'
        sta pu_buf,y
        iny
        bne -
+
-       dey
        sty pu_y
        lda pu_buf,y
        jsr CHROUT
        ldy pu_y
        bne -
        rts
; sdk_num = sdk_num / 10, the remainder in A
pu_div10:
        lda #0
        ldx #32
-       asl sdk_num
        rol sdk_num+1
        rol sdk_num+2
        rol sdk_num+3
        rol
        cmp #10
        bcc +
        sbc #10
        inc sdk_num
+       dex
        bne -
        rts
sdk_num: !32 0
pu_min: !byte 0
pu_y:   !byte 0
pu_buf: !fill 12, 0

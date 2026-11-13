; async.asm - M65-MCP SDK example 6: the unit works while the CPU goes on.
; What a program gets when it does not wait: a register read too early
; still holds its old value, and commands sent faster than the unit takes
; them are dropped once its queue of 16 is full. And how to do it right:
; MSTATUS bit 0 (busy) before a read, bit 1 (the queue nearly full) before
; a command in a fast loop.
;
;   acme -f cbm -I ../include -o async.prg async.asm      then LOAD and RUN

!cpu m65
!source "mcp.inc"
!source "sdk.inc"

NDIV    = 64                    ; divides sent in a row

; a DMA job (an enhanced F018B list in bank 0); the CPU waits for it
!macro dma_job .list {
        lda #0
        sta $d702               ; the list's bank
        sta $d704               ; its megabyte
        lda #>.list
        sta $d701
        lda #<.list
        sta $d705               ; start (enhanced: options first)
}

* = $2001
        !word +, 10             ; 10 SYS 8208
        !byte $9e
        !text "8208"
        !byte 0
+       !word 0

* = $2010
        jsr sdk_init            ; the SDK's pointers; is there an MCP?
        bcc +
        rts
+       +print t_title

        +mcp_enter              ; (interrupts off, the SDK's base page)
        +f_reset

        ; 1. A result takes its time. VNORM3 takes 66 clocks; the CPU's next
        ; instruction comes after about 20. Read at once, F4 is still what it
        ; was, and MSTATUS bit 0 says the unit is busy.
        +f_load_n 4, 4, c_vec           ; V1 = (3, 4, 0, 0)
        +f_wait
        +f_op3 MCPW_VNORM3, 1, 1, 0     ; V1 = V1 / its length: (0.6, 0.8, 0)
        ldz #4 * 4
        ldq [p_f]                       ; F4, read at once
        stq v_early
        ldz #MCP_STATUS
        lda [p_ctl],z
        sta v_busy
        +f_wait                         ; the right way: wait, then read
        ldz #4 * 4
        ldq [p_f]
        stq v_late

        ; An add takes 5 clocks: it is done before the CPU can ask. (Do not
        ; count on it: which commands are that fast is the unit's business.)
        +f_op MCP_FCONST, 8, MCPC_ONE
        +f_wait
        +f_op MCP_FADD, 8, 8            ; F8 = 1 + 1
        ldz #8 * 4
        ldq [p_f]
        stq v_add

        ; 2. The queue holds 16 commands. A DMA job writes a command every 4
        ; clocks, a divide takes 20: of 64 divides sent that way, most find
        ; the queue full and are dropped. MSTATUS bit 2 (overrun) says so,
        ; and stays set until MSTATUS is written.
        +f_op MCP_FCONST, 1, MCPC_ONE   ; F1 = 1, halved by every divide that runs
        +f_op MCP_FCONST, 2, MCPC_TWO
        +f_wait
        +dma_job d_divs                 ; NDIV times FDIV F1, F2, into MSTREAM
        +f_wait
        ldz #MCP_STATUS
        lda [p_ctl],z
        sta v_st_dma
        sta [p_ctl],z                   ; (any write clears bits 2, 3 and 5)
        lda [p_ctl],z
        sta v_st_clr
        ldz #1 * 4
        ldq [p_f]
        stq v_f1
        jsr halvings
        sta v_n_dma

        ; 3. The right way in a fast loop: MSTATUS bit 1 is set when 12 of
        ; the 16 are taken. Wait for it to clear before each command, and
        ; none is lost.
        +f_op MCP_FCONST, 1, MCPC_ONE
        ldx #NDIV
-       ldz #MCP_STATUS
--      lda [p_ctl],z
        and #$02
        bne --
        +f_op MCP_FDIV, 1, 2
        dex
        bne -
        +f_wait
        ldz #MCP_STATUS
        lda [p_ctl],z
        sta v_st_loop
        ldz #1 * 4
        ldq [p_f]
        stq v_f1
        jsr halvings
        sta v_n_loop

        +f_load 12, v_early             ; (print_freg prints a register)
        +f_load 13, v_late
        +f_load 11, v_add
        +mcp_leave

        +print_f t_early, 12
        +print t_busy
        lda v_busy
        and #$01
        jsr yes_no
        +print_f t_late, 13
        +print_f t_add, 11
        +print t_dma
        lda v_n_dma
        jsr print_count
        +print t_over
        lda v_st_dma
        and #$04
        jsr yes_no
        +print t_clr
        lda v_st_clr
        and #$04
        jsr yes_no
        +print t_loop
        lda v_n_loop
        jsr print_count
        +print t_over
        lda v_st_loop
        and #$04
        ; (fall through)

; YES if A is not 0, else NO
yes_no:
        beq +
        +print t_yes
        rts
+       +print t_no
        rts

; A as a decimal number, " OF 64" and a new line
print_count:
        sta sdk_num
        lda #0
        sta sdk_num+1
        sta sdk_num+2
        sta sdk_num+3
        lda #1
        jsr print_u32
        +print t_of
        rts

; how often v_f1 (1.0 at first) was halved: 127 less its exponent
halvings:
        lda v_f1+2
        asl                     ; (the exponent's low bit)
        lda v_f1+3
        rol
        sta v_exp
        lda #127
        sec
        sbc v_exp
        rts

d_divs: !byte $0b               ; an F018B list
        !byte $81, $ff          ; the destination's megabyte
        !byte $00               ; the options' end
        !byte $00               ; copy
        !word NDIV * 2
        !word c_divs            ; from (bank 0)
        !byte $00
        !word $f120             ; to $FFDF120: MSTREAM
        !byte $0d
        !byte $08               ; the destination held
        !word 0
c_divs: !for .i, 1, NDIV {
        !byte MCP_FDIV, $12     ; FDIV F1, F2, in the stream's format
        }

v_early: !32 0
v_late:  !32 0
v_add:   !32 0
v_f1:    !32 0
v_busy:  !byte 0
v_st_dma: !byte 0
v_st_clr: !byte 0
v_st_loop: !byte 0
v_n_dma: !byte 0
v_n_loop: !byte 0
v_exp:   !byte 0
c_vec:   !32 $40400000, $40800000, 0, 0         ; 3, 4, 0, 0
t_title: !text 147, "M65-MCP SDK: ASYNC", 13, 0
t_early: !text "VNORM3, READ AT ONCE = ", 0
t_busy:  !text "  MSTATUS SAYS BUSY  : ", 0
t_late:  !text "  AFTER THE WAIT     = ", 0
t_add:   !text "FADD, READ AT ONCE   = ", 0
t_dma:   !text "FDIV BY DMA, DONE    = ", 0
t_over:  !text "  OVERRUN (BIT 2)    : ", 0
t_clr:   !text "  AFTER A WRITE      : ", 0
t_loop:  !text "FDIV, BIT 1 HEEDED   = ", 0
t_of:    !text " OF 64", 13, 0
t_yes:   !text "YES", 13, 0
t_no:    !text "NO", 13, 0

!source "sdklib.asm"

; program.asm - M65-MCP SDK example 4: programs in the MCP's memory.
; A program is a list of commands the unit runs for a number of passes
; without the CPU: PEND ends a pass, PEXIT leaves on a condition, PSKIP
; skips commands on one. The registers are its variables. Three programs
; here, at entries 0, 16 and 32 of the 512.
;
;   acme -f cbm -I ../include -o program.prg program.asm    then LOAD and RUN

!cpu m65
!source "mcp.inc"
!source "sdk.inc"

P_NEWTON = 0
P_SERIES = 16
P_BALL   = 32

* = $2001
        !word +, 10             ; 10 SYS 8208
        !byte $9e
        !text "8208"
        !byte 0
+       !word 0

* = $2010
        jsr sdk_init
        bcc +
        rts
+       +print t_title

        +mcp_enter
        +f_reset
        +p_load newton, newton_end - newton, P_NEWTON
        +p_load series, series_end - series, P_SERIES
        +p_load ball, ball_end - ball, P_BALL

        ; 1. Newton's iteration for sqrt(2): at most 20 passes, PEXIT leaves
        ;    when the estimate stops changing. MPCNT: the passes it took
        +f_op MCP_FCONST, 0, MCPC_TWO   ; F0 = a
        +f_op MCP_FCONST, 1, MCPC_ONE   ; F1 = the first estimate
        +f_op MCP_FCONST, 2, MCPC_HALF
        +p_run P_NEWTON, 20
        +f_wait
        ldz #MCP_MPCNT
        lda [p_ctl],z                   ; (the low byte: it latches the high one)
        sta v_passes
        +mcp_leave
        +print_f t_newton, 1
        +print t_passes
        jsr print_count

        ; 2. a sum: 1 / (k x k) for k = 1 to 1,000, one PRUN (it tends to pi^2 / 6)
        +mcp_enter
        +f_op MCP_FCONST, 0, MCPC_ZERO  ; F0 = the sum
        +f_op MCP_FCONST, 1, MCPC_ONE   ; F1 = k
        +f_op MCP_FCONST, 2, MCPC_ONE
        +p_run P_SERIES, 1000
        +f_wait
        +f_op MCP_FMOVE, 4, 0           ; F4 = sqrt(6 x the sum): about pi
        +f_mem MCPM_FMUL, 4, c_six
        +f_op MCP_FSQRT, 4, 4
        +f_wait
        +mcp_leave
        +print_f t_series, 0
        +print_f t_pi, 4

        ; 3. a bouncing ball, 100 steps: PSKIP skips the bounce while it is
        ;    above the floor
        +mcp_enter
        +f_load 0, c_height             ; F0 = y
        +f_op MCP_FCONST, 1, MCPC_ZERO  ; F1 = the speed
        +f_load 2, c_gravity            ; F2 = the speed's change a step
        +f_op MCP_FCONST, 3, MCPC_ZERO  ; F3 = the floor
        +f_load 4, c_bounce             ; F4 = the speed kept in a bounce
        +p_run P_BALL, 100
        +f_wait
        +mcp_leave
        +print_f t_bally, 0
        +print_f t_ballv, 1
        rts

; the passes (fewer than 256 here), and a new line
print_count:
        lda v_passes
        sta sdk_num
        lda #0
        sta sdk_num+1
        sta sdk_num+2
        sta sdk_num+3
        lda #1
        jsr print_u32
        jmp print_cr

; ---- the programs, in the stream's format: a register form is the opcode
; and (d << 4) | s; a wide form $90, the op, (d << 4) | s, t << 4

newton:                                 ; x = (x + a / x) / 2: F0 a, F1 x, F2 0.5
        !byte MCP_FMOVE, $31            ; FMOVE F3, F1       the old estimate
        !byte MCP_FMOVE, $40            ; FMOVE F4, F0
        !byte MCP_FDIV, $41             ; FDIV  F4, F1       a / x
        !byte MCP_FADD, $14             ; FADD  F1, F4       x + a / x
        !byte MCP_FMUL, $12             ; FMUL  F1, F2       times 0.5
        !byte MCP_FCMP, $13             ; FCMP  F1, F3
        !byte MCP_PEXIT, $02            ; PEXIT equal        no change: done
        !byte MCP_PEND, 0
newton_end:

series:                                 ; sum += 1 / (k x k); k += 1: F0 sum, F1 k, F2 1.0
        !byte $90, MCPW_FMUL3, $31, $10 ; FMUL3 F3, F1, F1   k x k
        !byte MCP_FRECIP, $33           ; FRECIP F3, F3
        !byte MCP_FADD, $03             ; FADD  F0, F3
        !byte MCP_FADD, $12             ; FADD  F1, F2
        !byte MCP_PEND, 0
series_end:

ball:                                   ; F0 y, F1 speed, F2 gravity, F3 0.0, F4 the bounce
        !byte MCP_FSUB, $12             ; FSUB  F1, F2       falling faster
        !byte MCP_FADD, $01             ; FADD  F0, F1       moving
        !byte MCP_FCMP, $03             ; FCMP  F0, F3       against the floor
        !byte $90, MCPW_PSKIP, $0e, $30 ; PSKIP not less, 3  above it: no bounce
        !byte MCP_FNEG, $00             ; FNEG  F0, F0       back above the floor
        !byte MCP_FNEG, $11             ; FNEG  F1, F1       upward
        !byte MCP_FMUL, $14             ; FMUL  F1, F4       a little slower
        !byte MCP_PEND, 0
ball_end:

v_passes:  !byte 0
c_six:     !32 $40c00000        ; 6.0
c_height:  !32 $41200000        ; 10.0
c_gravity: !32 $3e800000        ; 0.25
c_bounce:  !32 $3f400000        ; 0.75
t_title:  !text 147, "M65-MCP SDK: PROGRAMS", 13, 0
t_newton: !text "SQRT(2) BY NEWTON    = ", 0
t_passes: !text "  PASSES             = ", 0
t_series: !text "1/(K*K), K TO 1000   = ", 0
t_pi:     !text "  SQRT(6 X THE SUM)  = ", 0
t_bally:  !text "BALL AFTER 100 STEPS = ", 0
t_ballv:  !text "  ITS SPEED          = ", 0

!source "sdklib.asm"

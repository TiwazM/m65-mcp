; scalar.asm - M65-MCP SDK example 1: scalar calculations.
; The three ways to give a command (register, memory and wide forms),
; constants, integers in and out, a compare and the flags.
;
;   acme -f cbm -I ../include -o scalar.prg scalar.asm      then LOAD and RUN

!cpu m65
!source "mcp.inc"
!source "sdk.inc"

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

        ; F0 = sqrt(2): a constant from the unit's table, then a register form
        +f_op MCP_FCONST, 0, MCPC_TWO
        +f_op MCP_FSQRT, 0, 0

        ; F1 = the area of a circle of radius 2.5: a value from memory
        +f_load 1, c_radius             ; F1 = r
        +f_op MCP_FMUL, 1, 1            ; r x r
        +f_op MCP_FCONST, 2, MCPC_PI
        +f_op MCP_FMUL, 1, 2            ; x pi

        ; F3 = hypot(3, 4): integers in (FILD), a fused multiply-add (a wide form)
        +f_mem MCPM_FILD, 3, c_three    ; F3 = float(3)
        +f_mem MCPM_FILD, 4, c_four
        +f_op MCP_FMUL, 3, 3            ; 9
        +f_op3 MCPW_FMA, 3, 4, 4        ; F3 = F4 x F4 + F3, rounded once
        +f_op MCP_FSQRT, 3, 3

        ; F5 = 98.6 Fahrenheit in Celsius: memory forms, each "F5 = F5 op value"
        +f_load 5, c_986
        +f_mem MCPM_FSUB, 5, c_32
        +f_mem MCPM_FMUL, 5, c_5
        +f_mem MCPM_FDIV, 5, c_9

        ; F6 = 1 / 3
        +f_mem MCPM_FRECIP, 6, c_3f

        ; compare F0 with F1: MCOND (read before the next compare, or FCLASS)
        +f_op MCP_FCMP, 0, 1
        +f_wait
        ldz #MCP_COND
        lda [p_ctl],z
        sta v_cond

        ; an integer out: MINT = int(1000 x sqrt(2)), rounded by MCTRL's mode
        +f_op MCP_FMOVE, 7, 0
        +f_mem MCPM_FMUL, 7, c_1000
        +f_op MCP_FTOI, 0, 7
        +f_wait                         ; (read nothing before the unit is idle)
        ldz #MCP_INT
        ldq [p_ctl]                     ; (LDQ [zp] adds Z)
        stq v_int
        ldz #MCP_FLAGS
        lda [p_ctl],z
        sta v_flags
        +mcp_leave

        +print_f t_sqrt, 0
        +print_f t_area, 1
        +print_f t_hypot, 3
        +print_f t_cels, 5
        +print_f t_third, 6
        +print t_int
        ldq v_int
        stq sdk_num
        jsr print_s32
        jsr print_cr
        +print t_less
        lda v_cond
        and #$01                        ; bit 0: less
        beq +
        +print t_yes
        jmp ++
+       +print t_no
++      +print t_flags
        lda v_flags
        jsr print_hex
        jmp print_cr

v_cond:  !byte 0
v_flags: !byte 0
v_int:   !32 0
c_radius: !32 $40200000         ; 2.5
c_three: !32 3                  ; (integers, for FILD)
c_four:  !32 4
c_986:   !32 $42c53333          ; 98.6
c_32:    !32 $42000000          ; 32.0
c_5:     !32 $40a00000          ; 5.0
c_9:     !32 $41100000          ; 9.0
c_3f:    !32 $40400000          ; 3.0
c_1000:  !32 $447a0000          ; 1000.0
t_title: !text 147, "M65-MCP SDK: SCALAR", 13, 0
t_sqrt:  !text "SQRT(2)            = ", 0
t_area:  !text "AREA, RADIUS 2.5   = ", 0
t_hypot: !text "HYPOT(3, 4)        = ", 0
t_cels:  !text "98.6 F IN CELSIUS  = ", 0
t_third: !text "1 / 3              = ", 0
t_int:   !text "INT(1000 SQRT(2))  = ", 0
t_less:  !text "SQRT(2) < AREA     : ", 0
t_yes:   !text "YES", 13, 0
t_no:    !text "NO", 13, 0
t_flags: !text "MFLAGS             = $", 0

!source "sdklib.asm"

; vector.asm - M65-MCP SDK example 2: vectors.
; V0-V3 are the F registers four at a time (V0 = F0-F3 as x, y, z, w; V1 =
; F4-F7; V2 = F8-F11; V3 = F12-F15). All vector commands are wide forms.
;
;   acme -f cbm -I ../include -o vector.prg vector.asm      then LOAD and RUN

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
        jsr sdk_init
        bcc +
        rts
+       +print t_title

        ; V0 = A, V1 = B: eight registers from memory
        +mcp_enter
        +f_reset
        +f_load_n 0, 8, c_ab

        +f_op3 MCPW_VADD, 2, 0, 1       ; V2 = V0 + V1
        +f_wait
        +mcp_leave
        +print t_add
        ldx #2
        lda #3
        jsr print_vec
        jsr print_cr

        +mcp_enter
        +f_op3 MCPW_VDOT3, 12, 0, 1     ; F12 = V0 . V1 (the result is an F register)
        +f_wait
        +mcp_leave
        +print_f t_dot, 12

        +mcp_enter
        +f_op3 MCPW_VCROSS, 2, 0, 1     ; V2 = V0 x V1
        +f_wait
        +mcp_leave
        +print t_cross
        ldx #2
        lda #3
        jsr print_vec
        jsr print_cr

        +mcp_enter
        +f_op3 MCPW_VDOT3, 12, 0, 0     ; F12 = A . A
        +f_op MCP_FSQRT, 12, 12         ; its root: the length
        +f_op3 MCPW_VNORM3, 2, 0, 0     ; V2 = V0 / its length
        +f_wait
        +mcp_leave
        +print_f t_len, 12
        +print t_norm
        ldx #2
        lda #3
        jsr print_vec
        jsr print_cr

        +mcp_enter
        +f_load 13, c_scale
        +f_op3 MCPW_VSCALE, 2, 0, 13    ; V2 = V0 x F13
        +f_wait
        +mcp_leave
        +print t_scale
        ldx #2
        lda #3
        jsr print_vec
        jmp print_cr

c_ab:    !32 $3f800000, $40000000, $40400000, 0         ; A = (1, 2, 3)
         !32 $40800000, $40a00000, $40c00000, 0         ; B = (4, 5, 6)
c_scale: !32 $40200000                                  ; 2.5
t_title: !text 147, "M65-MCP SDK: VECTORS", 13
         !text "A = (1, 2, 3)   B = (4, 5, 6)", 13, 0
t_add:   !text "A + B        = ", 0
t_dot:   !text "A . B        = ", 0
t_cross: !text "A X B        = ", 0
t_len:   !text "LENGTH OF A  = ", 0
t_norm:  !text "A NORMALISED = ", 0
t_scale: !text "2.5 A        = ", 0

!source "sdklib.asm"

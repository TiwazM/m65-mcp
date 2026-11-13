; matrix.asm - M65-MCP SDK example 3: matrices.
; The matrix bank M holds one 4 x 4 matrix by rows. MLOAD copies F0-F15
; into it, MXV multiplies it with a vector, MTXV its transpose, MMUL
; multiplies it by the matrix in F0-F15, and MSTORE brings it back.
;
;   acme -f cbm -I ../include -o matrix.prg matrix.asm      then LOAD and RUN

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

        ; M = R: the rotation into F0-F15, then MLOAD
        +mcp_enter
        +f_reset
        +f_load_n 0, 16, c_rot
        +f_op3 MCPW_MLOAD, 0, 0, 0
        ; V1 = M x V0, with V0 = the point (1, 0, 0, 1)
        +f_load_n 0, 4, c_point
        +f_op3 MCPW_MXV, 1, 0, 0
        +f_wait
        +mcp_leave
        +print t_once
        ldx #1
        lda #3
        jsr print_vec
        jsr print_cr

        ; M = M x F with F = R again: the rotation twice
        +mcp_enter
        +f_load_n 0, 16, c_rot
        +f_op3 MCPW_MMUL, 0, 0, 0
        +f_load_n 0, 4, c_point
        +f_op3 MCPW_MXV, 1, 0, 0        ; V1 = M x V0
        +f_op3 MCPW_MTXV, 2, 1, 0       ; V2 = transpose(M) x V1: back again
        +f_wait
        +mcp_leave
        +print t_twice
        ldx #1
        lda #3
        jsr print_vec
        jsr print_cr
        +print t_back
        ldx #2
        lda #3
        jsr print_vec
        jsr print_cr

        ; F0-F15 = M: its first two rows are V0 and V1
        +mcp_enter
        +f_op3 MCPW_MSTORE, 0, 0, 0
        +f_wait
        +mcp_leave
        +print t_row0
        ldx #0
        lda #4
        jsr print_vec
        jsr print_cr
        +print t_row1
        ldx #1
        lda #4
        jsr print_vec
        jmp print_cr

COS30 = $3f5db3d7               ; cos 30 degrees = 0.8660254
SIN30 = $3f000000               ; sin 30 degrees = 0.5
c_rot:   !32 COS30, SIN30 | $80000000, 0, 0     ; by rows: (c, -s, 0, 0)
         !32 SIN30, COS30, 0, 0                 ;          (s, c, 0, 0)
         !32 0, 0, $3f800000, 0
         !32 0, 0, 0, $3f800000
c_point: !32 $3f800000, 0, 0, $3f800000         ; (1, 0, 0, 1)
t_title: !text 147, "M65-MCP SDK: MATRICES", 13
         !text "R TURNS 30 DEGREES ABOUT Z; P = (1, 0, 0)", 13, 0
t_once:  !text "R P            = ", 0
t_twice: !text "R R P          = ", 0
t_back:  !text "AND BACK       = ", 0
t_row0:  !text "R R, ROW 0     = ", 0
t_row1:  !text "R R, ROW 1     = ", 0

!source "sdklib.asm"

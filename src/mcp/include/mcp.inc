; mcp.inc - the M65-MCP for ACME 0.97, !cpu m65: MCP-1 (the scalar FPU) and
; MCP-2's programs. Addresses, opcodes and a few macros; the programming
; model is src/mcp/MCP1.md and MCP2.md.
;
; The unit is at $FFDF100-$FFDF7FF, outside the 16-bit address space: the
; macros reach it through 32-bit base-page pointers ([zp],Z addressing).
; Two 45GS02 details (MCP.md, "The 45GS02 interface"): STQ [zp] does not
; add Z, LDQ [zp] does - and LDQ and STQ overwrite Z.

MCP          = $0ffdf000
MCP_CTRLPAGE = MCP + $100       ; a pointer here reaches the next ones with Z = offset
MCP_STATUS   = $00              ; (offsets from MCP_CTRLPAGE)
MCP_ID       = $01              ;   reads $4D
MCP_VER      = $02              ;   reads $01
MCP_QLEN     = $03
MCP_CTRL     = $04              ;   bits 0-1 rounding: MCP_RN, MCP_RD, MCP_RU, MCP_RZ
MCP_FLAGS    = $05
MCP_COND     = $06
MCP_RESET    = $07
MCP_INT      = $08              ;   4 bytes (byte 0 first: it latches the rest)
MCP_STREAM   = $20              ;   4 addresses, one port: STQ appends four bytes
MCP_STREAMRST = $24
MCP_MPPTR    = $0c              ;   (MCP-2) program memory address, 2 bytes
MCP_MPCNT    = $0e              ;   passes the last PRUN completed, 2 bytes (low first)
MCP_MPERR    = $10              ;   why the last program aborted
MCP_MPLIMIT  = $14              ;   commands a PRUN may run, 3 bytes (0: no limit)
MCP_MPLOAD   = $28              ;   4 addresses, one port: commands into program memory
MCP_MPLOADRST = $2c
MCP_MPABORT  = $2d
MCP_MPREAD   = $30              ;   8 bytes: the entry at MPPTR
MCP_REGFORM  = $80              ;   + opcode: write (d << 4) | s
MCP_MEMFORM  = MCP + $400       ; + m * 64 + d * 4: a 32-bit write (Fd = Fd op v)
MCP_FREGS    = MCP + $400       ; + d * 4: F0-F15 (read; a write is FMOVE)

MCP_RN = 0                      ; rounding: to nearest-even
MCP_RD = 1                      ;   toward -infinity
MCP_RU = 2                      ;   toward +infinity
MCP_RZ = 3                      ;   toward 0

; register forms (opcodes)
MCP_FMOVE  = $00
MCP_FADD   = $01
MCP_FSUB   = $02
MCP_FSUBR  = $03
MCP_FMUL   = $04
MCP_FDIV   = $05
MCP_FDIVR  = $06
MCP_FCMP   = $07
MCP_FMIN   = $08
MCP_FMAX   = $09
MCP_FSQRT  = $0a
MCP_FABS   = $0b
MCP_FNEG   = $0c
MCP_FRINT  = $0d
MCP_FTRUNC = $0e
MCP_FCLASS = $0f
MCP_FTOI   = $10
MCP_FTOX   = $11
MCP_FTOI16 = $12
MCP_FRECIP = $13
MCP_FXCHG  = $14
MCP_FCONST = $15
MCP_SETCTRL = $16
MCP_SETFLAGS = $17
MCP_PEXIT  = $18                ; (MCP-2, in a program) leave if MCOND and the data byte
MCP_PEND   = $19                ; (MCP-2, in a program) the end of a pass

; memory forms (m)
MCPM_FMOVE  = 0
MCPM_FADD   = 1
MCPM_FSUB   = 2
MCPM_FSUBR  = 3
MCPM_FMUL   = 4
MCPM_FDIV   = 5
MCPM_FDIVR  = 6
MCPM_FCMP   = 7
MCPM_FMIN   = 8
MCPM_FMAX   = 9
MCPM_FSQRT  = 10
MCPM_FRECIP = 11
MCPM_FILD   = 12
MCPM_FXLD   = 13
MCPM_PRUN   = 14                ; (MCP-2) v: start (bits 0-8), passes (bits 16-31)

; wide forms (MCP-2): write (d << 4) | s to MCP_WIDE + op * 2, then t << 4 to
; the next address (the second byte issues); in the stream: $90, op, both bytes
MCP_WIDE    = MCP + $200
MCPW_FADD3  = $00               ; Fd = Fs + Ft
MCPW_FSUB3  = $01               ; Fd = Fs - Ft
MCPW_FMUL3  = $02               ; Fd = Fs * Ft
MCPW_FMA    = $03               ; Fd = Fs * Ft + Fd, rounded once
MCPW_FMS    = $04               ; Fd = Fd - Fs * Ft, rounded once
; vectors (MCP-2 stage 3b): V0-V3 are F0-F3, F4-F7, F8-F11, F12-F15 (x, y,
; z, w); d, s, t name V registers, except VSCALE's t and VDOT's d (an F)
MCPW_VMOVE  = $10               ; Vd = Vs
MCPW_VADD   = $11               ; Vd = Vs + Vt, component by component
MCPW_VSUB   = $12               ; Vd = Vs - Vt
MCPW_VMUL   = $13               ; Vd = Vs * Vt
MCPW_VSCALE = $14               ; Vd = Vs * Ft
MCPW_VDOT3  = $15               ; Fd = Vs . Vt over x, y, z
MCPW_VDOT4  = $16               ; Fd = Vs . Vt over x, y, z, w
MCPW_VCROSS = $17               ; Vd.xyz = Vs.xyz x Vt.xyz, Vd.w = +0
MCPW_VNORM3 = $18               ; Vd.xyz = Vs.xyz / length(Vs.xyz), Vd.w = Vs.w
; the matrix bank M0-M15 (a 4 x 4 matrix by rows)
MCPW_MLOAD  = $20               ; M = F0-F15
MCPW_MSTORE = $21               ; F0-F15 = M
MCPW_MXV    = $22               ; Vd = M * Vs
MCPW_MTXV   = $23               ; Vd = transpose(M) * Vs
MCPW_MMUL   = $24               ; M = M * F (F0-F15 as a 4 x 4 matrix by rows)
; the vertex path (MCP-3, MCP3.md)
MCPW_VIN    = $25               ; Vd = the vertex's field t: 0 position, 1 normal, 2 colour
MCPW_VOUT   = $26               ; Fs into the entry at byte 2t, in format d (MCPV_*)
MCPW_VOUTC  = $27               ; Vs as four bytes (x 2^8) into the entry at byte 2t
MCP_VNEXT   = $1a               ; (register forms) the next vertex
MCP_VPASS   = $1b               ;   the vertex's attribute words into the entry from word (data)
MCP_VEND    = $1e               ;   the entry done: VTXIDX advances
MCPV_F32    = 0                 ; VOUT's formats: FP32 (4 bytes)
MCPV_F32HI  = 1                 ;   FP32's top half
MCPV_S12_4  = 2                 ;   s16 x 16
MCPV_U16    = 3                 ;   u16 x 2^16 (0-1 to 0-65535)
MCPV_S16    = 4                 ;   s16
MCPV_S16_16 = 5                 ;   s32 x 2^16 (4 bytes)
MCP_VINDATA = MCP + $000        ; the vertex page ($FFDF000 + offset): VINDATA, 4 addresses one port
MCP_VINPTR  = MCP + $004        ;   2 bytes: VINDATA's address in the vertex array
MCP_VINIDX  = MCP + $006        ;   2 bytes: the vertex VIN reads (bits 1-0 0)
MCP_VFMT    = MCP + $008        ;   bit 0 FP32 position, 1 normal, 2 colour, 3-4 attribute words
MCP_VPOSEXP = MCP + $009        ;   s16 positions x 2^-n
MCP_VTXIDX  = MCP + $00c        ;   2 bytes: the entry the stores go to
MCP_VBANK   = MCP + $00e        ;   which 2 KB of the result buffer the window shows
MCP_VOUTWIN = MCP + $800        ; the window: 64 entries of 32 bytes

; FCONST numbers
MCPC_ZERO = 0
MCPC_ONE  = 1
MCPC_TWO  = 2
MCPC_HALF = 3
MCPC_TEN  = 4
MCPC_PI   = 5
MCPC_PI2  = 6           ; pi / 2
MCPC_TWOPI = 7
MCPC_E    = 8
MCPC_LN2  = 9
MCPC_LOG2E = 10
MCPC_LOG10_2 = 11
MCPC_SQRT2 = 12
MCPC_SQRTH = 13         ; 1 / sqrt 2
MCPC_INF  = 14
MCPC_NAN  = 15

; a 32-bit base-page pointer: .zp = .addr
!macro mcp_ptr .zp, .addr {
        lda #<.addr
        sta .zp
        lda #>.addr
        sta .zp+1
        lda #^.addr
        sta .zp+2
        lda #(.addr >> 24)
        sta .zp+3
}

; a register form: .op Fd, Fs (.ctrl: a pointer to MCP_CTRLPAGE). Changes A, Z
!macro mcp_op .ctrl, .op, .d, .s {
        ldz #MCP_REGFORM + .op
        lda #(.d << 4) | .s
        sta [.ctrl],z
}

; wait until the unit is idle (MSTATUS bit 0). Changes A, Z
!macro mcp_wait .ctrl {
        ldz #MCP_STATUS
-       lda [.ctrl],z
        and #1
        bne -
}

; Q = Fd (.fregs: a pointer to MCP_FREGS). Changes A, X, Y, Z
!macro mcp_get .fregs, .d {
        ldz #.d * 4
        ldq [.fregs]
}

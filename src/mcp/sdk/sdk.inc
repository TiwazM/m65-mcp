; sdk.inc - what the M65-MCP's SDK examples share (ACME 0.97, !cpu m65):
; the pointers, and macros for the three command forms. Its routines are in
; sdklib.asm. After mcp.inc:
;
;       !source "mcp.inc"
;       !source "sdk.inc"
;
; The examples run under BASIC 65 and come back to it, so they keep off the
; KERNAL's memory: all of its base page is in use, and $1600-$1EFF is the
; region the MEGA65 guarantees free for programs. The SDK puts its own base
; page there. Between +mcp_enter and +mcp_leave the CPU's base page
; register is $16, so base-page addresses are $1600 + n and the pointers
; below work; interrupts are off meanwhile (the KERNAL's interrupt needs its
; own base page). Call the KERNAL, and sdklib's print routines, outside
; such a stretch.

SDK_BP  = $16                   ; the SDK's base page: $1600-$16FF
p_ctl   = $00                   ; (4) $FFDF100: the control page; register forms (Z = $80 + opcode)
p_wide  = $04                   ; (4) $FFDF200: the wide forms (Z = op * 2)
p_f     = $08                   ; (4) $FFDF400: F0-F15, to read (Z = d * 4) or to load (byte by byte)
p_mem   = $0c                   ; (4) a memory form's address: +f_mem sets it
p_vtx   = $10                   ; (4) $FFDF000: the vertex page
p_run   = $14                   ; (4) $FFDF780: PRUN (memory form 14)

; into the SDK's base page, interrupts off. Changes A
!macro mcp_enter {
        php
        sei
        lda #SDK_BP
        tab
}

; and back. Changes A
!macro mcp_leave {
        lda #0
        tab
        plp
}

; wait until the unit is idle. Changes A, Z
!macro f_wait {
        +mcp_wait p_ctl
}

; a register form: .op Fd, Fs. Changes A, Z
!macro f_op .op, .d, .s {
        +mcp_op p_ctl, .op, .d, .s
}

; a register form whose byte is data (SETCTRL, SETFLAGS, PEXIT, VPASS). Changes A, Z
!macro f_data .op, .data {
        ldz #MCP_REGFORM + .op
        lda #.data
        sta [p_ctl],z
}

; a wide form: .op d, s, t. Changes A, Z
!macro f_op3 .op, .d, .s, .t {
        ldz #.op * 2
        lda #(.d << 4) | .s
        sta [p_wide],z
        inz
        lda #.t << 4
        sta [p_wide],z
}

; a memory form: Fd = Fd .m the FP32 (or int32) at .addr. Changes A, X, Y, Z
!macro f_mem .m, .d, .addr {
        lda #<(MCP_MEMFORM + .m * 64 + .d * 4)
        sta p_mem
        lda #>(MCP_MEMFORM + .m * 64 + .d * 4)
        sta p_mem+1
        ldq .addr
        stq [p_mem]             ; (STQ [zp] does not add Z: the pointer is the address)
}

; Fd = the FP32 at .addr. Changes A, X, Y, Z
!macro f_load .d, .addr {
        +f_mem MCPM_FMOVE, .d, .addr
}

; the FP32 at .addr = Fd, once the unit is idle. Changes A, X, Y, Z
!macro f_store .d, .addr {
        +f_wait
        ldz #.d * 4
        ldq [p_f]               ; (LDQ [zp] adds Z)
        stq .addr
}

; .n registers from F.d on = the FP32s at .addr (each fourth byte written
; is an FMOVE). .n * 4 + .d * 4 at most 256. Changes A, X, Z
!macro f_load_n .d, .n, .addr {
        ldx #0
        ldz #.d * 4
-       lda .addr,x
        sta [p_f],z
        inz
        inx
        cpx #.n * 4
        bne -
}

; MRESET: the unit as it starts (the program memory's contents stay). Changes Z
!macro f_reset {
        ldz #MCP_RESET
        sta [p_ctl],z
}

; .len bytes of commands at .addr (the stream's format) into program memory
; from entry .entry. Changes A, X, Z
!macro p_load .addr, .len, .entry {
        ldz #MCP_MPLOADRST
        sta [p_ctl],z
        lda #<.entry
        ldz #MCP_MPPTR
        sta [p_ctl],z
        lda #>.entry
        inz
        sta [p_ctl],z
        ldx #0
-       lda .addr,x
        ldz #MCP_MPLOAD
        sta [p_ctl],z
        inx
        cpx #.len
        bne -
}

; PRUN: the program at .entry, .passes passes (it is queued: +f_wait for
; its end). Changes A, X, Y, Z
!macro p_run .entry, .passes {
        lda #<.entry
        ldx #>.entry
        ldy #<.passes
        ldz #>.passes
        stq [p_run]
}

; print the zero-terminated text at .addr (sdklib). Outside +mcp_enter
!macro print .addr {
        lda #<.addr
        ldx #>.addr
        jsr print_str
}

; print the text, F.d as a decimal number, and a new line (sdklib)
!macro print_f .addr, .d {
        +print .addr
        ldx #.d
        jsr print_freg
        jsr print_cr
}

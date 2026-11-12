"""bas2prg: a BASIC listing (plain text, upper case) to a MEGA65 BASIC 65 PRG
at $2001. Only the C64 keywords ($80-$CB), which BASIC 65 keeps with the
same tokens; numbers and variables stay text. Enough for mandel.bas.

    python3 -I bas2prg.py in.bas out.prg
"""
import sys

KEYWORDS = [
    "END", "FOR", "NEXT", "DATA", "INPUT#", "INPUT", "DIM", "READ", "LET", "GOTO", "RUN", "IF",
    "RESTORE", "GOSUB", "RETURN", "REM", "STOP", "ON", "WAIT", "LOAD", "SAVE", "VERIFY", "DEF",
    "POKE", "PRINT#", "PRINT", "CONT", "LIST", "CLR", "CMD", "SYS", "OPEN", "CLOSE", "GET", "NEW",
    "TAB(", "TO", "FN", "SPC(", "THEN", "NOT", "STEP", "+", "-", "*", "/", "^", "AND", "OR", ">",
    "=", "<", "SGN", "INT", "ABS", "USR", "FRE", "POS", "SQR", "RND", "LOG", "EXP", "COS", "SIN",
    "TAN", "ATN", "PEEK", "LEN", "STR$", "VAL", "ASC", "CHR$", "LEFT$", "RIGHT$", "MID$", "GO",
]
TOKENS = {k: 0x80 + i for i, k in enumerate(KEYWORDS)}
BY_LENGTH = sorted(KEYWORDS, key=len, reverse=True)


def tokenize(text):
    out, i, quoted, rem = bytearray(), 0, False, False
    while i < len(text):
        c = text[i]
        if quoted or rem:
            out.append(ord(c))
            quoted = quoted and c != '"'
            i += 1
            continue
        if c == '"':
            quoted = True
            out.append(ord(c))
            i += 1
            continue
        for k in BY_LENGTH:
            if text.startswith(k, i):
                out.append(TOKENS[k])
                rem = k == "REM"
                i += len(k)
                break
        else:
            out.append(ord(c))
            i += 1
    return out


def main(src, dst):
    addr, prg = 0x2001, bytearray(b"\x01\x20")
    for line in open(src):
        line = line.strip()
        if not line:
            continue
        num, _, body = line.partition(" ")
        tok = tokenize(body.strip())
        nxt = addr + 4 + len(tok) + 1
        prg += bytes((nxt & 255, nxt >> 8, int(num) & 255, int(num) >> 8)) + tok + b"\x00"
        addr = nxt
    prg += b"\x00\x00"
    open(dst, "wb").write(prg)


if __name__ == "__main__":
    main(sys.argv[1], sys.argv[2])

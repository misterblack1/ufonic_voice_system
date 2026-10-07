#!/usr/bin/env python3
"""basic_tok.py: tokenize an Applesoft listing into a DOS 3.3 type-A file.

DOS 3.3 stores an Applesoft program as a 2-byte little-endian length followed
by the tokenized program itself. The program is a chain of lines:

    [next-line pointer, 2 bytes LE] [line number, 2 bytes LE] [tokens] [$00]

and a $0000 next-line pointer ends the chain. The pointers are absolute
addresses, so they assume a load address. Applesoft's default is $0801 and
DOS relocates nothing, so that is what is baked in here.

Outside string literals Applesoft drops spaces and matches keywords by longest
prefix. Inside quotes, after REM, and after DATA the text is copied verbatim.

To check it, run the self-test on any tokenized file pulled off a disk image:

    python basic_tok.py --selftest <extracted-HELLO.bin>

Usage:
    python basic_tok.py <listing.bas> <out.bin>
"""
import sys

LOAD_ADDR = 0x0801

# Applesoft tokens, in order, starting at $80.
TOKENS = (
    "END FOR NEXT DATA INPUT DEL DIM READ GR TEXT PR# IN# CALL PLOT HLIN VLIN "
    "HGR2 HGR HCOLOR= HPLOT DRAW XDRAW HTAB HOME ROT= SCALE= SHLOAD TRACE "
    "NOTRACE NORMAL INVERSE FLASH COLOR= POP VTAB HIMEM: LOMEM: ONERR RESUME "
    "RECALL STORE SPEED= LET GOTO RUN IF RESTORE & GOSUB RETURN REM STOP ON "
    "WAIT LOAD SAVE DEF POKE PRINT CONT LIST CLEAR GET NEW TAB( TO FN SPC( "
    "THEN AT NOT STEP + - * / ^ AND OR > = < SGN INT ABS USR FRE SCRN( PDL "
    "POS SQR RND LOG EXP COS SIN TAN ATN PEEK LEN STR$ VAL ASC CHR$ LEFT$ "
    "RIGHT$ MID$"
).split()

# Longest first so PRINT is not shadowed by PR#, and HGR2 not by HGR.
BY_LENGTH = sorted(
    ((name, 0x80 + i) for i, name in enumerate(TOKENS)),
    key=lambda p: -len(p[0]),
)

LITERAL_TAIL = {0x80 + TOKENS.index("REM"), 0x80 + TOKENS.index("DATA")}


def tokenize_line(text):
    """Tokenize one line body (everything after the line number)."""
    out = bytearray()
    i = 0
    literal = False
    while i < len(text):
        c = text[i]
        if literal:
            out.append(ord(c))
            i += 1
            continue
        if c == '"':
            out.append(0x22)
            i += 1
            while i < len(text):
                out.append(ord(text[i]))
                closed = text[i] == '"'
                i += 1
                if closed:
                    break
            continue
        if c == ' ':
            i += 1
            continue
        upper = text[i:].upper()
        for name, code in BY_LENGTH:
            if upper.startswith(name):
                out.append(code)
                i += len(name)
                if code in LITERAL_TAIL:
                    literal = True
                break
        else:
            out.append(ord(c.upper()))
            i += 1
    return bytes(out)


def tokenize(listing):
    """Tokenize a full listing. Returns the DOS 3.3 type-A file bytes."""
    lines = []
    for raw in listing.splitlines():
        stripped = raw.strip()
        if not stripped:
            continue
        num = ""
        j = 0
        while j < len(stripped) and stripped[j].isdigit():
            num += stripped[j]
            j += 1
        if not num:
            raise ValueError("line has no line number: %r" % raw)
        lines.append((int(num), tokenize_line(stripped[j:].lstrip())))

    prog = bytearray()
    addr = LOAD_ADDR
    for num, body in lines:
        nxt = addr + 4 + len(body) + 1
        prog += bytes((nxt & 0xFF, nxt >> 8, num & 0xFF, num >> 8))
        prog += body
        prog.append(0x00)
        addr = nxt
    prog += b"\x00\x00"
    return bytes((len(prog) & 0xFF, len(prog) >> 8)) + prog


def detokenize(blob):
    """Inverse of tokenize, used by the self-test. Returns a listing string."""
    n = blob[0] | (blob[1] << 8)
    prog = blob[2:2 + n]
    out = []
    i = 0
    while i + 1 < len(prog):
        if (prog[i] | (prog[i + 1] << 8)) == 0:
            break
        num = prog[i + 2] | (prog[i + 3] << 8)
        i += 4
        body = ""
        literal = False
        while i < len(prog) and prog[i] != 0:
            c = prog[i]
            if c >= 0x80 and not literal:
                body += TOKENS[c - 0x80]
                if c in LITERAL_TAIL:
                    literal = True
            else:
                body += chr(c)
            i += 1
        i += 1
        out.append("%d %s" % (num, body))
    return "\n".join(out)


def selftest(path):
    original = open(path, "rb").read()
    n = original[0] | (original[1] << 8)
    original = original[:2 + n]
    listing = detokenize(original)
    rebuilt = tokenize(listing)
    print(listing)
    print("original %d bytes, rebuilt %d bytes" % (len(original), len(rebuilt)))
    if rebuilt == original:
        print("SELFTEST PASS: round trip is byte-identical")
        return 0
    print("SELFTEST FAIL")
    for k, (a, b) in enumerate(zip(original, rebuilt)):
        if a != b:
            print("  first diff at %d: original %02X rebuilt %02X" % (k, a, b))
            break
    return 1


def main(argv):
    if len(argv) == 2 and argv[0] == "--selftest":
        return selftest(argv[1])
    if len(argv) != 2:
        sys.stderr.write(__doc__)
        return 2
    blob = tokenize(open(argv[0], "r", encoding="ascii").read())
    open(argv[1], "wb").write(blob)
    print("wrote %s (%d bytes)" % (argv[1], len(blob)))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))

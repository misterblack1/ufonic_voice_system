#!/usr/bin/env python3
"""Build the disk: assemble, tokenize, lay out the disk, verify.

Usage: python build.py card.bin card.txt out.dsk
The top level build.py makes card.bin and card.txt and runs this. ACME is
taken from the ACME environment variable, else from the PATH.
"""
import os
import re
import shutil
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
if len(sys.argv) != 4:
    sys.exit(__doc__)
CARD, CARDTXT, OUT = (os.path.abspath(a) for a in sys.argv[1:])
os.chdir(HERE)

ACME = os.environ.get('ACME') or shutil.which('acme')
BUILD = 'build'
MASTER = os.path.join('masters', 'dos33_blank.dsk')
TMPDSK = os.path.join(BUILD, 'spell.tmp.dsk')
DSKPUT = os.path.join('tools', 'dskput.py')

TRACK_BYTES = 4096
SECTOR = 256
SPEECH_FIRST = 18
SPEECH_LAST = 33
VTOC_OFF = 17 * TRACK_BYTES
END_LIMIT = 0x4000


def fail(msg):
    sys.exit('build: ' + msg)


def run(cmd):
    r = subprocess.run(cmd)
    if r.returncode != 0:
        fail('command failed with %d: %s' % (r.returncode, ' '.join(cmd)))


def read_word(path):
    d = open(path, 'rb').read(4)
    return d[0] | (d[1] << 8), d[2] | (d[3] << 8)


def on_speech_track(t):
    return SPEECH_FIRST <= t <= SPEECH_LAST


def main():
    if not ACME:
        fail('ACME not found. Put acme on the PATH or set ACME to its path')
    run([sys.executable, 'mkwords.py', CARD])
    run([sys.executable, os.path.join('..', 'speech', 'ufonicfeed.py'), CARD,
         CARDTXT])
    os.makedirs(BUILD, exist_ok=True)

    run([ACME, '--cpu', '6502', '--format', 'apple',
         '-o', os.path.join(BUILD, 'spell.bin'),
         '-l', os.path.join(BUILD, 'spell.sym'), 'spell.asm'])
    run([ACME, '--cpu', '6502', '--format', 'apple',
         '-o', os.path.join(BUILD, 'diag.bin'),
         '-l', os.path.join(BUILD, 'diag.sym'), 'diag.asm'])
    load, length = read_word(os.path.join(BUILD, 'spell.bin'))
    if load + length > END_LIMIT:
        fail('spell.bin ends at $%04X, past $%04X' % (load + length, END_LIMIT))

    run([sys.executable, os.path.join('tools', 'basic_tok.py'),
         'hello.bas', os.path.join(BUILD, 'hello.bin')])

    shutil.copyfile(MASTER, TMPDSK)
    disk = bytearray(open(TMPDSK, 'rb').read())

    vtoc = disk[VTOC_OFF:VTOC_OFF + SECTOR]
    for t in range(SPEECH_FIRST, SPEECH_LAST + 1):
        base = 0x38 + 4 * t
        if vtoc[base] != 0xFF or vtoc[base + 1] != 0xFF:
            fail('master track %d not fully free' % t)
    for t in range(SPEECH_FIRST, SPEECH_LAST + 1):
        base = 0x38 + 4 * t
        vtoc[base:base + 4] = b'\x00' * 4
    disk[VTOC_OFF:VTOC_OFF + SECTOR] = vtoc
    with open(TMPDSK, 'wb') as f:
        f.write(disk)

    for local, name, ftype in (
            ('hello.bin', 'HELLO', 'A'),
            ('spell.bin', 'SPELL', 'B'),
            ('diag.bin', 'UFDIAG', 'B')):
        run([sys.executable, DSKPUT, 'put', TMPDSK,
             os.path.join(BUILD, local), name,
             '--type', ftype, '--overwrite'])

    image = open(CARD, 'rb').read()
    if len(image) != 65536:
        fail('card image is %d bytes, expected 65536' % len(image))
    disk = bytearray(open(TMPDSK, 'rb').read())
    # Card byte B maps to track 18 + B / 4096, sector (B / 256) & 15,
    # offset B & 255, which is plain sequential order over the 16 tracks.
    disk[SPEECH_FIRST * TRACK_BYTES:(SPEECH_LAST + 1) * TRACK_BYTES] = image
    with open(TMPDSK, 'wb') as f:
        f.write(disk)

    disk = open(TMPDSK, 'rb').read()
    got = disk[SPEECH_FIRST * TRACK_BYTES:(SPEECH_LAST + 1) * TRACK_BYTES]
    if got != image:
        fail('speech tracks read back different from the card image')
    vtoc = disk[VTOC_OFF:VTOC_OFF + SECTOR]
    for t in range(SPEECH_FIRST, SPEECH_LAST + 1):
        base = 0x38 + 4 * t
        if vtoc[base] | vtoc[base + 1] | vtoc[base + 2] | vtoc[base + 3]:
            fail('VTOC marks sectors free on speech track %d' % t)

    sys.path.insert(0, os.path.join(HERE, 'tools'))
    import dskput
    for ct, cs, data in dskput.catalog_sectors(disk):
        for i in range(7):
            fd = data[0x0B + 35 * i:0x0B + 35 * (i + 1)]
            if dskput.filedesc_status(fd) != 'normal':
                continue
            name = dskput.filedesc_name(fd)
            t, s = fd[0x00], fd[0x01]
            seen = set()
            while not (t == 0 and s == 0):
                if (t, s) in seen:
                    fail('T/S list loop in %s' % name)
                seen.add((t, s))
                if on_speech_track(t):
                    fail('%s T/S list lands on speech track %d' % (name, t))
                tsl = dskput.read_sector(disk, t, s)
                for k in range(dskput.TS_PAIRS_PER_LIST):
                    dt = tsl[0x0C + 2 * k]
                    ds = tsl[0x0D + 2 * k]
                    if dt == 0 and ds == 0:
                        continue
                    if on_speech_track(dt):
                        fail('%s data sector %d/%d on speech track'
                             % (name, dt, ds))
                t, s = tsl[0x01], tsl[0x02]

    os.replace(TMPDSK, OUT)

    run([sys.executable, DSKPUT, 'get', OUT, 'SPELL',
         os.path.join(BUILD, 'check.bin')])
    check = open(os.path.join(BUILD, 'check.bin'), 'rb').read()
    want = open(os.path.join(BUILD, 'spell.bin'), 'rb').read()
    # dskput get pads the last sector with zeros, so compare the file
    # bytes plus zero padding, which is the exact round trip DOS can give.
    if (len(check) < len(want) or check[:len(want)] != want
            or any(check[len(want):])):
        fail('SPELL read back from the disk differs from build/spell.bin')

    r = subprocess.run([sys.executable, DSKPUT, 'ls', OUT],
                       capture_output=True, text=True)
    if r.returncode != 0:
        fail('dskput ls failed with %d' % r.returncode)
    sys.stdout.write(r.stdout)

    cardsum = sum(image) & 0xFFFF
    m = re.search(r'^CARDSUM = \$([0-9A-F]+)', open('words.inc').read(), re.M)
    if m is None:
        fail('no CARDSUM line in words.inc')
    if cardsum != int(m.group(1), 16):
        fail('card sum $%04X, words.inc says CARDSUM $%04X'
             % (cardsum, int(m.group(1), 16)))
    print('CARDSUM $%04X' % cardsum)
    print('BUILD OK')


if __name__ == '__main__':
    main()

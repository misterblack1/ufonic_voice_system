#!/usr/bin/env python3
"""Build the disk: merge the speech, assemble, lay out the disk, verify.

Usage: python build.py cm73002.vsm cm63002.vsm out.dsk
The top level build.py finds the two speech ROMs and runs this. ACME is
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
EVA11, EVA24, OUT = (os.path.abspath(a) for a in sys.argv[1:])
os.chdir(HERE)

SPELL = os.path.join('..', 'spellgame')
ACME = os.environ.get('ACME') or shutil.which('acme')
BUILD = 'build'
MASTER = os.path.join(SPELL, 'masters', 'dos33_blank.dsk')
TMPDSK = os.path.join(BUILD, 'chrysler.tmp.dsk')
DSKPUT = os.path.join(SPELL, 'tools', 'dskput.py')
BASTOK = os.path.join(SPELL, 'tools', 'basic_tok.py')
CARD = os.path.join(BUILD, 'card.bin')
CARDTXT = os.path.join(BUILD, 'card.txt')

TRACK_BYTES = 4096
SECTOR = 256
SPEECH_FIRST = 18
VTOC_OFF = 17 * TRACK_BYTES
END_LIMIT = 0x9600          # DOS buffers start here


def fail(msg):
    sys.exit('build: ' + msg)


def run(cmd):
    r = subprocess.run(cmd)
    if r.returncode != 0:
        fail('command failed with %d: %s' % (r.returncode, ' '.join(cmd)))


def read_word(path):
    d = open(path, 'rb').read(4)
    return d[0] | (d[1] << 8), d[2] | (d[3] << 8)


def main():
    if not ACME:
        fail('ACME not found. Put acme on the PATH or set ACME to its path')
    os.makedirs(BUILD, exist_ok=True)
    run([sys.executable, 'mkphrases.py', EVA11, EVA24, CARD, CARDTXT])
    run([sys.executable, 'mkart.py'])
    run([sys.executable, os.path.join('..', 'speech', 'ufonicfeed.py'), CARD,
         CARDTXT])
    inc = open('phrases.inc').read()
    ntracks = int(re.search(r'^NTRACKS = (\d+)', inc, re.M).group(1))
    cardsum = int(re.search(r'^CARDSUM = \$([0-9A-F]+)', inc, re.M).group(1), 16)
    last = SPEECH_FIRST + ntracks - 1

    run([ACME, '--cpu', '6502', '--format', 'apple',
         '-o', os.path.join(BUILD, 'chrysler.bin'),
         '-l', os.path.join(BUILD, 'chrysler.sym'), 'chrysler.asm'])
    load, length = read_word(os.path.join(BUILD, 'chrysler.bin'))
    if load + length > END_LIMIT:
        fail('chrysler.bin ends at $%04X, past $%04X' % (load + length, END_LIMIT))
    print('CHRYSLER $%04X-$%04X' % (load, load + length - 1))

    run([sys.executable, BASTOK, 'hello.bas', os.path.join(BUILD, 'hello.bin')])

    shutil.copyfile(MASTER, TMPDSK)
    disk = bytearray(open(TMPDSK, 'rb').read())
    vtoc = disk[VTOC_OFF:VTOC_OFF + SECTOR]
    for t in range(SPEECH_FIRST, last + 1):
        base = 0x38 + 4 * t
        if vtoc[base] != 0xFF or vtoc[base + 1] != 0xFF:
            fail('master track %d not fully free' % t)
        vtoc[base:base + 4] = b'\x00' * 4
    disk[VTOC_OFF:VTOC_OFF + SECTOR] = vtoc
    with open(TMPDSK, 'wb') as f:
        f.write(disk)

    for local, name, ftype in (
            ('hello.bin', 'HELLO', 'A'),
            ('chrysler.bin', 'CHRYSLER', 'B')):
        run([sys.executable, DSKPUT, 'put', TMPDSK,
             os.path.join(BUILD, local), name, '--type', ftype, '--overwrite'])

    image = open(CARD, 'rb').read()[:ntracks * TRACK_BYTES]
    if sum(image) & 0xFFFF != cardsum:
        fail('card image sum differs from CARDSUM')
    disk = bytearray(open(TMPDSK, 'rb').read())
    # Card byte B maps to track 18 + B / 4096, sector (B / 256) & 15.
    # Only the tracks the speech fills are written.
    disk[SPEECH_FIRST * TRACK_BYTES:(last + 1) * TRACK_BYTES] = image
    with open(TMPDSK, 'wb') as f:
        f.write(disk)

    sys.path.insert(0, os.path.join(HERE, SPELL, 'tools'))
    import dskput
    disk = open(TMPDSK, 'rb').read()
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
                if SPEECH_FIRST <= t <= last:
                    fail('%s T/S list lands on speech track %d' % (name, t))
                tsl = dskput.read_sector(disk, t, s)
                for k in range(dskput.TS_PAIRS_PER_LIST):
                    dt = tsl[0x0C + 2 * k]
                    ds = tsl[0x0D + 2 * k]
                    if (dt or ds) and SPEECH_FIRST <= dt <= last:
                        fail('%s data sector %d/%d on speech track' % (name, dt, ds))
                t, s = tsl[0x01], tsl[0x02]

    os.replace(TMPDSK, OUT)

    run([sys.executable, DSKPUT, 'get', OUT, 'CHRYSLER',
         os.path.join(BUILD, 'check.bin')])
    check = open(os.path.join(BUILD, 'check.bin'), 'rb').read()
    want = open(os.path.join(BUILD, 'chrysler.bin'), 'rb').read()
    if (len(check) < len(want) or check[:len(want)] != want
            or any(check[len(want):])):
        fail('CHRYSLER read back from the disk differs from build/chrysler.bin')

    r = subprocess.run([sys.executable, DSKPUT, 'ls', OUT],
                       capture_output=True, text=True)
    if r.returncode != 0:
        fail('dskput ls failed with %d' % r.returncode)
    sys.stdout.write(r.stdout)
    print('SPEECH TRACKS %d-%d, CARDSUM $%04X' % (SPEECH_FIRST, last, cardsum))
    print('BUILD OK')


if __name__ == '__main__':
    main()

#!/usr/bin/env python3
"""Build spell.dsk from the Speak & Spell speech ROMs, and chrysler.dsk from
the Electronic Voice Alert speech ROMs.

Usage: python build.py ROMS [ROMS ...]

Each ROMS is a MAME snspellua, eva11 or eva24 zip, a folder, or a ROM file.
The speech ROMs are found by SHA1, whatever they are named, also inside
zips found in a folder. Each disk whose ROMs are all found is built. Writes
build/snspellua.bin, the card image, build/spell.dsk and build/chrysler.dsk.
Needs Python 3.8 or later and ACME on the PATH, or ACME set to its path.
"""
import hashlib
import os
import shutil
import subprocess
import sys
import zipfile

HERE = os.path.dirname(os.path.abspath(__file__))
BUILD = os.path.join(HERE, 'build')

# Speak & Spell US 1978 speech ROMs, in TMS6100 address order.
WANT = [
    ('tmc0351nl', '8b0f7586d2f12c3d4a885fdb528cf23feffa1a3b'),
    ('tmc0352nl', 'ddaa484be1bba5fef46b481cafae517e4acaa8ed'),
]
# Chrysler Electronic Voice Alert speech ROMs, eva11 then eva24.
WANT_EVA = [
    ('cm73002', '81195e8f870275d39a1abe1c8e2a6afdfdb15725'),
    ('cm63002', 'df7323eebcd2a8a5401c2e0addbbabb700182302'),
]
ROM_SIZES = (0x1000, 0x4000)


def scan_zip(path, found):
    with zipfile.ZipFile(path) as z:
        for info in z.infolist():
            if info.file_size in ROM_SIZES:
                take(z.read(info), found)


def take(data, found):
    if len(data) in ROM_SIZES:
        found.setdefault(hashlib.sha1(data).hexdigest(), data)


def scan(path, found):
    if os.path.isdir(path):
        for root, _, files in os.walk(path):
            for f in files:
                scan(os.path.join(root, f), found)
    elif zipfile.is_zipfile(path):
        scan_zip(path, found)
    elif os.path.getsize(path) in ROM_SIZES:
        take(open(path, 'rb').read(), found)


def run(cmd):
    if subprocess.run(cmd).returncode != 0:
        sys.exit('build: failed: ' + ' '.join(cmd))


def missing(want, found):
    return [name for name, sha in want if sha not in found]


def extract(want, found):
    os.makedirs(BUILD, exist_ok=True)
    paths = []
    for name, sha in want:
        p = os.path.join(BUILD, name + '.vsm')
        open(p, 'wb').write(found[sha])
        paths.append(p)
    return paths


def main():
    if len(sys.argv) < 2:
        sys.exit(__doc__)
    if not (os.environ.get('ACME') or shutil.which('acme')):
        sys.exit('build: ACME not found. Put acme on the PATH or set ACME to its path')
    found = {}
    for p in sys.argv[1:]:
        if not os.path.exists(p):
            sys.exit('build: no such file or folder: ' + p)
        scan(p, found)
    spell, eva = missing(WANT, found), missing(WANT_EVA, found)
    if spell and eva:
        sys.exit('build: not found, or not a good dump: %s\nNeeded SHA1:\n%s'
                 % (', '.join(spell + eva),
                    '\n'.join('  %s %s' % w for w in WANT + WANT_EVA)))

    if spell:
        print('build: skipping spell.dsk, not found: ' + ', '.join(spell))
    else:
        roms = extract(WANT, found)
        card = os.path.join(BUILD, 'snspellua.bin')
        cardtxt = os.path.join(BUILD, 'snspellua.txt')
        run([sys.executable, os.path.join(HERE, 'speech', 'mkcard.py')]
            + roms + [card, cardtxt])
        run([sys.executable, os.path.join(HERE, 'spellgame', 'build.py'),
             card, cardtxt, os.path.join(BUILD, 'spell.dsk')])
        print('Wrote ' + os.path.join(BUILD, 'spell.dsk'))

    if eva:
        print('build: skipping chrysler.dsk, not found: ' + ', '.join(eva))
    else:
        roms = extract(WANT_EVA, found)
        run([sys.executable, os.path.join(HERE, 'chrysler', 'build.py')]
            + roms + [os.path.join(BUILD, 'chrysler.dsk')])
        print('Wrote ' + os.path.join(BUILD, 'chrysler.dsk'))


if __name__ == '__main__':
    main()

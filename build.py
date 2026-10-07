#!/usr/bin/env python3
"""Build spell.dsk from the Speak & Spell speech ROMs.

Usage: python build.py ROMS [ROMS ...]

Each ROMS is a MAME snspellua zip, a folder, or a ROM file. The two speech
ROMs are found by SHA1, whatever they are named, also inside zips found in
a folder. Writes build/snspellua.bin, the card image, and build/spell.dsk.
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
ROM_SIZE = 0x4000


def scan_zip(path, found):
    with zipfile.ZipFile(path) as z:
        for info in z.infolist():
            if info.file_size == ROM_SIZE:
                take(z.read(info), found)


def take(data, found):
    if len(data) == ROM_SIZE:
        found.setdefault(hashlib.sha1(data).hexdigest(), data)


def scan(path, found):
    if os.path.isdir(path):
        for root, _, files in os.walk(path):
            for f in files:
                scan(os.path.join(root, f), found)
    elif zipfile.is_zipfile(path):
        scan_zip(path, found)
    elif os.path.getsize(path) == ROM_SIZE:
        take(open(path, 'rb').read(), found)


def run(cmd):
    if subprocess.run(cmd).returncode != 0:
        sys.exit('build: failed: ' + ' '.join(cmd))


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
    missing = [name for name, sha in WANT if sha not in found]
    if missing:
        sys.exit('build: not found, or not a good dump: %s\nNeeded SHA1:\n%s'
                 % (', '.join(missing),
                    '\n'.join('  %s %s' % w for w in WANT)))

    os.makedirs(BUILD, exist_ok=True)
    roms = []
    for name, sha in WANT:
        p = os.path.join(BUILD, name + '.vsm')
        open(p, 'wb').write(found[sha])
        roms.append(p)
    card = os.path.join(BUILD, 'snspellua.bin')
    cardtxt = os.path.join(BUILD, 'snspellua.txt')
    run([sys.executable, os.path.join(HERE, 'speech', 'mkcard.py')]
        + roms + [card, cardtxt])
    run([sys.executable, os.path.join(HERE, 'spellgame', 'build.py'),
         card, cardtxt, os.path.join(BUILD, 'spell.dsk')])
    print('Wrote ' + os.path.join(BUILD, 'spell.dsk'))


if __name__ == '__main__':
    main()

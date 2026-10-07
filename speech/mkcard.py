#!/usr/bin/env python3
"""Build the 64 KiB Ufonic card image from the Speak & Spell speech ROMs.

Finds every phrase in the two TMS6100 ROMs, requantizes it from the
TMC0281 tables to the TMS5220 tables, packs it clear of the ROM restart,
and lays the phrases out the way the card ROM expects. Also writes a
phrase table with each index, card address and source range.

Usage: python mkcard.py tmc0351nl.vsm tmc0352nl.vsm card.bin card.txt
"""
import sys

import lpcchip as L
import transcode
import ufonicfeed
import vsm

CARD = 0x10000
TABLE = 0x0082
QUEUE_FILL = 0x81


def card_image(blobs):
    """Return (image, addresses) for the packed phrases."""
    img = bytearray(CARD)
    for a in range(0x0002, 0x0080, 2):
        img[a] = QUEUE_FILL
    addr = TABLE + 2 * len(blobs)
    addrs = []
    for i, blob in enumerate(blobs):
        if addr + len(blob) > CARD:
            sys.exit('mkcard: phrases do not fit in 64 KiB')
        img[TABLE + 2 * i] = addr & 0xFF
        img[TABLE + 2 * i + 1] = addr >> 8
        img[addr:addr + len(blob)] = blob
        addrs.append(addr)
        addr += len(blob)
    return bytes(img), addrs


def main():
    if len(sys.argv) != 5:
        sys.exit(__doc__)
    src = L.CHIPS['tmc0281']
    dst = L.CHIPS['tms5220']
    data = open(sys.argv[1], 'rb').read() + open(sys.argv[2], 'rb').read()
    phrases = vsm.find(data, src, 0)
    blobs = []
    for s, e, fr in phrases:
        f2 = transcode.frames(fr, src)
        blob, f2 = ufonicfeed.safe_pack(f2, dst)
        back = L.parse(blob, dst, 0)
        if not back or back[0] != f2:
            sys.exit('mkcard: phrase at $%04X does not parse back' % s)
        blobs.append(blob)
    img, addrs = card_image(blobs)
    open(sys.argv[3], 'wb').write(img)
    with open(sys.argv[4], 'w', newline='\n') as t:
        t.write('snspellua, Speak & Spell US 1978, button keys, chip tmc0281, VSM base $0000\n')
        t.write('Index Card Bytes Frames Source\n')
        for i, ((s, e, fr), a) in enumerate(zip(phrases, addrs)):
            t.write('%5d $%04X %5d %6d $%04X-$%04X\n'
                    % (i + 1, a, len(blobs[i]), len(fr), s, e - 1))
    print('mkcard: %d phrases, wrote %s' % (len(phrases), sys.argv[3]))


if __name__ == '__main__':
    main()

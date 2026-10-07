"""Pack TMS5220 phrases so the Ufonic ROM stops cleanly after each one.

The ROM primes the FIFO with 9 bytes, then writes 8 more each time BL
interrupts while TS is up, reading on past the phrase end. If reading the
stop frame completes the byte that drops the FIFO to 8, BL fires while TS
is still up through the energy ramp. The ROM writes 8 more, the rising count
turns SPEN back on, and the chip speaks whatever follows the stop frame.

safe_pack moves the stop frame with silence frames until it no longer lands
there. It also fills the rest of the stop byte with ones and adds a $FF
byte, as the Ufonic's own speech data does, so a restart reads another stop.

Usage: python ufonicfeed.py card.bin card.txt
Exits 1 when any phrase in the card would restart.
"""
import re
import sys

import lpcchip as L

SILENCE = {'e': 0}


def stop_bit(frames, chip):
    """Bit offset of the stop frame from the phrase start."""
    n = 0
    for f in frames:
        if f['e'] == 15:
            return n
        n += 4
        if f['e'] == 0:
            continue
        n += 1 + chip['pitch_bits']
        if not f['r']:
            n += sum(chip['kbits'][:len(f['k'])])
    raise ValueError('no stop frame')


def restarts(sbit):
    """True when the stop frame read completes the byte that sets BL."""
    written, bl, byte = 9, False, 0
    while True:
        end = (byte + 1) * 8
        if end > sbit + 4:
            return False
        count = written - (byte + 1)
        hit = count <= 8 and not bl
        if hit and end > sbit:
            return True
        if hit:
            written += 8
            count += 8
        bl = count <= 8
        byte += 1


def safe_pack(frames, chip):
    """Pack frames, moving the stop frame clear of a ROM restart."""
    frames = list(frames)
    while restarts(stop_bit(frames, chip)):
        frames.insert(len(frames) - 1, SILENCE)
    blob = bytearray(L.pack(frames, chip))
    used = (stop_bit(frames, chip) + 4) % 8
    if used:
        blob[-1] |= (0xFF << used) & 0xFF
    return bytes(blob) + bytes([0xFF]), frames


def main():
    chip = L.CHIPS['tms5220']
    data = open(sys.argv[1], 'rb').read()
    bad = []
    for ln in open(sys.argv[2]):
        m = re.match(r'\s+(\d+) \$([0-9A-F]+)', ln)
        if m:
            frames, _ = L.parse(data, chip, int(m.group(2), 16))
            if restarts(stop_bit(frames, chip)):
                bad.append(m.group(1))
    print('restart after stop: %s' % (' '.join(bad) or 'none'))
    sys.exit(1 if bad else 0)


if __name__ == '__main__':
    main()

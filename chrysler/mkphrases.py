#!/usr/bin/env python3
"""Build the card image from the two Electronic Voice Alert speech ROMs and
write phrases.inc.

Finds every phrase in both TMS6100 ROMs, requantizes the kept ones from the
TMS5110A tables to the TMS5220 tables, and packs them into one image the way
the card ROM expects.

Usage: python mkphrases.py cm73002.vsm cm63002.vsm card.bin card.txt
cm73002 is the eva11 speech ROM, cm63002 the eva24 one.
"""
import math
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, '..', 'speech'))
import lpcchip as L  # noqa: E402
import transcode  # noqa: E402
import ufonicfeed  # noqa: E402
import vsm  # noqa: E402

# Phrases per set, as the ROM scan finds them.
SETS = {'eva11': 15, 'eva24': 30}

# Card phrases in card index order, 1 up. Name, set, index in that set.
PHRASES = [
    ('AJAR', 'eva11', 4),
    ('KEYS83', 'eva11', 1),
    ('FUEL', 'eva11', 6),
    ('OILPR', 'eva11', 7),
    ('WASHER', 'eva11', 8),
    ('ELEC', 'eva11', 11),
    ('YOUR', 'eva11', 14),
    ('ISLOW', 'eva11', 15),
    ('RRDOOR', 'eva24', 1),
    ('LRDOOR', 'eva24', 2),
    ('PSDOOR', 'eva24', 3),
    ('DRDOOR', 'eva24', 4),
    ('TRUNK', 'eva24', 5),
    ('HATCH', 'eva24', 6),
    ('OILCRIT', 'eva24', 7),
    ('OVERHEAT', 'eva24', 8),
    ('COOLANT', 'eva24', 9),
    ('FUELLVL', 'eva24', 10),
    ('TRANS', 'eva24', 11),
    ('CHARGING', 'eva24', 12),
    ('BRFLUID', 'eva24', 13),
    ('PADS', 'eva24', 14),
    ('WASHLOW', 'eva24', 15),
    ('RWASHLOW', 'eva24', 16),
    ('OILLVL', 'eva24', 17),
    ('HEADCHK', 'eva24', 18),
    ('BRLAMPS', 'eva24', 19),
    ('TAILS', 'eva24', 20),
    ('PARKBRK', 'eva24', 21),
    ('KEYSIGN', 'eva24', 22),
    ('HEADON', 'eva24', 23),
    ('TEMP', 'eva24', 24),
    ('ALLOK', 'eva24', 25),
    ('BELT', 'eva24', 26),
    ('THANKS', 'eva24', 27),
    ('DING', 'eva24', 28),
]

# Phrases whose leading frame bytes are replaced by another's, as (phrase,
# donor, bytes). PSDOOR's first frame, a quiet voiced frame ahead of half a
# second of silence, plays as a robotic buzz on the card. DRDOOR's leading
# frame is the same length in bits and plays clean.
PATCHES = [('PSDOOR', 'DRDOOR', 6)]

# What one key press says: phrases in order, then the caption, all caps.
ACTIONS = {
    'DR_OPEN': (['AJAR', 'DRDOOR'], 'A DOOR IS AJAR. PLEASE CLOSE YOUR DRIVER DOOR.'),
    'PS_OPEN': (['AJAR', 'PSDOOR'], 'A DOOR IS AJAR. PLEASE CLOSE YOUR PASSENGER DOOR.'),
    'LR_OPEN': (['AJAR', 'LRDOOR'], 'A DOOR IS AJAR. PLEASE CLOSE YOUR LEFT REAR DOOR.'),
    'RR_OPEN': (['AJAR', 'RRDOOR'], 'A DOOR IS AJAR. PLEASE CLOSE YOUR RIGHT REAR DOOR.'),
    'TRUNK': (['TRUNK'], 'PLEASE CLOSE YOUR TRUNK LID.'),
    'HATCH': (['HATCH'], 'PLEASE CLOSE YOUR REAR HATCH.'),
    'THANKS': (['THANKS'], 'THANK YOU.'),
    'DING': (['DING'], '(DING)'),
    'PARKBRK': (['PARKBRK'], 'YOUR PARKING BRAKE IS ON.'),
    'HEADON': (['HEADON'], 'YOUR HEADLAMPS ARE ON.'),
    'HEADCHK': (['HEADCHK'], 'PLEASE CHECK YOUR HEADLAMPS.'),
    'TAILS': (['TAILS'], 'PLEASE CHECK YOUR TAIL LAMPS.'),
    'BRLAMPS': (['BRLAMPS'], 'PLEASE CHECK YOUR BRAKE LAMPS.'),
    'BELT': (['BELT'], 'PLEASE FASTEN YOUR SEATBELT.'),
    'KEYSIGN': (['KEYSIGN'], 'YOUR KEYS ARE IN THE IGNITION.'),
    'KEYS83': (['KEYS83'], "DON'T FORGET YOUR KEYS."),
    'OILLVL': (['OILLVL'], 'PLEASE CHECK YOUR ENGINE OIL LEVEL.'),
    'OILLOW': (['YOUR', 'OILPR', 'ISLOW'], 'YOUR ENGINE OIL PRESSURE IS LOW.'),
    'OILCRIT': (['DING', 'OILCRIT'],
                'YOUR ENGINE OIL PRESSURE IS CRITICAL. ENGINE DAMAGE MAY OCCUR.'),
    'FUELLVL': (['FUELLVL'], 'PLEASE CHECK YOUR FUEL LEVEL.'),
    'FUELLOW': (['YOUR', 'FUEL', 'ISLOW'], 'YOUR FUEL IS LOW.'),
    'COOLANT': (['COOLANT'], 'PLEASE CHECK YOUR ENGINE COOLANT LEVEL.'),
    'TEMP': (['TEMP'], 'YOUR ENGINE TEMPERATURE IS ABOVE NORMAL.'),
    'OVERHEAT': (['OVERHEAT'],
                 'YOUR ENGINE IS OVERHEATING. PROMPT SERVICE IS REQUIRED.'),
    'CHARGING': (['CHARGING'],
                 'YOUR CHARGING SYSTEM IS MALFUNCTIONING. PROMPT SERVICE IS REQUIRED.'),
    'ELEC': (['ELEC'], 'ELECTRICAL SYSTEM IS MALFUNCTIONING.'),
    'WASHLOW': (['WASHLOW'], 'YOUR WASHER FLUID IS LOW.'),
    'RWASHLOW': (['RWASHLOW'], 'YOUR REAR WASHER FLUID IS LOW.'),
    'WASHLOW83': (['YOUR', 'WASHER', 'ISLOW'], 'YOUR WASHER FLUID IS LOW.'),
    'TRANS': (['TRANS'], 'PLEASE CHECK YOUR TRANSMISSION FLUID LEVEL.'),
    'BRFLUID': (['BRFLUID'], 'PLEASE CHECK YOUR BRAKE FLUID LEVEL.'),
    'PADS': (['PADS'], 'PLEASE CHECK YOUR DISC BRAKE PADS.'),
    'ALLOK': (['ALLOK'], 'ALL MONITORED SYSTEMS ARE FUNCTIONING.'),
}

# Key, then the actions it steps through on each press.
KEYS = [
    ('1', ['DR_OPEN', 'THANKS']),
    ('2', ['PS_OPEN', 'THANKS']),
    ('3', ['LR_OPEN', 'THANKS']),
    ('4', ['RR_OPEN', 'THANKS']),
    ('A', ['ALLOK']),
    ('B', ['PARKBRK']),
    ('C', ['COOLANT', 'TEMP', 'OVERHEAT']),
    ('D', ['PADS']),
    ('E', ['BRLAMPS']),
    ('F', ['FUELLVL', 'FUELLOW']),
    ('G', ['CHARGING', 'ELEC']),
    ('H', ['DING', 'DING']),
    ('K', ['KEYSIGN', 'KEYS83']),
    ('L', ['HEADON', 'HEADCHK']),
    ('O', ['OILLVL', 'OILLOW', 'OILCRIT']),
    ('P', ['TRANS']),
    ('R', ['TAILS']),
    ('S', ['BELT', 'THANKS']),
    ('T', ['TRUNK', 'THANKS']),
    ('U', ['BRFLUID']),
    ('W', ['WASHLOW', 'RWASHLOW', 'WASHLOW83']),
]

TABLE = 0x80                # Pointer for card index N sits at TABLE + 2N
FRAME_MS = 25


def fail(msg):
    sys.exit('mkphrases: ' + msg)


def convert(path, name):
    """Return (blob, source frame count) per phrase of one speech ROM."""
    src = L.CHIPS['tms5110a']
    dst = L.CHIPS['tms5220']
    phrases = vsm.find(open(path, 'rb').read(), src, 0)
    if len(phrases) != SETS[name]:
        fail('%s: found %d phrases, expected %d'
             % (path, len(phrases), SETS[name]))
    out = []
    for s, e, fr in phrases:
        f2 = transcode.frames(fr, src)
        blob, f2 = ufonicfeed.safe_pack(f2, dst)
        back = L.parse(blob, dst, 0)
        if not back or back[0] != f2:
            fail('%s phrase at $%04X does not parse back' % (name, s))
        out.append((blob, len(fr)))
    return out


def wrap(cap):
    """Rows the caption takes, wrapped as CAPTION in chrysler.asm does."""
    rows = ['']
    for w in cap.split(' '):
        line = rows[-1]
        if line and len(line) + 1 + len(w) > 40:
            rows.append(w)
        elif len(line) + len(w) > 40:
            rows.append(w)
        else:
            rows[-1] = line + ' ' + w if line else w
    return rows


def asm_text(s):
    return '"' + s.replace('"', "'") + '"'


def main():
    if len(sys.argv) != 5:
        sys.exit(__doc__)
    sets = {'eva11': convert(sys.argv[1], 'eva11'),
            'eva24': convert(sys.argv[2], 'eva24')}

    n = len(PHRASES)
    image = bytearray(65536)
    for i in range(2, TABLE, 2):        # Idle queue filler, as the card keeps it
        image[i] = 0x81
    at = TABLE + 2 * (n + 1)
    index = {}
    frames = {}
    txt = ['chrysler, eva11 and eva24 merged, chip tms5220, VSM base $0000',
           'Index Card Bytes Frames Source']
    for k, (pname, sname, si) in enumerate(PHRASES, 1):
        blob, nfr = sets[sname][si - 1]
        image[at:at + len(blob)] = blob
        image[TABLE + 2 * k] = at & 0xFF
        image[TABLE + 2 * k + 1] = at >> 8
        txt.append('%5d $%04X %5d %6d %s %d' % (k, at, len(blob), nfr, sname, si))
        index[pname] = k
        frames[pname] = nfr
        at += len(blob)
    start = {p: image[TABLE + 2 * k] | (image[TABLE + 2 * k + 1] << 8)
             for p, k in index.items()}
    for pname, donor, nb in PATCHES:
        image[start[pname]:start[pname] + nb] = image[start[donor]:start[donor] + nb]
    used = at
    ntracks = math.ceil(used / 4096)
    cardsum = sum(image[:ntracks * 4096]) & 0xFFFF

    for a, (phr, cap) in ACTIONS.items():
        if len(wrap(cap)) > 2:
            fail('caption for %s needs more than 2 rows' % a)
        for p in phr:
            if p not in index:
                fail('action %s names unknown phrase %s' % (a, p))
    for key, acts in KEYS:
        for a in acts:
            if a not in ACTIONS:
                fail('key %r names unknown action %s' % (key, a))
    if len(set(k for k, _ in KEYS)) != len(KEYS):
        fail('a key is listed twice')

    open(sys.argv[3], 'wb').write(image)
    open(sys.argv[4], 'w', newline='\n').write('\n'.join(txt) + '\n')

    names = list(ACTIONS)
    o = ['; Generated by mkphrases.py. Do not edit.', '']
    o.append('CARDSUM = $%04X' % cardsum)
    o.append('NTRACKS = %d' % ntracks)
    o.append('NKEYS   = %d' % len(KEYS))
    o.append('NACTS   = %d' % len(names))
    o.append('')
    for pname, _, _ in PHRASES:
        o.append('PH_%s = %d' % (pname, index[pname]))
    o.append('')
    for i, a in enumerate(names):
        o.append('A_%s = %d' % (a, i))
    o.append('')
    o.append('; KEYS: ASCII with bit 7 set, the number of actions, the first slot in')
    o.append('; KACTS.')
    o.append('keychr  !byte ' + ', '.join('$%02X' % (ord(k) | 0x80) for k, _ in KEYS))
    o.append('keycnt  !byte ' + ', '.join(str(len(a)) for _, a in KEYS))
    first, slots = [], []
    for _, acts in KEYS:
        first.append(len(slots))
        slots.extend(acts)
    o.append('keyfst  !byte ' + ', '.join(str(f) for f in first))
    o.append('kacts   !byte ' + ', '.join('A_' + a for a in slots))
    o.append('')
    o.append('; ACTIONS: queue length, offset into ACTQ, caption, no card time in 50 ms.')
    q, qoff = [], []
    for a in names:
        qoff.append(len(q))
        q.extend(ACTIONS[a][0])
    o.append('actn    !byte ' + ', '.join(str(len(ACTIONS[a][0])) for a in names))
    o.append('actoff  !byte ' + ', '.join(str(x) for x in qoff))
    durs = []
    for a in names:
        ms = sum(frames[p] for p in ACTIONS[a][0]) * FRAME_MS
        durs.append(min(255, max(1, (ms + 49) // 50)))
    o.append('actdur  !byte ' + ', '.join(str(d) for d in durs))
    o.append('actclo  !byte ' + ', '.join('<cap_' + a for a in names))
    o.append('actchi  !byte ' + ', '.join('>cap_' + a for a in names))
    o.append('actq    !byte ' + ', '.join('PH_' + p for p in q))
    o.append('')
    for a in names:
        o.append('cap_%s !text %s, 0' % (a, asm_text(ACTIONS[a][1])))
    open(os.path.join(HERE, 'phrases.inc'), 'w', newline='\n').write('\n'.join(o) + '\n')
    print('%d phrases, image ends at $%04X, %d tracks, CARDSUM $%04X'
          % (n, used - 1, ntracks, cardsum))


if __name__ == '__main__':
    main()

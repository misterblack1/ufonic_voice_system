#!/usr/bin/env python3
"""Write art.inc from art/car.json: polyline runs per item, hide, restore
and label lists, the key effects, the title and the text font.

Items are the base groups, then the overlays. A run is a point count, then
that many points of X low, X high, Y. An item ends with a count of 0.
"""
import json
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import mkphrases  # noqa: E402

OUT = os.path.join(HERE, 'art.inc')
FONT = os.path.join(HERE, '..', 'spellgame', 'font.inc')

# Effect ops. TOG flips an overlay, ON shows one and blinks it for the speech,
# FLASH blinks an item if it shows, INV inverts the page once. All the
# items of one press blink together.
OPS = {'TOG': 1, 'ON': 2, 'FLASH': 3, 'INV': 4}

# Overlays that show at the start.
START = ['HOOD', 'TRUNK LID']


def bay(part):
    """An engine bay part, or the hood when the hood hides it."""
    return [('FLASH', part), ('FLASH', 'HOOD')]


# Per key, the effects of each press in turn.
EFFECTS = {
    '1': [[('TOG', 'DOOR 1')]] * 2,
    '2': [[('TOG', 'DOOR 2')]] * 2,
    '3': [[('TOG', 'DOOR 3')]] * 2,
    '4': [[('TOG', 'DOOR 4')]] * 2,
    'A': [[('INV', None)]],
    'B': [[('ON', 'PARK BRAKE')]],
    'C': [[('FLASH', 'T_COOLANT')] + bay('T_RADIATOR'), bay('T_RADIATOR'),
          bay('T_RADIATOR')],
    'D': [[('ON', 'DISC PADS')]],
    'E': [[('ON', 'BRAKE LAMPS')]],
    'F': [[('FLASH', 'T_TANK')]] * 2,
    'G': [bay('T_BATTERY')] * 2,
    'H': [[('TOG', 'HOOD'), ('TOG', 'HOOD UP')]] * 2,
    'K': [[('ON', 'KEY')]] * 2,
    'L': [[('ON', 'HEADLAMPS')]] * 2,
    'O': [bay('T_ENGINE')] * 3,
    'P': [bay('T_TRANS')],
    'R': [[('ON', 'TAIL LAMPS')]],
    'S': [[('TOG', 'BELT OFF'), ('FLASH', 'BELT OFF')],
          [('TOG', 'BELT OFF'), ('ON', 'BELT ON')]],
    'T': [[('TOG', 'TRUNK LID'), ('TOG', 'TRUNK OPEN')]] * 2,
    'U': [bay('T_BOOSTER')],
    'W': [bay('T_WASHER')] * 3,
}


class Pixels(set):
    def __setitem__(self, k, v):
        self.add(k)


def segments(item):
    return [tuple(a + b) for r in item['runs'] for a, b in zip(r, r[1:])]


def line(px, x0, y0, x1, y1):
    """Bresenham, both ends included. hgrline.asm lights the same pixels."""
    dx, dy = abs(x1 - x0), -abs(y1 - y0)
    sx, sy = (1 if x0 < x1 else -1), (1 if y0 < y1 else -1)
    err = dx + dy
    while True:
        px[x0, y0] = 255
        if (x0, y0) == (x1, y1):
            return
        e2 = 2 * err
        if e2 >= dy:
            err += dy
            x0 += sx
        if e2 <= dx:
            err += dx
            y0 += sy


def text_font():
    """The tfont table of SPELL's font.inc, 64 glyphs by 8 rows."""
    lines = open(FONT).read().split('\n')
    at = lines.index('tfont') + 1
    out = []
    while lines[at].strip().startswith('!byte'):
        out += [int(v.strip()[1:], 16) for v in lines[at].split('!byte')[1].split(',')]
        at += 1
    assert len(out) == 64 * 8, len(out)
    return out


def seg_pixels(sg):
    p = Pixels()
    line(p, *sg)
    return p


def box(lab):
    x, y = lab['x'], lab['y']
    return {(x + c, y + r) for r in range(-2, 10) for c in range(-2, 9)}


def slots():
    """Effects per key slot in KACTS order."""
    keys = [k for k, _ in mkphrases.KEYS]
    acts = dict(mkphrases.KEYS)
    assert sorted(EFFECTS) == sorted(keys), sorted(set(EFFECTS) ^ set(keys))
    out = []
    for k in keys:
        assert len(EFFECTS[k]) == len(acts[k]), k
        out += EFFECTS[k]
    return out


def ident(name):
    return re.sub(r'[^A-Z0-9]', '_', name.upper())


def table(name, data, per=16):
    lines = [name]
    for i in range(0, len(data), per):
        lines.append('        !byte ' + ','.join('$%02X' % v for v in data[i:i + per]))
    return lines


def runs_data(label, runs):
    out = [label]
    for r in runs:
        assert 2 <= len(r) < 256, (label, len(r))
        pts = ','.join('$%02X,%d,%d' % (x & 0xFF, x >> 8, y) for x, y in r)
        out.append('        !byte %d,%s' % (len(r), pts))
    out.append('        !byte 0')
    return out


def ptrs(o, name, labels):
    o.append('%-7s !byte %s' % (name + 'lo', ','.join('<' + n for n in labels)))
    o.append('%-7s !byte %s' % (name + 'hi', ','.join('>' + n for n in labels)))


def main():
    doc = json.load(open(os.path.join(HERE, 'art', 'car.json')))
    gh = doc['art_height']
    items = doc['base'] + doc['overlays']
    for g in items:
        for r in g['runs']:
            for x, y in r:
                assert 0 <= x < 280 and 0 <= y < gh, (g['name'], x, y)
    inum = {g['name']: i for i, g in enumerate(items)}
    ngrp = len(doc['base'])
    nitem = len(items)
    for lab in doc['labels']:
        assert lab['x'] % 7 == 0 and 7 <= lab['x'] <= 266, lab
        assert 2 <= lab['y'] <= 190 - 9, lab
    # Labels draw over the art, so label boxes must not overlap. Art and
    # boxes stay clear of the text rows.
    pix = [set().union(*[seg_pixels(sg) for sg in segments(g)]) for g in items]
    boxes = [box(lab) for lab in doc['labels']]
    for i, a in enumerate(boxes):
        assert all(8 <= y < 176 for _, y in a), doc['labels'][i]
        for b in boxes[:i]:
            assert not a & b, ('label boxes overlap', doc['labels'][i])
    for g, p in zip(items, pix):
        assert all(8 <= y < 176 for _, y in p), g['name']

    sl = slots()
    erased = set()
    for press in sl:
        for op, name in press:
            if name:
                assert op == 'FLASH' or inum[name] >= ngrp, (op, name)
                erased.add(inum[name])
    for v in doc['overlays']:
        erased.update(inum[h] for h in v['hides'])
        erased.add(inum[v['name']])

    o = ['; Generated by mkart.py from art/car.json. Do not edit.', '']
    o.append('NGRP    = %d' % ngrp)
    o.append('NITEM   = %d' % nitem)
    o.append('NLAB    = %d' % len(doc['labels']))
    o.append('NBLINK  = %d' % max(len(p) for p in sl))
    for op, n in OPS.items():
        o.append('OP_%s = %d' % (op, n))
    for i, g in enumerate(items):
        o.append('I_%s = %d' % (ident(g['name']), i))
    o.append('')
    ptrs(o, 'it', ['g%d' % i for i in range(nitem)])
    hid0 = [0 if i < ngrp else 1 for i in range(nitem)]
    for name in START:
        hid0[inum[name]] = 0
        for h in items[inum[name]]['hides']:
            hid0[inum[h]] += 1
    o.append('; Hidden count per item at the start.')
    o.append('ihid0   !byte ' + ','.join(str(h) for h in hid0))

    # Hide lists: item numbers, $FF ends each.
    ptrs(o, 'ih', ['h%d' % i if i >= ngrp else 'none' for i in range(nitem)])
    o.append('none    !byte $FF')
    for i, v in enumerate(doc['overlays']):
        o.append('h%-6d !byte %s' % (ngrp + i, ','.join(
            [str(inum[h]) for h in v['hides']] + ['$FF'])))

    # Restore lists: each segment of another item that shares a pixel, as the
    # owner then X0 low, X0 high, Y0, X1 low, X1 high, Y1, $FF ends each.
    # Label lists: every label box the item or its restore segments touch.
    ptrs(o, 'ir', ['r%d' % i if i in erased else 'none' for i in range(nitem)])
    ptrs(o, 'il', ['l%d' % i for i in range(nitem)])
    rbytes = 0
    for i in range(nitem):
        touch = set(pix[i])
        if i in erased:
            rs = [(j, sg) for j, g in enumerate(items) if j != i
                  for sg in segments(g) if seg_pixels(sg) & pix[i]]
            o.append('r%d' % i)
            for j, (x0, y0, x1, y1) in rs:
                o.append('        !byte %d,$%02X,%d,%d,$%02X,%d,%d'
                         % (j, x0 & 0xFF, x0 >> 8, y0, x1 & 0xFF, x1 >> 8, y1))
                touch |= seg_pixels((x0, y0, x1, y1))
            o.append('        !byte $FF')
            rbytes += 7 * len(rs) + 1
        labs = [n for n, b in enumerate(boxes) if b & touch]
        o.append('l%-6d !byte %s' % (i, ','.join([str(n) for n in labs] + ['$FF'])))

    # Effects per key slot: op and item pairs, 0 ends each.
    ptrs(o, 'ef', ['e%d' % i for i in range(len(sl))])
    for i, press in enumerate(sl):
        o.append('e%-6d !byte %s' % (i, ','.join(
            ['%d,%d' % (OPS[op], inum[name] if name else 0) for op, name in press]
            + ['0'])))
    o.append('')

    o.append('labkey  !byte ' + ','.join(
        '$%02X' % (ord(lab['key']) | 0x80) for lab in doc['labels']))
    o.append('labcol  !byte ' + ','.join(
        str(lab['x'] // 7) for lab in doc['labels']))
    o.append('laby    !byte ' + ','.join(str(lab['y']) for lab in doc['labels']))
    title = doc['title']
    assert len(title) <= 40
    o.append('TITCOL  = %d' % ((40 - len(title)) // 2))
    o.append('title   !text "%s", 0' % title)
    o.append('')
    for i, g in enumerate(items):
        o += runs_data('g%d' % i, g['runs'])
    o.append('')
    o += table('tfont', text_font())
    open(OUT, 'w', newline='\n').write('\n'.join(o) + '\n')
    npts = sum(len(r) for g in items for r in g['runs'])
    print('art.inc: %d groups, %d overlays, %d labels, %d points, %d restore bytes'
          % (ngrp, nitem - ngrp, len(doc['labels']), npts, rbytes))


if __name__ == '__main__':
    main()

"""Requantize TMS5100 family frames to TMS5220 frames.

Each index is decoded with the source chip's table, then matched to the
nearest TMS5220 table entry. Reflection coefficients are matched on the
log area ratio scale, pitch on period, energy on amplitude. Frame structure,
repeat flags, unvoiced frames and the stop frame carry over unchanged.
The excitation chirp differs between the families and cannot be carried.
"""
import math

import lpcchip as L

DST = L.CHIPS['tms5220']


def _nearest(value, table, lo=0, hi=None, key=lambda v: v):
    hi = len(table) - 1 if hi is None else hi
    kv = key(value)
    return min(range(lo, hi + 1), key=lambda i: abs(key(table[i]) - kv))


def _lar(k):
    k = max(-511, min(511, k)) / 512.0
    return math.log((1 + k) / (1 - k))


def frame(f, src, dst=DST):
    e = f['e']
    if e in (0, 15):
        return {'e': e}
    ne = _nearest(src['energy'][e], dst['energy'], 1, 14)
    if f['p'] == 0:
        np = 0
    else:
        np = _nearest(src['pitch'][f['p']], dst['pitch'], 1)
    out = {'e': ne, 'r': f['r'], 'p': np, 'k': None}
    if not f['r']:
        out['k'] = [_nearest(src['k'][i][kv], dst['k'][i], key=_lar)
                    for i, kv in enumerate(f['k'])]
    return out


def frames(fs, src, dst=DST):
    return [frame(f, src, dst) for f in fs]

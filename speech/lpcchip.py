"""TI LPC frame parsing and packing for the TMS5100 and TMS5220 families.

Coefficient tables are read straight from MAME's tms5110r.hxx in mame/,
so nothing is retyped by hand.
"""
import os
import re

HERE = os.path.dirname(os.path.abspath(__file__))
HXX = os.path.join(HERE, 'mame', 'tms5110r.hxx')


def _macros(path=HXX):
    """Return {macro name: list of ints} for every table #define."""
    text = open(path).read()
    text = re.sub(r'/\*.*?\*/', '', text, flags=re.S)
    text = re.sub(r'//[^\n]*', '', text)
    out = {}
    for m in re.finditer(r'#define\s+(TI_\w+)\s*\\\n((?:.*\\\n)*.*)', text):
        body = m.group(2).replace('\\\n', ' ')
        groups = re.findall(r'\{([^{}]*)\}', body)
        rows = [[int(v, 0) for v in g.replace(',', ' ').split()] for g in groups]
        out[m.group(1)] = rows
    return out


_M = _macros()


def _chip(name, energy, pitch, lpc, chirp, pitch_bits, uv_silence_inhibit):
    chirp_t = [c - 256 if c > 127 else c for c in _M[chirp][0]]
    return {
        'name': name,
        'energy': _M[energy][0],
        'pitch': _M[pitch][0],
        'k': _M[lpc],
        'chirp': chirp_t,
        'interp': _M['TI_INTERP'][0],
        'pitch_bits': pitch_bits,
        'kbits': [5, 5, 4, 4, 4, 4, 4, 3, 3, 3],
        'uv_silence_inhibit': uv_silence_inhibit,
    }


CHIPS = {
    'tmc0281': _chip('tmc0281', 'TI_0280_PATENT_ENERGY', 'TI_0280_2801_PATENT_PITCH',
                     'TI_0280_PATENT_LPC', 'TI_0280_PATENT_CHIRP', 5, False),
    'tmc0281d': _chip('tmc0281d', 'TI_028X_LATER_ENERGY', 'TI_0280_2801_PATENT_PITCH',
                      'TI_0280_PATENT_LPC', 'TI_0280_PATENT_CHIRP', 5, False),
    'cd2801': _chip('cd2801', 'TI_028X_LATER_ENERGY', 'TI_0280_2801_PATENT_PITCH',
                    'TI_2801_2501E_LPC', 'TI_2801_CHIRP', 5, False),
    'cd2802': _chip('cd2802', 'TI_028X_LATER_ENERGY', 'TI_2802_PITCH',
                    'TI_2802_LPC', 'TI_2802_CHIRP', 5, False),
    'tms5110a': _chip('tms5110a', 'TI_028X_LATER_ENERGY', 'TI_5110_PITCH',
                      'TI_5110_5220_LPC', 'TI_LATER_CHIRP', 5, False),
    'tms5220': _chip('tms5220', 'TI_028X_LATER_ENERGY', 'TI_5220_PITCH',
                     'TI_5110_5220_LPC', 'TI_LATER_CHIRP', 6, True),
}


# FRAME PARSING:
class Bits:
    """Bytes are consumed LSB first. Within a field the first bit is the MSB."""
    def __init__(self, data, pos=0):
        self.d, self.p = data, pos * 8

    def get(self, n):
        v = 0
        for _ in range(n):
            byte = self.p >> 3
            bit = (self.d[byte] >> (self.p & 7)) & 1 if byte < len(self.d) else 0
            v = (v << 1) | bit
            self.p += 1
        return v


def parse(data, chip, start=0, max_frames=2000):
    """Parse one phrase. Returns (frames, end_byte) or None if no stop frame.

    A frame is a dict of raw table indices: e, r, p, k (list or None).
    The stop frame is included as e=15.
    """
    b = Bits(data, start)
    frames = []
    while len(frames) < max_frames:
        if (b.p >> 3) >= len(data):
            return None
        e = b.get(4)
        if e == 15:
            frames.append({'e': 15})
            return frames, (b.p + 7) >> 3
        if e == 0:
            frames.append({'e': 0})
            continue
        r = b.get(1)
        p = b.get(chip['pitch_bits'])
        f = {'e': e, 'r': r, 'p': p, 'k': None}
        if not r:
            n = 10 if p else 4
            f['k'] = [b.get(chip['kbits'][i]) for i in range(n)]
        frames.append(f)
    return None


def pack(frames, chip):
    """Serialize frames back to bytes, LSB first, MSB first within a field."""
    bits = []

    def put(v, n):
        for i in range(n - 1, -1, -1):
            bits.append((v >> i) & 1)

    for f in frames:
        put(f['e'], 4)
        if f['e'] in (0, 15):
            continue
        put(f['r'], 1)
        put(f['p'], chip['pitch_bits'])
        if not f['r']:
            for i, kv in enumerate(f['k']):
                put(kv, chip['kbits'][i])
    out = bytearray((len(bits) + 7) // 8)
    for i, bit in enumerate(bits):
        out[i >> 3] |= bit << (i & 7)
    return bytes(out)

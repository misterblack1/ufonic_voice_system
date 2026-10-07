"""Find the phrases in a TMS6100 voice synthesis memory image.

A VSM mixes speech with pointer tables and word records. Nothing marks which
bytes are which, and table or record bytes often parse to a stop frame by
chance, so a start found that way plays as noise.

Three kinds of evidence are combined:
  Table starts: targets of 16-bit little-endian words that sit in an
    ascending run of three or more, which is how the pointer tables look.
  Records: a word that points 3 to 16 bytes ahead of itself, landing just
    after a 00 byte. The bytes between are letter codes and flags, never
    speech, and the target is where the record's speech begins.
  Record ends: module records end in 01 00 and the speech follows.
  Spelling lists: long runs of letter codes $00 to $19 are never speech.
  Smoothness: real speech has energy, pitch and K1 tracks that move
    gradually. Random bytes almost never do.
Every byte offset is parsed. A parse is a candidate when it is smooth, or
when it starts on a table or record target and ends exactly on the next one,
which admits tone effects that are not smooth. The phrase set is the
non-overlapping tiling of candidates with the most weighted bytes, where a
table or record start counts for more than an unmarked one.
"""
import bisect

import lpcchip as L

MIN_FRAMES = 5
MAX_FRAMES = 800
MAX_DE = 3.2
MAX_SILENCE = 0.2
MAX_DK1 = 7
MAX_DPITCH = 6
MAX_STEP = 0x1000
MAX_PAD = 4
STRONG_RUN = 5
LETTER_RUN = 16
RECORD_BACK = 24
MARKED_WEIGHT = 1.5
UNMARKED_WEIGHT = 0.7


def smooth(frames):
    """True when a parsed phrase looks like real speech."""
    fr = frames[:-1]
    if len(fr) < MIN_FRAMES:
        return False
    if fr[0]['e'] == 0 and fr[1]['e'] == 0:
        return False
    first = next((f for f in fr if f['e']), None)
    if first is None or first['r']:
        return False
    es = [f['e'] for f in fr]
    de = sum(abs(a - b) for a, b in zip(es, es[1:])) / (len(es) - 1)
    sil = sum(1 for e in es if e == 0) / len(es)
    voiced = [f for f in fr if f['e'] and f['p']]
    k1 = [f['k'][0] for f in voiced if not f['r']]
    dk = sum(abs(a - b) for a, b in zip(k1, k1[1:])) / max(1, len(k1) - 1)
    ps = [f['p'] for f in voiced]
    dp = sum(abs(a - b) for a, b in zip(ps, ps[1:])) / max(1, len(ps) - 1)
    return de <= MAX_DE and sil <= MAX_SILENCE and dk <= MAX_DK1 and dp <= MAX_DPITCH


def _words(data, base):
    """Return w where w[i] is the word at byte i as an offset into data, or -1."""
    size = len(data)
    w = [-1] * size
    for i in range(size - 1):
        a = (data[i] | (data[i + 1] << 8)) - base
        if 0 <= a < size:
            w[i] = a
    return w


def table_targets(w):
    """Return (targets, strong targets, strong spans) of ascending word runs.

    The words in a run sit two bytes apart. Any run of three counts as a
    table. A run of STRONG_RUN or more is very unlikely to happen by chance
    in speech data, so its bytes are taken to be a table and never speech.
    """
    out, strong, spans = set(), set(), []
    n = len(w)
    i = 0
    while i < n:
        j = i
        while j + 2 < n and w[j] >= 0 and 0 < w[j + 2] - w[j] <= MAX_STEP:
            j += 2
        run = (j - i) // 2 + 1
        if run >= 3:
            ts = [w[k] for k in range(i, j + 1, 2)]
            out.update(ts)
            if run >= STRONG_RUN:
                strong.update(ts)
                spans.append((i, j + 2))
            i = j + 1
        else:
            i += 1
    return out, strong, spans


def records(data, w, chip):
    """Return ({speech start}, [(first record byte, speech start)])."""
    starts, spans = set(), []
    for i, p in enumerate(w):
        if i + 3 <= p <= i + 16 and data[p - 1] == 0:
            r = L.parse(data, chip, p, max_frames=MAX_FRAMES)
            if r and len(r[0]) > MIN_FRAMES:
                starts.add(p)
                spans.append((i, p))
    return starts, spans


def after_records(data, chip):
    """Return {speech start} for offsets just past a 01 00 record end."""
    out = set()
    for t in range(2, len(data)):
        if data[t] and data[t - 1] == 0 and data[t - 2] == 1:
            r = L.parse(data, chip, t, max_frames=MAX_FRAMES)
            if r and len(r[0]) > MIN_FRAMES:
                out.add(t)
    return out


def letter_runs(data):
    """Return [(start, end)] of spelling lists: LETTER_RUN or more bytes in a
    row that are all letter codes $00 to $19, with several different values."""
    out = []
    i = 0
    while i < len(data):
        j = i
        while j < len(data) and data[j] < 0x1A:
            j += 1
        if j - i >= LETTER_RUN and len(set(data[i:j])) >= 4:
            out.append((i, j))
        i = max(j, i + 1)
    return out


def find(data, chip, base=0):
    """Return a sorted list of (start, end, frames) with offsets into data.

    base is the TMS6100 address of data[0], used to match pointers.
    """
    size = len(data)
    w = _words(data, base)
    marked, strong, tspans = table_targets(w)
    rstarts, rspans = records(data, w, chip)
    after = after_records(data, chip)
    marked |= rstarts | after
    banned = bytearray(size + 1)
    for i, p in rspans + tspans + letter_runs(data):
        for j in range(i, p):
            banned[j] = 1
    nban = [0]
    for b in banned:
        nban.append(nban[-1] + b)

    def chained(e):
        if all(b in (0x00, 0xFF) for b in data[e:]):
            return True
        for k in range(MAX_PAD + 1):
            if e + k in marked or e + k >= size:
                return True
            if e + k < size and data[e + k] != 0:
                return False
        return False

    parsed = {}
    for t in range(size):
        if banned[t] or data[t] == 0:
            continue
        r = L.parse(data, chip, t, max_frames=MAX_FRAMES)
        if not r or r[1] > size:
            continue
        fr, e = r
        if nban[e] - nban[t]:
            continue
        mk = t in marked
        sm = smooth(fr)
        if sm or (mk and len(fr) > MIN_FRAMES and chained(e)):
            parsed[t] = (e, fr, sm)

    # A parse that starts up to RECORD_BACK bytes before a 01 00 record end
    # and falls into step with the speech after it began in the record.
    for t in after:
        if t in parsed:
            for t0 in range(max(0, t - RECORD_BACK), t):
                if t0 in parsed and parsed[t0][0] == parsed[t][0]:
                    del parsed[t0]

    # A parse that runs over a marked phrase start, and is not itself both
    # marked and smooth or a strong table target, began in non-speech bytes
    # and fell into step with the real phrase.
    # Phrases are packed back to back, so a start that falls where another
    # candidate ends, after at most MAX_PAD zero bytes, counts as marked.
    for e, fr, sm in list(parsed.values()):
        for k in range(MAX_PAD + 1):
            if e + k in parsed and (e + k) not in marked:
                marked.add(e + k)
            if e + k >= size or data[e + k] != 0:
                break
    good = sorted(t for t in parsed if t in marked)
    cands = []
    for t, (e, fr, sm) in parsed.items():
        mk = t in marked
        if not ((mk and sm) or t in strong):
            j = bisect.bisect_right(good, t)
            if j < len(good) and good[j] < e:
                continue
        cands.append((e, t, (e - t) * (MARKED_WEIGHT if mk else UNMARKED_WEIGHT), fr))
    cands.sort(key=lambda c: (c[0], c[1]))

    # Weighted interval scheduling over the candidates.
    ends = [c[0] for c in cands]
    best = [0.0] * (len(cands) + 1)
    pick = [None] * (len(cands) + 1)
    for k, (e, t, wt, _) in enumerate(cands):
        j = bisect.bisect_right(ends, t, 0, k)
        if best[j] + wt > best[k]:
            best[k + 1] = best[j] + wt
            pick[k + 1] = j
        else:
            best[k + 1] = best[k]
    out = []
    k = len(cands)
    while k > 0:
        if pick[k] is None:
            k -= 1
        else:
            e, t, _, fr = cands[k - 1]
            out.append((t, e, fr))
            k = pick[k]
    out.reverse()
    return out

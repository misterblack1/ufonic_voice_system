#!/usr/bin/env python3
"""dskput.py: put, delete, list and extract files on a DOS 3.3 disk image.

Layout:
  - A .dsk is 35 tracks x 16 sectors x 256 bytes, 143,360 bytes
  - Sectors are in logical order, offset(t,s) = t*4096 + s*256
  - The VTOC is at track 17, sector 0
  - The catalog is a linked list starting at the sector the VTOC names
  - Each catalog sector holds 7 file descriptors of 35 bytes, from 0x0B

Usage:
  python dskput.py ls   <disk.dsk>
  python dskput.py put  <disk.dsk> <local-file> <DOSNAME> [--type B] [--overwrite]
  python dskput.py del  <disk.dsk> <DOSNAME>
  python dskput.py get  <disk.dsk> <DOSNAME> <local-file>

DOSNAME is uppercased and cut or padded to 30 characters. A file for `put`
is raw DOS 3.3 binary file contents, a 4-byte load address and length header
then the data, which is what `acme -f apple` writes.
"""

import argparse
import os
import sys

TRACKS = 35
SECTORS = 16
BPS = 256                      # Bytes per sector
TRACK_BYTES = SECTORS * BPS    # 4096
DISK_BYTES = TRACKS * TRACK_BYTES  # 143360

VTOC_TRACK = 17
VTOC_SECTOR = 0

TS_PAIRS_PER_LIST = 122        # Track and sector pairs that fit in one T/S list sector

# DOS 3.3 file type codes, the low 7 bits. Bit 7 set means locked.
TYPE_CODES = {
    'T': 0x00,  # Text
    'I': 0x01,  # Integer BASIC
    'A': 0x02,  # Applesoft
    'B': 0x04,  # Binary
    'S': 0x08,
    'R': 0x10,  # Relocatable
    'N': 0x40,  # New B type
}


def offset(track, sector):
    return track * TRACK_BYTES + sector * BPS


def read_sector(disk, track, sector):
    o = offset(track, sector)
    return bytes(disk[o:o + BPS])


def write_sector(disk, track, sector, data):
    assert len(data) == BPS, f"sector must be {BPS} bytes, got {len(data)}"
    o = offset(track, sector)
    disk[o:o + BPS] = bytearray(data)


# VTOC:

def vtoc_is_free(disk, track, sector):
    """Return True if (track,sector) is marked free in the VTOC bitmap."""
    v = read_sector(disk, VTOC_TRACK, VTOC_SECTOR)
    base = 0x38 + 4 * track
    # byte[1] holds sectors 0-7 and byte[0] sectors 8-15. A set bit is free.
    if sector < 8:
        b = v[base + 1]
        bit = sector
    else:
        b = v[base + 0]
        bit = sector - 8
    return bool(b & (1 << bit))


def vtoc_set_free(disk, track, sector, free):
    """Mark (track,sector) as free (True) or used (False) in the VTOC bitmap."""
    v = bytearray(read_sector(disk, VTOC_TRACK, VTOC_SECTOR))
    base = 0x38 + 4 * track
    if sector < 8:
        bit = sector
        mask = 1 << bit
        if free:
            v[base + 1] |= mask
        else:
            v[base + 1] &= ~mask & 0xFF
    else:
        bit = sector - 8
        mask = 1 << bit
        if free:
            v[base + 0] |= mask
        else:
            v[base + 0] &= ~mask & 0xFF
    write_sector(disk, VTOC_TRACK, VTOC_SECTOR, v)


def vtoc_get_catalog_start(disk):
    v = read_sector(disk, VTOC_TRACK, VTOC_SECTOR)
    return v[0x01], v[0x02]  # Track, sector


def vtoc_get_last_track(disk):
    v = read_sector(disk, VTOC_TRACK, VTOC_SECTOR)
    direction = v[0x31]
    if direction >= 128:
        direction -= 256  # Sign extend
    return v[0x30], direction


def vtoc_set_last_track(disk, track):
    v = bytearray(read_sector(disk, VTOC_TRACK, VTOC_SECTOR))
    v[0x30] = track & 0xFF
    write_sector(disk, VTOC_TRACK, VTOC_SECTOR, v)


# CATALOG:

def catalog_sectors(disk):
    """Yield (track, sector, data) for each catalog sector in the linked list."""
    t, s = vtoc_get_catalog_start(disk)
    seen = set()
    while not (t == 0 and s == 0):
        if (t, s) in seen:
            raise ValueError(f"catalog loop at {t}/{s}")
        seen.add((t, s))
        data = read_sector(disk, t, s)
        yield t, s, data
        t, s = data[0x01], data[0x02]


def filedesc_status(fd):
    """Return 'normal', 'deleted', or 'unused' for a 35-byte descriptor."""
    if fd[0x00] == 0x00:
        return 'unused'
    if fd[0x00] == 0xFF:
        return 'deleted'
    return 'normal'


def filedesc_name(fd):
    """Return the printable name from a 35-byte descriptor with high bits stripped."""
    raw = fd[0x03:0x21]
    s = ''.join(chr(b & 0x7F) for b in raw)
    return s.rstrip()


def filedesc_type(fd):
    code = fd[0x02] & 0x7F
    locked = '*' if (fd[0x02] & 0x80) else ' '
    for ch, val in TYPE_CODES.items():
        if val == code:
            return f"{locked}{ch}"
    return f"{locked}?"


def list_catalog(disk, out):
    found = False
    for t, s, data in catalog_sectors(disk):
        for i in range(7):
            fd = data[0x0B + 35 * i: 0x0B + 35 * (i + 1)]
            st = filedesc_status(fd)
            if st == 'normal':
                name = filedesc_name(fd)
                nsec = fd[0x21] | (fd[0x22] << 8)
                tsl_t, tsl_s = fd[0x00], fd[0x01]
                out.write(f"{filedesc_type(fd)} {nsec:5d}  {name}\n")
                found = True
    if not found:
        out.write("(no files)\n")


# SECTOR ALLOCATION:

def find_free_sectors(disk, count, reserved):
    """Allocate `count` free (track,sector) pairs, avoiding anything in the
    `reserved` set. Returns a list of (track,sector) pairs in allocation order.
    Starts from the VTOC's last track and direction, as DOS does, then sweeps
    the whole disk if it runs out in that direction."""
    last_track, direction = vtoc_get_last_track(disk)
    if direction == 0:
        direction = 1

    # Build track visit order: start near last_track, expand outward in the
    # preferred direction, eventually covering all tracks.
    order = []
    t = last_track
    for _ in range(TRACKS):
        if 0 <= t < TRACKS:
            order.append(t)
        t = (t + direction) % TRACKS
    # Drop repeats, keep the order, and cover every track.
    seen = set()
    track_order = []
    for t in order:
        if t not in seen:
            seen.add(t)
            track_order.append(t)
    for t in range(TRACKS):
        if t not in seen:
            track_order.append(t)

    allocated = []
    for tr in track_order:
        if len(allocated) >= count:
            break
        for sec in range(SECTORS):
            if len(allocated) >= count:
                break
            if (tr, sec) in reserved:
                continue
            if vtoc_is_free(disk, tr, sec):
                allocated.append((tr, sec))
                reserved.add((tr, sec))  # Never hand out the same sector twice

    if len(allocated) < count:
        raise ValueError(
            f"not enough free sectors: need {count}, found {len(allocated)}")
    return allocated


# T/S LIST AND DATA WRITING:

def ceil_div(a, b):
    return (a + b - 1) // b


def write_file_data(disk, payload, reserved):
    """Write `payload` to the disk as data sectors plus one or more T/S list
    sectors. Returns (tsl_track, tsl_sector, sector_count).

    `reserved` is the set of (track,sector) pairs already claimed. Everything
    allocated here is added to it."""
    n_data = ceil_div(len(payload), BPS)
    n_data = max(n_data, 1)  # Always at least one sector
    n_tsl = ceil_div(n_data, TS_PAIRS_PER_LIST)
    n_tsl = max(n_tsl, 1)

    total_needed = n_data + n_tsl
    sectors = find_free_sectors(disk, total_needed, reserved)

    tsl_sectors = sectors[:n_tsl]
    data_sectors = sectors[n_tsl:n_tsl + n_data]

    # Mark them all used in the bitmap.
    for (t, s) in sectors:
        vtoc_set_free(disk, t, s, False)

    # Write the data sectors, zero padded to 256.
    payload = payload + b'\x00' * (n_data * BPS - len(payload))
    for i, (t, s) in enumerate(data_sectors):
        write_sector(disk, t, s, payload[i * BPS:(i + 1) * BPS])

    # Build the T/S list sectors. Each holds 122 pairs. SectorOffset is the
    # index of the data sector this list starts at.
    tsl_buf = bytearray(BPS)
    first_tsl = tsl_sectors[0]
    for idx, (tlist_t, tlist_s) in enumerate(tsl_sectors):
        tsl_buf[0x00] = 0x00             # Unused
        if idx + 1 < n_tsl:
            nxt = tsl_sectors[idx + 1]
            tsl_buf[0x01] = nxt[0]
            tsl_buf[0x02] = nxt[1]
        else:
            tsl_buf[0x01] = 0x00         # No next
            tsl_buf[0x02] = 0x00
        tsl_buf[0x03] = 0x00
        tsl_buf[0x04] = 0x00
        so = idx * TS_PAIRS_PER_LIST
        tsl_buf[0x05] = so & 0xFF
        tsl_buf[0x06] = (so >> 8) & 0xFF
        for k in range(0x07, 0x0C):
            tsl_buf[k] = 0x00
        # Fill the 122 T/S pair slots of this list sector.
        for k in range(TS_PAIRS_PER_LIST):
            data_idx = idx * TS_PAIRS_PER_LIST + k
            if data_idx < n_data:
                dt, ds = data_sectors[data_idx]
            else:
                dt, ds = 0, 0
            tsl_buf[0x0C + k * 2] = dt
            tsl_buf[0x0D + k * 2] = ds
        # 0x0C + 122 x 2 is 0x100, so the pairs fill the sector exactly.
        write_sector(disk, tlist_t, tlist_s, bytes(tsl_buf))

    sector_count = n_data + n_tsl
    return first_tsl[0], first_tsl[1], sector_count


# CATALOG SLOT MANAGEMENT:

def encode_name(name):
    """DOS 3.3 filename encoding: uppercase, high bit set, space padded to 30."""
    name = name.upper()[:30]
    if not name:
        raise ValueError("empty filename")
    out = bytearray(30)
    for i in range(30):
        if i < len(name):
            out[i] = ord(name[i]) | 0x80
        else:
            out[i] = 0xA0  # Space with the high bit set
    return bytes(out)


def find_file(disk, name):
    """Return (cat_t, cat_s, fd_index, fd_bytes) for the named file, or None."""
    name_u = name.upper()
    for t, s, data in catalog_sectors(disk):
        for i in range(7):
            fd = data[0x0B + 35 * i: 0x0B + 35 * (i + 1)]
            if filedesc_status(fd) == 'normal' and filedesc_name(fd) == name_u:
                return (t, s, i, fd)
    return None


def free_file_sectors(disk, fd):
    """Mark every sector of this file's data and T/S lists free."""
    t, s = fd[0x00], fd[0x01]
    seen_ts = set()
    while not (t == 0 and s == 0):
        if (t, s) in seen_ts:
            raise ValueError("T/S list loop")
        seen_ts.add((t, s))
        vtoc_set_free(disk, t, s, True)
        tsl = read_sector(disk, t, s)
        for k in range(TS_PAIRS_PER_LIST):
            dt = tsl[0x0C + k * 2]
            ds = tsl[0x0D + k * 2]
            if dt == 0 and ds == 0:
                continue
            vtoc_set_free(disk, dt, ds, True)
        t, s = tsl[0x01], tsl[0x02]


def find_or_alloc_catalog_slot(disk, reserved):
    """Find an unused or deleted catalog descriptor slot. If there is none,
    allocate a new catalog sector, link it onto the end of the catalog chain,
    and return its first slot.

    Returns (cat_t, cat_s, slot_index, sector_was_allocated_bool)."""
    # Look for an unused or deleted slot in the existing catalog sectors.
    cat_sectors = list(catalog_sectors(disk))
    for t, s, data in cat_sectors:
        for i in range(7):
            fd = data[0x0B + 35 * i: 0x0B + 35 * (i + 1)]
            if filedesc_status(fd) in ('unused', 'deleted'):
                return t, s, i, False

    # No free slot, so allocate a new catalog sector. DOS keeps its catalog
    # on track 17 with the VTOC. This takes any free sector that is not the
    # VTOC or an existing catalog sector.
    existing_cat = {(VTOC_TRACK, VTOC_SECTOR)} | {(t, s) for t, s, _ in cat_sectors}
    for r in existing_cat:
        reserved.add(r)
    new_secs = find_free_sectors(disk, 1, reserved)
    nt, ns = new_secs[0]
    vtoc_set_free(disk, nt, ns, False)

    # Clear the new catalog sector. A T/S list track of 0 marks a slot unused.
    new_data = bytearray(BPS)
    new_data[0x00] = 0x00
    new_data[0x01] = 0x00  # No next sector
    new_data[0x02] = 0x00
    write_sector(disk, nt, ns, bytes(new_data))

    # Point the last catalog sector, the one whose next is 0/0, at the new
    # sector.
    if cat_sectors:
        last_t, last_s, last_data = cat_sectors[-1]
        ld = bytearray(last_data)
        ld[0x01] = nt
        ld[0x02] = ns
        write_sector(disk, last_t, last_s, bytes(ld))
    else:
        # No catalog at all, so point the VTOC at the new sector.
        v = bytearray(read_sector(disk, VTOC_TRACK, VTOC_SECTOR))
        v[0x01] = nt
        v[0x02] = ns
        write_sector(disk, VTOC_TRACK, VTOC_SECTOR, bytes(v))

    return nt, ns, 0, True


def put_file(disk, local_path, dosname, type_char, overwrite, out):
    payload = open(local_path, 'rb').read()
    if len(payload) > 256 * 256:
        raise ValueError(f"file too large: {len(payload)} bytes (max 64 KiB)")

    # An existing file is an error unless overwrite is set.
    existing = find_file(disk, dosname)
    if existing is not None:
        if not overwrite:
            out.write(f"error: {dosname} already exists, use --overwrite\n")
            return 1
        # Deleting frees its sectors and marks its slot deleted.
        del_file(disk, dosname, out, quiet=True)

    reserved = set()
    # Reserve the VTOC and every catalog sector so allocation never picks them.
    reserved.add((VTOC_TRACK, VTOC_SECTOR))
    for t, s, _ in catalog_sectors(disk):
        reserved.add((t, s))

    # Write the data and T/S lists.
    tsl_t, tsl_s, sector_count = write_file_data(disk, payload, reserved)

    # Find a catalog slot, which may allocate a new catalog sector.
    ct, cs, slot, _ = find_or_alloc_catalog_slot(disk, reserved)

    # Build the file descriptor.
    name_bytes = encode_name(dosname)
    type_code = TYPE_CODES.get(type_char.upper(), 0x04)
    fd = bytearray(35)
    fd[0x00] = tsl_t
    fd[0x01] = tsl_s
    fd[0x02] = type_code  # Not locked
    fd[0x03:0x21] = name_bytes
    fd[0x21] = sector_count & 0xFF
    fd[0x22] = (sector_count >> 8) & 0xFF

    # Patch it into the catalog sector.
    cat = bytearray(read_sector(disk, ct, cs))
    cat[0x0B + 35 * slot: 0x0B + 35 * (slot + 1)] = fd
    write_sector(disk, ct, cs, bytes(cat))

    out.write(
        f"put {dosname}: {len(payload)} bytes -> {sector_count} sectors "
        f"(T/S list at {tsl_t}/{tsl_s}, catalog slot {ct}/{cs}[{slot}])\n")
    return 0


def del_file(disk, dosname, out, quiet=False):
    found = find_file(disk, dosname)
    if found is None:
        if not quiet:
            out.write(f"error: {dosname} not found\n")
        return 1
    ct, cs, slot, fd = found
    free_file_sectors(disk, fd)
    # Mark the catalog entry deleted. The T/S list track becomes 0xFF and the
    # original track goes in the last byte of the name, as DOS does.
    cat = bytearray(read_sector(disk, ct, cs))
    base = 0x0B + 35 * slot
    cat[base + 0x00] = 0xFF
    cat[base + 0x20] = fd[0x00]  # Original T/S list track, for undelete
    write_sector(disk, ct, cs, bytes(cat))
    if not quiet:
        out.write(f"deleted {dosname}\n")
    return 0


def get_file(disk, dosname, local_path, out):
    """Extract a file's raw contents, in T/S list order, to local_path.
    The last T/S list stops at its last non-zero pair. Zero pairs before that
    become 256 zero bytes, as in a sparse file. The length comes out a whole
    number of sectors. For B, I and A files the 4-byte header in the first
    data sector holds the true length."""
    found = find_file(disk, dosname)
    if found is None:
        out.write(f"error: {dosname} not found\n")
        return 1
    _, _, _, fd = found

    # Gather the chain of T/S list sectors first.
    tsl_sectors = []
    t, s = fd[0x00], fd[0x01]
    seen = set()
    while not (t == 0 and s == 0):
        if (t, s) in seen:
            raise ValueError("T/S list loop")
        seen.add((t, s))
        tsl_sectors.append((t, s))
        tsl = read_sector(disk, t, s)
        t, s = tsl[0x01], tsl[0x02]

    payload = bytearray()
    for idx, (tt, ts) in enumerate(tsl_sectors):
        tsl = read_sector(disk, tt, ts)
        is_last = (idx == len(tsl_sectors) - 1)
        if is_last:
            # Read through the last non-zero pair.
            end = -1
            for k in range(TS_PAIRS_PER_LIST):
                dt = tsl[0x0C + k * 2]
                ds = tsl[0x0D + k * 2]
                if dt != 0 or ds != 0:
                    end = k
            if end < 0:
                break  # Empty list
        else:
            end = TS_PAIRS_PER_LIST - 1
        for k in range(end + 1):
            dt = tsl[0x0C + k * 2]
            ds = tsl[0x0D + k * 2]
            if dt == 0 and ds == 0:
                payload += b'\x00' * BPS
            else:
                payload += read_sector(disk, dt, ds)

    with open(local_path, 'wb') as f:
        f.write(payload)
    out.write(f"extracted {dosname}: {len(payload)} bytes -> {local_path}\n")
    return 0


# CLI:

def main(argv):
    p = argparse.ArgumentParser(description=__doc__,
                                formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = p.add_subparsers(dest='cmd', required=True)

    pl = sub.add_parser('ls', help='list files')
    pl.add_argument('disk')

    pp = sub.add_parser('put', help='put a file on the disk')
    pp.add_argument('disk')
    pp.add_argument('local')
    pp.add_argument('dosname')
    pp.add_argument('--type', default='B', help='file type letter, B, I, A or T')
    pp.add_argument('--overwrite', '-f', action='store_true')

    pd = sub.add_parser('del', help='delete a file')
    pd.add_argument('disk')
    pd.add_argument('dosname')

    pg = sub.add_parser('get', help='extract a file')
    pg.add_argument('disk')
    pg.add_argument('dosname')
    pg.add_argument('local')

    args = p.parse_args(argv)

    if not os.path.exists(args.disk):
        sys.stderr.write(f"error: disk image not found: {args.disk}\n")
        return 2

    disk = bytearray(open(args.disk, 'rb').read())
    if len(disk) != DISK_BYTES:
        sys.stderr.write(
            f"error: disk image is {len(disk)} bytes, expected {DISK_BYTES}\n")
        return 2

    rc = 0
    if args.cmd == 'ls':
        list_catalog(disk, sys.stdout)
    elif args.cmd == 'put':
        rc = put_file(disk, args.local, args.dosname, args.type,
                      args.overwrite, sys.stdout)
        if rc == 0:
            with open(args.disk, 'wb') as f:
                f.write(disk)
    elif args.cmd == 'del':
        rc = del_file(disk, args.dosname, sys.stdout)
        if rc == 0:
            with open(args.disk, 'wb') as f:
                f.write(disk)
    elif args.cmd == 'get':
        rc = get_file(disk, args.dosname, args.local, sys.stdout)
    return rc


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))

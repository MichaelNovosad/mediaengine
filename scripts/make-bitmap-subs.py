#!/usr/bin/env python3
"""Writes tiny picture-subtitle test files: PGS (Blu-ray) as bitmap.sup, VobSub (DVD) as bitmap.idx + bitmap.sub.

Both show the same picture: a 200 x 50 red rectangle with a white square at its left end, for a video of 640 x 360.
  PGS:     shown at (100, 250) from 0.5 s to 2.0 s, then at (300, 100) from 3.0 s to 4.5 s
  VobSub:  shown at (100, 250) from 0.5 s to 2.0 s, then at (300, 100) from 3.0 s to 4.5 s
Pixel values: index 1 red, index 2 white, index 0 transparent. Generated, so no third-party material is involved.
usage: python3 -I scripts/make-bitmap-subs.py <output directory>
"""
import os
import struct
import sys

WIDTH, HEIGHT = 200, 50
VIDEO = (640, 360)
SHOWS = [(0.5, 2.0, 100, 250), (3.0, 4.5, 300, 100)]


def picture():
    """Rows of colour indices: 1 red, 2 white square (20 x 30) at the left end, 0 transparent border of one pixel."""
    rows = []
    for y in range(HEIGHT):
        row = [0] * WIDTH
        for x in range(WIDTH):
            if 1 <= x < WIDTH - 1 and 1 <= y < HEIGHT - 1:
                row[x] = 2 if (6 <= x < 26 and 10 <= y < 40) else 1
        rows.append(row)
    return rows


def runs(row):
    result = []
    for value in row:
        if result and result[-1][0] == value:
            result[-1][1] += 1
        else:
            result.append([value, 1])
    return result


# ---------------------------------------------------------------- PGS

def pgs_rle(rows):
    out = bytearray()
    for row in rows:
        for color, n in runs(row):
            if color == 0:
                out += bytes([0, n]) if n < 64 else bytes([0, 0x40 | (n >> 8), n & 0xFF])
            elif n == 1:
                out += bytes([color])
            elif n == 2:
                out += bytes([color, color])
            elif n < 64:
                out += bytes([0, 0x80 | n, color])
            else:
                out += bytes([0, 0xC0 | (n >> 8), n & 0xFF, color])
        out += bytes([0, 0])
    return bytes(out)


def ycrcb(r, g, b):
    """Limited-range BT.709, the order PGS stores them in: Y, Cr, Cb."""
    y = 16 + (0.2126 * r + 0.7152 * g + 0.0722 * b) * 219 / 255
    cb = 128 + (-0.1146 * r - 0.3854 * g + 0.5 * b) * 224 / 255
    cr = 128 + (0.5 * r - 0.4542 * g - 0.0458 * b) * 224 / 255
    return round(y), round(cr), round(cb)


def pgs_segment(kind, pts_seconds, payload):
    pts = round(pts_seconds * 90000)
    return b'PG' + struct.pack('>IIBH', pts, 0, kind, len(payload)) + payload


def pgs_display(start, x, y, rows, number):
    pcs = struct.pack('>HHBHBBBB', VIDEO[0], VIDEO[1], 0x10, number, 0x80, 0, 0, 1) + struct.pack('>HBBHH', 0, 0, 0, x, y)
    wds = struct.pack('>BBHHHH', 1, 0, x, y, WIDTH, HEIGHT)
    palette = bytes([0]) + bytes([0]) + bytes([0, 16, 128, 128, 0]) \
        + bytes([1]) + bytes(ycrcb(255, 0, 0)) + bytes([255]) + bytes([2]) + bytes(ycrcb(255, 255, 255)) + bytes([255])
    data = pgs_rle(rows)
    ods = struct.pack('>HBB', 0, 0, 0xC0) + struct.pack('>I', len(data) + 4)[1:] + struct.pack('>HH', WIDTH, HEIGHT) + data
    return (pgs_segment(0x16, start, pcs) + pgs_segment(0x17, start, wds) + pgs_segment(0x14, start, palette)
            + pgs_segment(0x15, start, ods) + pgs_segment(0x80, start, b''))


def pgs_clear(end, number):
    pcs = struct.pack('>HHBHBBBB', VIDEO[0], VIDEO[1], 0x10, number, 0x00, 0, 0, 0)
    wds = struct.pack('>BBHHHH', 1, 0, 0, 0, 8, 8)
    return pgs_segment(0x16, end, pcs) + pgs_segment(0x17, end, wds) + pgs_segment(0x80, end, b'')


def make_pgs(rows):
    data, number = b'', 0
    for start, end, x, y in SHOWS:
        data += pgs_display(start, x, y, rows, number); number += 1
        data += pgs_clear(end, number); number += 1
    return data


# ---------------------------------------------------------------- VobSub

def nibbles_for(value):
    if value <= 0xF:
        return [value]
    if value <= 0xFF:
        return [(value >> 4) & 0xF, value & 0xF]
    if value <= 0xFFF:
        return [(value >> 8) & 0xF, (value >> 4) & 0xF, value & 0xF]
    return [(value >> 12) & 0xF, (value >> 8) & 0xF, (value >> 4) & 0xF, value & 0xF]


def vob_field(rows):
    nibs = []
    for row in rows:
        mine = []
        for color, n in runs(row):
            if color == 0 and n == len(row):
                mine += [0, 0, 0, color]
                continue
            value = (n << 2) | color
            # The smallest form that holds it: 1 nibble 0x4-0xF, 2 nibbles 0x10-0x3F, 3 nibbles 0x40-0xFF, 4 nibbles above.
            if value < 4 or value > 0x3FF:
                raise ValueError('run of %d pixels cannot be coded' % n)
            if value <= 0xF:
                mine += [value]
            elif value <= 0x3F:
                mine += [(value >> 4) & 0xF, value & 0xF]
            elif value <= 0xFF:
                mine += [0, (value >> 4) & 0xF, value & 0xF]
            else:
                mine += [0, (value >> 8) & 0xF, (value >> 4) & 0xF, value & 0xF]
        if len(mine) % 2:
            mine.append(0)
        nibs += mine
    out = bytearray()
    for i in range(0, len(nibs), 2):
        out.append((nibs[i] << 4) | nibs[i + 1])
    return bytes(out)


def spu(rows, x, y, duration_seconds):
    top = vob_field(rows[0::2])
    bottom = vob_field(rows[1::2])
    header = 4
    top_offset = header
    bottom_offset = header + len(top)
    control = header + len(top) + len(bottom)
    delay_units = round(duration_seconds * 90000 / 1024)
    x1, x2, y1, y2 = x, x + WIDTH - 1, y, y + HEIGHT - 1
    # start display; palette: pixel 3,2,1,0 use colours 3,2,1,0; alpha: pixel 0 transparent, the others opaque; area; field offsets
    commands = bytes([0x01, 0x03, 0x32, 0x10, 0x04, 0xFF, 0xF0]) + bytes([0x05]) \
        + bytes([(x1 >> 4) & 0xFF, ((x1 & 0xF) << 4) | ((x2 >> 8) & 0xF), x2 & 0xFF, (y1 >> 4) & 0xFF, ((y1 & 0xF) << 4) | ((y2 >> 8) & 0xF), y2 & 0xFF]) \
        + bytes([0x06]) + struct.pack('>HH', top_offset, bottom_offset) + bytes([0xFF])
    second = control + 4 + len(commands)
    seq1 = struct.pack('>HH', 0, second) + commands
    seq2 = struct.pack('>HH', delay_units, second) + bytes([0x02, 0xFF])
    body = top + bottom + seq1 + seq2
    total = header + len(body)
    return struct.pack('>HH', total, control) + body


def pes(substream_payload, pts_seconds):
    pts = round(pts_seconds * 90000)
    stamp = bytes([0x21 | ((pts >> 29) & 0x0E), (pts >> 22) & 0xFF, 0x01 | ((pts >> 14) & 0xFE), (pts >> 7) & 0xFF, 0x01 | ((pts << 1) & 0xFE)])
    inner = bytes([0x81, 0x80, 5]) + stamp + bytes([0x20]) + substream_payload
    return b'\x00\x00\x01\xBD' + struct.pack('>H', len(inner)) + inner


def pack_header(scr_seconds):
    scr = round(scr_seconds * 90000)
    return b'\x00\x00\x01\xBA' + bytes([0x44 | ((scr >> 27) & 0x38) | ((scr >> 28) & 0x03), (scr >> 20) & 0xFF,
                                          0x04 | ((scr >> 12) & 0xF8) | ((scr >> 13) & 0x03), (scr >> 5) & 0xFF,
                                          0x04 | ((scr << 3) & 0xF8), 0x01, 0x01, 0x89, 0xC3, 0xF8])


def make_vobsub(rows):
    sub = b''
    stamps = []
    for start, end, x, y in SHOWS:
        stamps.append((start, len(sub)))
        sub += pack_header(start) + pes(spu(rows, x, y, end - start), start)
    idx = ('# VobSub index file, v7 (do not modify this line!)\n'
           'size: %dx%d\n'
           'palette: 000000, ff0000, ffffff, 808080, 000000, 000000, 000000, 000000, 000000, 000000, 000000, 000000, 000000, 000000, 000000, 000000\n'
           'langidx: 0\n\n'
           'id: en, index: 0\n') % VIDEO
    for start, offset in stamps:
        total_ms = round(start * 1000)
        idx += 'timestamp: %02d:%02d:%02d:%03d, filepos: %09x\n' % (total_ms // 3600000, total_ms // 60000 % 60, total_ms // 1000 % 60, total_ms % 1000, offset)
    return idx, sub


if __name__ == '__main__':
    out = sys.argv[1]
    os.makedirs(out, exist_ok=True)
    picture_rows = picture()
    with open(os.path.join(out, 'bitmap.sup'), 'wb') as f:
        f.write(make_pgs(picture_rows))
    idx, sub = make_vobsub(picture_rows)
    with open(os.path.join(out, 'bitmap.idx'), 'w') as f:
        f.write(idx)
    with open(os.path.join(out, 'bitmap.sub'), 'wb') as f:
        f.write(sub)
    print('wrote bitmap.sup, bitmap.idx, bitmap.sub in', out)

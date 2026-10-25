#!/usr/bin/env python3
"""Writes Fixtures/src/BlockFont.ttf: a tiny TrueType font whose letters, digits and space are plain rectangles.

Why: subtitle rendering tests need a font that is (a) not installed on any machine, so using it proves the attachment
of the container was used, and (b) made of shapes whose size is known, so a test can measure what libass drew. The font
is generated, has no third-party licence, and is byte-for-byte reproducible.

Family "Media Blocks". Units per em 1000, ascender 800, descender -200. Every glyph is one rectangle from x = 50 to
advance - 50: upper case letters and "W"/"M" up to y = 700 (W and M are 800 units wide), lower case up to 500, digits up
to 650, all starting at the baseline. The advance of every other glyph is 600. Space is empty with advance 300.
usage: python3 -I scripts/make-block-font.py [output.ttf]
"""
import struct
import sys

UNITS = 1000


def glyph_spec():
    """(codepoint, advance, height) for every character the font covers, in glyph order after .notdef."""
    specs = [(0x20, 300, 0)]
    for c in range(ord('0'), ord('9') + 1):
        specs.append((c, 600, 650))
    for c in range(ord('A'), ord('Z') + 1):
        specs.append((c, 800 if chr(c) in 'MW' else 600, 700))
    for c in range(ord('a'), ord('z') + 1):
        specs.append((c, 800 if chr(c) in 'mw' else 600, 500))
    return specs


def rectangle(advance, height):
    """A glyf entry for one filled rectangle, or an empty entry for height 0."""
    if height == 0:
        return b''
    x0, x1, y0, y1 = 50, advance - 50, 0, height
    data = struct.pack('>hhhhh', 1, x0, y0, x1, y1)          # one contour and its bounding box
    data += struct.pack('>H', 3)                              # last point of contour 0
    data += struct.pack('>H', 0)                              # no instructions
    data += bytes([1, 1, 1, 1])                               # on-curve points, 16-bit coordinates
    points = [(x0, y0), (x0, y1), (x1, y1), (x1, y0)]         # clockwise
    previous = 0
    for x, _ in points:
        data += struct.pack('>h', x - previous); previous = x
    previous = 0
    for _, y in points:
        data += struct.pack('>h', y - previous); previous = y
    return data


def notdef():
    """A hollow box, so a missing glyph can be told from a letter."""
    outer = [(50, 0), (50, 700), (550, 700), (550, 0)]
    inner = [(120, 70), (480, 70), (480, 630), (120, 630)]    # counter-clockwise: a hole
    data = struct.pack('>hhhhh', 2, 50, 0, 550, 700)
    data += struct.pack('>HH', 3, 7) + struct.pack('>H', 0) + bytes([1] * 8)
    for axis in (0, 1):
        previous = 0
        for point in outer + inner:
            data += struct.pack('>h', point[axis] - previous); previous = point[axis]
    return data


def pad4(data):
    return data + b'\0' * (-len(data) % 4)


def checksum(data):
    data = pad4(data)
    return sum(struct.unpack('>%dI' % (len(data) // 4), data)) & 0xFFFFFFFF


def build():
    specs = glyph_spec()
    glyphs = [(600, notdef())] + [(adv, rectangle(adv, h)) for _, adv, h in specs]
    count = len(glyphs)

    glyf, loca = b'', []
    for _, data in glyphs:
        loca.append(len(glyf))
        glyf += pad4(data)
    loca.append(len(glyf))

    hmtx = b''.join(struct.pack('>Hh', adv, 50 if data else 0) for adv, data in glyphs)

    # cmap, format 4, one segment per contiguous run of characters.
    runs = []
    for index, (code, _, _) in enumerate(specs, start=1):
        if runs and runs[-1][1] + 1 == code and runs[-1][2] + (code - runs[-1][0]) == index:
            runs[-1][1] = code
        else:
            runs.append([code, code, index])
    ends = [r[1] for r in runs] + [0xFFFF]
    starts = [r[0] for r in runs] + [0xFFFF]
    deltas = [(r[2] - r[0]) & 0xFFFF for r in runs] + [1]
    seg = len(ends)
    search = 2 * (1 << (seg.bit_length() - 1))
    sub = struct.pack('>HHHHHHH', 4, 16 + 8 * seg, 0, seg * 2, search, (seg.bit_length() - 1), seg * 2 - search)
    sub += b''.join(struct.pack('>H', v) for v in ends) + struct.pack('>H', 0)
    sub += b''.join(struct.pack('>H', v) for v in starts)
    sub += b''.join(struct.pack('>H', v) for v in deltas)
    sub += b'\0\0' * seg
    cmap = struct.pack('>HH', 0, 1) + struct.pack('>HHI', 3, 1, 12) + sub

    strings = {1: 'Media Blocks', 2: 'Regular', 3: 'MediaEngine Block Font 1.0', 4: 'Media Blocks', 6: 'MediaBlocks-Regular'}
    records, pool = [], b''
    for platform, encoding, language, codec in ((1, 0, 0, 'mac_roman'), (3, 1, 0x409, 'utf-16-be')):
        for name_id, text in sorted(strings.items()):
            raw = text.encode(codec)
            records.append((platform, encoding, language, name_id, len(raw), len(pool)))
            pool += raw
    name = struct.pack('>HHH', 0, len(records), 6 + 12 * len(records))
    name += b''.join(struct.pack('>HHHHHH', *r) for r in records) + pool

    xmax = max(adv for adv, _ in glyphs)
    head = struct.pack('>IIIIHHqqhhhhHHhhh', 0x00010000, 0x00010000, 0, 0x5F0F3CF5, 0x000B, UNITS, 0, 0, 0, -200, xmax, 800, 0, 8, 2, 1, 0)
    hhea = struct.pack('>IhhhHhhhhhhhhhhhH', 0x00010000, 800, -200, 0, xmax, 0, 0, xmax, 1, 0, 0, 0, 0, 0, 0, 0, count)
    maxp = struct.pack('>IHHHHHHHHHHHHHH', 0x00010000, count, 8, 2, 0, 0, 1, 0, 0, 0, 0, 0, 0, 0, 0)
    os2 = struct.pack('>HhHHH', 1, 600, 400, 5, 0)
    os2 += struct.pack('>8h', 650, 600, 0, 75, 650, 600, 0, 350)       # sub- and superscript boxes
    os2 += struct.pack('>hhh', 50, 300, 0)                               # strikeout size and position, family class
    os2 += bytes(10)                                                     # panose
    os2 += struct.pack('>4I', 1, 0, 0, 0) + b'MEBF'                      # Unicode ranges (Basic Latin), vendor
    os2 += struct.pack('>HHH', 0x0040, 0x20, 0x7A)                       # regular, first and last character
    os2 += struct.pack('>hhhHH', 800, -200, 0, 800, 200)                 # typographic and Windows metrics
    os2 += struct.pack('>II', 1, 0)                                      # code pages (Latin 1)
    assert len(os2) == 86
    post = struct.pack('>IIhhIIIII', 0x00030000, 0, -100, 50, 0, 0, 0, 0, 0)

    tables = {b'OS/2': os2, b'cmap': cmap, b'glyf': glyf, b'head': head, b'hhea': hhea, b'hmtx': hmtx,
              b'loca': b''.join(struct.pack('>I', v) for v in loca), b'maxp': maxp, b'name': name, b'post': post}
    tags = sorted(tables)
    header = struct.pack('>IHHHH', 0x00010000, len(tags), 16 * (1 << (len(tags).bit_length() - 1)),
                         len(tags).bit_length() - 1, 16 * len(tags) - 16 * (1 << (len(tags).bit_length() - 1)))
    offset = 12 + 16 * len(tags)
    directory, body, where = b'', b'', {}
    for tag in tags:
        data = tables[tag]
        where[tag] = offset + len(body)
        directory += struct.pack('>4sIII', tag, checksum(data), where[tag], len(data))
        body += pad4(data)
    font = bytearray(header + directory + body)
    # checkSumAdjustment lives 8 bytes into the head table.
    struct.pack_into('>I', font, where[b'head'] + 8, (0xB1B0AFBA - checksum(bytes(font))) & 0xFFFFFFFF)
    return bytes(font)


if __name__ == '__main__':
    out = sys.argv[1] if len(sys.argv) > 1 else 'Fixtures/src/BlockFont.ttf'
    data = build()
    with open(out, 'wb') as f:
        f.write(data)
    print('wrote %s (%d bytes)' % (out, len(data)))

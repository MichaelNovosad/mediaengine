"""Turns two ordinary Matroska files into a linked pair with an ordered edition.

usage: make-ordered-fixtures.py <main.mkv> <linked.mkv> <out-main.mkv> <out-main-missing.mkv> <out-linked.mkv>

FFmpeg's muxer cannot write ordered chapters or choose segment UIDs, so this patches the bytes: the segment UIDs are
overwritten in place (same size) and the Chapters element is replaced by an ordered edition, padded with a Void element
to the old size so that no other offset in the file (SeekHead, Cues) moves. The placeholder chapters in the main file
reserve the room.
"""
import sys

OWN = bytes.fromhex("b1b2b3b4b5b6b7b8b9babbbcbdbebfc0")      # the main file
LINKED = bytes.fromhex("a1a2a3a4a5a6a7a8a9aaabacadaeafb0")   # the opening, a separate file
MISSING = bytes.fromhex("deadbeefdeadbeefdeadbeefdeadbeef")  # a file that does not exist


def vint(n):
    for length in range(1, 9):
        if n < (1 << (7 * length)) - 1:
            return ((1 << (7 * length)) | n).to_bytes(length, "big")
    raise ValueError(n)


def element(id_bytes, payload):
    return id_bytes + vint(len(payload)) + payload


def uint(id_bytes, value):
    length = max(1, (value.bit_length() + 7) // 8)
    return element(id_bytes, value.to_bytes(length, "big"))


def read_vint(data, pos):
    first = data[pos]
    length = 1
    while not first & (0x80 >> (length - 1)):
        length += 1
    value = first & (0xFF >> length)
    for b in data[pos + 1:pos + length]:
        value = value << 8 | b
    return value, length


def header(data, pos):
    first = data[pos]
    id_len = 1
    while not first & (0x80 >> (id_len - 1)):
        id_len += 1
    ident = int.from_bytes(data[pos:pos + id_len], "big")
    size, size_len = read_vint(data, pos + id_len)
    return ident, id_len + size_len, size


def children(data, start, end):
    pos = start
    while pos < end:
        ident, hlen, size = header(data, pos)
        yield ident, pos, hlen, size
        pos += hlen + size


def find_segment(data):
    ident, hlen, size = header(data, 0)
    pos = hlen + size
    ident, hlen, size = header(data, pos)
    assert ident == 0x18538067
    return pos + hlen, pos + hlen + size


def set_segment_uid(data, uid):
    start, end = find_segment(data)
    for ident, pos, hlen, size in children(data, start, end):
        if ident == 0x1549A966:                               # Info
            for cid, cpos, chlen, csize in children(data, pos + hlen, pos + hlen + size):
                if cid == 0x73A4:
                    assert csize == 16
                    data[cpos + chlen:cpos + chlen + 16] = uid
                    return
    raise SystemExit("no SegmentUID")


def atom(uid_n, start_s, end_s, title, segment_uid=None):
    body = uint(b"\x73\xC4", uid_n)
    body += uint(b"\x91", int(round(start_s * 1e9))) + uint(b"\x92", int(round(end_s * 1e9)))
    body += uint(b"\x45\x98", 1)
    if segment_uid:
        body += element(b"\x6E\x67", segment_uid)
    body += element(b"\x80", element(b"\x85", title.encode()) + element(b"\x43\x7C", b"eng"))
    return element(b"\xB6", body)


def chapters(atoms, ordered=True):
    edition = uint(b"\x45\xBC", 1) + uint(b"\x45\xDB", 1) + uint(b"\x45\xDD", 1 if ordered else 0) + b"".join(atoms)
    return element(b"\x10\x43\xA7\x70", element(b"\x45\xB9", edition))


def void(total):
    """A Void element that takes exactly `total` bytes (2 or more)."""
    for size_len in range(1, 9):
        payload = total - 1 - size_len
        if payload >= 0 and payload < (1 << (7 * size_len)) - 1:
            return b"\xEC" + ((1 << (7 * size_len)) | payload).to_bytes(size_len, "big") + bytes(payload)
    raise ValueError(total)


def replace_chapters(data, new):
    start, end = find_segment(data)
    for ident, pos, hlen, size in children(data, start, end):
        if ident == 0x1043A770:
            old_total = hlen + size
            spare = old_total - len(new)
            assert spare >= 2, f"not enough room: need {len(new)}, have {old_total}"
            data[pos:pos + old_total] = new + void(spare)
            return
    raise SystemExit("no Chapters")


def build(main, atoms):
    data = bytearray(main)
    set_segment_uid(data, OWN)
    replace_chapters(data, chapters(atoms))
    return bytes(data)


main_path, linked_path, out_main, out_missing, out_linked = sys.argv[1:6]
main = open(main_path, "rb").read()
linked = bytearray(open(linked_path, "rb").read())
set_segment_uid(linked, LINKED)
open(out_linked, "wb").write(linked)

opening = atom(1, 0.0, 2.0, "Opening", LINKED)
second = atom(2, 2.0, 4.0, "Second half")
first = atom(3, 0.0, 2.0, "First half")
lost = atom(4, 0.0, 1.0, "Lost scene", MISSING)
open(out_main, "wb").write(build(main, [opening, second, first]))
open(out_missing, "wb").write(build(main, [opening, lost, second]))

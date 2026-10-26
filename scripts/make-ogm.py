#!/usr/bin/env python3
"""Writes an OGM file (Ogg container with a Xvid/MPEG-4 video stream, as DVD-rip tools made them) from the frames of an
AVI file made by our host ffmpeg, because no FFmpeg muxer writes OGM. Only used to make the test fixture.
usage: python3 -I scripts/make-ogm.py <in.avi> <out.ogm>
Layout follows libavformat/oggparseogm.c: a header packet (type 1, "video", fourcc, sizes, frame time in 100 ns units,
width, height), a comment packet (type 3), then one data packet per frame: flags byte (bit 3 = key frame, bits 6-7 =
number of duration bytes), the duration in frames, the MPEG-4 frame. One packet per page; granule position = frame index.
"""
import struct
import sys


def crc_table():
    table = []
    for i in range(256):
        r = i << 24
        for _ in range(8):
            r = ((r << 1) ^ 0x04C11DB7) & 0xFFFFFFFF if r & 0x80000000 else (r << 1) & 0xFFFFFFFF
        table.append(r)
    return table


CRC = crc_table()


def page(serial, sequence, granule, payload, flags=0):
    segments, rest = [], len(payload)
    while rest >= 255:
        segments.append(255); rest -= 255
    segments.append(rest)
    if len(segments) > 255:
        raise ValueError('packet too large for one page')
    header = b'OggS' + struct.pack('<BBqIIIB', 0, flags, granule, serial, sequence, 0, len(segments)) + bytes(segments)
    data = bytearray(header + payload)
    crc = 0
    for byte in data:
        crc = ((crc << 8) & 0xFFFFFFFF) ^ CRC[((crc >> 24) & 0xFF) ^ byte]
    struct.pack_into('<I', data, 22, crc)
    return bytes(data)


def avi_frames(path):
    """The video chunks of an AVI file, with width, height, frame rate and the FourCC."""
    data = open(path, 'rb').read()
    assert data[:4] == b'RIFF' and data[8:12] == b'AVI '
    frames, width, height, micros, fourcc = [], 0, 0, 40000, b'XVID'
    def walk(start, end):
        nonlocal width, height, micros, fourcc
        pos = start
        while pos + 8 <= end:
            tag, size = data[pos:pos + 4], struct.unpack('<I', data[pos + 4:pos + 8])[0]
            body = pos + 8
            if tag == b'LIST':
                kind = data[body:body + 4]
                if kind in (b'hdrl', b'strl', b'movi'):
                    walk(body + 4, body + size)
            elif tag == b'avih':
                micros = struct.unpack('<I', data[body:body + 4])[0]
                width, height = struct.unpack('<II', data[body + 32:body + 40])
            elif tag == b'strh' and data[body:body + 4] == b'vids':
                fourcc = data[body + 4:body + 8]
            elif tag[2:] in (b'dc', b'db') and tag[:2] == b'00':
                frames.append(data[body:body + size])
            pos = body + size + (size & 1)
    walk(12, len(data))
    return frames, width, height, micros, fourcc


def is_key(frame):
    index = frame.find(b'\x00\x00\x01\xb6')
    return index >= 0 and index + 4 < len(frame) and (frame[index + 4] >> 6) == 0


if __name__ == '__main__':
    frames, width, height, micros, fourcc = avi_frames(sys.argv[1])
    serial = 0x4F474D31
    header = b'\x01video\0\0\0' + fourcc + struct.pack('<IQQIIIII', 56, micros * 10, 1, 1, 0x100000, 0, width, height)[:0]
    header += struct.pack('<I', 56) + struct.pack('<QQ', micros * 10, 1) + struct.pack('<I', 1) + struct.pack('<II', 0x100000, 24 << 16) \
        + struct.pack('<II', width, height)
    comment = b'\x03vorbis' + struct.pack('<II', 0, 0) + b'\x01'
    out = page(serial, 0, 0, header, flags=0x02) + page(serial, 1, 0, comment)
    for number, frame in enumerate(frames):
        flags = 0x40 | (0x08 if is_key(frame) else 0)
        out += page(serial, 2 + number, number, bytes([flags, 1]) + frame, flags=0x04 if number == len(frames) - 1 else 0)
    open(sys.argv[2], 'wb').write(out)
    print('wrote %s: %d frames, %dx%d, %s' % (sys.argv[2], len(frames), width, height, fourcc.decode()))

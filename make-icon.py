#!/usr/bin/env python3
"""Assemble standard PNG-backed ICNS chunks from a generated iconset."""
import struct
import sys
from pathlib import Path
iconset, output = map(Path, sys.argv[1:])
entries = [('icp4', '16x16'), ('icp5', '32x32'), ('icp6', '32x32@2x'),
           ('ic07', '128x128'), ('ic08', '256x256'), ('ic09', '512x512'),
           ('ic10', '512x512@2x'), ('ic11', '16x16@2x'),
           ('ic12', '32x32@2x'), ('ic13', '128x128@2x'), ('ic14', '256x256@2x')]
chunks = []
for kind, suffix in entries:
    data = (iconset / f'icon_{suffix}.png').read_bytes()
    if not data.startswith(b'\x89PNG\r\n\x1a\n'):
        raise ValueError('Expected PNG image')
    # sips may add EXIF defaults: retain only pixels and color information.
    clean = data[:8]
    offset = 8
    while offset < len(data):
        length = struct.unpack('>I', data[offset:offset + 4])[0]
        if data[offset + 4:offset + 8] in {b'IHDR', b'IDAT', b'IEND', b'sRGB', b'gAMA', b'cHRM'}:
            clean += data[offset:offset + length + 12]
        offset += length + 12
    data = clean
    chunks.append(kind.encode('ascii') + struct.pack('>I', len(data) + 8) + data)
body = b''.join(chunks)
output.write_bytes(b'icns' + struct.pack('>I', len(body) + 8) + body)

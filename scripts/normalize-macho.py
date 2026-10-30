#!/usr/bin/env python3
"""Print the SHA-256 of a thin Mach-O executable with its LC_UUID zeroed.

Apple's linker writes a random LC_UUID on every link, so two builds of the
same source differ only in those 16 bytes (once the code signature is removed
with `codesign --remove-signature`). Zeroing them makes builds comparable.
Usage: normalize-macho.py <thin-unsigned-binary>
"""
import hashlib
import struct
import sys

LC_UUID = 0x1B
data = bytearray(open(sys.argv[1], "rb").read())
magic, _, _, _, ncmds, _, _, _ = struct.unpack_from("<IiiIIIII", data, 0)
if magic != 0xFEEDFACF:
    sys.exit("not a thin 64-bit Mach-O (run lipo -thin first)")
offset = 32
for _ in range(ncmds):
    cmd, size = struct.unpack_from("<II", data, offset)
    if cmd == LC_UUID:
        data[offset + 8 : offset + 24] = bytes(16)
    offset += size
print(hashlib.sha256(data).hexdigest())

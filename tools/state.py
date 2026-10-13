#!/usr/bin/env python3
"""Read RAM out of an mGBA savestate without running the emulator.

    python3 tools/state.py read STATE 0x02023716            # one byte
    python3 tools/state.py read STATE 0x02023a98 100        # hex dump
    python3 tools/state.py u32 STATE 0x03005da4             # little-endian u32 (also u16)
    python3 tools/state.py find STATE e78117972365 06e6     # where these bytes occur in EWRAM / IWRAM
    python3 tools/state.py dump STATE out.bin               # the decompressed state, for diffing

STATE is either a PNG savestate (the `gbAs` chunk) or a raw state from emu:saveStateFile.
EWRAM (0x02000000) is at offset 0x21000 of the decompressed state, IWRAM (0x03000000) at 0x19000.
"""
import struct
import sys
import zlib

REGIONS = [(0x02000000, 0x40000, 0x21000), (0x03000000, 0x8000, 0x19000)]


def load(path):
    with open(path, "rb") as f:
        data = f.read()
    if data[:8] == b"\x89PNG\r\n\x1a\n":
        i = 8
        while i < len(data):
            n, kind = struct.unpack(">I4s", data[i:i + 8])
            if kind == b"gbAs":
                return zlib.decompress(data[i + 8:i + 8 + n])
            i += 12 + n
        sys.exit(f"{path}: PNG without a gbAs chunk (re-saved by an image tool?)")
    return data


def offset(addr):
    for base, size, off in REGIONS:
        if base <= addr < base + size:
            return off + addr - base
    sys.exit(f"0x{addr:08x} is not in EWRAM or IWRAM")


def main():
    if len(sys.argv) < 3:
        sys.exit(__doc__)
    cmd, state = sys.argv[1], load(sys.argv[2])
    args = sys.argv[3:]
    if cmd == "read":
        addr, n = int(args[0], 0), int(args[1], 0) if len(args) > 1 else 1
        o = offset(addr)
        chunk = state[o:o + n]
        if n == 1:
            print(chunk[0])
        for i in range(0, len(chunk), 16) if n > 1 else []:
            print(f"{addr + i:08x}  {chunk[i:i + 16].hex(' ')}")
    elif cmd in ("u16", "u32"):
        fmt = "<H" if cmd == "u16" else "<I"
        for a in args:
            print(f"{int(a, 0):08x} = 0x{struct.unpack_from(fmt, state, offset(int(a, 0)))[0]:x}")
    elif cmd == "find":
        pat = bytes.fromhex("".join(args))
        for base, size, off in REGIONS:
            region = state[off:off + size]
            i = region.find(pat)
            while i >= 0:
                print(f"{base + i:08x}")
                i = region.find(pat, i + 1)
    elif cmd == "dump":
        with open(args[0], "wb") as f:
            f.write(state)
    else:
        sys.exit(__doc__)


if __name__ == "__main__":
    main()

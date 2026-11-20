#!/usr/bin/env python3
"""Gives the build root's programs joe's paths back, on an aarch64 build
machine (bootstrap/stage2.sh, part A).

There, the cross-compiled temporary tools run natively during their own
builds (configure's test programs, the tools a package builds and uses), so
they are linked to find bionic's dynamic linker and libraries in the build
root, ROOT/usr/lib, rather than in /usr/lib, which is this machine's. Once
they are installed, every reference to ROOT is taken out again:

  - in ELF files, the program interpreter ROOT/usr/lib/ld-bionic-aarch64.so.1
    becomes /usr/lib/ld-bionic-aarch64.so.1, and ROOT/usr/lib in a run path
    becomes /usr/lib. The new strings are shorter and are written in place,
    padded with NULs, so nothing else in the file moves;
  - in other files (pkg-config files, libtool archives, *-config scripts),
    the link flags themselves are removed.

A file that still has one of the flags, or the interpreter's path in ROOT,
is listed and the script fails.

    joe-paths.py ROOT INTERP FLAG...

INTERP: joe's program interpreter (/usr/lib/ld-bionic-aarch64.so.1); FLAG:
the exact link flags that were added (stage2.sh's LDFLAGS words).
"""

import os
import struct
import sys

PT_DYNAMIC, PT_INTERP, PT_LOAD = 2, 3, 1
DT_NULL, DT_STRTAB, DT_RPATH, DT_RUNPATH = 0, 5, 15, 29
EM_AARCH64 = 183
SKIP = ("usr/lib/joe-cross", "build", "sources", "proc", "sys", "dev", "run", "tmp")


def elf_paths(data, prefix):
    """The (offset, old, new) string rewrites of an ELF64 little-endian file."""
    if data[:4] != b"\x7fELF" or data[4] != 2 or data[5] != 1:
        return None
    (machine,) = struct.unpack_from("<H", data, 0x12)
    if machine != EM_AARCH64:
        return []
    (phoff,) = struct.unpack_from("<Q", data, 0x20)
    phentsize, phnum = struct.unpack_from("<HH", data, 0x36)
    segments = [struct.unpack_from("<IIQQQQQQ", data, phoff + i * phentsize) for i in range(phnum)]

    def file_offset(vaddr):
        for p_type, _, offset, va, _, filesz, _, _ in segments:
            if p_type == PT_LOAD and va <= vaddr < va + filesz:
                return vaddr - va + offset
        return None

    def under_prefix(path):
        return path[len(prefix):] if path.startswith(prefix + b"/") else path

    edits = []
    for p_type, _, offset, _, _, filesz, _, _ in segments:
        if p_type == PT_INTERP:
            old = data[offset:offset + filesz].split(b"\0", 1)[0]
            new = under_prefix(old)
            if new != old:
                edits.append((offset, old, new))
        elif p_type == PT_DYNAMIC:
            entries = [struct.unpack_from("<qQ", data, offset + i) for i in range(0, filesz - 15, 16)]
            strtab = next((value for tag, value in entries if tag == DT_STRTAB), None)
            base = file_offset(strtab) if strtab is not None else None
            for tag, value in entries:
                if tag == DT_NULL:
                    break
                if tag in (DT_RPATH, DT_RUNPATH) and base is not None:
                    start = base + value
                    old = data[start:data.index(b"\0", start)]
                    new = b":".join(under_prefix(p) for p in old.split(b":"))
                    if new != old:
                        edits.append((start, old, new))
    return edits


def main():
    root = os.path.abspath(sys.argv[1])  # as the flags spell it, not resolved
    interp = sys.argv[2].encode()
    flags = [f.encode() for f in sys.argv[3:]]
    prefix = root.encode()
    added = flags + [prefix + interp]
    left = []
    for top, dirs, files in os.walk(root):
        rel = os.path.relpath(top, root)
        if rel == ".":
            dirs[:] = [d for d in dirs if d not in SKIP]
        elif rel == "usr/lib":
            dirs[:] = [d for d in dirs if d != "joe-cross"]
        for name in files:
            path = os.path.join(top, name)
            if os.path.islink(path) or not os.path.isfile(path):
                continue
            with open(path, "rb") as f:
                data = f.read()
            if prefix not in data:
                continue
            edits = elf_paths(data, prefix)
            out = bytearray(data)
            if edits is None:  # not ELF: drop the flags, with the space before them
                for flag in flags:
                    out = out.replace(b" " + flag, b"").replace(flag, b"")
            else:
                for offset, old, new in edits:
                    out[offset:offset + len(old)] = new + b"\0" * (len(old) - len(new))
            if out != data:
                mode = os.stat(path).st_mode
                os.chmod(path, mode | 0o200)
                with open(path, "r+b") as f:  # in place: hard links stay linked
                    f.write(out)
                    f.truncate()
                os.chmod(path, mode)
            if any(a in out for a in added):
                left.append(os.path.relpath(path, root))
    if left:
        print("joe-paths.py: these files still have the build machine's paths:", file=sys.stderr)
        for path in left:
            print("  " + path, file=sys.stderr)
        sys.exit(1)


if __name__ == "__main__":
    main()

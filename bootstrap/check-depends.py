#!/usr/bin/env python3
"""Check that every package installed in the build root depends on the
packages that provide the shared libraries its programs and libraries need.

dave installs what a package's package.zon names, not what its ELF files ask
for, and the recipes come from joe Linux, where glibc provides libraries that
bionic does not (libintl): a dependency left out shows only on a system that
lacks the other package, an image or an initramfs. Packages built but not
installed (build-only in packages/ORDER) are not checked.

Usage: check-depends.py [TOP]   (TOP: this repository; by default, the one
this script is in). Exits 1 and names each missing dependency."""

import pathlib
import re
import subprocess
import sys

top = pathlib.Path(sys.argv[1] if len(sys.argv) > 1 else pathlib.Path(__file__).resolve().parent.parent)
root = top / "build/bootstrap/root"
dave = top / "dave/zig-out/bin/dave"
readelf = root / "usr/lib/joe-cross/bin/llvm-readelf"

depends = {}
for zon in (top / "packages").glob("*/package.zon"):
    text = zon.read_text()
    name = re.search(r'^\s*\.name\s*=\s*"([^"]+)"', text, re.M).group(1)
    m = re.search(r"^\s*\.depends\s*=\s*\.\{(.*?)\}", text, re.M | re.S)
    depends[name] = re.findall(r'"([^"]+)"', m.group(1)) if m else []


def dave_lines(*args):
    out = subprocess.run([str(dave), "--root", str(root), *args], check=True, capture_output=True, text=True)
    return out.stdout.splitlines()


installed = [line.split()[0] for line in dave_lines("list") if line.strip()]
provides = {}  # soname (or file name, for a library without one) -> package
needs = {}  # package -> {soname: first file that needs it}
for package in installed:
    for path in dave_lines("files", package):
        f = root / path.lstrip("/")
        if path.endswith("/") or f.is_symlink() or not f.is_file():
            continue
        with open(f, "rb") as fh:
            if fh.read(4) != b"\x7fELF":
                continue
        out = subprocess.run([str(readelf), "-dW", str(f)], capture_output=True, text=True).stdout
        entries = re.findall(r"\((NEEDED|SONAME)\)\s+\S+ \S+: \[([^\]]+)\]", out)
        sonames = [lib for kind, lib in entries if kind == "SONAME"]
        for lib in sonames or ([f.name] if ".so" in f.name else []):
            provides.setdefault(lib, package)
        for kind, lib in entries:
            if kind == "NEEDED":
                needs.setdefault(package, {}).setdefault(lib, path)


def closure(name, seen):
    if name not in seen:
        seen.add(name)
        for d in depends.get(name, []):
            closure(d, seen)
    return seen


missing = 0
for package in sorted(needs):
    have = closure(package, set())
    for lib, path in sorted(needs[package].items()):
        provider = provides.get(lib)
        if provider is None:
            print(f"{package}: {path} needs {lib}, which no installed package provides")
            missing += 1
        elif provider not in have:
            print(f"{package}: {path} needs {lib}, from {provider}, which {package} does not depend on")
            missing += 1
sys.exit(1 if missing else 0)

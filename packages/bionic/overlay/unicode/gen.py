#!/usr/bin/env python3
"""Generate icu4x.c: bionic's Unicode character properties, in C.

    gen.py UCD.zip > icu4x.c

bionic answers iswalpha(), towupper(), wcwidth() and the rest above ASCII by
calling the 15 functions of libc/private/icu4x.h, which upstream implements
in Rust on top of the ICU4X crates. joe Linux implements them in C, with
tables generated here from the Unicode Character Database, so that the C
library can be built before there is a Rust compiler for it. The answers
are those of the ICU4X properties the Rust wrapper uses:

  general category, East Asian width, Hangul syllable type   (maps)
  Alphabetic, Default_Ignorable_Code_Point, Lowercase,
  Uppercase, White_Space                                     (UCD properties)
  alnum, blank, graph, print, xdigit                         (UTS #18 Annex C)
  simple upper- and lowercase mappings

Each table is a sorted array of ranges searched by bisection.
"""

import re
import sys
import zipfile

MAX = 0x110000

# ICU's UCharCategory numbering, which ICU4X's GeneralCategory shares.
GC = {
    "Cn": 0, "Lu": 1, "Ll": 2, "Lt": 3, "Lm": 4, "Lo": 5, "Mn": 6, "Me": 7, "Mc": 8,
    "Nd": 9, "Nl": 10, "No": 11, "Zs": 12, "Zl": 13, "Zp": 14, "Cc": 15, "Cf": 16,
    "Co": 17, "Cs": 18, "Pd": 19, "Ps": 20, "Pe": 21, "Pc": 22, "Po": 23, "Sm": 24,
    "Sc": 25, "Sk": 26, "So": 27, "Pi": 28, "Pf": 29,
}
# Short and long value names: @missing lines use the long ones.
EAW = {"N": 0, "A": 1, "H": 2, "F": 3, "Na": 4, "W": 5,
       "Neutral": 0, "Ambiguous": 1, "Halfwidth": 2, "Fullwidth": 3, "Narrow": 4, "Wide": 5}
HST = {"NA": 0, "L": 1, "V": 2, "T": 3, "LV": 4, "LVT": 5,
       "Not_Applicable": 0, "Leading_Jamo": 1, "Vowel_Jamo": 2, "Trailing_Jamo": 3,
       "LV_Syllable": 4, "LVT_Syllable": 5}


def records(text):
    """(first, last, fields) for each data line of a UCD file."""
    for line in text.splitlines():
        line = line.split("#", 1)[0].strip()
        if not line:
            continue
        fields = [f.strip() for f in line.split(";")]
        r = fields[0].split("..")
        yield int(r[0], 16), int(r[-1], 16), fields[1:]


def missing(text):
    """The @missing defaults of a UCD file, in order."""
    for m in re.finditer(r"^# @missing: ([0-9A-F]+)\.\.([0-9A-F]+); (\S+)", text, re.M):
        yield int(m.group(1), 16), int(m.group(2), 16), m.group(3)


def unicode_data(text):
    """General category and simple case mappings from UnicodeData.txt,
    whose ranges are written as <..., First> and <..., Last> pairs."""
    gc = [0] * MAX
    upper, lower = {}, {}
    first = None
    for line in text.splitlines():
        f = line.split(";")
        cp = int(f[0], 16)
        if f[1].endswith(", First>"):
            first = cp
            continue
        start = first if f[1].endswith(", Last>") else cp
        first = None
        for c in range(start, cp + 1):
            gc[c] = GC[f[2]]
        if f[12]:
            upper[cp] = int(f[12], 16)
        if f[13]:
            lower[cp] = int(f[13], 16)
    return gc, upper, lower


def binary_props(text, names):
    sets = {n: bytearray(MAX) for n in names}
    for a, b, (prop, *_) in records(text):
        if prop in sets:
            for c in range(a, b + 1):
                sets[prop][c] = 1
    return sets


def map_prop(text, values, default):
    out = [values[default]] * MAX
    for a, b, v in missing(text):
        for c in range(a, b + 1):
            out[c] = values[v]
    for a, b, (v, *_) in records(text):
        for c in range(a, b + 1):
            out[c] = values[v]
    return out


def ranges(pred):
    out, start = [], None
    for c in range(MAX):
        if pred(c):
            if start is None:
                start = c
        elif start is not None:
            out.append((start, c - 1))
            start = None
    if start is not None:
        out.append((start, MAX - 1))
    return out


def value_ranges(values, skip):
    out, c = [], 0
    while c < MAX:
        v = values[c]
        e = c
        while e + 1 < MAX and values[e + 1] == v:
            e += 1
        if v != skip:
            out.append((c, e, v))
        c = e + 1
    return out


def main():
    z = zipfile.ZipFile(sys.argv[1])
    read = lambda n: z.read(n).decode("utf-8")
    gc, upper, lower = unicode_data(read("UnicodeData.txt"))
    core = binary_props(read("DerivedCoreProperties.txt"),
                        ["Alphabetic", "Default_Ignorable_Code_Point", "Lowercase", "Uppercase"])
    plist = binary_props(read("PropList.txt"), ["White_Space", "Hex_Digit"])
    eaw = map_prop(read("EastAsianWidth.txt"), EAW, "N")
    hst = map_prop(read("HangulSyllableType.txt"), HST, "NA")

    ws, alpha, hexd = plist["White_Space"], core["Alphabetic"], plist["Hex_Digit"]
    cntrl = lambda c: gc[c] == GC["Cc"]
    # UTS #18 Annex C, as ICU and ICU4X define the POSIX classes.
    alnum = lambda c: alpha[c] or gc[c] == GC["Nd"]
    blank = lambda c: ws[c] and c not in (0x0A, 0x0B, 0x0C, 0x0D, 0x85) and gc[c] not in (GC["Zl"], GC["Zp"])
    graph = lambda c: not ws[c] and gc[c] not in (GC["Cc"], GC["Cs"], GC["Cn"])
    print_ = lambda c: (graph(c) or blank(c)) and not cntrl(c)
    xdigit = lambda c: gc[c] == GC["Nd"] or hexd[c]

    sets = [
        ("alphabetic", lambda c: alpha[c]),
        ("default_ignorable_code_point", lambda c: core["Default_Ignorable_Code_Point"][c]),
        ("lowercase", lambda c: core["Lowercase"][c]),
        ("uppercase", lambda c: core["Uppercase"][c]),
        ("white_space", lambda c: ws[c]),
        ("alnum", alnum), ("blank", blank), ("graph", graph), ("print", print_), ("xdigit", xdigit),
    ]
    maps = [("general_category", gc, 0), ("east_asian_width", eaw, 0), ("hangul_syllable_type", hst, 0)]

    w = sys.stdout.write
    w("/* Generated by joe Linux's packages/bionic/overlay/unicode/gen.py from the\n"
      " * Unicode Character Database (" + read("ReadMe.txt").splitlines()[1].lstrip("# ") + ").\n"
      " * Do not edit. */\n\n"
      "#include <stdbool.h>\n#include <stddef.h>\n#include <stdint.h>\n\n"
      "struct range { uint32_t first, last; };\n"
      "struct vrange { uint32_t first, last; uint8_t value; };\n"
      "struct pair { uint32_t from, to; };\n\n"
      "static bool in(const struct range* r, size_t n, uint32_t c) {\n"
      "  size_t lo = 0, hi = n;\n"
      "  while (lo < hi) {\n"
      "    size_t mid = lo + (hi - lo) / 2;\n"
      "    if (c < r[mid].first) hi = mid;\n"
      "    else if (c > r[mid].last) lo = mid + 1;\n"
      "    else return true;\n"
      "  }\n"
      "  return false;\n"
      "}\n\n"
      "static uint8_t lookup(const struct vrange* r, size_t n, uint32_t c, uint8_t missing) {\n"
      "  size_t lo = 0, hi = n;\n"
      "  while (lo < hi) {\n"
      "    size_t mid = lo + (hi - lo) / 2;\n"
      "    if (c < r[mid].first) hi = mid;\n"
      "    else if (c > r[mid].last) lo = mid + 1;\n"
      "    else return r[mid].value;\n"
      "  }\n"
      "  return missing;\n"
      "}\n\n"
      "static uint32_t mapped(const struct pair* p, size_t n, uint32_t c) {\n"
      "  size_t lo = 0, hi = n;\n"
      "  while (lo < hi) {\n"
      "    size_t mid = lo + (hi - lo) / 2;\n"
      "    if (c < p[mid].from) hi = mid;\n"
      "    else if (c > p[mid].from) lo = mid + 1;\n"
      "    else return p[mid].to;\n"
      "  }\n"
      "  return c;\n"
      "}\n\n")
    for name, pred in sets:
        rs = ranges(pred)
        w(f"static const struct range {name}_ranges[] = {{\n")
        for a, b in rs:
            w(f"  {{0x{a:04x}, 0x{b:04x}}},\n")
        w("};\n\n")
        w(f"bool __icu4x_bionic_is_{name}(uint32_t c) {{\n"
          f"  return in({name}_ranges, sizeof({name}_ranges) / sizeof({name}_ranges[0]), c);\n}}\n\n")
    for name, values, skip in maps:
        rs = value_ranges(values, skip)
        w(f"static const struct vrange {name}_ranges[] = {{\n")
        for a, b, v in rs:
            w(f"  {{0x{a:04x}, 0x{b:04x}, {v}}},\n")
        w("};\n\n")
        w(f"uint8_t __icu4x_bionic_{name}(uint32_t c) {{\n"
          f"  return lookup({name}_ranges, sizeof({name}_ranges) / sizeof({name}_ranges[0]), c, {skip});\n}}\n\n")
    for name, table in (("upper", upper), ("lower", lower)):
        w(f"static const struct pair to_{name}_pairs[] = {{\n")
        for a in sorted(table):
            w(f"  {{0x{a:04x}, 0x{table[a]:04x}}},\n")
        w("};\n\n")
        w(f"uint32_t __icu4x_bionic_to_{name}(uint32_t c) {{\n"
          f"  return mapped(to_{name}_pairs, sizeof(to_{name}_pairs) / sizeof(to_{name}_pairs[0]), c);\n}}\n\n")


if __name__ == "__main__":
    main()

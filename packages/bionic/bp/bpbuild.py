#!/usr/bin/env python3
"""Write a ninja file that builds Soong modules for joe Linux.

    bpbuild.py --tree AOSP --out DIR [--overlay FILE]... PRODUCT...

PRODUCT is NAME:static, NAME:shared, or NAME (a binary, cc_object or
genrule). The toolchain is taken from the environment (see joe.py). The
ninja file is DIR/build.ninja; `bpbuild.py --print PRODUCT` prints where a
product will be instead of writing anything.
"""

import argparse
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import joe  # noqa: E402
from ninja import Ninja  # noqa: E402
from soong import Config, EvalError, Tree  # noqa: E402


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--tree", required=True)
    ap.add_argument("--out", required=True)
    ap.add_argument("--overlay", action="append", default=[])
    ap.add_argument("--release-flag", action="append", default=[], metavar="NAME=VALUE")
    ap.add_argument("--print", action="store_true", help="print each product's path")
    ap.add_argument("products", nargs="+")
    args = ap.parse_args()

    flags = {}
    for kv in args.release_flag:
        k, _, v = kv.partition("=")
        flags[k] = {"true": True, "false": False}.get(v, v)
    try:
        config = Config(release_flags=flags, product_variables=joe.PRODUCT_VARIABLES)
        tree = Tree(args.tree, config, subdirs=joe.SUBDIRS, overlays=args.overlay)
        n = Ninja(tree, args.out, joe.toolchain(os.environ))
        products = [n.product(p) for p in args.products]
    except EvalError as e:
        print(f"bpbuild: {e}", file=sys.stderr)
        return 1
    if args.print:
        for spec, path in zip(args.products, products):
            print(spec, path)
        return 0
    os.makedirs(args.out, exist_ok=True)
    n.write(os.path.join(args.out, "build.ninja"), products)
    return 0


if __name__ == "__main__":
    sys.exit(main())

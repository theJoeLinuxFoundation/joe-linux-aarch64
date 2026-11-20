#!/usr/bin/env python3
"""Prints the order in which to build every recipe in packages/.

The base system keeps the hand-written order of packages/ORDER, because its
packages replace the bootstrap's temporary tools in a sequence that
dependencies alone do not express. Every other recipe follows, ordered so
that each comes after everything it lists in `depends` and `build_depends`.

Each output line is `name` or `name build-only`.

    order.py                 every recipe
    order.py NAME...         only these, in build order
"""
import os
import re
import sys

top = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
packages = os.path.join(top, "packages")


def strings(block):
    return [re.split(r"[ <>=]", s)[0] for s in re.findall(r'"([^"]+)"', block)]


# Recipes that say `.build_only = true`: built, but not installed into the
# build root.
build_only = set()


def read(name):
    text = open(os.path.join(packages, name, "package.zon")).read()
    text = re.sub(r"//.*", "", text)
    deps = []
    for field in ("depends", "build_depends"):
        m = re.search(r"\.%s = \.\{(.*?)\}" % field, text, re.S)
        if m:
            deps += strings(m.group(1))
    if re.search(r"\.build_only = true", text):
        build_only.add(name)
    return deps


base = []
for line in open(os.path.join(packages, "ORDER")):
    line = line.strip()
    if line and not line.startswith("#"):
        base.append(line)
base_names = {line.split()[0] for line in base}

recipes = sorted(
    d for d in os.listdir(packages)
    if os.path.exists(os.path.join(packages, d, "package.zon"))
)
deps = {name: read(name) for name in recipes}

# With package names on the command line, only those packages and what they
# need are considered, so an unfinished recipe elsewhere does not get in the way.
wanted = set(sys.argv[1:])
if wanted:
    closure = set()

    def need(name):
        if name in closure or name not in deps:
            return
        closure.add(name)
        for d in deps[name]:
            need(d)

    for name in wanted:
        if name not in deps:
            print(f"order: no recipe for {name}", file=sys.stderr)
            sys.exit(1)
        need(name)
    recipes = [n for n in recipes if n in closure]

problems = []
for name in recipes:
    for d in deps[name]:
        if d not in deps:
            problems.append(f"{name} depends on {d}, which has no recipe")

rest = [n for n in recipes if n not in base_names]
done = set(base_names)
ordered = []
state = {}


def visit(name, trail):
    if name in done:
        return
    if state.get(name) == "visiting":
        cycle = trail[trail.index(name):] + [name]
        problems.append("dependency cycle: " + " -> ".join(cycle))
        return
    state[name] = "visiting"
    for d in deps.get(name, []):
        if d in deps:
            visit(d, trail + [name])
    done.add(name)
    ordered.append(name)


for name in rest:
    visit(name, [])

if problems:
    for p in sorted(set(problems)):
        print("order: " + p, file=sys.stderr)
    sys.exit(1)

# The image-defining packages are built last, so they can depend on anything.
last = [l for l in base if l.split()[0] in ("joe-filesystem", "dave", "joe-base")]
ordered = [n + " build-only" if n in build_only else n for n in ordered]
lines = [l for l in base if l not in last] + ordered + last
if wanted:
    lines = [l for l in lines if l.split()[0] in wanted]
print("\n".join(lines))

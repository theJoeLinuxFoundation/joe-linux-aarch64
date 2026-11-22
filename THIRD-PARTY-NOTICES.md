# Third-party notices

joe Linux ARM's own files are under the MIT License in [LICENSE](LICENSE).
This file lists what is not, or not only, covered by it: files in this
repository that carry another licence, work this repository is derived from,
and the software that joe Linux ARM builds but does not contain.

## Files in this repository under another licence

| Files | Licence | Why |
|-------|---------|-----|
| `packages/linux/joe-lsm/joe.c`, `Kconfig`, `Makefile` | GPL-2.0-only | The joe security module is compiled into the Linux kernel. Each file states its licence in an SPDX line. |
| `packages/bash/joe-sealed-scripts.patch` | GPL-3.0-or-later | A change to GNU Bash, Copyright © Free Software Foundation, Inc. |
| `packages/python/joe-sealed-code.patch` | PSF-2.0 | A change to CPython, Copyright © Python Software Foundation. |
| `packages/bionic/patches/*.patch` | bionic's licences | Changes to bionic, the C library of the Android Open Source Project. bionic's files are under BSD-style licences, each stated in the file and collected in AOSP bionic's `NOTICE` file. |
| The other `packages/*/*.patch` | their programs' licences | Changes to the programs named by their directories (fuse3, libbsd, mosquitto, socat, valkey). |

The patches contain lines of the programs they change and are distributed
under those programs' licences. The licence texts are in
[LICENSES/](LICENSES/) and [LICENSE](LICENSE), and those of the patched
programs in their sources.

## bionic and its build

The C library is built from AOSP's sources (android-17.0.0_r1), named by
commit in `packages/bionic/aosp.list` and `bootstrap/sources`.
`packages/bionic/bp/` is a small evaluator of AOSP's `Android.bp` files that
reimplements, in Python, what bionic's build needs of Soong, AOSP's build
system (Apache-2.0). It contains no source code of Soong; the compiler flags
in `bp/joe.py` are Soong's for an arm64 device, from the files that module
names. `packages/bionic/overlay/` holds joe's replacements for the parts of
AOSP that joe does not build.

## Linux From Scratch and Beyond Linux From Scratch

The bootstrap's temporary tools (`bootstrap/stage2.sh`) and many recipes
(`packages/*/build.sh`, `packages/*/package.zon`) follow the build
instructions of [Linux From Scratch](https://www.linuxfromscratch.org/lfs/)
and [Beyond Linux From Scratch](https://www.linuxfromscratch.org/blfs/), as
joe Linux's do. Both books allow their computer instructions to be extracted
under the MIT License:

> Copyright © 1999-2026 Gerard Beekmans (Linux From Scratch)
>
> Copyright © 1999-2026 The BLFS Development Team (Beyond Linux From Scratch)
>
> Permission is hereby granted, free of charge, to any person obtaining a copy
> of this software and associated documentation files (the "Software"), to deal
> in the Software without restriction, including without limitation the rights
> to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
> copies of the Software, and to permit persons to whom the Software is
> furnished to do so, subject to the following conditions:
>
> The above copyright notice and this permission notice shall be included in
> all copies or substantial portions of the Software.
>
> THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
> IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
> FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
> AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
> LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
> OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
> SOFTWARE.

The text of the books is under a Creative Commons licence and is not
reproduced here.

## PubGrub

dave's solver (`dave/src/solver/`), copied from joe Linux, implements the
PubGrub algorithm in Zig, after Natalie Weizenbaum's description in
[dart-lang/pub](https://github.com/dart-lang/pub/blob/master/doc/solver.md)
and the structure of
[pubgrub-rs](https://github.com/pubgrub-rs/pubgrub). It contains no source
code of either project.

## Software that joe Linux ARM builds

This repository contains no source code or binaries of the packages it builds
(bionic's sources are fetched from AOSP when it is built). Each recipe names
its sources by URL and SHA-256, and they are downloaded when the package is
built. No recipe fetches anything else while it builds.

Every recipe states its package's licence as an SPDX expression in the
`.license` field of `packages/NAME/package.zon`. To list them:

```
grep -H '\.license' packages/*/package.zon
```

The installation medium and the repository contain those packages, each
under its own licence. Distributors must meet the terms of the packages they
distribute: for the GPL and LGPL packages, among them the Linux kernel, that
includes providing the corresponding source. The source archive of every
published package is published beside the medium, at
[joelinux.io/sources/](https://joelinux.io/sources/).

## Trademarks

Linux is a registered trademark of Linus Torvalds. Android is a trademark of
Google LLC. Arm is a registered trademark of Arm Limited. Other names belong
to their owners. joe Linux ARM is not affiliated with or endorsed by any of
these projects.

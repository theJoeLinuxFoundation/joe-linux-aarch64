# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

joe Linux ARM is joe Linux (https://github.com/theJoeLinuxFoundation/joe-linux, checked out beside this repository as `../joe-linux`) for 64-bit Arm servers: console only, on bionic (Android's C library, from AOSP android-17.0.0_r1), with dynamod (the user's own init system, https://github.com/sinisterMage/dynamod; its port is branch `aarch64-bionic` of https://github.com/theJoeLinuxFoundation/dynamod, checked out as `../dynamod` or wherever `JOE_DYNAMOD` points) instead of systemd. dave (`dave/`) and the joe security module (`packages/linux/joe-lsm/`) were copied from joe-linux; read joe-linux's CLAUDE.md for how they work. Everything else is being rebuilt for bionic and LLVM. README.md explains the design.

## Hard constraints

- **Nothing runs as root on the host, and sudo is not available.** Build roots are entered with `bwrap` in a user namespace; anything that truly needs root runs in QEMU.
- **The target is aarch64; the build machine is x86_64 or aarch64** (`JOE_HOST_ARCH` in `bootstrap/lib.sh`). On x86_64, aarch64 programs run through qemu-user registered with binfmt_misc (`F` flag), including inside bwrap, and KVM cannot run aarch64 guests: VMs use TCG and are slow. On aarch64 they run natively; stage 2's cross-compiled tools are linked to find bionic in the build root during their builds, and `bootstrap/joe-paths.py` puts joe's paths back. An aarch64 machine builds much faster; without KVM (a cloud instance that is not bare metal) its VMs use TCG too.
- **Zig 0.17.1** for dave and dynamod-init (see joe-linux's CLAUDE.md for its traps).
- **Toolchain:** LLVM only (clang, lld, compiler-rt, libunwind, libc++). The target triple is `aarch64-unknown-linux-android37`; clang is patched to write `/usr/lib/ld-bionic-aarch64.so.1` as the program interpreter. clang defines `__ANDROID__`, so upstream code takes its bionic paths.
- **Configure scripts are told the system is `aarch64-unknown-linux-android`** (the driver's `CONFIG_SITE`), as config.guess says: gnulib's m4 recognises bionic by `*-android*` and compiles the workarounds (setlocale-fixes, ...) its C code calls under `__ANDROID__`; telling it linux-gnu breaks links (gettext's `setlocale_fixed_null`) or silently drops fixes. Two exceptions: libtool's Android case (no versioned sonames, Android app packaging) is renamed out of every configure by the driver (`libtool_as_linux`), so libtool uses its GNU/Linux case; Python's recipe sets `ac_cv_host`/`ac_cv_build` to linux-gnu (its Android mode builds an app's Python). `--host` does not override the cached host; set `ac_cv_host`. The stage-2 temporary tools are told the same (`build/bootstrap/root/usr/share/joe/config.site`, written by stage2.sh), without the libtool change.
- Fix bionic incompatibilities in bionic (a patch in `packages/bionic/patches/`) when bionic is what differs from a Linux C library, rather than patching each package.
- `build/` must be on btrfs. All generated state lives there and is git-ignored.

## Commands

```
make host-tools        ninja, cmake into build/host-tools
make stage1            bootstrap/stage1.sh: LLVM, bionic, compiler-rt, libunwind, libc++, the dynamic linker
make stage2            bootstrap/stage2.sh: temporary tools (cross-compiled, then built inside the build root)
bootstrap/enter.sh CMD run a command inside the build root
```

Bootstrap steps leave markers in `build/bootstrap/done/`; delete a marker to redo a step (and the ones after it that depend on it). Logs: `build/bootstrap/logs/STEP.log`. Sources are pinned in `bootstrap/sources` (`FILE SHA256 URL`; `git+URL#COMMIT` for AOSP, made with `git archive` because AOSP's own archives differ on every download). `JOE_SOURCE_CACHE=PATH/joe-linux/build/src` reuses joe-linux's downloads.

## dave

dave (`dave/`) is joe-linux's, with two changes for this repository: `-Darch=x86_64|aarch64` (default: the architecture compiled for) names the architecture of the systems it manages (`src/arch.zig` holds everything derived from it; packages and repositories of another architecture are refused), and its boot integration is dynamod's instead of systemd's (`boot-check` blesses the boot entry itself, gated on the `LoaderBootCountPath` EFI variable; `boot-watchdog` replaces boot-complete.target's timeout; `reboot` replaces `systemctl reboot`). Its dynamod services are in `system/*.toml`. Build and test with `-Darch=aarch64`: `cd dave && zig build -Doptimize=ReleaseSafe -Darch=aarch64`, `zig build test -Darch=aarch64 [-Dtest-filter=NAME]` (plain `zig test src/main.zig` does not work: the build options module is needed). `bootstrap/build-packages.sh` builds both the host copy and the aarch64 one the dave package ships.

## bionic (`packages/bionic/`)

- `bp/` is a small Soong: `blueprint.py` parses Android.bp, `soong.py` evaluates modules for an arm64 device (defaults, arch/target blocks, static/shared variants, exports), `ninja.py` writes the build, `joe.py` holds the flags (Soong's, from build/soong/cc/config) and toolchain, `bpbuild.py` is the command line. It implements only what bionic and its few AOSP dependencies use. When a build fails because of the evaluator, compare with Soong's source (build/soong in an AOSP checkout) rather than guessing: flags are shell-escaped like blueprint's ShellEscape (spaces split words), whole_static_libs re-export headers, commonGlobalIncludes go on every platform module.
- `bionic.sh` (sourced by stage1.sh and, later, the recipe) assembles the tree from `aosp.list`, applies `patches/`, adds `overlay/` at `joe/`, and generates the Unicode tables.
- Patches are made from a git checkout of AOSP bionic with the previous patches applied, one topic per patch, numbered in order; check that the series reproduces the edited tree exactly.

## Git

- Commit messages: `area: imperative summary`, lowercase, no trailing period.
- Never add `Co-Authored-By`, `Generated-with`, `Assisted-by` or any similar trailer.
- The author line is the human who committed it.

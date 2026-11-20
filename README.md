# joe Linux ARM

joe Linux for 64-bit Arm servers. It is a console system built on **bionic**,
Android's C library, and an **LLVM** toolchain, with
[dynamod](https://github.com/theJoeLinuxFoundation/dynamod) as its init
system.

It keeps what is original about [joe Linux](https://github.com/theJoeLinuxFoundation/joe-linux):

- **Transactional upgrades on a root that is not immutable.** An upgrade is
  applied to a btrfs snapshot and takes effect on the next boot. If the new
  system does not boot, the machine goes back to the previous one by itself.
- **dave**, the package manager built around that model.
- **A security model for root.** A privileged process runs only code the
  distribution has signed. One kernel security module enforces it.

Everything under those is new:

| | joe Linux | joe Linux ARM |
|-|-----------|---------------|
| Processors | x86_64 | aarch64 (ARMv8.0 and later; UEFI, with ACPI or a device tree) |
| C library | glibc | bionic from AOSP (android-17.0.0_r1), adapted to an ordinary Linux system |
| Toolchain | GCC and binutils | LLVM only: clang, lld, compiler-rt, libunwind, libc++ |
| Init | systemd | dynamod, with dave's boot integration ported to it |
| Boot loader | systemd-boot | systemd-boot, built on its own |
| Desktop | GNOME | none: console only |

The userland is GNU, as in joe Linux, so the system is ordinary to use: bash,
coreutils, util-linux, Linux-PAM, shadow, OpenSSH, doas, vim and nano.

> **Status: work in progress, not usable yet.** The goal of the first
> milestone is a bootable UEFI install medium: an ISO that boots an Arm server
> (or QEMU) from a CD or a USB stick into a live console system, from which
> `dave install-system` installs joe onto a disk.

## Where it stands

Done:

- **The toolchain.** It builds reproducibly from pinned sources: LLVM 23,
  bionic, compiler-rt, libunwind and libc++. A C++ program that throws, starts
  threads and loads libraries runs on joe's dynamic linker.
- **A Rust cross compiler for bionic**, which dynamod's service manager needs.
- **The temporary tools** (following Linux From Scratch's chapters 6 and 7),
  and the build root they make.
- **dave for aarch64**, with its boot integration moved from systemd to
  dynamod.
- **dynamod**, ported to aarch64 and bionic. Its PID 1 is in Zig, its service
  manager in Rust.
- **The kernel** (Linux 7.3 with the joe security module) and **systemd-boot**
  both build, and the kernel boots.

In progress: building the base system's packages (about 90) against bionic.
Each build failure caused by bionic is fixed in bionic itself, as a patch,
rather than in every package. After that: the live ISO, and installing from
it.

## bionic as a Linux C library

bionic is built from AOSP's sources, using AOSP's own build descriptions.
`packages/bionic/bp/` evaluates the `Android.bp` files the way Soong (AOSP's
build system) does for an arm64 device and writes a ninja file. The C library
therefore gets exactly the sources and flags Android builds it with, and
nothing else of AOSP's build is needed.

What turns it from Android's C library into a Linux one is in
`packages/bionic/patches/`, one topic per patch:

- accounts come from `/etc/passwd` and `/etc/group`, with group members and
  supplementary groups (Android uses fixed and per-app ids), and from
  `/etc/shadow`, through `<shadow.h>`;
- time zones come from `/usr/share/zoneinfo` and `/etc/localtime` (Android
  uses one packed file and a system property);
- the resolver reads `/etc/resolv.conf`, and the host databases are in `/etc`
  (Android uses netd and `/system/etc`);
- `/bin/sh`, `/tmp` and a Linux `PATH`; `syslog(3)` writes to `/dev/log`
  (Android uses logd);
- the dynamic linker is `/usr/lib/ld-bionic-aarch64.so.1` and searches
  `/usr/lib` and `/usr/local/lib`;
- the libraries loaded with a program are in the global symbol scope, as in
  glibc, so that plugins (perl and Python modules, PAM modules) find their
  host's symbols. Android's scope is the executable alone;
- POSIX shared memory (`shm_open`, as files in `/dev/shm`) and message queues
  (`<mqueue.h>`), which Android has no use for;
- wrappers for the Linux system calls Android does not allow apps: fanotify,
  file handles (`name_to_handle_at`) and `cachestat`;
- GNU and BSD interfaces that programs written for Linux use without checking
  for them: `strverscmp` and `versionsort`, `strftime_z`, `ushort`,
  `MAXNAMLEN`, the rest of `<paths.h>`, IPv6 address macros that take any
  pointer, and `faccessat` with `AT_EACCESS`;
- functions the headers declare under another name are also exported under
  their own, so that configure scripts' link tests tell the truth;
- `<sched.h>` gives programs the kernel's constants without
  `struct clone_args`, whose member names collide with programs' macros.

Beside libc, bionic's package also carries:
- **`liblog`**, Android's logging library, for programs written for Android
  (Rust's standard library links it). joe's writes to standard error.
- **Empty `libpthread`, `librt`, `libutil`, `libresolv` and `libxnet`**, as
  musl has. Their functions are in libc, but builds still ask for them.

`packages/bionic/overlay/` replaces the parts of AOSP that joe does not
build. The character tables bionic takes from ICU4X (Rust) are generated in C
from the Unicode Character Database. The dynamic linker's support for loading
libraries out of APKs is left out.

### Android or Linux

The compiler's target is Android's (`aarch64-unknown-linux-android37`),
because that is the target clang and Rust know for bionic, and it defines
`__ANDROID__`. Upstream C code mostly takes that to mean bionic, which is
right. gnulib, which most of the GNU userland carries, recognises bionic's
private `FILE` and its missing functions only by it. The few programs that
take it to mean the Android system are corrected in their recipes (cmake, for
one, calls its system "Android").

Build systems, on the other hand, are told the system is Linux. Configure
scripts see `aarch64-unknown-linux-gnu`, because on a system called Android,
libtool drops versioned sonames and Python installs itself as an Android
app's.

## Building

Everything builds from source as an ordinary user. Nothing needs root:
build roots are entered with bubblewrap in a user namespace.

Requirements on the build machine:

- x86_64 or aarch64 Linux with glibc, a C and C++ compiler, Python 3,
  bubblewrap, git, curl and [Zig 0.17.1](https://ziglang.org/download/),
  with the headers of xz and zstd (for mksquashfs) and of OpenSSL, and
  pkg-config (for Rust's cargo). On Debian:
  `apt install build-essential python3 bubblewrap btrfs-progs git curl liblzma-dev libzstd-dev libssl-dev pkg-config`;
- a build directory on btrfs (`build/` in this repository);
- on x86_64 only, qemu-user registered with binfmt_misc for aarch64, with the
  `F` flag (as distributions' `qemu-user-static-binfmt` packages do);
- dynamod's port: a checkout of
  [theJoeLinuxFoundation/dynamod](https://github.com/theJoeLinuxFoundation/dynamod)
  at branch `aarch64-bionic`, beside this repository or wherever
  `JOE_DYNAMOD` points.

```
make host-tools               ninja, cmake, mtools, xorriso, mksquashfs, into build/host-tools
make stage1                   the toolchain (LLVM), bionic, LLVM's runtimes, Rust
make stage2                   the temporary tools, and the build root they make
bootstrap/build-packages.sh   every package, with dave, into build/repo
```

An aarch64 build machine is much faster. There, the build root's programs
run natively. On x86_64 they run under qemu-user, all but the compiler: the
toolchain is installed in the build root as a program for the build machine,
so it compiles at full speed, but configure scripts and make, which spend
most of a package's build time, are emulated.

Every step leaves a marker in `build/bootstrap/done/`, and an interrupted
build continues where it stopped. Delete a marker to redo that step. Logs are
in `build/bootstrap/logs/`. Sources are pinned with their SHA-256 in
`bootstrap/sources` and in each package's `package.zon`.

## Layout

| | |
|-|-|
| `bootstrap/` | the toolchain and the build root: `stage1.sh`, `stage2.sh`, `build-packages.sh` |
| `packages/` | one recipe per package (`package.zon`, `build.sh`); `packages/ORDER` is the build order |
| `packages/bionic/` | the C library: the Soong evaluator (`bp/`), patches, the overlay |
| `packages/linux/` | the kernel configuration and the joe security module (`joe-lsm/`) |
| `dave/` | the package manager, from joe Linux, with `-Darch=aarch64` and dynamod integration |
| `system/` | dave's dynamod services: sealing, upgrades, boot checking |
| `image/` | image descriptions: the console system and the live ISO |
| `docs/init.md` | how joe's upgrade model maps onto dynamod |

## License

joe Linux ARM's own code is under the [MIT License](LICENSE). The joe
security module is GPL-2.0-only, as part of the kernel. The patches to other
projects (bionic's, Python's and others) are under those projects' licenses,
and each recipe names its package's. `LICENSES/` has the texts that apply.
The recipes follow Linux From Scratch and Beyond LFS, as joe Linux's do.

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

> **Status: alpha.** **J1-7.3.1-0.3.0-alpha2** is the newest release: an
> installation medium for 64-bit Arm machines with UEFI, and a repository of
> 203 packages. The first alpha had no compiler; this one has clang in the
> base system. It has been tested in QEMU (the `virt` machine, as a CD and as
> a USB stick); no physical server has run it yet. Keep anything that matters
> elsewhere.

## Where it stands

Done:

- **The toolchain.** It builds reproducibly from pinned sources: LLVM 23,
  bionic, compiler-rt, libunwind and libc++, and a Rust cross compiler for
  bionic, which dynamod's service manager needs. It bootstraps natively on an
  aarch64 machine as well as under qemu-user on x86_64.
- **dynamod** as init, ported to aarch64 and bionic (PID 1 in Zig, the service
  manager in Rust), and **dave** with its boot integration moved to it:
  installed systems upgrade into btrfs snapshots and step back by themselves
  when a new system does not boot.
- **The kernel** (Linux 7.3.1 with the joe security module) and
  **systemd-boot**.
- **A native toolchain** in the base system: clang, lld and LLVM's binary
  tools (also as `cc`, `c++`, `ld`, `ar`, `nm` and the other binutils names)
  and compiler-rt's builtins, configured as the cross compiler that builds
  joe is, so an installed system builds software with the same toolchain.
- **The base system**, about 85 packages, and **118 more**: libraries,
  development tools (git, curl, rsync, texinfo, ccache, ...), the command line
  (tmux, htop, jq, GnuPG, tcpdump, ...), and servers (nginx, HAProxy,
  PostgreSQL, Valkey, memcached, Unbound, chrony, WireGuard, OpenVPN, ...).
  Servers are installed disabled; `dynamodctl enable NAME` starts one at boot.
- **The installation medium**: it starts a live console system with root
  logged in, from which `dave install-system` installs joe onto a disk.

Not done yet:

- **Hardware.** Only QEMU's `virt` machine has run it. Arm servers with UEFI
  and ACPI should work; reports are welcome.
- **The security module's declarations.** Most privileged programs are
  sealed `undeclared` (`make audit-security` lists them), which is fine while
  the module only logs, as it does unless the kernel is started with
  `joe=enforce`.
- **Some packages** wait on bionic: rsyslog relies on POSIX thread
  cancellation, which bionic does not have; strace, zsh, nfs-utils and
  nftables need more work. Programs that need Go, Rust or Node.js are not
  packaged.
- **A desktop.** It is to come from [Shades](https://github.com/sinisterMage/shades),
  a display protocol and compositor in Zig, rather than Wayland and Mesa.

## Installing

Write the medium to a USB stick (`dd if=joe-J1-7.3.1-0.3.0-alpha2-aarch64.iso
of=/dev/sdX bs=4M`) or attach it as a CD, and start the machine from it with
UEFI. In QEMU:

```
qemu-system-aarch64 -M virt -cpu host -accel kvm -m 4G -smp 4 \
    -drive if=pflash,format=raw,readonly=on,file=QEMU_EFI.fd \
    -drive if=pflash,format=raw,file=QEMU_VARS.fd \
    -device virtio-scsi-pci -device scsi-cd,drive=cd \
    -drive if=none,id=cd,media=cdrom,readonly=on,file=joe-J1-7.3.1-0.3.0-alpha2-aarch64.iso \
    -drive if=virtio,file=disk.qcow2 -nographic
```

(`-accel hvf` on a Mac; on an x86_64 machine leave out `-cpu host -accel ...`
for `-cpu max`, which is slow.) The live system logs root in on the console.
`dave install-system --list` shows the disks and `dave install-system --disk
DISK` erases one and installs onto it. At its first start the installed
system asks on its console for root's password, then offers an account of
your own (which becomes root with `doas`) and an SSH public key.

Installed systems take their packages from
[joelinux.io/aarch64](https://joelinux.io/aarch64/): `dave install NAME`,
`dave upgrade` (applied at the next restart), `dave rollback`.

## Releases

A release is named **J*X*-*Y*-*Z***, with a stage such as `-alpha1` before
it is final, as joe Linux's are:

| Part | Is | In J1-7.3.1-0.3.0-alpha2 |
|------|----|--------------------------|
| J | joe, the distribution | J |
| *X* | the system revision | 1 |
| *Y* | the kernel's version | 7.3.1 |
| *Z* | dave's version | 0.3.0 |

`packages/joe-release` writes the name into `os-release` (as "joe Linux ARM")
and the medium is named after it. Its package version is the revision and
stage alone (`1alpha2`), which dave orders before the final `1`. joe Linux
ARM's revisions and dave versions are its own: J1-7.3.1-0.3.0-alpha1 is not
the same system as joe Linux's J1-7.3.1-0.2.0-alpha1.

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
  `MAXNAMLEN`, `IFTODT`, the rest of `<paths.h>`, `<sys/kd.h>`, IPv6
  address macros that take any pointer, and `faccessat` with `AT_EACCESS`;
- functions the headers declare under another name are also exported under
  their own, so that configure scripts' link tests tell the truth;
- `<sched.h>` gives programs the kernel's constants without
  `struct clone_args`, whose member names collide with programs' macros;
- `errno` is zero when `main` starts;
- memory mappings are not named, as glibc does not name them: naming is a
  `prctl()` at every `malloc()` that maps memory, which the seccomp sandboxes
  of programs written for glibc (OpenSSH's, dhcpcd's) do not allow;
- login records are written (`updwtmp`), so that agetty can be built.

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

Configure scripts are told the same: the system is
`aarch64-unknown-linux-android`, which is how gnulib's build checks recognise
bionic, and compile the workarounds its code then calls. Two packages'
behaviour on an Android host is wrong for a Linux system, and is turned back:
libtool would package libraries as Android apps do, without versioned
sonames, so the build driver gives libtool its GNU/Linux case instead; and
Python would build itself for embedding in an Android app, so its recipe
calls the system linux-gnu.

## Building

Everything builds from source as an ordinary user. Nothing needs root:
build roots are entered with bubblewrap in a user namespace.

Requirements on the build machine:

- x86_64 or aarch64 Linux with glibc, a C and C++ compiler, Python 3,
  bubblewrap, git, curl and [Zig 0.17.1](https://ziglang.org/download/),
  with the headers of xz and zstd (for mksquashfs) and of OpenSSL, and
  pkg-config (for Rust's cargo). On Debian:
  `apt install build-essential python3 bubblewrap btrfs-progs dosfstools git curl liblzma-dev libzstd-dev libssl-dev pkg-config`;
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

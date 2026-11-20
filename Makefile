# joe Linux ARM: top-level build entry points.
#
# Everything here runs as an ordinary user. Nothing needs root on the host.

DAVE := dave/zig-out/bin/dave
# Tools image builds need that the host may not have (mtools, xorriso,
# mksquashfs) are built here. mkfs.vfat, mkfs.btrfs and sfdisk are in
# /usr/sbin, which Debian leaves out of an ordinary user's PATH.
export PATH := $(CURDIR)/build/host-tools/bin:$(PATH):/usr/sbin:/sbin
# Images read joe's repository from build/repo and are configured to fetch from
# REPO_URL: by default http://10.0.2.2:8643, this machine as a QEMU guest sees
# it, as in joe Linux; https://joelinux.io/aarch64 for the published one.
REPO_URL ?= http://10.0.2.2:8643
REPO := --repo joe,$(CURDIR)/build/repo,$(REPO_URL),$(CURDIR)/build/keys/joe.pub

.PHONY: help dave test host-tools stage1 stage2 bootstrap packages audit-security iso clean

help:
	@echo "make dave          build dave for this machine, managing aarch64 systems"
	@echo "make test          dave's unit tests"
	@echo "make host-tools    ninja, cmake and the image tools, into build/host-tools"
	@echo "make stage1        the cross toolchain, bionic and LLVM's runtimes"
	@echo "make stage2        the temporary tools, in the build root"
	@echo "make bootstrap     host-tools, stage1 and stage2"
	@echo "make packages      every package, into build/repo"
	@echo "make audit-security  privileged programs not yet declared, and invalid seals"
	@echo "make iso           the installation medium, build/images/joe-live.iso"

$(DAVE): $(wildcard dave/src/*.zig dave/src/solver/*.zig) dave/build.zig
	cd dave && zig build -Doptimize=ReleaseSafe -Darch=aarch64

dave: $(DAVE)

test:
	cd dave && zig build test -Darch=aarch64

host-tools:
	bootstrap/host-tools.sh

stage1: host-tools
	bootstrap/stage1.sh

stage2: stage1
	bootstrap/stage2.sh

bootstrap: stage2

packages: $(DAVE)
	bootstrap/build-packages.sh

# The security model's work list, as in joe Linux: programs sealed undeclared
# (no authority of their own) and seals that do not verify.
audit-security: $(DAVE)
	$(DAVE) repo audit build/repo

# The installation medium (image/live.zon), configured for REPO_URL.
iso: $(DAVE)
	mkdir -p build/images
	$(DAVE) image build image/live.zon $(REPO) --out build/images/joe-live.iso

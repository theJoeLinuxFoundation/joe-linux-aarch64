# joe Linux ARM: top-level build entry points.
#
# Everything here runs as an ordinary user. Nothing needs root on the host.

DAVE := dave/zig-out/bin/dave

.PHONY: help dave test host-tools stage1 stage2 bootstrap clean

help:
	@echo "make dave          build dave for this machine, managing aarch64 systems"
	@echo "make test          dave's unit tests"
	@echo "make host-tools    ninja and cmake, into build/host-tools"
	@echo "make stage1        the cross toolchain, bionic and LLVM's runtimes"
	@echo "make stage2        the temporary tools, in the build root"
	@echo "make bootstrap     host-tools, stage1 and stage2"

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

"""joe Linux's configuration for building bionic with soong.py/ninja.py.

The flags are Soong's for an arm64 device (build/soong/cc/config/global.go
and arm64_device.go at android-17.0.0_r1), with these differences:

- the target triple is joe's, aarch64-unknown-linux-android37, whose
  interpreter clang writes as /usr/lib/ld-bionic-aarch64.so.1;
- branch protection (PAC and BTI) is on, and so is the stack protector.
  Soong drops the stack protector where PAC is available, but most Arm
  servers in service are Neoverse N1 (ARMv8.2), on which the PAC
  instructions do nothing;
- no debug-info compression, and no sanitizers, LTO or AFDO;
- -Wno-unknown-warning-option, because bionic builds with -Werror and
  Android's clang is a little older than joe's.
"""

import os

from ninja import Toolchain


COMMON_CFLAGS = [
    "-O2", "-g",
    "-Wall", "-Wextra", "-Wpointer-arith", "-Wunguarded-availability",
    "-Werror=bool-operation", "-Werror=date-time", "-Werror=format-security",
    "-Werror=int-conversion", "-Werror=multichar", "-Werror=pragma-pack",
    "-Werror=pragma-pack-suspicious-include", "-Werror=sizeof-array-div",
    "-Werror=sizeof-pointer-memaccess", "-Werror=string-plus-int",
    "-Werror=unreachable-code-loop-increment",
    "-Wno-error=deprecated-declarations",
    "-Wno-c23-extensions", "-Wno-c99-designator", "-Wno-gnu-folding-constant",
    "-Wno-inconsistent-missing-override", "-Wno-error=reorder-init-list",
    "-Wno-reorder-init-list", "-Wno-sign-compare", "-Wno-unused",
    "-DANDROID", "-DNDEBUG", "-UDEBUG",
    "-D__compiler_offsetof=__builtin_offsetof",
    "-D__ANDROID_UNAVAILABLE_SYMBOLS_ARE_WEAK__",
    "-faddrsig", "-ffp-contract=off", "-fno-exceptions", "-fno-strict-aliasing",
    "-fmessage-length=0", "-no-canonical-prefixes",
]

DEVICE_CFLAGS = [
    "-ffunction-sections", "-fdata-sections", "-fno-short-enums", "-funwind-tables",
    "-Wa,--noexecstack", "-D_FORTIFY_SOURCE=3", "-fstack-protector-strong",
    "-Werror=non-virtual-dtor", "-Werror=address", "-Werror=sequence-point",
    "-nostdlibinc",
]

ARM64_CFLAGS = [
    "-march=armv8-a", "-mbranch-protection=standard",
    "-Werror=implicit-function-declaration", "-fstack-clash-protection",
]

NO_OVERRIDE_CFLAGS = [
    "-Wno-unknown-warning-option",
    # Newer than Android's clang.
    "-Wno-error=unused-template",
    "-Werror=address-of-temporary", "-Werror=dangling", "-Werror=format-insufficient-args",
    "-Werror=fortify-source", "-Werror=incompatible-function-pointer-types",
    "-Werror=int-in-bool-context", "-Werror=int-to-pointer-cast", "-Werror=null-dereference",
    "-Werror=return-type", "-Werror=xor-used-as-pow", "-Wno-missing-field-initializers",
    "-Wno-packed-non-pod", "-Wno-error=tautological-constant-compare",
    "-Wno-implicit-int-float-conversion", "-Wno-tautological-overlap-compare",
    "-Wno-deprecated-copy", "-Wno-zero-as-null-pointer-constant",
    "-Wno-deprecated-anon-enum-enum-conversion", "-Wno-deprecated-enum-enum-conversion",
    "-Wno-error=pessimizing-move", "-Wno-non-c-typedef-for-linkage", "-Wno-align-mismatch",
    "-Wno-error=unused-but-set-parameter", "-Wno-error=deprecated", "-Wno-error=invalid-offsetof",
    "-Wno-nontrivial-memcall", "-Wno-invalid-specialization",
    "-Wno-unterminated-string-initialization", "-Wno-implicit-int-conversion-on-negation",
    "-Wno-default-const-init-field-unsafe", "-Wno-default-const-init-var-unsafe",
    "-Wno-preferred-type-bitfield-enum-conversion", "-Wno-implicit-enum-enum-cast",
    "-Wno-character-conversion", "-Wno-error=uninitialized-const-pointer",
    "-Wno-incompatible-pointer-types", "-Wno-c2y-extensions", "-Wno-vla-cxx-extension",
    "-Wno-cast-function-type-mismatch",
    # noOverride64GlobalCflags
    "-Wno-error=unused-but-set-variable",
]

CPPFLAGS = [
    "-Wimplicit-fallthrough", "-D_LIBCPP_ENABLE_THREAD_SAFETY_ANNOTATIONS",
    "-Wno-gnu-include-next", "-fvisibility-inlines-hidden",
]

LDFLAGS = [
    "-Wl,-z,noexecstack", "-Wl,-z,relro", "-Wl,-z,now", "-Wl,--build-id=sha1",
    "-Wl,--fatal-warnings", "-Wl,--no-undefined-version",
    "-Wl,--exclude-libs,libunwind.a", "-Wl,--hash-style=gnu",
    # arm64Ldflags
    "-Wl,-z,separate-code", "-Wl,-z,separate-loadable-segments",
]


def toolchain(env):
    """The Toolchain for building bionic. env supplies:

    JOE_CROSS      the cross toolchain's prefix (bin/clang, ...)
    JOE_SYSROOT    the root being built against
    JOE_TARGET     the target triple
    JOE_RUNTIMES   a directory holding libunwind.a, libunwind-exported.a and
                   libc++_noexcept.a (empty while those are not built yet)
    """
    cross = env["JOE_CROSS"]
    sysroot = env["JOE_SYSROOT"]
    runtimes = env.get("JOE_RUNTIMES", "")
    tc = Toolchain()
    tc.target = env["JOE_TARGET"]
    tc.cc = f"{cross}/bin/clang --sysroot={sysroot}"
    tc.cxx = f"{cross}/bin/clang++ --sysroot={sysroot}"
    tc.ar = f"{cross}/bin/llvm-ar"
    tc.objcopy = f"{cross}/bin/llvm-objcopy"
    tc.cflags = COMMON_CFLAGS + DEVICE_CFLAGS + ARM64_CFLAGS
    tc.no_override_cflags = NO_OVERRIDE_CFLAGS
    tc.cppflags = CPPFLAGS
    tc.asflags = ["-D__ASSEMBLY__"]
    tc.ldflags = LDFLAGS
    tc.libcxx_include = [f"{sysroot}/usr/include/c++/v1"]
    tc.builtins = env.get("JOE_BUILTINS")
    # build/soong/cc/config/global.go's commonGlobalIncludes; the others
    # (system/media, hardware/, frameworks/) are not in joe's tree.
    tc.global_includes = ["system/core/include", "system/logging/liblog/include"]
    tc.tools = {}
    tc.prebuilts = {}
    if runtimes:
        noexcept = f"{runtimes}/libc++_noexcept.a"
        tc.prebuilts = {
            "libunwind": {"static": f"{runtimes}/libunwind.a"},
            "libunwind-exported": {"static": f"{runtimes}/libunwind-exported.a"},
            "libc++_static_noexcept": {"static": noexcept, "system_include": tc.libcxx_include},
            "libc++demangle_noexcept": {"static": noexcept, "system_include": tc.libcxx_include},
        }
    return tc


# Soong's product variables. platform_sdk_version is the API level bionic
# implements, written into an ELF note in every binary (crtbrand.S).
PRODUCT_VARIABLES = {
    "platform_sdk_version": 37,
}

# The parts of AOSP the build reads, relative to the tree's root.
SUBDIRS = [
    "bionic",
    "external/scudo",
    "external/gwp_asan",
    "external/llvm-libc",
    "external/arm-optimized-routines",
    "external/google-highway",
    "external/fmtlib",
    "system/logging/liblog",
    "system/libbase",
    "system/libprocinfo",
    "system/libziparchive",
    "system/core/libcutils",
    "system/core/libprocessgroup",
    "system/core/property_service",
]

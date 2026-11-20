"""Writes a ninja file that builds Soong modules evaluated by soong.Tree.

Paths in the ninja file are absolute. Outputs live under OUT:

    OUT/obj/MODULE/VARIANT/...   objects
    OUT/gen/MODULE/...           genrule outputs (a genrule's $(genDir))
    OUT/lib/MODULE.a             static libraries
    OUT/lib/MODULE.so            shared libraries
    OUT/bin/NAME                 binaries
    OUT/obj/MODULE.o             cc_object results

The toolchain and the global flags come from a Toolchain object (see
joe.py, which is the configuration joe Linux uses).
"""

import glob
import os
import shlex

from soong import CC_TYPES, GEN_TYPES, EvalError


def q(s):
    """Quote for ninja and the shell."""
    return shlex.quote(s).replace("$", "$$")


_SHELL_SAFE = set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_+-=.,/ ")


def shell_escape(s):
    """blueprint's proptools.ShellEscape: words with nothing but these
    characters, and spaces, are left alone, so the shell splits them at the
    spaces ("-include foo.h" is two arguments); anything else is quoted."""
    if all(c in _SHELL_SAFE for c in s):
        return s
    return "'" + s.replace("'", "'\\''") + "'"


def esc(flags):
    return [shell_escape(f) for f in flags]


def bare(name):
    """`//dir:name` and `name{.tag}` → name."""
    if ":" in name:
        name = name.rsplit(":", 1)[1]
    return name.split("{", 1)[0]


class Toolchain:
    cc = "clang"
    cxx = "clang++"
    ar = "llvm-ar"
    objcopy = "llvm-objcopy"
    python = "python3"
    target = None
    cflags = []
    no_override_cflags = []
    cppflags = []
    conlyflags = []
    asflags = []
    ldflags = []
    c_std = "gnu23"
    cpp_std = "gnu++2b"
    c_std_experimental = "gnu2y"
    cpp_std_experimental = "gnu++2b"
    # Modules provided as files: name -> {"static": path} or {"shared": path},
    # optionally "include", "system_include" (lists of absolute paths).
    prebuilts = {}
    # stl "libc++" (the default for C++ modules): include directories and
    # libraries.
    libcxx_include = []
    builtins = None          # compiler-rt's builtins archive
    # Python host tools: module name -> script, when the module's srcs do
    # not say (or the module is not in the tree).
    tools = {}
    # Soong's CommonGlobalIncludes (relative to the tree), added to every
    # module after its own include directories.
    global_includes = []


class Ninja:
    def __init__(self, tree, out, tc):
        self.tree, self.out, self.tc = tree, os.path.abspath(out), tc
        self.lines = []
        self.done = {}
        self.rules()

    def emit(self, *lines):
        self.lines.extend(lines)

    def rules(self):
        tc = self.tc
        self.emit(
            "ninja_required_version = 1.10",
            f"cc = {tc.cc}",
            f"cxx = {tc.cxx}",
            f"ar = {tc.ar}",
            f"objcopy = {tc.objcopy}",
            "rule cc",
            "  command = $cc -MD -MF $out.d $flags -c $in -o $out",
            "  depfile = $out.d",
            "  deps = gcc",
            "  description = CC $out",
            "rule cxx",
            "  command = $cxx -MD -MF $out.d $flags -c $in -o $out",
            "  depfile = $out.d",
            "  deps = gcc",
            "  description = CXX $out",
            "rule ar",
            "  command = rm -f $out && $ar crsD $out @$out.rsp",
            "  rspfile = $out.rsp",
            "  rspfile_content = $in",
            "  description = AR $out",
            "rule link",
            "  command = $cxx $flags -o $out @$out.rsp $libs",
            "  rspfile = $out.rsp",
            "  rspfile_content = $in",
            "  description = LINK $out",
            "rule prefix",
            "  command = $objcopy --prefix-symbols=$prefix $in $out",
            "  description = PREFIX $out",
            "rule gen",
            "  command = cd $top && $cmd",
            "  description = GEN $name",
            "rule copy",
            "  command = cp $in $out",
            # A static library that includes other archives (Soong's
            # whole_static_libs): llvm-ar's L modifier adds an archive's
            # members rather than the archive itself.
            "rule merge",
            "  command = rm -f $out && $ar qcsDL $out $in",
            "  description = AR $out",
            "",
        )

    # --- paths ---------------------------------------------------------

    def src_path(self, m, rel):
        return os.path.normpath(os.path.join(m.dir, rel))

    def expand_srcs(self, m, srcs, excludes=()):
        """Source paths for a module's srcs: globs expanded, :refs resolved
        (filegroup files, genrule outputs). Returns (paths, generated)."""
        out, generated = [], []
        exc = set()
        for e in excludes:
            if e.startswith(":"):
                exc.update(self.ref_files(bare(e[1:]))[0])
            else:
                exc.update(glob.glob(self.src_path(m, e), recursive=True) or [self.src_path(m, e)])
        for s in srcs:
            if s.startswith(":") or s.startswith("//"):
                files, gen = self.ref_files(bare(s.lstrip(":")))
                out += files
                generated += gen
            elif any(c in s for c in "*?["):
                out += sorted(glob.glob(self.src_path(m, s), recursive=True))
            else:
                out.append(self.src_path(m, s))
        return [p for p in out if p not in exc], generated

    def ref_files(self, name):
        """Files a :name reference stands for: (files, of which generated)."""
        m = self.tree.get(name)
        if m.type == "filegroup":
            p = self.tree.props(name)
            files, gen = self.expand_srcs(m, p.get("srcs", []), p.get("exclude_srcs", []))
            return files, gen
        if m.type in GEN_TYPES:
            outs = self.genrule(name)
            return outs, outs
        raise EvalError(f":{name} is a {m.type}, not a filegroup or genrule")

    # --- genrules ------------------------------------------------------

    def tool(self, name):
        name = bare(name)
        if name in self.tc.tools:
            return f"{self.tc.python} {self.tc.tools[name]}"
        m = self.tree.get(name)
        if m.type == "python_binary_host":
            p = self.tree.props(name)
            main = p.get("main") or p["srcs"][0]
            return f"{self.tc.python} {q(self.src_path(m, main))}"
        raise EvalError(f"tool {name} is a {m.type}; give it a script in Toolchain.tools")

    def genrule(self, name):
        key = ("gen", name)
        if key in self.done:
            return self.done[key]
        m = self.tree.get(name)
        p = self.tree.props(name)
        gendir = os.path.join(self.out, "gen", name)
        outs = [os.path.join(gendir, o) for o in p.get("out", [])]
        self.done[key] = outs
        srcs, gen = self.expand_srcs(m, p.get("srcs", []), p.get("exclude_srcs", []))
        tools = p.get("tools", []) + p.get("tool_files", [])
        cmd = p["cmd"]

        def location(arg):
            arg = arg.strip()
            if not arg:
                return self.tool(tools[0]) if tools else q(srcs[0])
            if arg in p.get("tools", []):
                return self.tool(arg)
            if arg in p.get("tool_files", []):
                return q(self.src_path(m, arg))
            files = self.ref_files(bare(arg.lstrip(":")))[0] if arg.startswith(":") else [self.src_path(m, arg)]
            return " ".join(q(f) for f in files)

        res, i = [], 0
        while i < len(cmd):
            if cmd.startswith("$$", i):
                res.append("$")
                i += 2
            elif cmd.startswith("$(", i):
                j = cmd.index(")", i)
                word = cmd[i + 2:j]
                verb, _, arg = word.partition(" ")
                if verb in ("location", "locations"):
                    res.append(location(arg))
                elif verb == "in":
                    res.append(" ".join(q(s) for s in srcs))
                elif verb == "out":
                    res.append(" ".join(q(o) for o in outs))
                elif verb == "genDir":
                    res.append(q(gendir))
                elif verb == "depfile":
                    res.append(q(os.path.join(gendir, "depfile")))
                else:
                    raise EvalError(f"{name}: unknown $({word}) in cmd")
                i = j + 1
            else:
                res.append(cmd[i])
                i += 1
        command = "mkdir -p " + q(gendir) + " && " + "".join(res)
        self.emit(
            f"build {' '.join(q(o) for o in outs)}: gen {' '.join(q(s) for s in srcs)}",
            f"  name = {name}",
            f"  top = {q(self.tree.root)}",
            f"  cmd = {self.ninja_escape(command)}",
        )
        return outs

    @staticmethod
    def ninja_escape(s):
        return s.replace("$", "$$").replace("\n", " ")

    # --- cc modules ----------------------------------------------------

    def cc_props(self, name, variant):
        m = self.tree.get(name)
        if m.type not in CC_TYPES:
            raise EvalError(f"{name} is a {m.type}, not a cc module")
        p = self.tree.props(name, variant)
        if p.get("enabled") is False:
            raise EvalError(f"{name} is disabled for this target")
        return m, p

    def exported(self, name, variant, seen=None):
        """What depending on a module adds to the depender's compile:
        (include dirs, system include dirs, generated headers)."""
        name = bare(name)
        seen = seen if seen is not None else set()
        if (name, variant) in seen:
            return [], [], []
        seen.add((name, variant))
        pre = self.tc.prebuilts.get(name)
        if pre is not None:
            return list(pre.get("include", [])), list(pre.get("system_include", [])), []
        m, p = self.cc_props(name, variant)
        inc = [self.src_path(m, d) for d in p.get("export_include_dirs", [])]
        sysinc = [self.src_path(m, d) for d in p.get("export_system_include_dirs", [])]
        gen = []
        for g in p.get("export_generated_headers", []):
            outs = self.genrule(bare(g))
            gen += outs
            inc.append(os.path.join(self.out, "gen", bare(g)))
        for key, v in (("export_header_lib_headers", "headers"), ("export_static_lib_headers", "static"),
                       ("export_shared_lib_headers", "shared"), ("whole_static_libs", "static")):
            for d in p.get(key, []):
                i, s, g = self.exported(d, v, seen)
                inc += i
                sysinc += s
                gen += g
        return inc, sysinc, gen

    def system_shared_libs(self, p):
        if "system_shared_libs" in p:
            return p["system_shared_libs"]
        return ["libc", "libm", "libdl"]

    def stl(self, p, cxx):
        stl = p.get("stl")
        if stl is None:
            stl = "libc++" if cxx else "none"
        return stl

    def compile(self, name, variant):
        """Compile a module's sources. Returns (objects, include flags)."""
        key = ("obj", name, variant)
        if key in self.done:
            return self.done[key]
        m, p = self.cc_props(name, variant)
        tc = self.tc
        srcs, generated = self.expand_srcs(m, p.get("srcs", []), p.get("exclude_srcs", []))
        for g in p.get("generated_sources", []):
            outs = self.genrule(bare(g))
            srcs += [o for o in outs if not o.endswith(".h")]
            generated += outs

        inc = [self.src_path(m, d) for d in p.get("local_include_dirs", [])]
        inc += [os.path.join(self.tree.root, d) for d in p.get("include_dirs", [])]
        if p.get("include_build_directory", True):
            inc.append(m.dir)
        own = self.exported(name, variant, set())
        inc += own[0]
        sysinc = list(own[1])
        gen_headers = list(own[2])
        for g in p.get("generated_headers", []):
            gen_headers += self.genrule(bare(g))
            inc.append(os.path.join(self.out, "gen", bare(g)))
        deps = [(d, "headers") for d in p.get("header_libs", [])]
        deps += [(d, "static") for d in p.get("static_libs", []) + p.get("whole_static_libs", [])]
        deps += [(d, "shared") for d in p.get("shared_libs", []) + self.system_shared_libs(p)]
        for d, v in deps:
            i, s, g = self.exported(d, v, set())
            inc += i
            sysinc += s
            gen_headers += g
        is_cxx = any(s.endswith((".cpp", ".cc", ".cxx")) for s in srcs)
        if self.stl(p, is_cxx) not in ("none", ""):
            sysinc += tc.libcxx_include
        # libc++'s headers wrap the C library's (<cstring> includes libc++'s
        # <string.h>, which includes bionic's), so they come first, as Soong
        # puts the STL's include directories before the system libraries'.
        sysinc = [d for d in sysinc if d in tc.libcxx_include] + [d for d in sysinc if d not in tc.libcxx_include]

        def dedup(xs):
            seen, out = set(), []
            for x in xs:
                if x not in seen:
                    seen.add(x)
                    out.append(x)
            return out

        # Soong's CommonGlobalIncludes, that exist, for every platform module.
        glob_inc = [os.path.join(self.tree.root, d) for d in tc.global_includes
                    if os.path.isdir(os.path.join(self.tree.root, d))]
        incflags = ([f"-I{d}" for d in dedup(inc)] + [f"-I{d}" for d in glob_inc] +
                    [f"-isystem{d}" for d in dedup(sysinc)])
        pic = ["-fPIE"] if m.type == "cc_binary" else ["-fPIC"]
        common = ["-target", tc.target] + tc.cflags + pic + esc(p.get("cflags", []))
        c_std = p.get("c_std")
        c_std = tc.c_std_experimental if c_std == "experimental" else (c_std or tc.c_std)
        cpp_std = p.get("cpp_std")
        cpp_std = tc.cpp_std_experimental if cpp_std == "experimental" else (cpp_std or tc.cpp_std)
        rtti = [] if p.get("rtti") else ["-fno-rtti"]

        objdir = os.path.join(self.out, "obj", name, variant or "none")
        objs = []
        implicit = " | " + " ".join(q(h) for h in dedup(gen_headers)) if gen_headers else ""
        for s in srcs:
            if s.endswith(".h"):
                continue
            rel = os.path.relpath(s, self.out if s.startswith(self.out) else self.tree.root)
            o = os.path.join(objdir, rel.replace("../", "__/") + ".o")
            if s.endswith((".c",)):
                rule, flags = "cc", common + tc.conlyflags + [f"-std={c_std}"] + esc(p.get("conlyflags", [])) + incflags
            elif s.endswith((".cpp", ".cc", ".cxx")):
                rule, flags = "cxx", common + tc.cppflags + [f"-std={cpp_std}"] + rtti + esc(p.get("cppflags", [])) + incflags
            elif s.endswith((".S", ".s")):
                rule, flags = "cc", common + tc.asflags + esc(p.get("asflags", [])) + incflags
            else:
                raise EvalError(f"{name}: do not know how to compile {s}")
            flags = flags + tc.no_override_cflags
            # Soong hands flags to the shell as written, so "-include x.h"
            # is two words and the Android.bp authors quote what needs it.
            self.emit(f"build {q(o)}: {rule} {q(s)}{implicit}",
                      f"  flags = {self.ninja_escape(' '.join(flags))}")
            objs.append(o)
        for ob in p.get("objs", []):
            objs.append(self.cc_object(bare(ob)))
        self.done[key] = (objs, incflags)
        return self.done[key]

    def static_lib(self, name):
        """OUT/lib/NAME.a, with the objects of its whole_static_libs."""
        name = bare(name)
        pre = self.tc.prebuilts.get(name)
        if pre is not None:
            if "static" not in pre:
                raise EvalError(f"prebuilt {name} has no static library")
            return pre["static"]
        key = ("a", name)
        if key in self.done:
            return self.done[key]
        out = os.path.join(self.out, "lib", name + ".a")
        self.done[key] = out
        m, p = self.cc_props(name, "static")
        objs = list(self.compile(name, "static")[0])
        whole = []
        for w in p.get("whole_static_libs", []):
            whole.append(self.static_lib(w))
        if whole:
            self.emit(f"build {q(out)}: merge {' '.join(q(o) for o in objs + whole)}")
        else:
            self.emit(f"build {q(out)}: ar {' '.join(q(o) for o in objs)}")
        return out

    def cc_object(self, name):
        """A cc_object: its sources (and objs) partially linked into one .o."""
        key = ("o", name)
        if key in self.done:
            return self.done[key]
        out = os.path.join(self.out, "obj", name + ".o")
        self.done[key] = out
        m, p = self.cc_props(name, None)
        objs = self.compile(name, None)[0]
        flags = ["-target", self.tc.target, "-nostdlib", "-no-pie", "-Wl,-r"]
        if p.get("linker_script"):
            flags.append("-Wl,-T," + self.src_path(m, p["linker_script"]))
        self.emit(f"build {q(out)}: link {' '.join(q(o) for o in objs)}",
                  f"  flags = {self.ninja_escape(' '.join(flags))}",
                  "  libs =")
        return out

    def link_inputs(self, name, variant, p, shared):
        """Libraries a shared library or binary links, in Soong's order."""
        tc = self.tc
        libs = []
        whole = [self.static_lib(w) for w in p.get("whole_static_libs", [])]
        if whole:
            libs += ["-Wl,--whole-archive"] + whole + ["-Wl,--no-whole-archive"]
        libs += [self.static_lib(s) for s in p.get("static_libs", [])]
        if not p.get("no_libcrt") and tc.builtins:
            libs.append(tc.builtins)
        for s in p.get("shared_libs", []) + self.system_shared_libs(p):
            libs.append(self.shared_lib(s))
        # The C++ standard library, as Soong links it: stl "libc++" (the
        # default for a module with C++ sources) is the shared libc++,
        # "libc++_static" the archive; "none" is nothing.
        m = self.tree.get(name)
        srcs, _ = self.expand_srcs(m, p.get("srcs", []), p.get("exclude_srcs", []))
        is_cxx = any(x.endswith((".cpp", ".cc", ".cxx")) for x in srcs)
        stl = self.stl(p, is_cxx)
        if stl in ("libc++", "c++_shared"):
            libs.append("-lc++")
        elif stl in ("libc++_static", "c++_static"):
            libs.append("-l:libc++.a")
        return libs

    def shared_lib(self, name):
        name = bare(name)
        pre = self.tc.prebuilts.get(name)
        if pre is not None:
            if "shared" not in pre:
                raise EvalError(f"prebuilt {name} has no shared library")
            return pre["shared"]
        key = ("so", name)
        if key in self.done:
            return self.done[key]
        m, p = self.cc_props(name, "shared")
        soname = p.get("stem", name) + p.get("suffix", "") + ".so"
        out = os.path.join(self.out, "lib", soname)
        self.done[key] = out
        objs = list(self.compile(name, "shared")[0])
        tc = self.tc
        crt_begin, crt_end = [], []
        if not p.get("nocrt"):
            crt_begin, crt_end = [self.cc_object("crtbegin_so")], [self.cc_object("crtend_so")]
        flags = ["-target", tc.target, "-shared", "-nostdlib", "-Wl,--gc-sections", "-Wl,--no-undefined",
                 f"-Wl,-soname,{soname}"] + tc.ldflags
        flags += self.pack_flags(p)
        vs = p.get("version_script")
        implicit = []
        if vs:
            path = self.ref_files(bare(vs[1:]))[0][0] if vs.startswith(":") else self.src_path(m, vs)
            flags.append(f"-Wl,--version-script,{path}")
            implicit.append(path)
        flags += esc(p.get("ldflags", []))
        libs = self.link_inputs(name, "shared", p, True)
        inputs = crt_begin + objs
        self.emit(f"build {q(out)}: link {' '.join(q(o) for o in inputs)}"
                  f" | {' '.join(q(x) for x in libs + crt_end + implicit if x.startswith('/'))}",
                  f"  flags = {self.ninja_escape(' '.join(flags))}",
                  f"  libs = {self.ninja_escape(' '.join(shlex.quote(x) for x in libs + crt_end))}")
        return out

    def pack_flags(self, p):
        if p.get("pack_relocations") is False:
            return ["-Wl,--pack-dyn-relocs=none"]
        return []

    def binary(self, name, path=None):
        key = ("bin", name)
        if key in self.done:
            return self.done[key]
        m, p = self.cc_props(name, None)
        stem = p.get("stem", name) + p.get("suffix", "")
        out = path or os.path.join(self.out, "bin", stem)
        self.done[key] = out
        tc = self.tc
        objs = list(self.compile(name, None)[0])
        static = p.get("static_executable", False)
        local = esc(p.get("ldflags", []))
        flags = ["-target", tc.target] + tc.ldflags
        crt_begin, crt_end = [], []
        if static:
            if "-shared" not in local:
                flags.append("-static")
            flags += ["-nostdlib", "-Bstatic", "-Wl,--gc-sections"]
            if not p.get("nocrt"):
                crt_begin, crt_end = [self.cc_object("crtbegin_static")], [self.cc_object("crtend_android")]
        else:
            flags += ["-pie", "-nostdlib", "-Bdynamic", "-Wl,--gc-sections", "-Wl,-z,nocopyreloc"]
            if not p.get("nocrt"):
                crt_begin, crt_end = [self.cc_object("crtbegin_dynamic")], [self.cc_object("crtend_android")]
        flags += self.pack_flags(p)
        vs = p.get("version_script")
        implicit = []
        if vs:
            vpath = self.ref_files(bare(vs[1:]))[0][0] if vs.startswith(":") else self.src_path(m, vs)
            flags.append(f"-Wl,--version-script,{vpath}")
            implicit.append(vpath)
        flags += local
        libs = self.link_inputs(name, None, p, False)
        if static and p.get("system_shared_libs") is None:
            # A static executable links the static C library.
            libs = [x for x in libs if not x.endswith(".so")]
            libs += [self.static_lib("libc"), self.static_lib("libm")]
        prefix = p.get("prefix_symbols")
        linked = out + ".unprefixed" if prefix else out
        self.emit(f"build {q(linked)}: link {' '.join(q(o) for o in crt_begin + objs)}"
                  f" | {' '.join(q(x) for x in libs + crt_end + implicit if x.startswith('/'))}",
                  f"  flags = {self.ninja_escape(' '.join(flags))}",
                  f"  libs = {self.ninja_escape(' '.join(shlex.quote(x) for x in libs + crt_end))}")
        if prefix:
            self.emit(f"build {q(out)}: prefix {q(linked)}", f"  prefix = {prefix}")
        return out

    def product(self, spec):
        """NAME:static, NAME:shared, NAME (binary or cc_object)."""
        name, _, variant = spec.partition(":")
        m = self.tree.get(name)
        if variant == "static":
            return self.static_lib(name)
        if variant == "shared":
            return self.shared_lib(name)
        if m.type == "cc_object":
            return self.cc_object(name)
        if m.type == "cc_binary":
            return self.binary(name)
        if m.type in GEN_TYPES:
            return " ".join(self.genrule(name))
        raise EvalError(f"do not know what to build for {spec}")

    def write(self, path, products):
        with open(path, "w") as f:
            f.write("\n".join(self.lines) + "\n")
            f.write(f"build all: phony {' '.join(q(p) for p in products)}\n")
            f.write("default all\n")

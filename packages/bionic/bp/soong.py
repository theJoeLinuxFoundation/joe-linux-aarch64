"""Evaluates Android.bp modules the way Soong would for one device target,
and writes a ninja file that builds the ones asked for.

This is not Soong. It implements what bionic and the few AOSP libraries it
needs use: cc_library, cc_library_static, cc_library_shared,
cc_library_headers, cc_object, cc_binary, cc_defaults, filegroup, genrule,
cc_genrule and python_binary_host (as genrule tools), with Soong's rules for
merging defaults and arch/target variants, propagating exported include
directories, and adding crt objects, compiler-rt's builtins and the system
libraries. Everything else (tests, fuzzers, APEX, NDK stubs, sanitizers,
LTO, afdo) is ignored.

The target is fixed by a Config: one OS (android), one architecture (arm64),
LP64. Property merging follows blueprint's proptools: lists concatenate,
maps merge, scalars are replaced. A module's defaults are applied before its
own properties, in order, recursively; arch and target blocks of the merged
result are then applied in Soong's order; then the static or shared block;
then exclude_* lists.
"""

import fnmatch
import glob
import os
import shlex

from blueprint import Concat, ParseError, Ref, Select, UNSET, parse_file


class EvalError(Exception):
    pass


# Module types that are cc_defaults under another name.
DEFAULTS_TYPES = {"cc_defaults"}
CC_TYPES = {"cc_library", "cc_library_static", "cc_library_shared", "cc_library_headers",
            "cc_object", "cc_binary"}
GEN_TYPES = {"genrule", "cc_genrule"}

# Properties applied by variant selection, never seen by the build.
VARIANT_KEYS = ("arch", "target", "multilib", "static", "shared", "product_variables",
                "soong_config_variables", "android", "host", "vendor", "recovery", "ramdisk",
                "vendor_ramdisk", "apex", "native_bridge", "codegen")


def deepcopy(v):
    if isinstance(v, dict):
        return {k: deepcopy(x) for k, x in v.items()}
    if isinstance(v, list):
        return [deepcopy(x) for x in v]
    return v


def append(dst, src):
    """proptools.AppendProperties: src after dst."""
    out = dict(dst)
    for k, v in src.items():
        if v is UNSET:
            continue
        if k not in out:
            out[k] = deepcopy(v)
        elif isinstance(out[k], list) and isinstance(v, list):
            out[k] = out[k] + deepcopy(v)
        elif isinstance(out[k], dict) and isinstance(v, dict):
            out[k] = append(out[k], v)
        else:
            out[k] = deepcopy(v)
    return out


class Config:
    def __init__(self, arch="arm64", os_name="android", release_flags=None,
                 soong_config=None, product_variables=None):
        self.arch = arch
        self.os = os_name
        self.release_flags = release_flags or {}
        self.soong_config = soong_config or {}
        self.product_variables = product_variables or {}

    def target_keys(self):
        """The target: blocks that apply, in the order Soong applies them."""
        a = self.arch
        return ["linux", "bionic", self.os, "android64", f"linux_{a}", f"bionic_{a}", f"{self.os}_{a}"]


class Module:
    def __init__(self, type_, props, path, scope):
        self.type = type_
        self.raw = props
        self.path = path              # the Android.bp file
        self.dir = os.path.dirname(path)
        self.scope = scope            # the file's variables
        self.name = None


class Tree:
    """Every module of every Android.bp below the given directories."""

    def __init__(self, root, config, subdirs=None, overlays=()):
        self.root = os.path.abspath(root)
        self.config = config
        self.modules = {}
        self.module_types = {}        # soong_config_module_type name -> base type
        files = []
        for sub in subdirs or ["."]:
            files += sorted(glob.glob(os.path.join(self.root, sub, "**", "Android.bp"), recursive=True))
        # Overlays are read last and replace upstream modules of the same name.
        for path in files + [os.path.abspath(p) for p in overlays]:
            self._load(path, replace=path in overlays or path.startswith(tuple(os.path.abspath(p) for p in overlays)))

    def _load(self, path, replace=False):
        try:
            defs = parse_file(path)
        except ParseError as e:
            raise EvalError(str(e))
        scope = {}
        for d in defs:
            if d[0] == "assign":
                _, name, op, expr = d
                value = self.value(expr, scope)
                if op == "+=":
                    value = scope[name] + value
                scope[name] = value
                continue
            _, type_, props = d
            if type_ == "soong_config_module_type":
                self.module_types[props["name"]] = props["module_type"]
                continue
            type_ = self.module_types.get(type_, type_)
            m = Module(type_, props, path, scope)
            name = props.get("name")
            if not isinstance(name, str):
                continue
            m.name = name
            if name in self.modules and not replace:
                # Soong namespaces would separate these; the first one wins.
                continue
            self.modules[name] = m

    # --- values --------------------------------------------------------

    def value(self, expr, scope):
        if isinstance(expr, Ref):
            if expr.name not in scope:
                raise EvalError(f"undefined variable {expr.name}")
            return deepcopy(scope[expr.name])
        if isinstance(expr, Concat):
            parts = [self.value(p, scope) for p in expr.parts]
            out = parts[0]
            for p in parts[1:]:
                if isinstance(out, dict):
                    out = append(out, p)
                else:
                    out = out + p
            return out
        if isinstance(expr, Select):
            return self.value(self.select(expr), scope)
        if isinstance(expr, list):
            return [self.value(x, scope) for x in expr]
        if isinstance(expr, dict):
            return {k: self.value(v, scope) for k, v in expr.items()}
        return expr

    def condition_value(self, func, args):
        c = self.config
        if func == "arch":
            return c.arch
        if func == "os":
            return c.os
        if func == "release_flag":
            return c.release_flags.get(args[0])
        if func == "soong_config_variable":
            return c.soong_config.get(tuple(args))
        if func == "product_variable":
            return c.product_variables.get(args[0])
        if func == "variant":
            return None
        raise EvalError(f"unknown select() condition {func}")

    def select(self, sel):
        values = [self.condition_value(f, a) for f, a in sel.conditions]
        for pats, value in sel.cases:
            if pats == ["default"]:
                return value
            if all(p == "default" or (isinstance(p, tuple) and p[0] == "any" and v is not None)
                   or (v is not None and p == v) for p, v in zip(pats, values)):
                return value
        return UNSET

    # --- modules -------------------------------------------------------

    def get(self, name):
        m = self.modules.get(name)
        if m is None:
            raise EvalError(f"no module named {name}")
        return m

    def with_defaults(self, m, seen=()):
        """A module's properties with its defaults applied, variants unselected."""
        if m.name in seen:
            raise EvalError(f"defaults cycle through {m.name}")
        props = self.value(m.raw, m.scope)
        out = {}
        for d in props.get("defaults", []):
            dm = self.get(d)
            dp = self.with_defaults(dm, seen + (m.name,))
            dp.pop("name", None)
            # As in Soong, a default's paths are read relative to the module
            # that uses it, not to the defaults module.
            out = append(out, dp)
        return append(out, props)

    def specialize(self, props, variant):
        """Apply arch, multilib, target, soong_config and the static/shared
        block, recursively, to merged properties."""
        c = self.config
        out = {k: v for k, v in props.items() if k not in VARIANT_KEYS}
        parts = []
        arch = props.get("arch", {})
        if c.arch in arch:
            parts.append(arch[c.arch])
        multilib = props.get("multilib", {})
        if "lib64" in multilib:
            parts.append(multilib["lib64"])
        target = props.get("target", {})
        for key in c.target_keys():
            if key in target:
                parts.append(target[key])
        for var, cases in props.get("soong_config_variables", {}).items():
            chosen = None
            for (ns, name), value in c.soong_config.items():
                if name == var and value in cases:
                    chosen = cases[value]
            if chosen is None:
                chosen = cases.get("conditions_default")
            if chosen:
                parts.append(chosen)
        for var, block in props.get("product_variables", {}).items():
            value = c.product_variables.get(var)
            if value:
                # A variable's value replaces %d or %s in its block's strings.
                parts.append(substitute(block, value))
        if variant in ("static", "shared") and variant in props:
            parts.append(props[variant])
        for p in parts:
            out = append(out, self.specialize(p, variant))
        return out

    def props(self, name, variant=None):
        m = self.get(name)
        p = self.specialize(self.with_defaults(m), variant)
        for key in list(p):
            if key.startswith("exclude_") and isinstance(p[key], list):
                base = key[len("exclude_"):]
                if base in p:
                    p[base] = [x for x in p[base] if x not in p[key]]
        return p


def substitute(v, value):
    if isinstance(v, str):
        return v.replace("%d", str(value)).replace("%s", str(value))
    if isinstance(v, list):
        return [substitute(x, value) for x in v]
    if isinstance(v, dict):
        return {k: substitute(x, value) for k, x in v.items()}
    return v

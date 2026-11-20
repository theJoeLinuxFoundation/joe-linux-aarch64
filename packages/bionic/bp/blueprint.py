"""A parser for Blueprint, the language of Android.bp files.

The grammar is that of github.com/google/blueprint/parser:

    file       = { assignment | module }
    assignment = IDENT ( "=" | "+=" ) expr
    module     = IDENT "{" { IDENT ":" expr "," } "}"
               | IDENT "(" { IDENT "=" expr "," } ")"
    expr       = operand { "+" operand }
    operand    = STRING | INT | "true" | "false" | IDENT | list | map | select
    list       = "[" { expr "," } "]"
    map        = "{" { IDENT ":" expr "," } "}"
    select     = "select" "(" condition "," "{" { pattern ":" expr "," } "}" ")"

Values come out as Python values: str, int, bool, list, dict (properties
keep their order), plus Select for select() expressions and Ref for a
variable that is evaluated later. Modules are (type, properties, file).
"""

import re


class ParseError(Exception):
    pass


class Ref:
    """A variable reference, resolved by the evaluator in the file's scope."""
    def __init__(self, name):
        self.name = name

    def __repr__(self):
        return f"Ref({self.name})"


class Select:
    """select(conditions, {patterns: value}): conditions is a list of
    (function, args), cases a list of (patterns, value). A pattern is a
    string, bool, "default", or ("any", binding)."""
    def __init__(self, conditions, cases):
        self.conditions = conditions
        self.cases = cases

    def __repr__(self):
        return f"Select({self.conditions}, {self.cases})"


class Concat:
    """a + b, kept until variables are resolved."""
    def __init__(self, parts):
        self.parts = parts

    def __repr__(self):
        return f"Concat({self.parts})"


class Unset:
    """`unset` inside a select(): the property is as if not written."""
    def __repr__(self):
        return "Unset"


UNSET = Unset()

_token = re.compile(r"""
    (?P<ws>\s+)
  | (?P<comment>//[^\n]*|/\*.*?\*/)
  | (?P<string>"(?:[^"\\\n]|\\.)*"|`[^`]*`)
  | (?P<int>-?[0-9]+)
  | (?P<ident>[A-Za-z_][A-Za-z0-9_]*)
  | (?P<op>\+=|[=:,{}\[\]()+@])
""", re.S | re.X)


def _unquote(s):
    if s[0] == "`":
        return s[1:-1]
    # Go string escapes; the files use few of them.
    out, i = [], 1
    while i < len(s) - 1:
        c = s[i]
        if c == "\\":
            n = s[i + 1]
            out.append({"n": "\n", "t": "\t", '"': '"', "\\": "\\"}.get(n, "\\" + n))
            i += 2
        else:
            out.append(c)
            i += 1
    return "".join(out)


def tokenize(text, path):
    pos, toks = 0, []
    while pos < len(text):
        m = _token.match(text, pos)
        if not m:
            line = text.count("\n", 0, pos) + 1
            raise ParseError(f"{path}:{line}: unexpected {text[pos:pos + 20]!r}")
        kind = m.lastgroup
        if kind == "string":
            toks.append(("string", _unquote(m.group()), pos))
        elif kind == "int":
            toks.append(("int", int(m.group()), pos))
        elif kind in ("ident", "op"):
            toks.append((kind, m.group(), pos))
        pos = m.end()
    toks.append(("eof", None, pos))
    return toks


class Parser:
    def __init__(self, text, path):
        self.text, self.path = text, path
        self.toks = tokenize(text, path)
        self.i = 0

    def error(self, msg):
        pos = self.toks[self.i][2]
        line = self.text.count("\n", 0, pos) + 1
        raise ParseError(f"{self.path}:{line}: {msg}")

    def peek(self, k=0):
        return self.toks[self.i + k]

    def take(self, kind=None, value=None):
        t = self.toks[self.i]
        if (kind and t[0] != kind) or (value is not None and t[1] != value):
            self.error(f"expected {value or kind}, found {t[1]!r}")
        self.i += 1
        return t

    def accept(self, value):
        if self.toks[self.i][1] == value and self.toks[self.i][0] in ("op", "ident"):
            self.i += 1
            return True
        return False

    def file(self):
        """[("assign", name, op, value) | ("module", type, props)]"""
        defs = []
        while self.peek()[0] != "eof":
            name = self.take("ident")[1]
            if self.accept("="):
                defs.append(("assign", name, "=", self.expr()))
            elif self.accept("+="):
                defs.append(("assign", name, "+=", self.expr()))
            elif self.accept("{"):
                defs.append(("module", name, self.props("}", ":")))
            elif self.accept("("):
                defs.append(("module", name, self.props(")", "=")))
            else:
                self.error(f"expected a module or an assignment after {name}")
        return defs

    def props(self, close, sep):
        props = {}
        while not self.accept(close):
            key = self.take("ident")[1]
            self.take("op", sep)
            props[key] = self.expr()
            if not self.accept(","):
                self.take("op", close)
                break
        return props

    def expr(self):
        parts = [self.operand()]
        while self.accept("+"):
            parts.append(self.operand())
        return parts[0] if len(parts) == 1 else Concat(parts)

    def operand(self):
        kind, value, _ = self.peek()
        if kind in ("string", "int"):
            self.i += 1
            return value
        if kind == "ident":
            self.i += 1
            if value == "true":
                return True
            if value == "false":
                return False
            if value == "unset":
                return UNSET
            if value == "select" and self.peek()[1] == "(":
                return self.select()
            return Ref(value)
        if self.accept("["):
            items = []
            while not self.accept("]"):
                items.append(self.expr())
                if not self.accept(","):
                    self.take("op", "]")
                    break
            return items
        if self.accept("{"):
            return self.props("}", ":")
        self.error(f"unexpected {value!r}")

    def condition(self):
        func = self.take("ident")[1]
        self.take("op", "(")
        args = []
        while not self.accept(")"):
            args.append(self.take("string")[1])
            if not self.accept(","):
                self.take("op", ")")
                break
        return (func, args)

    def pattern(self):
        kind, value, _ = self.peek()
        if kind == "string":
            self.i += 1
            return value
        if kind == "ident" and value in ("true", "false"):
            self.i += 1
            return value == "true"
        if kind == "ident" and value == "default":
            self.i += 1
            return "default"
        if kind == "ident" and value == "any":
            self.i += 1
            binding = None
            if self.accept("@"):
                binding = self.take("ident")[1]
            return ("any", binding)
        self.error(f"unexpected select pattern {value!r}")

    def select(self):
        # operand() has consumed the keyword.
        self.take("op", "(")
        if self.accept("("):
            conditions = []
            while not self.accept(")"):
                conditions.append(self.condition())
                if not self.accept(","):
                    self.take("op", ")")
                    break
        else:
            conditions = [self.condition()]
        self.take("op", ",")
        self.take("op", "{")
        cases = []
        while not self.accept("}"):
            if self.accept("("):
                pats = []
                while not self.accept(")"):
                    pats.append(self.pattern())
                    if not self.accept(","):
                        self.take("op", ")")
                        break
            else:
                pats = [self.pattern()]
            self.take("op", ":")
            cases.append((pats, self.expr()))
            if not self.accept(","):
                self.take("op", "}")
                break
        self.accept(",")
        self.take("op", ")")
        return Select(conditions, cases)


def parse(text, path="<string>"):
    return Parser(text, path).file()


def parse_file(path):
    with open(path, encoding="utf-8") as f:
        return parse(f.read(), path)

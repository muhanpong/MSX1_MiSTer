#!/usr/bin/env python3
"""Repair the two things ghdl emits that Verilog will not take.

1.  A VHDL signal whose name is a Verilog keyword comes out escaped (``\\reg ``),
    which is right -- but when ghdl flattens a sub-instance it PREFIXES the
    escaped name, giving ``u0_\\reg ``.  An escaped identifier has to start at
    the backslash, so that is a syntax error.  Move the backslash to the front.
    ghdl 4.1.0 does this for T80's ``reg``; another ghdl may not.

2.  ``do`` is a SystemVerilog keyword and Verilator 5 refuses it as a plain
    identifier, where Verilator 4 took it.  T80 has a port called ``do``, so
    escape it at its three sites: the declaration, the assign and the
    connection.  Escaping changes how the name is spelled, not which name it is.

Both rewrites are no-ops on output that does not contain them, so a toolchain
that never produces these patterns is unaffected.  The verilator lint in
prep.sh is what proves the result is still acceptable.
"""
import pathlib
import re
import sys

SV_KEYWORDS = ("do",)


def fix(text):
    n = 0
    #  u0_\reg   ->  \u0_reg
    text, k = re.subn(r"([A-Za-z_][A-Za-z0-9_]*)\\([A-Za-z_][A-Za-z0-9_]*) ",
                      lambda m: "\\" + m.group(1) + m.group(2) + " ", text)
    n += k
    for kw in SV_KEYWORDS:
        esc = "\\" + kw + " "
        #  (?<!\\) keeps this idempotent: ghdl 6 already escapes `do` itself, and
        #  escaping an escaped name again gives `\\do`, which is not an identifier.
        for pat, repl in (
            (r"(?m)^(\s*(?:input|output|inout)\b[^;,]*?)(?<![\\\w])" + kw + r"\b",
             lambda m: m.group(1) + esc),
            (r"(?m)^(\s*assign\s+)(?<!\\)" + kw + r"\b",
             lambda m: m.group(1) + esc),
            (r"(?<!\\)\." + kw + r"\(",
             lambda m: "." + esc + "("),
        ):
            text, k = re.subn(pat, repl, text)
            n += k
    return text, n


def main():
    out = pathlib.Path(sys.argv[1] if len(sys.argv) > 1 else ".")
    files = 0
    for f in sorted(out.glob("*.v")):
        orig = f.read_text()
        text, n = fix(orig)
        if text != orig:
            f.write_text(text)
            files += 1
            print(f"  {f.name}: {n} identifier(s) repaired")
    print(f"identifier fixups: {files} file(s)")


if __name__ == "__main__":
    main()

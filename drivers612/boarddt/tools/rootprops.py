#!/usr/bin/env python3
"""rootprops.py <dtb>: root properties of a dtbo entry as dts lines (selection properties)."""
import os, struct, sys
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import fdt
for k, v in fdt.load(sys.argv[1]).props.items():
    if fdt.is_strings(v):
        val = ", ".join('"%s"' % s for s in fdt.strings(v))
    else:
        val = "<" + " ".join("0x%x" % c for c in struct.unpack(">%dI" % (len(v) // 4), v)) + ">"
    print("\t%s = %s;" % (k, val))

#!/usr/bin/env python3
"""Minimal FDT reader (no external deps): dtb -> Node tree, plus overlay metadata."""
import struct
from collections import OrderedDict

class Node:
    __slots__ = ("name", "props", "children", "parent")
    def __init__(self, name, parent=None):
        self.name, self.props, self.children, self.parent = name, OrderedDict(), OrderedDict(), parent
    def path(self):
        if self.parent is None:
            return "/"
        p = self.parent.path()
        return (p if p.endswith("/") else p + "/") + self.name
    def walk(self):
        yield self
        for c in self.children.values():
            yield from c.walk()
    def get(self, path):
        n = self
        for part in [x for x in path.split("/") if x]:
            n = n.children.get(part)
            if n is None:
                return None
        return n

def parse(blob):
    magic, total, off_struct, off_strings = struct.unpack_from(">IIII", blob, 0)
    assert magic == 0xd00dfeed, "not a dtb"
    def cstr(o):
        e = blob.index(b"\0", o)
        return blob[o:e].decode()
    p = off_struct
    root = cur = None
    while True:
        tok = struct.unpack_from(">I", blob, p)[0]; p += 4
        if tok == 1:
            name = cstr(p); p = (p + len(name) + 1 + 3) & ~3
            if cur is None:
                root = cur = Node("")
            else:
                n = Node(name, cur); cur.children[name] = n; cur = n
        elif tok == 2:
            cur = cur.parent
            if cur is None and root is not None:
                pass
        elif tok == 3:
            ln, no = struct.unpack_from(">II", blob, p); p += 8
            cur.props[cstr(off_strings + no)] = blob[p:p + ln]; p = (p + ln + 3) & ~3
        elif tok == 4:
            continue
        elif tok == 9:
            break
        else:
            raise ValueError("bad token %x" % tok)
    return root

def load(path):
    with open(path, "rb") as f:
        return parse(f.read())

def strings(b):
    return [s.decode() for s in b.split(b"\0")[:-1]]

def symbols(root):
    s = root.children.get("__symbols__")
    return {k: v.rstrip(b"\0").decode() for k, v in s.props.items()} if s else {}

def is_strings(b):
    if not b or b[-1] != 0:
        return False
    parts = b[:-1].split(b"\0")
    return all(len(x) > 0 and all(32 <= c < 127 for c in x) for x in parts)

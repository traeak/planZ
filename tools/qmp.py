#!/usr/bin/env python3
"""Talk to a QEMU started with -qmp unix:SOCK,server=on,wait=off.

usage: qmp.py SOCK command [args]...

  shot FILE            screenshot: a PPM if FILE ends in .ppm, otherwise a PNG
  key QCODE...         press the keys together, e.g. "key ctrl alt delete"
  type TEXT            type printable ASCII text; \\n is Enter
  move DX DY           relative mouse motion
  abs X Y              absolute pointer position, 0..32767 (needs a tablet)
  btn left|middle|right down|up|click
  raw JSON             send one QMP command, print the reply

Several commands can be given, separated by a lone ",".
"""

import json
import os
import socket
import struct
import sys
import tempfile
import time
import zlib

KEYS = {
    " ": "spc", "\n": "ret", "\t": "tab", "-": "minus", "=": "equal",
    "[": "bracket_left", "]": "bracket_right", ";": "semicolon",
    "'": "apostrophe", "`": "grave_accent", "\\": "backslash", ",": "comma",
    ".": "dot", "/": "slash",
}
SHIFTED = {
    "!": "1", "@": "2", "#": "3", "$": "4", "%": "5", "^": "6", "&": "7",
    "*": "8", "(": "9", ")": "0", "_": "minus", "+": "equal",
    "{": "bracket_left", "}": "bracket_right", ":": "semicolon",
    '"': "apostrophe", "~": "grave_accent", "|": "backslash", "<": "comma",
    ">": "dot", "?": "slash",
}


class Qmp:
    def __init__(self, path):
        self.s = socket.socket(socket.AF_UNIX)
        self.s.connect(path)
        self.f = self.s.makefile("rw")
        self.f.readline()  # greeting
        self.cmd("qmp_capabilities")

    def cmd(self, name, **args):
        msg = {"execute": name}
        if args:
            msg["arguments"] = args
        self.f.write(json.dumps(msg) + "\n")
        self.f.flush()
        while True:
            line = self.f.readline()
            if not line:
                sys.exit("qmp: connection closed")
            r = json.loads(line)
            if "event" in r:
                continue
            if "error" in r:
                sys.exit("qmp: %s: %s" % (name, r["error"].get("desc")))
            return r.get("return")

    def keys(self, names):
        self.cmd("send-key", keys=[{"type": "qcode", "data": k} for k in names])
        time.sleep(0.12)

    def events(self, evs):
        self.cmd("input-send-event", events=evs)
        time.sleep(0.03)


def keysfor(c):
    if c in KEYS:
        return [KEYS[c]]
    if c in SHIFTED:
        return ["shift", SHIFTED[c]]
    if c.isalpha() and c.isascii():
        return ["shift", c.lower()] if c.isupper() else [c]
    if c.isdigit():
        return [c]
    sys.exit("qmp: cannot type %r" % c)


def ppm2png(ppm, png):
    data = open(ppm, "rb").read()
    # P6, width, height, maxval, each followed by white space.
    fields, i = [], 0
    while len(fields) < 4:
        j = i
        while not data[j:j + 1].isspace():
            j += 1
        fields.append(data[i:j])
        i = j + 1
    w, h = int(fields[1]), int(fields[2])
    raw = b"".join(b"\0" + data[i + y * w * 3:i + (y + 1) * w * 3] for y in range(h))

    def chunk(t, d):
        return struct.pack(">I", len(d)) + t + d + struct.pack(">I", zlib.crc32(t + d))

    with open(png, "wb") as f:
        f.write(b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 2, 0, 0, 0))
                + chunk(b"IDAT", zlib.compress(raw, 6)) + chunk(b"IEND", b""))


def run(q, c, a):
    if c == "shot":
        fd, ppm = tempfile.mkstemp(suffix=".ppm")
        os.close(fd)
        try:
            q.cmd("screendump", filename=ppm)
            if a[0].endswith(".ppm"):
                open(a[0], "wb").write(open(ppm, "rb").read())
            else:
                ppm2png(ppm, a[0])
        finally:
            os.unlink(ppm)
    elif c == "key":
        q.keys(a)
    elif c == "type":
        for ch in a[0].replace("\\n", "\n"):
            q.keys(keysfor(ch))
    elif c == "move":
        q.events([{"type": "rel", "data": {"axis": "x", "value": int(a[0])}},
                  {"type": "rel", "data": {"axis": "y", "value": int(a[1])}}])
    elif c == "abs":
        q.events([{"type": "abs", "data": {"axis": "x", "value": int(a[0])}},
                  {"type": "abs", "data": {"axis": "y", "value": int(a[1])}}])
    elif c == "btn":
        downs = {"down": [True], "up": [False], "click": [True, False]}[a[1]]
        for d in downs:
            q.events([{"type": "btn", "data": {"button": a[0], "down": d}}])
            time.sleep(0.1)
    elif c == "raw":
        m = json.loads(a[0])
        print(json.dumps(q.cmd(m["execute"], **m.get("arguments", {}))))
    else:
        sys.exit("qmp: unknown command " + c)


def main():
    if len(sys.argv) < 3:
        sys.exit(__doc__)
    q = Qmp(sys.argv[1])
    cur = []
    for a in sys.argv[2:] + [","]:
        if a == ",":
            if cur:
                run(q, cur[0], cur[1:])
            cur = []
        else:
            cur.append(a)


main()

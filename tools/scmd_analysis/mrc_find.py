#!/usr/bin/env python3
"""Search the parsed msx.org thread.

Usage:  mrc_find.py REGEX [AUTHOR] [WINDOW]
        AUTHOR ''  = any author.  Manuel Pazos posts as `guillian`.
        WINDOW     = context characters either side (default 400)

Reads posts.json from $MRC_DIR or ~/msx_archive/mfrsd_scmd_20260823/thread
(produced by mrc_parse.py).

    mrc_find.py "64 ?K.{0,30}RAM" guillian 330
"""
import json, re, sys, os

DEFAULT = os.path.expanduser('~/msx_archive/mfrsd_scmd_20260823/thread')
DIR = os.environ.get('MRC_DIR', DEFAULT)

posts = json.load(open(os.path.join(DIR, 'posts.json')))
rx = re.compile(sys.argv[1], re.I)
only = sys.argv[2] if len(sys.argv) > 2 and sys.argv[2] else None
W = int(sys.argv[3]) if len(sys.argv) > 3 else 400

n = 0
for p in posts:
    if only and p['author'] != only:
        continue
    t = p['text']
    spans = []
    for m in rx.finditer(t):
        a, b = max(0, m.start() - W), min(len(t), m.end() + W)
        if spans and a <= spans[-1][1]:          # merge overlapping windows
            spans[-1] = (spans[-1][0], max(b, spans[-1][1]))
        else:
            spans.append((a, b))
    if not spans:
        continue
    n += 1
    print(f"=== p{p['page']} | {p['author']} | {p['date']}")
    for a, b in spans[:3]:
        print("  ..." + re.sub(r'\n', ' / ', t[a:b]) + "...")
    print()
print(f"[{n} posts]")

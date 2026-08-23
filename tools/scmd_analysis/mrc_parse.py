#!/usr/bin/env python3
"""Parse a scraped msx.org forum thread into posts.json.

Usage:  mrc_parse.py [DIR]        (DIR holds p000.html ... pNNN.html)
        DIR defaults to $MRC_DIR or ~/msx_archive/mfrsd_scmd_20260823/thread

Scrape the pages first, e.g.:
    B="https://msx.org/forum/msx-talk/hardware/big-megaflashrom-scc-sd-topic"
    for i in $(seq 0 107); do
      f=$(printf "p%03d.html" $i)
      [ "$i" = 0 ] && U="$B" || U="$B?page=$i"
      curl -sS -A "Mozilla/5.0" -o "$f" "$U"; sleep 0.4
    done
(msx.org returns 403 to the default curl/python user agent.)
"""
import re, glob, html, json, os, sys

DEFAULT = os.path.expanduser('~/msx_archive/mfrsd_scmd_20260823/thread')
DIR = sys.argv[1] if len(sys.argv) > 1 else os.environ.get('MRC_DIR', DEFAULT)


def strip(t):
    t = re.sub(r'(?is)<(script|style).*?</\1>', ' ', t)
    t = re.sub(r'(?is)<div class="quote-author"><em>([^<]*)</em>[^<]*</div>',
               r' [quoting \1] ', t)
    t = re.sub(r'(?i)<br\s*/?>', '\n', t)
    t = re.sub(r'(?i)</p>|</div>', '\n', t)
    t = re.sub(r'<[^>]+>', ' ', t)
    t = html.unescape(t)
    t = re.sub(r'[ \t]+', ' ', t)
    t = re.sub(r'\n\s*\n+', '\n', t)
    # drop the pager / site chrome that trails the last post on each page
    t = re.split(r'\n ?Last ?\n ?Next ?\n', t)[0]
    t = re.split(r'Login or register to post comments', t)[0]
    return t.strip()


posts = []
for f in sorted(glob.glob(os.path.join(DIR, 'p*.html'))):
    pg = int(re.search(r'p(\d+)\.html', f).group(1))
    h = open(f, encoding='utf-8', errors='replace').read()
    # each post begins with <div class="author"> and runs to the next one
    for c in h.split('<div class="author">')[1:]:
        au = re.search(r'/users/([^"]+)"', c)
        dt = re.findall(r'([0-9]{2}-[0-9]{2}-[0-9]{4},\s*[0-9:]+)', c[:1500])
        i = c.find('<div class="txt">')
        if i < 0:
            continue
        body = c[i:]
        j = body.find('<div class="comment-options"')
        if j > 0:
            body = body[:j]
        posts.append(dict(page=pg, author=au.group(1) if au else '?',
                          date=dt[0] if dt else '?', text=strip(body)))

out = os.path.join(DIR, 'posts.json')
json.dump(posts, open(out, 'w'))
print("pages:", len(glob.glob(os.path.join(DIR, 'p*.html'))),
      "posts:", len(posts), "->", out)

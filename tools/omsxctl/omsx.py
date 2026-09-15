#!/usr/bin/env python3
"""Minimal openMSX control-socket client: omsx.py 'tcl command' ['tcl command' ...]"""
import socket, sys, glob, re, html
path = sorted(glob.glob('/tmp/openmsx-*/socket.*'))[-1]
s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM); s.connect(path); s.settimeout(30)
buf = b''
def recv_until(pat):
    global buf
    while not re.search(pat, buf):
        chunk = s.recv(65536)
        if not chunk: break
        buf += chunk
s.sendall(b'<openmsx-control>\n')
for cmd in sys.argv[1:]:
    s.sendall(('<command>' + html.escape(cmd) + '</command>\n').encode())
    recv_until(rb'<reply result="(ok|nok)">.*?</reply>')
    m = re.search(rb'<reply result="(ok|nok)">(.*?)</reply>', buf, re.S)
    res, body = m.group(1).decode(), html.unescape(m.group(2).decode())
    buf = buf[m.end():]
    print(f"[{res}] {cmd}\n{body}")

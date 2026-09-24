#  Extract exactly what createMSXpack.py reads from the XMLs into one compact JSON.
#  Everything else in the XML (comments, prose, unused tags) is dropped.
import glob, json, os, re, xml.etree.ElementTree as ET, collections

def shas(node):
    """Every accepted SHA-1, in XML order.  More than one is allowed when several dumps
    of the same firmware are usable; the page takes the first one it actually has."""
    out = []
    for tag in ('SHA1', 'sha1'):
        for e in node.findall(tag):
            if e.text is not None and e.text.strip() and e.text.strip() not in out:
                out.append(e.text.strip())
    return out


def put_shas(e, node):
    hs = shas(node)
    if hs:
        e['h'] = hs[0]                 # 대표 해시 (한 개뿐이면 이것만)
        if len(hs) > 1:
            e['hs'] = hs
    return e


def blk(b, sec):
    v = {'start': int(b.attrib['start']) & 3 if 'start' in b.attrib else None}
    for tag, key, conv in (('type','t',str), ('block_count','n',int), ('filename','f',str),
                           ('pattern','p',int), ('skip','s',int), ('ref','r',str)):
        e = b.find(tag)
        if e is not None and e.text is not None:
            v[key] = conv(e.text.strip())
    v = {k: x for k, x in v.items() if x is not None}
    return put_shas(v, b)

machines, layouts = [], collections.OrderedDict()
for f in sorted(glob.glob('Computer/*/*.xml')):
    r = ET.parse(f).getroot()
    if r.tag != 'msxConfig':
        continue
    m = {'name': os.path.basename(f)[:-4], 'vendor': f.split('/')[1], 'kind': 'msx'}
    t = r.findtext('type')
    if t: m['type'] = t.strip()
    kb = r.findtext('kbd_layout')
    if kb:
        kb = kb.strip()
        if kb not in layouts:
            layouts[kb] = len(layouts)
        m['kbd'] = layouts[kb]
    slots = []
    for pr in r.findall('./primary'):
        for sec in pr.findall('./secondary'):
            bl = [blk(b, sec) for b in sec.findall('./block')]
            if bl:
                slots.append({'ps': int(pr.attrib['slot']), 'ss': int(sec.attrib['slot']), 'b': bl})
    m['slots'] = slots
    devs = []
    for d in r.findall('./device'):
        e = {'typ': d.attrib['typ']}
        rom = d.find('./rom')
        if rom is not None:
            fn = rom.findtext('filename')
            if fn: e['f'] = fn.strip()
            put_shas(e, rom)
        devs.append(e)
    if devs:
        m['devices'] = devs
    machines.append(m)

for f in sorted(glob.glob('Extension/*.xml')):
    r = ET.parse(f).getroot()
    if r.tag != 'fwConfig':
        continue
    fws = []
    for fw in r.findall('./fw'):
        e = {'name': fw.attrib['name']}
        for tag, key, conv in (('filename','f',str), ('size','sz',int), ('skip','s',int)):
            x = fw.find(tag)
            if x is not None and x.text is not None:
                e[key] = conv(x.text.strip())
        fws.append(put_shas(e, fw))
    machines.append({'name': os.path.basename(f)[:-4], 'vendor': 'Extension', 'kind': 'fw', 'fw': fws})

out = {'layouts': list(layouts.keys()), 'machines': machines}
print(json.dumps(out, separators=(',', ':')))

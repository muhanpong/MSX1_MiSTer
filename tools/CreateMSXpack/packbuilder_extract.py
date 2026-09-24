#  Extract exactly what createMSXpack.py reads from the XMLs into one compact JSON.
#  Everything else in the XML (comments, prose, unused tags) is dropped.
import glob, json, os, re, xml.etree.ElementTree as ET, collections

def blk(b, sec):
    v = {'start': int(b.attrib['start']) & 3 if 'start' in b.attrib else None}
    for tag, key, conv in (('type','t',str), ('block_count','n',int), ('filename','f',str),
                           ('SHA1','h',str), ('pattern','p',int), ('skip','s',int), ('ref','r',str)):
        e = b.find(tag)
        if e is not None and e.text is not None:
            v[key] = conv(e.text.strip())
    return {k: x for k, x in v.items() if x is not None}

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
            h = rom.findtext('sha1')
            fn = rom.findtext('filename')
            if h: e['h'] = h.strip()
            if fn: e['f'] = fn.strip()
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
        for tag, key, conv in (('filename','f',str), ('SHA1','h',str), ('size','sz',int), ('skip','s',int)):
            x = fw.find(tag)
            if x is not None and x.text is not None:
                e[key] = conv(x.text.strip())
        fws.append(e)
    machines.append({'name': os.path.basename(f)[:-4], 'vendor': 'Extension', 'kind': 'fw', 'fw': fws})

out = {'layouts': list(layouts.keys()), 'machines': machines}
print(json.dumps(out, separators=(',', ':')))

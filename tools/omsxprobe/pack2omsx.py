#!/usr/bin/env python3
"""pack2omsx.py -- turn MiSTer MSX1 pack XMLs into equivalent openMSX machine XMLs.

Slots, ROM files/SHA1s, RAM mapper size, FDC (WD2793 + the pack's disk ROM) and the
contents of every subslot are taken from the pack XML verbatim.  Only the off-slot
hardware (VDP, PSG, RTC, printer port, T9769 ...) comes from the stock openMSX machine
used as a template; switched-I/O devices the pack does not declare (S1985, Matsushita,
reset-status) are dropped, because the core does not have them either.
Packs declaring MOONSOUND need `-ext moonsound` on the openMSX command line (listed in
the 2nd output column).

Validated 20260923: SD Snatcher boot matrix over 13 Panasonic packs matched the board.

usage: pack2omsx.py OUTDIR [--packs DIR] [--rom DIR] [--match REGEX]
  OUTDIR   an openMSX user machines dir, e.g. $OPENMSX_HOME/share/machines
  --packs  pack XML dir   (default: tools/CreateMSXpack/Computer/Panasonic)
  --rom    ROM collection (default: tools/CreateMSXpack/ROM; used to size kanji fonts)
  --match  filename regex (default: Panasonic FS-A1(F|FX|WX)[ .])
Machines are written as PK_<pack name>.xml.  Templates: FS-A1F / FS-A1FX / FS-A1WX only.
"""
import argparse
import sys, xml.etree.ElementTree as ET, re, os
HERE=os.path.dirname(os.path.abspath(__file__))
ap=argparse.ArgumentParser(); ap.add_argument('out')
ap.add_argument('--packs',default=os.path.join(HERE,'..','CreateMSXpack','Computer','Panasonic'))
ap.add_argument('--rom',default=os.path.join(HERE,'..','CreateMSXpack','ROM'))
ap.add_argument('--match',default=r'Panasonic FS-A1(F|FX|WX)[ .]')
A=ap.parse_args(); PACKDIR=A.packs; ROM=A.rom; out=A.out
def tmpl(name):
    if 'F1XDmk2' in name: return 'Sony_HB-F1XDmk2'
    if 'F1XV' in name: return 'Sony_HB-F1XV'
    if 'A1FX' in name: return 'Panasonic_FS-A1FX'
    if 'A1WX' in name: return 'Panasonic_FS-A1WX'
    return 'Panasonic_FS-A1F'
def romel(fn,sha):
    r=ET.Element('rom'); ET.SubElement(r,'filename').text=fn; ET.SubElement(r,'sha1').text=sha; return r
def dev_for(b):
    t=b.find('type').text; start=int(b.attrib.get('start','0'))
    cnt=b.find('block_count'); cnt=int(cnt.text) if cnt is not None else 0
    fn=b.find('filename'); fn=fn.text if fn is not None else None
    sha=b.find('SHA1'); sha=sha.text if sha is not None else None
    ident=b.attrib.get('id',t)
    if t=='ROM':
        e=ET.Element('ROM',id=ident); ET.SubElement(e,'mappertype').text='Normal'
        e.append(romel(fn,sha)); ET.SubElement(e,'mem',base=hex(start*0x4000),size=hex(cnt*0x4000)); return e
    if t=='MSX-MUSIC':
        e=ET.Element('MSX-MUSIC',id='MSX Music'); ET.SubElement(e,'io',base='0x7C',num='2',type='O')
        ET.SubElement(e,'mem',base='0x4000',size='0x4000'); e.append(romel(fn,sha))
        s=ET.SubElement(e,'sound'); ET.SubElement(s,'volume').text='9000'; return e
    if t=='RAM MAPPER':
        e=ET.Element('MemoryMapper',id='Main RAM'); ET.SubElement(e,'size').text=str(cnt*16)
        ET.SubElement(e,'mem',base='0x0000',size='0x10000'); return e
    if t=='FDC':
        e=ET.Element('WD2793',id='Memory Mapped FDC'); ET.SubElement(e,'connectionstyle').text='Sony'
        ET.SubElement(e,'motor_off_timeout_ms').text='4000'; ET.SubElement(e,'drives').text='1'
        e.append(romel(fn,sha)); ET.SubElement(e,'mem',base='0x4000',size='0x8000'); return e
    if t=='MSXDOS2':
        e=ET.Element('ROM',id='MSX-DOS2 ROM'); ET.SubElement(e,'mappertype').text='MSXDOS2'
        e.append(romel(fn,sha)); ET.SubElement(e,'mem',base='0x4000',size='0x4000'); return e
    raise SystemExit(f"unhandled block type {t}")
made=[]
for f in sorted(os.listdir(PACKDIR)):
    if not f.endswith('.xml') or not re.match(A.match,f): continue
    pk=ET.parse(os.path.join(PACKDIR,f)).getroot()
    base=tmpl(f)
    mt=ET.parse(f'/usr/share/openmsx/machines/{base}.xml'); m=mt.getroot()
    dv=m.find('devices')
    declared={d.attrib['typ'] for d in pk.findall('./device')}
    for c in list(dv):
        if c.tag=='primary': dv.remove(c)
        elif c.tag in ('S1985',) : dv.remove(c)                      # core has no MSX-ENGINE backup RAM
        elif c.tag=='Matsushita' and 'MATSUSHITA' not in declared: dv.remove(c)
        elif c.tag=='ResetStatusRegister' and 'RESET_STATUS' not in declared: dv.remove(c)
        elif c.tag=='Kanji':
            kd=[d for d in pk.findall('./device') if d.attrib['typ']=='KANJI'][0].find('rom')
            for r in c.findall('rom'): c.remove(r)
            kfn=kd.find('filename').text; ksha=kd.find('sha1').text
            c.append(romel(kfn,ksha))
            cand=[os.path.join(dp,x) for dp,_,xs in os.walk(ROM) for x in xs if x==kfn]
            if not cand:                                  # pack filenames need not match the ROM store
                import hashlib
                cand=[os.path.join(dp,x) for dp,_,xs in os.walk(ROM) for x in xs
                      if hashlib.sha1(open(os.path.join(dp,x),'rb').read()).hexdigest()==ksha]
            sz=os.path.getsize(cand[0])
            io=c.find('io'); io.attrib['num']='4' if sz>=0x40000 else '2'
    # slots
    for p in pk.findall('./primary'):
        ps=p.attrib['slot']; secs=p.findall('./secondary')
        blocks=[(s.attrib['slot'],b) for s in secs for b in s.findall('./block')]
        ext=[b for _,b in blocks if b.find('type').text in ('SLOT A','SLOT B')]
        if ext: ET.SubElement(dv,'primary',external='true',slot=ps); continue
        pe=ET.Element('primary',slot=ps)
        expanded=any(ss!='0' for ss,_ in blocks)
        if expanded:
            for n in '0123':
                se=ET.SubElement(pe,'secondary',slot=n)
                for ss,b in blocks:
                    if ss==n: se.append(dev_for(b))
        else:
            for _,b in blocks: pe.append(dev_for(b))
        dv.insert(0,pe)
    name='PK_'+re.sub(r'[^A-Za-z0-9]+','_',f[:-4].replace('Panasonic ','')).strip('_')
    info=m.find('info')
    ET.indent(mt)
    open(os.path.join(out,name+'.xml'),'w',encoding='utf-8').write("<?xml version=\"1.0\" ?>\n<!DOCTYPE msxconfig SYSTEM 'msxconfig2.dtd'>\n"+ET.tostring(m,encoding='unicode'))
    made.append((name, 'MOONSOUND' in declared, f))
for n,ms,f in made: print(f"{n}\t{int(ms)}\t{f}")

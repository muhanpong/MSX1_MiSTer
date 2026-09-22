# compact Z80 decoder: length + mnemonic + 16-bit operand info
R=['B','C','D','E','H','L','(HL)','A']; RP=['BC','DE','HL','SP']; RP2=['BC','DE','HL','AF']
CC=['NZ','Z','NC','C','PO','PE','P','M']; ALU=['ADD A,','ADC A,','SUB ','SBC A,','AND ','XOR ','OR ','CP ']
def w(m,a): return m[a&0xFFFF] | (m[(a+1)&0xFFFF]<<8)
def dec(m,pc):
    """returns (len, text, kind, target) ; kind in call,jp,jr,ret,rst,imm16,mem16,None"""
    op=m[pc]; ix=None; base=pc
    if op in (0xDD,0xFD):
        ix='IX' if op==0xDD else 'IY'; pc+=1; op=m[pc]
        if op==0xCB:
            d=m[pc+1]; o=m[pc+2]; return (4,f"{ix}-CB {d:02X} {o:02X}",None,None)
        if op in (0xDD,0xFD,0xED): return (1,'NOP*',None,None)
    x,y,z=op>>6,(op>>3)&7,op&7; p,q=y>>1,y&1
    HL = ix or 'HL'
    def ind(): return f"({ix}+{m[pc+1]:02X})" if ix else '(HL)'
    pre = 1 if ix else 0
    uses_d = ix and (op in (0x34,0x35,0x36) or (0x40<=op<=0x7F and op!=0x76 and (z==6 or y==6)) or (0x80<=op<=0xBF and z==6))
    dl = 1 if uses_d else 0
    if op==0xCB: return (2,f"CB {m[pc+1]:02X}",None,None)
    if op==0xED:
        o=m[pc+1]
        if o in (0x43,0x53,0x63,0x73): a=w(m,pc+2); return (4,f"LD ({a:04X}),{RP[(o>>4)&3]}",'mem16',a)
        if o in (0x4B,0x5B,0x6B,0x7B): a=w(m,pc+2); return (4,f"LD {RP[(o>>4)&3]},({a:04X})",'mem16',a)
        names={0xB0:'LDIR',0xB8:'LDDR',0xB1:'CPIR',0xB2:'INIR',0xB3:'OTIR',0xA0:'LDI',0xA3:'OUTI',0xA2:'INI',0x45:'RETN',0x4D:'RETI',0x56:'IM 1',0x46:'IM 0',0x5E:'IM 2',0x47:'LD I,A',0x57:'LD A,I',0x44:'NEG',0x52:'SBC HL,DE',0x5A:'ADC HL,DE',0x42:'SBC HL,BC',0x4A:'ADC HL,BC',0x62:'SBC HL,HL',0x72:'SBC HL,SP',0x78:'IN A,(C)',0x79:'OUT (C),A',0x6F:'RLD',0x67:'RRD'}
        k='ret' if o in (0x45,0x4D) else None
        return (2,names.get(o,f"ED {o:02X}"),k,None)
    L=lambda n: pre+dl+n
    if x==0:
        if z==0:
            if y==0: return (L(1),'NOP',None,None)
            if y==1: return (L(1),"EX AF,AF'",None,None)
            e=m[pc+1]; t=(pc+2+(e-256 if e>127 else e))&0xFFFF
            nm=['DJNZ','JR','JR NZ,','JR Z,','JR NC,','JR C,'][y-2]
            return (L(2),f"{nm} {t:04X}",'jr' if y==3 else 'jrc',t)
        if z==1:
            if q==0: a=w(m,pc+1); return (L(3),f"LD {HL if p==2 else RP[p]},{a:04X}",'imm16',a)
            return (L(1),f"ADD {HL},{RP[p] if p!=2 else HL}",None,None)
        if z==2:
            if p<2: return (L(1),['LD (BC),A','LD A,(BC)','LD (DE),A','LD A,(DE)'][p*2+q],None,None)
            a=w(m,pc+1)
            t=[f"LD ({a:04X}),{HL}",f"LD {HL},({a:04X})",f"LD ({a:04X}),A",f"LD A,({a:04X})"][(p-2)*2+q]
            return (L(3),t,'mem16',a)
        if z==3: return (L(1),f"{'INC' if q==0 else 'DEC'} {RP[p] if p!=2 else HL}",None,None)
        if z in (4,5): return (L(1),f"{'INC' if z==4 else 'DEC'} {ind() if y==6 else R[y]}",None,None)
        if z==6:
            if y==6 and ix: return (4,f"LD {ind()},{m[pc+2]:02X}",None,None)
            return (L(2),f"LD {ind() if y==6 else R[y]},{m[pc+1+dl]:02X}",None,None)
        return (L(1),['RLCA','RRCA','RLA','RRA','DAA','CPL','SCF','CCF'][y],None,None)
    if x==1:
        if op==0x76: return (1,'HALT',None,None)
        return (L(1),f"LD {ind() if y==6 else R[y]},{ind() if z==6 else R[z]}",None,None)
    if x==2: return (L(1),f"{ALU[y]}{ind() if z==6 else R[z]}",None,None)
    # x==3
    if z==0: return (L(1),f"RET {CC[y]}",'retc',None)
    if z==1:
        if q==0: return (L(1),f"POP {RP2[p] if p!=2 else HL}",None,None)
        return (L(1),['RET','EXX',f'JP ({HL})','LD SP,'+HL][p],['ret',None,'jpind',None][p],None)
    if z==2: a=w(m,pc+1); return (L(3),f"JP {CC[y]},{a:04X}",'jpc',a)
    if z==3:
        if y==0: a=w(m,pc+1); return (L(3),f"JP {a:04X}",'jp',a)
        if y==2: return (L(2),f"OUT ({m[pc+1]:02X}),A",None,None)
        if y==3: return (L(2),f"IN A,({m[pc+1]:02X})",None,None)
        return (L(1),['','',None,None,f'EX (SP),{HL}','EX DE,HL','DI','EI'][y],None,None)
    if z==4: a=w(m,pc+1); return (L(3),f"CALL {CC[y]},{a:04X}",'callc',a)
    if z==5:
        if q==0: return (L(1),f"PUSH {RP2[p] if p!=2 else HL}",None,None)
        a=w(m,pc+1); return (L(3),f"CALL {a:04X}",'call',a)
    if z==6: return (L(2),f"{ALU[y]}{m[pc+1]:02X}",None,None)
    return (L(1),f"RST {y*8:02X}",'rst',y*8)

def explore(m, entries, lo=0x4000, hi=0x8000):
    """recursive descent; returns dict addr->(len,text,kind,target)"""
    code={}; todo=list(entries)
    while todo:
        pc=todo.pop()
        while lo<=pc<hi and pc not in code:
            n,t,k,a=dec(m,pc); code[pc]=(n,t,k,a)
            if k in ('call','callc','jpc','jrc') and a is not None and lo<=a<hi: todo.append(a)
            if k in ('jp','jr'):
                if a is not None and lo<=a<hi: todo.append(a)
                break
            if k in ('ret','jpind'): break
            if k=='rst' and a in (0x08,0x30): pc+=n; continue   # RST 08 / 30 may have inline args; keep going
            pc+=n
    return code

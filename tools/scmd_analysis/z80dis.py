#!/usr/bin/env python3
import sys

r8=['B','C','D','E','H','L','(HL)','A']
rp=['BC','DE','HL','SP']
rp2=['BC','DE','HL','AF']
cc=['NZ','Z','NC','C','PO','PE','P','M']
alu=['ADD A,','ADC A,','SUB ','SBC A,','AND ','XOR ','OR ','CP ']
rot=['RLC','RRC','RL','RR','SLA','SRA','SLL','SRL']

def h8(v): return '0x%02X'%v
def h16(v): return '0x%04X'%v

class D:
    def __init__(self,data,base):
        self.d=data; self.base=base
    def u8(self,p): return self.d[p]
    def u16(self,p): return self.d[p]|(self.d[p+1]<<8)

    def dis(self,p):
        """returns (length, text, targets)  targets=list of (kind,addr)"""
        d=self.d; start=p
        idx='HL'; disp=None
        op=d[p]; p+=1
        if op in (0xDD,0xFD):
            idx='IX' if op==0xDD else 'IY'
            op=d[p]; p+=1
            if op==0xCB:
                disp=self.s8(d[p]); p+=1
                op2=d[p]; p+=1
                return (p-start, self.cb_idx(op2,idx,disp), [])
        if op==0xCB:
            op2=d[p]; p+=1
            return (p-start, self.cb(op2), [])
        if op==0xED:
            op2=d[p]; p+=1
            return self.ed(op2,p,start)
        return self.main(op,p,start,idx)

    def s8(self,v): return v-256 if v>127 else v

    def rname(self,i,idx,disp,p):
        if i==6 and idx!='HL':
            return ('(%s%+d)'%(idx,disp), p)
        if i==6: return ('(HL)',p)
        n=r8[i]
        if idx!='HL' and n in ('H','L'): n=idx+n
        return (n,p)

    def main(self,op,p,start,idx):
        d=self.d; t=[]
        x=op>>6; y=(op>>3)&7; z=op&7; q=y&1; pp=y>>1
        IH=idx
        def need_disp():
            nonlocal p
            if idx!='HL':
                v=self.s8(d[p]); p+=1; return v
            return None
        if x==0:
            if z==0:
                if y==0: return (p-start,'NOP',[])
                if y==1: return (p-start,"EX AF,AF'",[])
                if y==2:
                    e=self.s8(d[p]); p+=1; tgt=(self.base+ (p) + e)&0xFFFF
                    return (p-start,'DJNZ '+h16(tgt),[('j',tgt)])
                if y==3:
                    e=self.s8(d[p]); p+=1; tgt=(self.base+ p + e)&0xFFFF
                    return (p-start,'JR '+h16(tgt),[('j',tgt)])
                e=self.s8(d[p]); p+=1; tgt=(self.base+p+e)&0xFFFF
                return (p-start,'JR %s,%s'%(cc[y-4],h16(tgt)),[('j',tgt)])
            if z==1:
                if q==0:
                    nn=self.u16(p); p+=2
                    n=rp[pp]
                    if n=='HL': n=IH
                    return (p-start,'LD %s,%s'%(n,h16(nn)),[])
                n=rp[pp]
                if n=='HL': n=IH
                return (p-start,'ADD %s,%s'%(IH,n),[])
            if z==2:
                if q==0:
                    if pp==0: return (p-start,'LD (BC),A',[])
                    if pp==1: return (p-start,'LD (DE),A',[])
                    nn=self.u16(p);p+=2
                    if pp==2: return (p-start,'LD (%s),%s'%(h16(nn),IH),[('w',nn)])
                    return (p-start,'LD (%s),A'%h16(nn),[('w',nn)])
                else:
                    if pp==0: return (p-start,'LD A,(BC)',[])
                    if pp==1: return (p-start,'LD A,(DE)',[])
                    nn=self.u16(p);p+=2
                    if pp==2: return (p-start,'LD %s,(%s)'%(IH,h16(nn)),[('r',nn)])
                    return (p-start,'LD A,(%s)'%h16(nn),[('r',nn)])
            if z==3:
                n=rp[pp]
                if n=='HL': n=IH
                return (p-start,('INC ' if q==0 else 'DEC ')+n,[])
            if z==4 or z==5:
                dsp=need_disp()
                nm,p=self.rname(y,idx,dsp,p)
                return (p-start,('INC ' if z==4 else 'DEC ')+nm,[])
            if z==6:
                dsp=need_disp()
                nm,p=self.rname(y,idx,dsp,p)
                n=d[p];p+=1
                return (p-start,'LD %s,%s'%(nm,h8(n)),[])
            return (p-start,['RLCA','RRCA','RLA','RRA','DAA','CPL','SCF','CCF'][y],[])
        if x==1:
            if y==6 and z==6: return (p-start,'HALT',[])
            dsp=None
            if idx!='HL' and (y==6 or z==6):
                dsp=self.s8(d[p]); p+=1
            if y==6:
                dst,p=self.rname(6,idx,dsp,p); src=r8[z]
            elif z==6:
                src,p=self.rname(6,idx,dsp,p); dst=r8[y]
            else:
                dst,_=self.rname(y,idx,None,p); src,_=self.rname(z,idx,None,p)
            return (p-start,'LD %s,%s'%(dst,src),[])
        if x==2:
            dsp=None
            if idx!='HL' and z==6:
                dsp=self.s8(d[p]); p+=1
            nm,p=self.rname(z,idx,dsp,p)
            return (p-start,alu[y]+nm,[])
        # x==3
        if z==0: return (p-start,'RET '+cc[y],[])
        if z==1:
            if q==0:
                n=rp2[pp]
                if n=='HL': n=IH
                return (p-start,'POP '+n,[])
            if pp==0: return (p-start,'RET',[])
            if pp==1: return (p-start,'EXX',[])
            if pp==2: return (p-start,'JP ('+IH+')',[])
            return (p-start,'LD SP,'+IH,[])
        if z==2:
            nn=self.u16(p);p+=2
            return (p-start,'JP %s,%s'%(cc[y],h16(nn)),[('j',nn)])
        if z==3:
            if y==0:
                nn=self.u16(p);p+=2
                return (p-start,'JP '+h16(nn),[('j',nn)])
            if y==1: pass
            if y==2:
                n=d[p];p+=1
                return (p-start,'OUT (%s),A'%h8(n),[('o',n)])
            if y==3:
                n=d[p];p+=1
                return (p-start,'IN A,(%s)'%h8(n),[('i',n)])
            if y==4: return (p-start,'EX (SP),'+IH,[])
            if y==5: return (p-start,'EX DE,HL',[])
            if y==6: return (p-start,'DI',[])
            return (p-start,'EI',[])
        if z==4:
            nn=self.u16(p);p+=2
            return (p-start,'CALL %s,%s'%(cc[y],h16(nn)),[('c',nn)])
        if z==5:
            if q==0:
                n=rp2[pp]
                if n=='HL': n=IH
                return (p-start,'PUSH '+n,[])
            if pp==0:
                nn=self.u16(p);p+=2
                return (p-start,'CALL '+h16(nn),[('c',nn)])
            return (p-start,'?',[])
        if z==6:
            n=d[p];p+=1
            return (p-start,alu[y]+h8(n),[])
        return (p-start,'RST '+h8(y*8),[('c',y*8)])

    def cb(self,op):
        x=op>>6;y=(op>>3)&7;z=op&7
        if x==0: return rot[y]+' '+r8[z]
        return ['','BIT','RES','SET'][x]+' %d,%s'%(y,r8[z])
    def cb_idx(self,op,idx,disp):
        x=op>>6;y=(op>>3)&7;z=op&7
        tgt='(%s%+d)'%(idx,disp)
        if x==0: return rot[y]+' '+tgt
        return ['','BIT','RES','SET'][x]+' %d,%s'%(y,tgt)
    def ed(self,op,p,start):
        x=op>>6;y=(op>>3)&7;z=op&7;q=y&1;pp=y>>1
        if x==1:
            if z==0: return (p-start,'IN %s,(C)'%(r8[y] if y!=6 else 'F'),[])
            if z==1: return (p-start,'OUT (C),%s'%(r8[y] if y!=6 else '0'),[])
            if z==2: return (p-start,('SBC HL,' if q==0 else 'ADC HL,')+rp[pp],[])
            if z==3:
                nn=self.u16(p);p+=2
                if q==0: return (p-start,'LD (%s),%s'%(h16(nn),rp[pp]),[('w',nn)])
                return (p-start,'LD %s,(%s)'%(rp[pp],h16(nn)),[('r',nn)])
            if z==4: return (p-start,'NEG',[])
            if z==5: return (p-start,'RETN' if y!=1 else 'RETI',[])
            if z==6: return (p-start,'IM %d'%[0,0,1,2,0,0,1,2][y],[])
            return (p-start,['LD I,A','LD R,A','LD A,I','LD A,R','RRD','RLD','NOP','NOP'][y],[])
        if x==2 and z<4 and y>=4:
            names={(4,0):'LDI',(4,1):'CPI',(4,2):'INI',(4,3):'OUTI',
                   (5,0):'LDD',(5,1):'CPD',(5,2):'IND',(5,3):'OUTD',
                   (6,0):'LDIR',(6,1):'CPIR',(6,2):'INIR',(6,3):'OTIR',
                   (7,0):'LDDR',(7,1):'CPDR',(7,2):'INDR',(7,3):'OTDR'}
            return (p-start,names[(y,z)],[])
        return (p-start,'DB 0xED,%s'%h8(op),[])

def run(path,base,start_off=0,end_off=None,entries=None):
    data=open(path,'rb').read()
    if end_off is None: end_off=len(data)
    d=D(data,base)
    out=[]
    p=start_off
    while p<end_off:
        try:
            ln,txt,tg=d.dis(p)
        except Exception as e:
            ln,txt,tg=1,'DB 0x%02X'%data[p],[]
        raw=' '.join('%02X'%b for b in data[p:p+ln])
        out.append('%04X  %-14s %s'%(base+p,raw,txt))
        p+=ln
    return '\n'.join(out)

if __name__=='__main__':
    path=sys.argv[1]; base=int(sys.argv[2],0)
    s=int(sys.argv[3],0) if len(sys.argv)>3 else 0
    e=int(sys.argv[4],0) if len(sys.argv)>4 else None
    print(run(path,base,s,e))

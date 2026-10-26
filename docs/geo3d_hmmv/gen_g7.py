# SCREEN 8 (G7, 1 byte per pixel): one-row HMMV vs one-row LINE, HS on, display on
L=[]
def R(r,v): L.append("R %02x %02x"%(r,v&0xFF))
def X(lab,v): L.append("X %s %02x"%(lab,v))
def xy(base,x,y): R(base,x&0xFF); R(base+1,(x>>8)&1); R(base+2,y&0xFF); R(base+3,(y>>8)&7)
def nxy(nx,ny): R(40,nx&0xFF); R(41,(nx>>8)&1); R(42,ny&0xFF); R(43,(ny>>8)&3)
L.append("P4 00")
for hs,disp in ((1,1),(1,0)):
    c="g7hs%dd%d"%(hs,disp); L.append("M "+c)
    R(0,0x0E); R(1,0x40 if disp else 0); R(8,0x0A); R(9,0x80); R(2,0x1F); R(23,0); R(25,0)
    R(14,0); R(15,2); R(20,0x11 if hs else 0x10); R(21,0x00)
    for n in (1,2,4,8,16,32,64,128,256):
        xy(36,0 if n==256 else 37,20); nxy(n,1); R(44,0x5A); R(45,0); X(c+"_HMMVrow%d"%n,0xC0)
        xy(36,0 if n==256 else 37,40); nxy(n if n<256 else 255,0); R(44,0x5A); R(45,0); X(c+"_LINErow%d"%n,0x70)
    for i in range(200):   # back to back, like a polygon's rows
        xy(36,(i*7)%200,5+i%200); nxy(32,1); R(44,(i%200)+1); R(45,0); X(c+"_HMMVbatch200x32",0xC0)
    for i in range(200):
        xy(36,(i*7)%200,5+i%200); nxy(32,0); R(44,(i%200)+1); R(45,0); X(c+"_LINEbatch200x32",0x70)
open("cmds_g7.txt","w").write("\n".join(L)+"\n"); print(len(L))

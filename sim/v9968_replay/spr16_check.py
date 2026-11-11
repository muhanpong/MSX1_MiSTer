#  spr16_check.py frame.ppm N : the N sprites of spr16.py must show as runs at
#  x = 15, 31, 45, ... (16 wide, then 14 each: sprite i hides the first 2 dots of i+1);
#  at most 16 are shown.
import sys
f=open(sys.argv[1],'rb').read(); p=f.split(b'\n',3); w,h=map(int,p[1].split()); d=p[3]; n=min(int(sys.argv[2]),16)
y=47; row=[d[((y+14)*w+x)*3:((y+14)*w+x)*3+3] for x in range(w)]
runs=[]
for x,c in enumerate(row):
    if runs and runs[-1][0]==c: runs[-1][2]+=1
    else: runs.append([c,x-32,1])
got=[(x,k) for c,x,k in runs if c!=b'\0\0\0']
want=[(15,16)]+[(17+14*i,14) for i in range(1,n)]
print("PASS" if got==want else "FAIL", "N=%s"%sys.argv[2], "got", got[-3:], "want", want[-3:])
sys.exit(got!=want)

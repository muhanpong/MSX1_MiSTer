import re,sys
def load(f):
    d={}
    for l in open(f):
        m=re.match(r'FRAME (\d+) run_ns (\d+)',l)
        if m: d[int(m[1])]=int(m[2])
    return d
names=sys.argv[1:]
ds=[load(f) for f in names]
# upstream harness prints frames index starting with 0 (counter of F before R) ; ours prints R index
n=min(len(d) for d in ds)
print("frames",n)
for i,(f,d) in enumerate(zip(names,ds)):
    v=[d[k] for k in sorted(d)][:n]
    print(f"{f}: max {max(v)/1e6:.3f} ms (frame {v.index(max(v))}) mean {sum(v)/len(v)/1e6:.3f} ms")
base=[ds[0][k] for k in sorted(ds[0])][:n]
for f,d in zip(names[1:],ds[1:]):
    v=[d[k] for k in sorted(d)][:n]
    r=[a/b for a,b in zip(v,base)]
    print(f"{f} / {names[0]}: ratio min {min(r):.3f} max {max(r):.3f} mean {sum(r)/len(r):.3f}; max/max {max(v)/max(base):.3f}")

import json,collections,sys,gzip
HS=sys.argv[2]; N=sys.argv[3]
stages=[json.loads(l) for l in open(sys.argv[1])]
def load(h):
    snaps=[];cur=None
    for l in gzip.open(f'{HS}/{N}-{h}.log.gz','rt'):
        p=l.split()
        if p[0]=='T': cur={'t':float(p[1]),'D':{},'N':{},'O':{},'Q':{}}; snaps.append(cur)
        elif p[0]=='cpu': cur['cpu']=list(map(int,p[1:]))
        elif p[0]=='D': cur['D'][p[1]]=(int(p[2]),int(p[3]))
        elif p[0]=='N': cur['N'][p[1]]=(int(p[2]),int(p[3]))
        elif p[0]=='O': cur['O'][p[1]]=int(p[2])
        elif p[0]=='Q': cur['Q'][p[1]]=(p[2],int(p[3]))
    return snaps
H=['node1','node2','node3']
S={h:load(h) for h in H}
def near(sn,t):
    return min(sn,key=lambda s:abs(s['t']-t))
for st in stages:
    t0=st['t0']+1; t1=st['t1']-0.5
    print(f"\n=== qd={st['qd']} {st['MBps']} MB/s clat {st['clat_us']}us  (guest)")
    g0=list(map(int,st['gcpu0'].split()[1:]));g1=list(map(int,st['gcpu1'].split()[1:]))
    d=[b-a for a,b in zip(g0,g1)]; tot=sum(d[:8]) or 1
    print("  guest cpu: user %.0f%% sys %.0f%% iowait %.0f%% softirq %.0f%% (of all vcpus)"%(100*d[0]/tot,100*d[2]/tot,100*d[4]/tot,100*d[6]/tot))
    for h in H:
        a=near(S[h],t0); b=near(S[h],t1); dt=b['t']-a['t']
        c=[y-x for x,y in zip(a['cpu'],b['cpu'])]; tot=sum(c[:8])
        ncpu=tot/dt/100
        cpu="cpu busy %.0f%% (usr %.0f sys %.0f sirq %.0f iow %.0f) of %d cpus"%(100*(tot-c[3]-c[4])/tot,100*c[0]/tot,100*c[2]/tot,100*c[6]/tot,100*c[4]/tot,round(ncpu))
        net=" ".join("%s rx %.0f tx %.0f"%(n,(b['N'][n][0]-a['N'][n][0])/dt/1e6,(b['N'][n][1]-a['N'][n][1])/dt/1e6) for n in ['enp193s0f0','enp193s0f1'])
        disks=[]
        for k in a['D']:
            rd=(b['D'][k][0]-a['D'][k][0])*512/dt/1e6; util=(b['D'][k][1]-a['D'][k][1])/dt/10
            if rd>5 or util>10: disks.append("%s %.0fMB/s %.0f%%"%(k,rd,util))
        osd=" ".join("%.0f"%((b['O'][p]-a['O'][p])/dt) for p in a['O'] if p in b['O'])
        print(f"  {h}: {cpu} | {net} MB/s")
        print(f"        disks: {' '.join(disks)} | ceph-osd %core: {osd}")
        if a['Q']:
            th=collections.Counter()
            for tid,(nm,v) in a['Q'].items():
                if tid in b['Q']: th[f"{nm}"]+=(b['Q'][tid][1]-v)/dt
            print("        qemu threads %core: "+", ".join(f"{n} {v:.0f}" for n,v in th.most_common(6)))

"""Resolve a library's undefined dynamic symbols against a set of provider libraries (BFS over NEEDED)."""
import subprocess, sys, os, re
def needed(p): return re.findall(r'NEEDED.*\[(.*)\]', subprocess.run(['readelf','-dW',p],capture_output=True,text=True).stdout)
def syms(p):
    defs,und=set(),set()
    for l in subprocess.run(['readelf','--dyn-syms','-W',p],capture_output=True,text=True).stdout.splitlines():
        f=l.split()
        if len(f)<8 or not f[0].rstrip(':').isdigit(): continue
        name=f[7].split('@')[0]
        if not name: continue
        if f[6]=='UND':
            if f[4]!='WEAK': und.add(name)
        else: defs.add(name)
    return defs,und
def check(root, paths, system_ok):
    q=[root]; seen={}; missing_libs=set()
    while q:
        p=q.pop(0)
        if p in seen.values(): continue
        seen[os.path.basename(p)]=p
        for n in needed(p):
            if n in seen: continue
            for d in paths:
                c=os.path.join(d,n)
                if os.path.exists(c): q.append(c); seen.setdefault(n,None); break
            else:
                if n not in system_ok: missing_libs.add(n)
    loaded={k:v for k,v in seen.items() if v}
    alldefs=set()
    for p in loaded.values(): alldefs|=syms(p)[0]
    return loaded, missing_libs, alldefs

"""Recover JNINativeMethod {name, signature, fnPtr} tables from an AArch64 .so by scanning
pointer-sized words in data sections (works with RELA and packed RELR relocations)."""
import subprocess, sys, re, struct
def load(path):
    data=open(path,'rb').read()
    segs=[]
    for l in subprocess.run(['readelf','-lW',path],capture_output=True,text=True).stdout.splitlines():
        p=l.split()
        if p and p[0]=='LOAD': segs.append((int(p[2],16),int(p[1],16),int(p[4],16)))
    def rd(va):
        for v,o,fs in segs:
            if v<=va<v+fs:
                o2=o+va-v; e=data.find(b'\0',o2,o2+512)
                if e<0: return None
                try: return data[o2:e].decode('ascii')
                except: return None
        return None
    secs=[]
    for l in subprocess.run(['readelf','-SW',path],capture_output=True,text=True).stdout.splitlines():
        m=re.search(r'\]\s+(\.data\.rel\.ro|\.data)\s+\S+\s+([0-9a-f]+)\s+([0-9a-f]+)\s+([0-9a-f]+)',l)
        if m: secs.append((int(m.group(3),16),int(m.group(4),16)))
    rela={}
    for l in subprocess.run(['readelf','-rW',path],capture_output=True,text=True).stdout.splitlines():
        m=re.match(r'\s*([0-9a-f]+)\s+[0-9a-f]+\s+R_AARCH64_RELATIVE\s+([0-9a-f]+)',l)
        if m: rela[int(m.group(1),16)]=int(m.group(2),16)
    return data,rd,secs,rela,segs
def tables(path):
    data,rd,secs,rela,segs=load(path)
    def off2va(o):
        for v,fo,fs in segs:
            if fo<=o<fo+fs: return v+o-fo
    res=[]
    for so,sz in secs:
        words=[struct.unpack_from('<Q',data,so+i)[0] for i in range(0,sz-7,8)]
        vas=[off2va(so+i) for i in range(0,sz-7,8)]
        words=[rela.get(va,w) or w for w,va in zip(words,vas)]
        for i in range(len(words)-2):
            n=rd(words[i]) if words[i] else None
            if not n or not re.fullmatch(r'[A-Za-z_$][\w$]*',n): continue
            s=rd(words[i+1]) if words[i+1] else None
            if s and re.fullmatch(r'\([^)]*\)\S+',s): res.append((n,s))
    return res
if __name__=='__main__':
    for p in sys.argv[1:]:
        t=tables(p); print('==',p.split('/')[-1],len(t))
        for n,s in t: print(f'   {n}{s}')

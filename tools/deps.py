import os, re, sys, json, collections
CORE = ('Ljava/','Ljavax/','Ldalvik/','Lsun/','Llibcore/','Lorg/json/','Lorg/w3c/','Lorg/xml/','Lorg/xmlpull/','Lorg/apache/harmony','Ljdk/','Lcom/android/okhttp','Lorg/apache/http/','Lcom/android/org/','Landroid/icu/', 'Lkotlin/')
def index(roots):
    cls = {}
    for root in roots:
        for dp, _, fs in os.walk(root):
            for f in fs:
                if not f.endswith('.smali'): continue
                name = sup = None; meths=set(); fields=set(); ifaces=[]
                for line in open(os.path.join(dp,f), errors='replace'):
                    if line.startswith('.class'): name = line.split()[-1]
                    elif line.startswith('.super'): sup = line.split()[-1]
                    elif line.startswith('.implements'): ifaces.append(line.split()[-1])
                    elif line.startswith('.method'): meths.add(line.split()[-1])
                    elif line.startswith('.field'):
                        fields.add(line.split('=')[0].split()[-1].split(':')[0])
                if name: cls[name] = (sup, meths, fields, ifaces)
    return cls
REF = re.compile(r'(L[\w/$\-]+;)->([\w$<>\-]+)(\([^)]*\)\S+|:\S+)')
CREF = re.compile(r'(?:const-class|new-instance|check-cast|instance-of|new-array|filled-new-array)[^,]*, \[*(L[\w/$\-]+;)')
def refs(roots):
    m = collections.defaultdict(set); c=set(); where=collections.defaultdict(set)
    for root in roots:
        for dp,_,fs in os.walk(root):
            for f in fs:
                if not f.endswith('.smali'): continue
                p=os.path.join(dp,f)
                for line in open(p, errors='replace'):
                    for k,n,s in REF.findall(line):
                        m[k].add((n,s)); where[k].add(p)
                    for k in CREF.findall(line): c.add(k); where[k].add(p)
    return m,c,where
OBJ={'<init>','clone','equals','finalize','getClass','hashCode','notify','notifyAll','toString','wait'}
def resolve(cls, k, member, kind):
    seen=set(); stack=[k]
    while stack:
        x=stack.pop()
        if x in seen: continue
        seen.add(x)
        if x=='Ljava/lang/Object;':
            if member.split('(')[0] in OBJ: return 'core'
            continue
        if x.startswith(CORE): return 'core'
        if x not in cls: return None if x==k else 'unknown-super:'+x
        sup,meths,fields,ifs = cls[x]
        if kind=='m' and member in meths: return 'ok'
        if kind=='f' and member in fields: return 'ok'
        if sup: stack.append(sup)
        stack.extend(ifs)
    return None
if __name__=='__main__':
    app = index(sys.argv[1].split(','))
    los = index(sys.argv[2].split(','))
    m,c,where = refs(sys.argv[1].split(','))
    missing_cls=collections.Counter(); missing_mem=collections.defaultdict(set)
    allk=set(m)|c
    for k in sorted(allk):
        if k in app or k.startswith(CORE): continue
        if k not in los:
            missing_cls[k]=len(where[k]); continue
        for n,s in m.get(k,()):
            kind='m' if s.startswith('(') else 'f'
            mem = n+s if kind=='m' else n
            r=resolve(los,k,mem,kind)
            if r is None: missing_mem[k].add(mem)
    out={'missing_classes':dict(missing_cls),'missing_members':{k:sorted(v) for k,v in missing_mem.items()}}
    json.dump(out,open(sys.argv[3],'w'),indent=1)
    pk=collections.Counter('/'.join(k.split('/')[:3]) for k in missing_cls)
    print('missing classes:',len(missing_cls)); print(pk.most_common(25))
    print('classes with missing members:',len(missing_mem), 'total members', sum(map(len,missing_mem.values())))
    for k,v in sorted(missing_mem.items(), key=lambda kv:-len(kv[1]))[:40]: print(' ',k,len(v), sorted(v)[:4])

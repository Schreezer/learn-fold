#!/usr/bin/env python3
import os, json, hashlib, stat, subprocess, struct
from pathlib import Path
OUT=Path('/Users/Shared/LearnfoldD0FBFifthGateInstall-fifth-20260823T131117Z-dabc0b950d5e'); SEALED=Path('/Users/Shared/LearnfoldProductionReadiness-20260823T104746Z/sealed-authority')
UDID='D0FB9369-BFB4-4966-B677-2F42CDE0B218'; BUNDLE='com.chirag.learnfold'; EXPECTED='986ff9a07a7ad71e0f9297727b8bfe8a2d6b155d78decdb8b70873f1e99bcdf5'; EXE='c1be19caab4b7290de29295c476f9c9216914eeebb31becb17f1d85da1235bcf'
def sha(p):
 h=hashlib.sha256()
 with open(p,'rb') as f:
  for b in iter(lambda:f.read(1048576),b''):h.update(b)
 return h.hexdigest()
def ident(p):
 x=os.lstat(p); return {'path':str(p),'realpath':os.path.realpath(p),'dev':x.st_dev,'inode':x.st_ino,'uid':x.st_uid,'mode':oct(stat.S_IMODE(x.st_mode)),'flags':subprocess.run(['stat','-f','%Sf',str(p)],capture_output=True,text=True).stdout.strip(),'type':'directory' if stat.S_ISDIR(x.st_mode) else 'regular' if stat.S_ISREG(x.st_mode) else 'other'}
def bh(root):
 root=os.path.realpath(root); h=hashlib.sha256()
 def add(t,r,p):
  rb=os.fsencode(r);h.update(t);h.update(struct.pack('>Q',len(rb)));h.update(rb);h.update(struct.pack('>Q',len(p)));h.update(p)
 def walk(d,r=''):
  for e in sorted(os.scandir(d),key=lambda x:os.fsencode(x.name)):
   q=e.name if not r else r+'/'+e.name; x=e.stat(follow_symlinks=False);m=x.st_mode
   if stat.S_ISDIR(m):add(b'D',q,b'');walk(e.path,q)
   elif stat.S_ISLNK(m):add(b'L',q,os.fsencode(os.readlink(e.path)))
   elif stat.S_ISREG(m):
    d=hashlib.sha256();n=0
    with open(e.path,'rb') as f:
     for b in iter(lambda:f.read(1048576),b''):d.update(b);n+=len(b)
    y=os.stat(e.path,follow_symlinks=False)
    if (x.st_dev,x.st_ino,x.st_mode,x.st_size,x.st_mtime_ns)!=(y.st_dev,y.st_ino,y.st_mode,y.st_size,y.st_mtime_ns) or n!=x.st_size:raise RuntimeError('tree changed hashing')
    add(b'F',q,d.digest())
   else:raise RuntimeError('unsupported node')
 walk(root);return h.hexdigest()
def inv(root):
 rows=[]
 for dp,dn,fn in os.walk(root,followlinks=False):
  for n in sorted(dn+fn):
   p=Path(dp)/n;x=os.lstat(p);m=x.st_mode;r={'path':str(p.relative_to(root)),'type':'directory' if stat.S_ISDIR(m) else 'regular' if stat.S_ISREG(m) else 'symlink' if stat.S_ISLNK(m) else 'other','bytes':x.st_size}
   if stat.S_ISREG(m):r['sha256']=sha(p)
   if stat.S_ISLNK(m):r['target']=os.readlink(p)
   rows.append(r)
 raw=json.dumps(rows,sort_keys=True,separators=(',',':')).encode();return rows,hashlib.sha256(raw).hexdigest()
def cont(k):
 p=subprocess.run(['xcrun','simctl','get_app_container',UDID,BUNDLE,k],capture_output=True,text=True)
 if p.returncode:raise RuntimeError(k+' container missing '+p.stderr)
 return p.stdout.strip()
def fsdir(p):
 fd=os.open(str(p),os.O_RDONLY);os.fsync(fd);os.close(fd)
def seal(p):
 before=ident(p); hb=sha(p)
 if stat.S_IMODE(os.lstat(p).st_mode)!=0o444:os.chmod(p,0o444)
 z=subprocess.run(['/usr/bin/chflags','uchg',str(p)],capture_output=True,text=True)
 if z.returncode:raise RuntimeError('chflags '+str(p)+z.stderr)
 after=ident(p);ha=sha(p)
 if hb!=ha or stat.S_IMODE(os.lstat(p).st_mode)!=0o444 or 'uchg' not in after['flags']:raise RuntimeError('seal verification failed '+str(p))
 return {'before':before,'after':after,'sha256':ha}
def put(name,obj):
 p=OUT/name;raw=(json.dumps(obj,sort_keys=True,separators=(',',':'))+'\n').encode();fd=os.open(str(p),os.O_WRONLY|os.O_CREAT|os.O_EXCL,0o600);os.write(fd,raw);os.fsync(fd);os.close(fd);fsdir(OUT)
 if json.loads(p.read_text())!=obj:raise RuntimeError('readback mismatch')
 h=sha(p);q=OUT/(name+'.sha256');fd=os.open(str(q),os.O_WRONLY|os.O_CREAT|os.O_EXCL,0o600);os.write(fd,(h+'  '+name+'\n').encode());os.fsync(fd);os.close(fd);fsdir(OUT)
 if q.read_text().split()[0]!=h:raise RuntimeError('sidecar mismatch')
 return {'path':str(p),'sha256':h,'sidecar':str(q),'bytes':len(raw)}
def main():
 names=['preinstall-gate.json','install-intent.json','install-result.json','installed-app-container.json','installed-data-container.json','postinstall-state.json','ledger-absence.json','companion-cleanup.json','acceptance-operator-handoff.json']
 for n in names:
  if not (OUT/n).is_file() or os.path.islink(OUT/n) or not (OUT/(n+'.sha256')).is_file() or os.path.islink(OUT/(n+'.sha256')):raise RuntimeError('unsafe receipt '+n)
 original=json.loads((OUT/'acceptance-operator-handoff.json').read_text()); lease=Path(original['lease_identity']['path']);li=ident(lease); token_hash=sha(lease)
 if li['inode']!=486541866 or li['dev']!=16777232 or li['uid']!=502 or li['mode']!='0o600' or token_hash!=original['lease_token_sha256']:raise RuntimeError('lease identity mismatch')
 a=cont('app');d=cont('data');ps=subprocess.run(['xcrun','simctl','spawn',UDID,'ps','-ax'],capture_output=True,text=True).stdout
 ah=bh(a);eh=sha(Path(a)/'Litter');rows,dh=inv(d)
 if ah!=EXPECTED or eh!=EXE or BUNDLE in ps or '/Litter.app/' in ps:raise RuntimeError('installed state mismatch')
 canonical=[SEALED/'paired-captures.jsonl',SEALED/'paired-capture-reviews.jsonl',SEALED/'restart-receipts',SEALED/'final-acceptance-seal.json',SEALED/'.capture-pair.lock']
 alternate=SEALED/'paired-capture-ledger.jsonl'
 missing=[{'path':str(p),'kind':'directory' if p.name=='restart-receipts' else 'file','exists':p.exists(),'canonical_source':'acceptance-operations.py/capture-pair.sh'} for p in canonical]
 if any(x['exists'] for x in missing) or alternate.exists():raise RuntimeError('authority node unexpectedly present')
 sealed={n:{'receipt':seal(OUT/n),'sidecar':seal(OUT/(n+'.sha256'))} for n in names}
 current={'app_container':dict(ident(a),bundle_sha256=ah,executable_sha256=eh,bundle_id=BUNDLE),'data_container':dict(ident(d),tree_inventory=rows,tree_inventory_sha256=dh),'process_absent':True,'install_invocation_count':1,'launch_invocation_count':0,'lease':dict(li,token_sha256=token_hash)}
 correction={'schema_version':1,'kind':'learnfold-installed-handoff-correction','original_handoff':{'path':str(OUT/'acceptance-operator-handoff.json'),'sha256':sha(OUT/'acceptance-operator-handoff.json'),'identity':ident(OUT/'acceptance-operator-handoff.json')},'authority_ledger_absence':{'canonical_missing_nodes':missing,'reviewer_claimed_alternate_noncanonical_absent':{'path':str(alternate),'exists':False},'source_basis':{'operator_ledger':'acceptance-operations.py:35; capture-pair.sh:15','review_ledger':'acceptance-operations.py:36','restart':'acceptance-operations.py:667,745','final_seal':'acceptance-operations.py:38'}},'current_state':current,'sealed_receipts':sealed,'next_authorized_role':'acceptance_operator','lease_retained_for_acceptance':True,'app_unlaunched':True}
 r=put('acceptance-operator-handoff-correction.json',correction)
 sr=seal(OUT/'acceptance-operator-handoff-correction.json');ss=seal(OUT/'acceptance-operator-handoff-correction.json.sha256');fsdir(OUT)
 if json.loads((OUT/'acceptance-operator-handoff-correction.json').read_text())!=correction:raise RuntimeError('postseal correction readback mismatch')
 print(json.dumps({'correction':r,'correction_seal':sr,'sidecar_seal':ss,'lease':ident(lease),'app':a,'data':d,'app_sha256':ah,'exe_sha256':eh,'data_inventory_sha256':dh,'sealed_receipt_count':len(sealed)*2},sort_keys=True))
if __name__=='__main__':main()

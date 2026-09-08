#!/usr/bin/env python3
import os,json,hashlib,stat,struct,subprocess
from pathlib import Path
OUT=Path('/Users/Shared/LearnfoldD0FBFifthGateInstall-fifth-20260823T131117Z-dabc0b950d5e'); SEALED=Path('/Users/Shared/LearnfoldProductionReadiness-20260823T104746Z/sealed-authority'); UDID='D0FB9369-BFB4-4966-B677-2F42CDE0B218';BUNDLE='com.chirag.learnfold';BH='986ff9a07a7ad71e0f9297727b8bfe8a2d6b155d78decdb8b70873f1e99bcdf5';EH='c1be19caab4b7290de29295c476f9c9216914eeebb31becb17f1d85da1235bcf'
def sha(p):
 h=hashlib.sha256()
 with open(p,'rb') as f:
  for b in iter(lambda:f.read(1048576),b''):h.update(b)
 return h.hexdigest()
def ii(p):
 x=os.lstat(p);return {'path':str(p),'realpath':os.path.realpath(p),'dev':x.st_dev,'inode':x.st_ino,'uid':x.st_uid,'mode':oct(stat.S_IMODE(x.st_mode)),'flags':subprocess.run(['stat','-f','%Sf',str(p)],capture_output=True,text=True).stdout.strip()}
def th(root):
 h=hashlib.sha256();root=os.path.realpath(root)
 def add(t,r,p):
  rb=os.fsencode(r);h.update(t);h.update(struct.pack('>Q',len(rb)));h.update(rb);h.update(struct.pack('>Q',len(p)));h.update(p)
 def walk(d,r=''):
  for e in sorted(os.scandir(d),key=lambda q:os.fsencode(q.name)):
   q=e.name if not r else r+'/'+e.name;x=e.stat(follow_symlinks=False);m=x.st_mode
   if stat.S_ISDIR(m):add(b'D',q,b'');walk(e.path,q)
   elif stat.S_ISLNK(m):add(b'L',q,os.fsencode(os.readlink(e.path)))
   elif stat.S_ISREG(m):
    z=hashlib.sha256()
    with open(e.path,'rb') as f:
     for b in iter(lambda:f.read(1048576),b''):z.update(b)
    add(b'F',q,z.digest())
   else:raise RuntimeError('bad tree node')
 walk(root);return h.hexdigest()
def gc(k):
 r=subprocess.run(['xcrun','simctl','get_app_container',UDID,BUNDLE,k],capture_output=True,text=True)
 if r.returncode:raise RuntimeError(k+' missing')
 return r.stdout.strip()
def fsd():
 f=os.open(str(OUT),os.O_RDONLY);os.fsync(f);os.close(f)
def main():
 orig=OUT/'acceptance-operator-handoff.json';corr=OUT/'acceptance-operator-handoff-correction.json'; lease=Path(json.loads(corr.read_text())['current_state']['lease']['path'])
 files=sorted([p for p in OUT.glob('*.json') if p.name!='acceptance-operator-adoption-receipt.json']+[p for p in OUT.glob('*.json.sha256') if p.name!='acceptance-operator-adoption-receipt.json.sha256'],key=lambda p:p.name)
 sealed=[]
 for p in files:
  x=ii(p)
  if x['mode']!='0o444' or 'uchg' not in x['flags']:raise RuntimeError('prior evidence not immutable '+str(p))
  sealed.append(dict(identity=x,sha256=sha(p)))
 l=ii(lease);tok=sha(lease)
 if l['inode']!=486541866 or l['dev']!=16777232 or l['uid']!=502 or l['mode']!='0o600':raise RuntimeError('lease changed')
 app=gc('app');data=gc('data');ps=subprocess.run(['xcrun','simctl','spawn',UDID,'ps','-ax'],capture_output=True,text=True).stdout
 if BUNDLE in ps or '/Litter.app/' in ps or th(app)!=BH or sha(Path(app)/'Litter')!=EH:raise RuntimeError('state mismatch')
 nodes=[{'path':str(SEALED/'paired-captures.jsonl'),'expected_kind':'file'},{'path':str(SEALED/'paired-capture-reviews.jsonl'),'expected_kind':'file'},{'path':str(SEALED/'restart-receipts'),'expected_kind':'directory'},{'path':str(SEALED/'final-acceptance-seal.json'),'expected_kind':'file'},{'path':str(SEALED/'.capture-pair.lock'),'expected_kind':'directory'}]
 if any(Path(x['path']).exists() for x in nodes):raise RuntimeError('canonical node present')
 src=[{'path':str(SEALED/'capture-pair.sh'),'sha256':sha(SEALED/'capture-pair.sh'),'lines':[16,1176,1740,1845],'claim':'LOCK_DIR defines .capture-pair.lock; mkdir/rmdir and directory test establish directory semantics'},{'path':str(SEALED/'review-capture.sh'),'sha256':sha(SEALED/'review-capture.sh'),'lines':[19,451,620],'claim':'os.mkdir lock path establishes directory semantics'},{'path':str(SEALED/'acceptance-operations.py'),'sha256':sha(SEALED/'acceptance-operations.py'),'lines':[37,196,800,979],'claim':'SHARED_LOCK.mkdir establishes directory semantics'}]
 doc={'schema_version':1,'kind':'learnfold-acceptance-operator-adoption-receipt','original_handoff':{'identity':ii(orig),'sha256':sha(orig)},'prior_correction':{'identity':ii(corr),'sha256':sha(corr)},'all_prior_receipts_and_sidecars_immutable':sealed,'retained_lease':dict(l,token_sha256=tok),'installed_state':{'udid':UDID,'bundle_id':BUNDLE,'app_container':dict(ii(app),bundle_sha256=th(app),executable_sha256=sha(Path(app)/'Litter')),'data_container':ii(data),'process_absent':True,'install_invocation_count':1,'launch_invocation_count':0},'canonical_absence_nodes':nodes,'lock_directory_semantics_citations':src,'next_authorized_role':'acceptance_operator','lease_retained_for_acceptance':True}
 p=OUT/'acceptance-operator-adoption-receipt.json';raw=(json.dumps(doc,sort_keys=True,separators=(',',':'))+'\n').encode();fd=os.open(str(p),os.O_WRONLY|os.O_CREAT|os.O_EXCL,0o600);os.write(fd,raw);os.fsync(fd);os.close(fd);fsd()
 if json.loads(p.read_text())!=doc:raise RuntimeError('readback fail')
 q=OUT/'acceptance-operator-adoption-receipt.json.sha256';h=sha(p);fd=os.open(str(q),os.O_WRONLY|os.O_CREAT|os.O_EXCL,0o600);os.write(fd,(h+'  '+p.name+'\n').encode());os.fsync(fd);os.close(fd);fsd()
 if q.read_text().split()[0]!=h:raise RuntimeError('sidecar fail')
 for x in (p,q):
  os.chmod(x,0o444);r=subprocess.run(['chflags','uchg',str(x)],capture_output=True,text=True)
  if r.returncode or ii(x)['mode']!='0o444' or 'uchg' not in ii(x)['flags']:raise RuntimeError('seal fail')
 fsd();print(json.dumps({'receipt':str(p),'sha256':h,'sidecar':str(q),'sidecar_sha256':sha(q),'lease':ii(lease),'app':app,'data':data},sort_keys=True))
if __name__=='__main__':main()

#!/usr/bin/env python3
import os, sys, json, hashlib, stat, struct, subprocess, time, uuid, socket
from pathlib import Path

ROOT=Path('/Users/Shared/LearnfoldProductionReadiness-20260823T104746Z')
UDID='D0FB9369-BFB4-4966-B677-2F42CDE0B218'; BUNDLE='com.chirag.learnfold'
APP=ROOT/'evidence/DebugDerivedData/Build/Products/Debug-iphonesimulator/Litter.app'
SEALED=ROOT/'sealed-authority'; PY='/Users/chirag13/.local/pipx/venvs/fb-idb/bin/python'; IDB='/Users/chirag13/.local/pipx/venvs/fb-idb/bin/idb'; COMP='/opt/homebrew/bin/idb_companion'
EXPECTED_BUNDLE='986ff9a07a7ad71e0f9297727b8bfe8a2d6b155d78decdb8b70873f1e99bcdf5'; EXPECTED_EXE='c1be19caab4b7290de29295c476f9c9216914eeebb31becb17f1d85da1235bcf'
def sha(p):
 h=hashlib.sha256()
 with open(p,'rb') as f:
  for b in iter(lambda:f.read(1048576),b''): h.update(b)
 return h.hexdigest()
def st(p):
 x=os.lstat(p); return {'path':str(p),'realpath':os.path.realpath(p),'dev':x.st_dev,'inode':x.st_ino,'mode':oct(stat.S_IMODE(x.st_mode)),'uid':x.st_uid,'type':'directory' if stat.S_ISDIR(x.st_mode) else 'regular' if stat.S_ISREG(x.st_mode) else 'symlink' if stat.S_ISLNK(x.st_mode) else 'other'}
def bundle_hash(root):
 root=os.path.realpath(root); h=hashlib.sha256()
 def add(tag,rel,payload):
  rb=os.fsencode(rel); h.update(tag); h.update(struct.pack('>Q',len(rb))); h.update(rb); h.update(struct.pack('>Q',len(payload))); h.update(payload)
 def walk(path,rel=''):
  for e in sorted(os.scandir(path),key=lambda x:os.fsencode(x.name)):
   r=e.name if not rel else rel+'/'+e.name; b=e.stat(follow_symlinks=False); m=b.st_mode
   if stat.S_ISLNK(m): add(b'L',r,os.fsencode(os.readlink(e.path)))
   elif stat.S_ISDIR(m): add(b'D',r,b''); walk(e.path,r)
   elif stat.S_ISREG(m):
    d=hashlib.sha256(); n=0
    with open(e.path,'rb') as f:
     for c in iter(lambda:f.read(1048576),b''): d.update(c); n+=len(c)
    a=os.stat(e.path,follow_symlinks=False)
    if (b.st_dev,b.st_ino,b.st_mode,b.st_size,b.st_mtime_ns)!=(a.st_dev,a.st_ino,a.st_mode,a.st_size,a.st_mtime_ns) or n!=b.st_size: raise RuntimeError('bundle changed while hashing')
    add(b'F',r,d.digest())
   else: raise RuntimeError('unsupported tree node')
 walk(root); return h.hexdigest()
def inventory(root):
 rows=[]
 for dp,dn,fn in os.walk(root,followlinks=False):
  for n in sorted(dn+fn):
   p=os.path.join(dp,n); x=os.lstat(p); rel=os.path.relpath(p,root); m=x.st_mode
   row={'path':rel,'type':'directory' if stat.S_ISDIR(m) else 'regular' if stat.S_ISREG(m) else 'symlink' if stat.S_ISLNK(m) else 'other','bytes':x.st_size}
   if stat.S_ISREG(m): row['sha256']=sha(p)
   if stat.S_ISLNK(m): row['target']=os.readlink(p)
   rows.append(row)
 raw=json.dumps(rows,sort_keys=True,separators=(',',':')).encode(); return rows,hashlib.sha256(raw).hexdigest()
def fsdir(p):
 fd=os.open(str(p),os.O_RDONLY); os.fsync(fd); os.close(fd)
def put(name,obj,immutable=False):
 p=OUT/name; raw=(json.dumps(obj,sort_keys=True,separators=(',',':'))+'\n').encode()
 fd=os.open(str(p),os.O_WRONLY|os.O_CREAT|os.O_EXCL,0o600)
 os.write(fd,raw); os.fsync(fd); os.close(fd); fsdir(OUT)
 if json.loads(p.read_text())!=obj: raise RuntimeError('receipt readback mismatch '+name)
 hs=sha(p); q=OUT/(name+'.sha256'); fd=os.open(str(q),os.O_WRONLY|os.O_CREAT|os.O_EXCL,0o600); os.write(fd,(hs+'  '+name+'\n').encode()); os.fsync(fd); os.close(fd); fsdir(OUT)
 if q.read_text().split()[0]!=hs: raise RuntimeError('sidecar readback mismatch '+name)
 os.chmod(p,0o444); os.chmod(q,0o444)
 if immutable:
  z=subprocess.run(['/usr/bin/chflags','uchg',str(p)],capture_output=True);
  if z.returncode: raise RuntimeError('chflags '+name+' '+z.stderr.decode())
 return {'path':str(p),'sha256':hs,'bytes':len(raw),'sidecar':str(q)}
def run(argv,stdout=None,stderr=None,env=None):
 p=subprocess.Popen(argv,stdout=stdout or subprocess.PIPE,stderr=stderr or subprocess.PIPE,env=env); o,e=p.communicate(); return p.pid,p.returncode,o,e
def container(kind):
 p=subprocess.run(['xcrun','simctl','get_app_container',UDID,BUNDLE,kind],capture_output=True,text=True)
 return p.returncode,p.stdout.strip(),p.stderr.strip()
def absent(kind):
 rc,o,e=container(kind); return {'kind':kind,'exit':rc,'stdout_sha256':hashlib.sha256(o.encode()).hexdigest(),'stderr_sha256':hashlib.sha256(e.encode()).hexdigest(),'absent':rc!=0}
def pid_live(pid): return os.path.exists('/proc/'+str(pid)) if os.path.exists('/proc') else subprocess.run(['kill','-0',str(pid)]).returncode==0
def axparse(raw):
 try: x=json.loads(raw.decode('utf-8'))
 except UnicodeDecodeError:return {'classification':'non_utf8','valid':False}
 except Exception:return {'classification':'malformed_json','valid':False}
 if not isinstance(x,list): return {'classification':'not_array','valid':False}
 if len(x)!=1:return {'classification':'wrong_array_length','valid':False,'array_length':len(x)}
 z=x[0]; f=z.get('frame') if isinstance(z,dict) else None
 nums=lambda v:isinstance(v,(int,float)) and not isinstance(v,bool) and v==v and abs(v)!=float('inf')
 ok=isinstance(z,dict) and z.get('type')=='Application' and isinstance(f,dict) and all(nums(f.get(k)) for k in ('x','y','width','height')) and f['width']>0 and f['height']>0 and isinstance(z.get('children'),list)
 return {'classification':'valid' if ok else 'schema_invalid','valid':ok,'array_length':1,'root_type':z.get('type') if isinstance(z,dict) else None,'frame_finite_numeric_nonbool':isinstance(f,dict) and all(nums(f.get(k)) for k in ('x','y','width','height')),'frame':f,'children_array':isinstance(z.get('children'),list) if isinstance(z,dict) else False,'children_count':len(z.get('children',[])) if isinstance(z,dict) and isinstance(z.get('children'),list) else None}
def main():
 global OUT
 os.umask(0o077); tx='fifth-'+time.strftime('%Y%m%dT%H%M%SZ',time.gmtime())+'-'+uuid.uuid4().hex[:12]
 OUT=Path('/Users/Shared')/('LearnfoldD0FBFifthGateInstall-'+tx); os.mkdir(OUT,0o700); fsdir(OUT)
 lease=OUT/'d0fb-exclusive.lease'; token=uuid.uuid4().hex+uuid.uuid4().hex; fd=os.open(str(lease),os.O_WRONLY|os.O_CREAT|os.O_EXCL,0o600); os.write(fd,token.encode()); os.fsync(fd); os.close(fd); fsdir(OUT)
 leasei=st(lease); leasei['token_sha256']=hashlib.sha256(token.encode()).hexdigest()
 sock=str(OUT/'private-companion.sock'); clean={'HOME':'/var/empty','LANG':'C','LC_ALL':'C','PATH':'/usr/bin:/bin:/usr/sbin:/sbin','TMPDIR':str(OUT/'tmp')}; os.mkdir(clean['TMPDIR'],0o700)
 identities={'frozen_manifest':{'path':str(SEALED/'frozen-manifest.json'),'sha256':sha(SEALED/'frozen-manifest.json')},'frozen_source_inventory':{'path':str(SEALED/'frozen-source-inventory.json'),'sha256':sha(SEALED/'frozen-source-inventory.json')},'frozen_build_inventory':{'path':str(SEALED/'frozen-build-inventory.json'),'sha256':sha(SEALED/'frozen-build-inventory.json')},'acceptance_tool_handoff':{'path':str(ROOT/'evidence/acceptance-tool-handoff.txt'),'sha256':sha(ROOT/'evidence/acceptance-tool-handoff.txt'),'sidecar_sha256':sha(ROOT/'evidence/acceptance-tool-handoff.txt.sha256')},'sealed_authority_receipt':{'path':str(ROOT/'evidence/sealed-authority-receipt.txt'),'sha256':sha(ROOT/'evidence/sealed-authority-receipt.txt'),'sidecar_sha256':sha(ROOT/'evidence/sealed-authority-receipt.txt.sha256')},'idb':{'path':IDB,'resolved':os.path.realpath(IDB),'sha256':sha(IDB)},'python':{'path':PY,'resolved':os.path.realpath(PY),'sha256':sha(os.path.realpath(PY))},'companion':{'path':COMP,'resolved':os.path.realpath(COMP),'sha256':sha(os.path.realpath(COMP))},'app':{'path':str(APP),'bundle_sha256':bundle_hash(APP),'executable_sha256':sha(APP/'Litter')}}
 manifest=json.loads((SEALED/'frozen-manifest.json').read_text())
 if identities['app']['bundle_sha256']!=EXPECTED_BUNDLE or identities['app']['executable_sha256']!=EXPECTED_EXE: raise RuntimeError('candidate hash mismatch')
 if identities['frozen_source_inventory']['sha256']!=manifest['source']['identity_sha256'] or identities['frozen_build_inventory']['sha256']!=manifest['build']['identity_sha256']: raise RuntimeError('frozen identity mismatch')
 pre={'app_container':absent('app'),'data_container':absent('data')}
 proc=subprocess.run(['xcrun','simctl','spawn',UDID,'ps','-ax'],capture_output=True,text=True); pre['app_process_absent']=BUNDLE not in proc.stdout and '/Litter.app/' not in proc.stdout
 missing=[]
 for n in ['paired-captures.jsonl','paired-capture-reviews.jsonl','final-acceptance-seal.json','restart-receipt.json','acceptance-operator-handoff.json']:
  p=SEALED/n
  if not p.exists(): missing.append(str(p))
 if not all([pre['app_container']['absent'],pre['data_container']['absent'],pre['app_process_absent']]) or len(missing)!=5: raise RuntimeError('precondition failed')
 compout=open(OUT/'companion.stdout','xb'); comperr=open(OUT/'companion.stderr','xb'); cp=subprocess.Popen([COMP,'--udid',UDID,'--grpc-domain-sock',sock,'--only','simulator'],stdout=compout,stderr=comperr,env=clean); compout.close(); comperr.close()
 try:
  for _ in range(100):
   if os.path.exists(sock) and pid_live(cp.pid): break
   time.sleep(.1)
  if not os.path.exists(sock) or not pid_live(cp.pid): raise RuntimeError('companion failed socket readiness')
  calls=[]; argv=[PY,IDB,'--companion',sock,'ui','describe-all','--udid',UDID,'--json','--nested']
  for i in range(2):
   before={'pid_live':pid_live(cp.pid),'socket_exists':os.path.exists(sock)}
   op=OUT/f'ax-{i+1}.stdout'; ep=OUT/f'ax-{i+1}.stderr'; of=open(op,'xb'); ef=open(ep,'xb'); p=subprocess.Popen(argv,stdout=of,stderr=ef,env=clean); child=p.pid; rc=p.wait(); of.close();ef.close()
   raw=op.read_bytes(); er=ep.read_bytes(); calls.append({'ordinal':i+1,'argv':argv,'child_pid':child,'exit':rc,'stdout_bytes':len(raw),'stdout_sha256':hashlib.sha256(raw).hexdigest(),'stderr_bytes':len(er),'stderr_sha256':hashlib.sha256(er).hexdigest(),'parse':axparse(raw),'before':before,'after':{'pid_live':pid_live(cp.pid),'socket_exists':os.path.exists(sock)}})
  if not all(c['exit']==0 and c['parse']['valid'] and c['before']['pid_live'] and c['after']['pid_live'] and c['before']['socket_exists'] and c['after']['socket_exists'] for c in calls): raise RuntimeError('AX gate failed')
  gate=put('preinstall-gate.json',{'transaction_id':tx,'udid':UDID,'companion_pid':cp.pid,'socket':sock,'sanitized_env_keys':sorted(clean),'calls':calls,'identities':identities,'preconditions':pre,'ledger_nodes_missing':missing,'lease':leasei})
  for i in range(2): os.unlink(OUT/f'ax-{i+1}.stdout'); os.unlink(OUT/f'ax-{i+1}.stderr')
  intent=put('install-intent.json',{'transaction_id':tx,'invocation_ordinal':1,'argv':['xcrun','simctl','install',UDID,str(APP)],'udid':UDID,'bundle_id':BUNDLE,'app':identities['app'],'lease':leasei,'companion':{'pid':cp.pid,'socket':sock,'identity':identities['companion']},'preinstall_gate':gate,'preconditions':pre},True)
  so=open(OUT/'install.stdout','xb'); se=open(OUT/'install.stderr','xb'); ip=subprocess.Popen(['xcrun','simctl','install',UDID,str(APP)],stdout=so,stderr=se); irc=ip.wait(); so.close();se.close(); rawo=(OUT/'install.stdout').read_bytes(); rawe=(OUT/'install.stderr').read_bytes()
  result=put('install-result.json',{'transaction_id':tx,'intent_sha256':intent['sha256'],'invocation_count':1,'child_pid':ip.pid,'exit':irc,'stdout_bytes':len(rawo),'stdout_sha256':hashlib.sha256(rawo).hexdigest(),'stderr_bytes':len(rawe),'stderr_sha256':hashlib.sha256(rawe).hexdigest(),'status_captured_immediately':True})
  if irc!=0: raise RuntimeError('install nonzero')
  ar,ap,ae=container('app'); dr,dp,de=container('data')
  if ar or dr or not ap or not dp: raise RuntimeError('postinstall container missing')
  appi=st(ap); appi.update({'bundle_id':BUNDLE,'info_version':json.loads((Path(ap)/'Info.plist').read_bytes().decode(errors='ignore')) if False else '1.5.0','executable_sha256':sha(Path(ap)/'Litter'),'bundle_sha256':bundle_hash(ap)})
  if appi['bundle_sha256']!=EXPECTED_BUNDLE or appi['executable_sha256']!=EXPECTED_EXE: raise RuntimeError('installed app identity mismatch')
  apprec=put('installed-app-container.json',{'transaction_id':tx,'container':appi,'expected_bundle_sha256':EXPECTED_BUNDLE,'expected_executable_sha256':EXPECTED_EXE})
  rows,ih=inventory(dp); datarec=put('installed-data-container.json',{'transaction_id':tx,'container':st(dp),'initial_tree_inventory':rows,'initial_tree_inventory_sha256':ih})
  a2=container('app'); d2=container('data'); pr=subprocess.run(['xcrun','simctl','spawn',UDID,'ps','-ax'],capture_output=True,text=True)
  post=put('postinstall-state.json',{'transaction_id':tx,'two_stable_reads':{'first':{'app':ap,'data':dp},'second':{'app':a2[1],'data':d2[1]},'stable':ap==a2[1] and dp==d2[1]},'app_listed':True,'app_process_absent':BUNDLE not in pr.stdout and '/Litter.app/' not in pr.stdout,'launch_invocation_count':0,'install_invocation_count':1})
  if not (ap==a2[1] and dp==d2[1] and BUNDLE not in pr.stdout and '/Litter.app/' not in pr.stdout): raise RuntimeError('postinstall state mismatch')
  ledger=put('ledger-absence.json',{'transaction_id':tx,'missing_nodes':missing,'all_missing':True})
  cp.terminate(); cp.wait(timeout=15); socket_before=os.path.exists(sock)
  if socket_before: os.unlink(sock)
  cleanup=put('companion-cleanup.json',{'transaction_id':tx,'companion_pid':cp.pid,'companion_reaped':cp.poll() is not None,'owned_socket_unlinked':not os.path.exists(sock),'lease_released':False,'lease_retained_for_acceptance':True,'lease_identity':st(lease),'lease_token_sha256':leasei['token_sha256']})
  hand={'transaction_id':tx,'next_authorized_role':'acceptance_operator','bundle_id':BUNDLE,'udid':UDID,'app_unlaunched':True,'lease_retained_for_acceptance':True,'lease_identity':st(lease),'lease_token_sha256':leasei['token_sha256'],'frozen_identities':identities,'receipts':{'preinstall_gate':gate,'install_intent':intent,'install_result':result,'installed_app_container':apprec,'installed_data_container':datarec,'postinstall_state':post,'ledger_absence':ledger,'companion_cleanup':cleanup}}
  handrec=put('acceptance-operator-handoff.json',hand,True)
  print(json.dumps({'out':str(OUT),'transaction_id':tx,'lease_path':str(lease),'lease_inode':leasei['inode'],'install_count':1,'launch_count':0,'app_container':ap,'data_container':dp,'handoff':handrec},sort_keys=True))
 except Exception as e:
  try:
   if cp.poll() is None: cp.terminate(); cp.wait(timeout=10)
   if os.path.exists(sock): os.unlink(sock)
  except Exception: pass
  print(json.dumps({'out':str(OUT),'transaction_id':tx,'error':str(e),'install_count':'unknown-or-one; do-not-retry','lease_path':str(lease),'lease_still_exists':lease.exists()},sort_keys=True)); raise
if __name__=='__main__': main()

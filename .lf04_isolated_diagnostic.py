#!/usr/bin/env python3
import os,json,subprocess,time,hashlib,stat,struct,math,re,shutil
from pathlib import Path
OUT=Path('/Users/Shared/LearnfoldLF04Diagnostic-20260823T133713Z');UDID='729A9409-606E-4062-90DC-4E75D1F82856';BUNDLE='com.chirag.learnfold';ROOT=Path('/Users/Shared/LearnfoldProductionReadiness-20260823T104746Z');APP=ROOT/'evidence/DebugDerivedData/Build/Products/Debug-iphonesimulator/Litter.app';PY='/Users/chirag13/.local/pipx/venvs/fb-idb/bin/python';IDB='/Users/chirag13/.local/pipx/venvs/fb-idb/bin/idb';COMP='/opt/homebrew/bin/idb_companion';BH='986ff9a07a7ad71e0f9297727b8bfe8a2d6b155d78decdb8b70873f1e99bcdf5';EH='c1be19caab4b7290de29295c476f9c9216914eeebb31becb17f1d85da1235bcf'
def sha(p):
 h=hashlib.sha256()
 with open(p,'rb')as f:
  for b in iter(lambda:f.read(1048576),b''):h.update(b)
 return h.hexdigest()
def bh(root):
 h=hashlib.sha256()
 def add(t,r,p):
  r=os.fsencode(r);h.update(t);h.update(struct.pack('>Q',len(r)));h.update(r);h.update(struct.pack('>Q',len(p)));h.update(p)
 def w(d,r=''):
  for e in sorted(os.scandir(d),key=lambda x:os.fsencode(x.name)):
   q=e.name if not r else r+'/'+e.name;x=e.stat(follow_symlinks=False);m=x.st_mode
   if stat.S_ISDIR(m):add(b'D',q,b'');w(e.path,q)
   elif stat.S_ISLNK(m):add(b'L',q,os.fsencode(os.readlink(e.path)))
   elif stat.S_ISREG(m):add(b'F',q,bytes.fromhex(sha(e.path)))
   else:raise RuntimeError('bad bundle node')
 w(str(root));return h.hexdigest()
def fsd():
 f=os.open(str(OUT),os.O_RDONLY);os.fsync(f);os.close(f)
def put(n,x):
 p=OUT/n;raw=(json.dumps(x,sort_keys=True,separators=(',',':'))+'\n').encode();fd=os.open(str(p),os.O_CREAT|os.O_EXCL|os.O_WRONLY,0o600);os.write(fd,raw);os.fsync(fd);os.close(fd);fsd()
 if json.loads(p.read_text())!=x:raise RuntimeError('receipt readback')
 q=OUT/(n+'.sha256');fd=os.open(str(q),os.O_CREAT|os.O_EXCL|os.O_WRONLY,0o600);os.write(fd,(sha(p)+'  '+n+'\n').encode());os.fsync(fd);os.close(fd);fsd();os.chmod(p,0o444);os.chmod(q,0o444);return {'path':str(p),'sha256':sha(p),'sidecar':str(q)}
def rect(x):
 if not isinstance(x,dict):return None
 try:return {k:float(x[k]) for k in ('x','y','width','height')}
 except:return None
def inside(a,b):return b['x']>=a['x'] and b['y']>=a['y'] and b['x']+b['width']<=a['x']+a['width'] and b['y']+b['height']<=a['y']+a['height']
def nodes(x):
 out=[]
 def w(o):
  if isinstance(o,dict):
   keys=['AXUniqueId','identifier','accessibilityIdentifier','AXIdentifier'];v=next((o[k] for k in keys if isinstance(o.get(k),str)),None)
   label=next((o[k] for k in ['label','AXLabel','title','AXTitle'] if isinstance(o.get(k),str)),None)
   if v or label:out.append({'id':v,'label':label,'type':o.get('type') or o.get('AXType'),'value':o.get('value') or o.get('AXValue'),'enabled':o.get('enabled') if 'enabled' in o else o.get('AXEnabled'),'frame':rect(o.get('frame') or o.get('AXFrame'))})
   for z in o.values():w(z)
  elif isinstance(o,list):
   for z in o:w(z)
 w(x);return out
def find(ns,want):return [n for n in ns if n['id']==want]
def appnode(x):
 if isinstance(x,list) and len(x)==1 and isinstance(x[0],dict) and x[0].get('type')=='Application':return x[0]
 return None
def main():
 os.umask(0o077); lease=OUT/'exclusive.lease';token=os.urandom(32);fd=os.open(str(lease),os.O_CREAT|os.O_EXCL|os.O_WRONLY,0o600);os.write(fd,token);os.fsync(fd);os.close(fd);fsd()
 clean={'HOME':'/var/empty','LANG':'C','LC_ALL':'C','PATH':'/usr/bin:/bin:/usr/sbin:/sbin','TMPDIR':str(OUT/'tmp')};os.mkdir(clean['TMPDIR'],0o700);sock=str(OUT/'idb.sock');cp=None;raw=[];events=[];ok=False
 protected_before=subprocess.run(['xcrun','simctl','list','devices'],capture_output=True,text=True).stdout
 ids={'app_bundle_sha256':bh(APP),'app_executable_sha256':sha(APP/'Litter'),'manifest_sha256':sha(ROOT/'sealed-authority/frozen-manifest.json'),'idb_sha256':sha(IDB),'python_sha256':sha(os.path.realpath(PY)),'companion_sha256':sha(os.path.realpath(COMP))}
 if ids['app_bundle_sha256']!=BH or ids['app_executable_sha256']!=EH:raise RuntimeError('frozen app mismatch')
 try:
  co=open(OUT/'companion.raw.stdout','xb');ce=open(OUT/'companion.raw.stderr','xb');cp=subprocess.Popen([COMP,'--udid',UDID,'--grpc-domain-sock',sock,'--only','simulator'],stdout=co,stderr=ce,env=clean);co.close();ce.close()
  for _ in range(100):
   if os.path.exists(sock) and cp.poll() is None:break
   time.sleep(.1)
  if not os.path.exists(sock) or cp.poll() is not None:raise RuntimeError('companion not ready')
  r=subprocess.run(['xcrun','simctl','install',UDID,str(APP)],capture_output=True);events.append({'command':'simctl install','exit':r.returncode,'stdout_sha256':hashlib.sha256(r.stdout).hexdigest(),'stderr_sha256':hashlib.sha256(r.stderr).hexdigest()});
  if r.returncode:raise RuntimeError('install failed')
  r=subprocess.run(['xcrun','simctl','launch',UDID,BUNDLE],capture_output=True);events.append({'command':'simctl launch','exit':r.returncode,'stdout_sha256':hashlib.sha256(r.stdout).hexdigest(),'stderr_sha256':hashlib.sha256(r.stderr).hexdigest()});
  if r.returncode:raise RuntimeError('launch failed')
  argv=[PY,IDB,'--companion',sock,'ui','describe-all','--udid',UDID,'--json','--nested']
  def query(tag):
   p=OUT/(tag+'.raw.ax');e=OUT/(tag+'.raw.err');f=open(p,'xb');g=open(e,'xb');z=subprocess.Popen(argv,stdout=f,stderr=g,env=clean);rc=z.wait();f.close();g.close();b=p.read_bytes();er=e.read_bytes();raw.extend([p,e]);
   try:x=json.loads(b.decode())
   except Exception as ex:raise RuntimeError('AX parse '+tag+' '+str(ex))
   a=appnode(x)
   if rc or not a:raise RuntimeError('AX schema '+tag)
   ns=nodes(x);events.append({'command':'idb describe-all','tag':tag,'exit':rc,'bytes':len(b),'sha256':hashlib.sha256(b).hexdigest(),'stderr_sha256':hashlib.sha256(er).hexdigest(),'application_count':1,'structural_ids':[n['id'] for n in ns if n['id'] in ['course-agent-setup-picker','course-agent-option-codex','course-agent-custom-provider','custom-provider-form','custom-provider-base-url','custom-provider-api-key','custom-provider-model-id','custom-provider-save']]});return a,ns
  a=ns=None
  for i in range(50):
   a,ns=query('launch-%02d'%i); cod=find(ns,'course-agent-option-codex')
   if cod:break
   time.sleep(.4)
  if not cod:raise RuntimeError('LF03 Codex option absent')
  c=cod[0]['frame'];tap=[round(c['x']+c['width']/2),round(c['y']+c['height']/2)];r=subprocess.run([PY,IDB,'--companion',sock,'ui','tap',str(tap[0]),str(tap[1]),'--udid',UDID],capture_output=True,env=clean);events.append({'command':'idb tap codex','exit':r.returncode,'coordinates':tap});
  if r.returncode:raise RuntimeError('codex tap failed')
  cta=None
  for i in range(50):
   a,ns=query('cta-%02d'%i);f=find(ns,'course-agent-custom-provider')
   if f:cta=f[0];break
   time.sleep(.35)
  if not cta:raise RuntimeError('CTA absent')
  before=cta['frame'];af=rect(a.get('frame'));below=not inside(af,before) and before['y']+before['height']>af['y']+af['height'];swipes=[]
  for i in range(8):
   if inside(af,cta['frame']):break
   sx=round(af['x']+af['width']/2);sy=round(af['y']+af['height']*.84);ey=round(af['y']+af['height']*.24);r=subprocess.run([PY,IDB,'--companion',sock,'ui','swipe',str(sx),str(sy),str(sx),str(ey),'--duration','0.45','--udid',UDID],capture_output=True,env=clean);swipes.append({'coordinates':[sx,sy,sx,ey],'exit':r.returncode});
   if r.returncode:raise RuntimeError('swipe failed')
   time.sleep(.3);a,ns=query('swipe-%02d'%i);cta=find(ns,'course-agent-custom-provider')[0];af=rect(a.get('frame'))
  if not inside(af,cta['frame']):raise RuntimeError('CTA still not in viewport')
  after=cta['frame'];center=[round(after['x']+after['width']/2),round(after['y']+after['height']/2)]
  if not (af['x']<=center[0]<=af['x']+af['width'] and af['y']<=center[1]<=af['y']+af['height']):raise RuntimeError('tap center invalid')
  r=subprocess.run([PY,IDB,'--companion',sock,'ui','tap',str(center[0]),str(center[1]),'--udid',UDID],capture_output=True,env=clean);events.append({'command':'idb tap CTA','exit':r.returncode,'coordinates':center});
  if r.returncode:raise RuntimeError('CTA tap failed')
  form=None;poll=[]
  for i in range(40):
   a,ns=query('form-%02d'%i);form=find(ns,'custom-provider-form');titles=[n for n in ns if n['label']=='Custom Provider']
   poll.append({'ordinal':i+1,'form_count':len(form),'title_count':len(titles)})
   if len(form)==1 and len(titles)>=1:break
   time.sleep(.35)
  if len(form)!=1 or len(titles)<1:raise RuntimeError('custom form/title absent')
  fields={k:find(ns,k) for k in ['custom-provider-base-url','custom-provider-api-key','custom-provider-model-id','custom-provider-save']}
  if not all(len(fields[k])==1 for k in fields):raise RuntimeError('expected field cardinality')
  # Fresh app only: prove structural empty values without retaining any string values.
  empties={k:(fields[k][0]['value'] in [None,'']) for k in fields if k!='custom-provider-save'};save=fields['custom-provider-save'][0];save_disabled=(save['enabled'] is False or str(save['value']).lower() in ['disabled','not enabled'])
  if not all(empties.values()) or not save_disabled:raise RuntimeError('empty/disabled form structure mismatch')
  png=OUT/'custom-provider.png';r=subprocess.run(['xcrun','simctl','io',UDID,'screenshot',str(png)],capture_output=True);
  if r.returncode:raise RuntimeError('screenshot failed')
  dim=subprocess.run(['sips','-g','pixelWidth','-g','pixelHeight',str(png)],capture_output=True,text=True).stdout;nums=re.findall(r'pixel(?:Width|Height):\s*(\d+)',dim)
  receipt={'schema_version':1,'kind':'learnfold-lf04-isolated-navigation-diagnostic','udid':UDID,'bundle_id':BUNDLE,'identities':ids,'companion':{'pid':cp.pid,'socket':sock,'live_before_cleanup':cp.poll() is None},'lease':{'path':str(lease),'inode':os.lstat(lease).st_ino,'token_sha256':hashlib.sha256(token).hexdigest()},'commands':events,'lf03':{'codex_option_count':1},'cta':{'identifier':'course-agent-custom-provider','value':'not-configured','count':1,'application_frame':af,'before_frame':before,'below_viewport_before_swipe':below,'swipes':swipes,'after_frame':after,'wholly_inside_after_swipe':inside(af,after),'tap_center':center},'form':{'identifier':'custom-provider-form','count':1,'navigation_title':'Custom Provider','polling_count':len(poll),'polls':poll,'visible_fields_empty':empties,'save_present':True,'save_disabled':save_disabled},'screenshot':{'path':str(png),'sha256':sha(png),'bytes':png.stat().st_size,'dimensions':nums},'raw_ax_retained':False}
  rec=put('sanitized-receipt.json',receipt);ok=True
 finally:
  rawhash=[]
  for p in raw:
   if p.exists():rawhash.append({'name':p.name,'bytes':p.stat().st_size,'sha256':sha(p)});p.unlink()
  for p in [OUT/'companion.raw.stdout',OUT/'companion.raw.stderr']:
   if p.exists():rawhash.append({'name':p.name,'bytes':p.stat().st_size,'sha256':sha(p)});p.unlink()
  if cp and cp.poll() is None:cp.terminate();cp.wait(timeout=15)
  if os.path.exists(sock):os.unlink(sock)
  u=subprocess.run(['xcrun','simctl','uninstall',UDID,BUNDLE],capture_output=True);sd=subprocess.run(['xcrun','simctl','shutdown',UDID],capture_output=True);de=subprocess.run(['xcrun','simctl','delete',UDID],capture_output=True); lease.unlink();protected_after=subprocess.run(['xcrun','simctl','list','devices'],capture_output=True,text=True).stdout
  cleanup={'success':ok,'raw_deleted':rawhash,'companion_reaped':cp is None or cp.poll() is not None,'socket_absent':not os.path.exists(sock),'uninstall_exit':u.returncode,'shutdown_exit':sd.returncode,'delete_exit':de.returncode,'lease_absent':not lease.exists(),'protected_devices_unchanged':all(x in protected_after for x in ['D0FB9369-BFB4-4966-B677-2F42CDE0B218','2ABF8F31-6E24-4308-9ED9-32CF3CAE54D3']),'frozen_manifest_unchanged':sha(ROOT/'sealed-authority/frozen-manifest.json')==ids['manifest_sha256'],'frozen_app_unchanged':bh(APP)==BH}
  put('cleanup-receipt.json',cleanup)
  if not ok:raise RuntimeError('diagnostic failed')
if __name__=='__main__':main()

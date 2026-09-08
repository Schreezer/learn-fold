#!/usr/bin/env python3
import os,json,hashlib,stat,struct,subprocess,time,uuid,re,datetime
from pathlib import Path
ROOT=Path('/Users/Shared/LearnfoldProductionReadiness-20260823T104746Z');APP=ROOT/'evidence/DebugDerivedData/Build/Products/Debug-iphonesimulator/Litter.app';BUNDLE='com.chirag.learnfold';PY='/Users/chirag13/.local/pipx/venvs/fb-idb/bin/python';IDB='/Users/chirag13/.local/pipx/venvs/fb-idb/bin/idb';COMP='/opt/homebrew/bin/idb_companion';BH='986ff9a07a7ad71e0f9297727b8bfe8a2d6b155d78decdb8b70873f1e99bcdf5';EH='c1be19caab4b7290de29295c476f9c9216914eeebb31becb17f1d85da1235bcf';PROTECTED={'D0FB9369-BFB4-4966-B677-2F42CDE0B218','2ABF8F31-6E24-4308-9ED9-32CF3CAE54D3'}
def now():return datetime.datetime.now(datetime.timezone.utc).isoformat().replace('+00:00','Z')
def sha(p):
 h=hashlib.sha256()
 with open(p,'rb') as f:
  for b in iter(lambda:f.read(1048576),b''):h.update(b)
 return h.hexdigest()
def fsd(d):
 f=os.open(str(d),os.O_RDONLY);os.fsync(f);os.close(f)
def put(d,n,x,seal=False):
 p=d/n;raw=(json.dumps(x,sort_keys=True,separators=(',',':'))+'\n').encode();fd=os.open(str(p),os.O_CREAT|os.O_EXCL|os.O_WRONLY,0o600);os.write(fd,raw);os.fsync(fd);os.close(fd);fsd(d)
 if json.loads(p.read_text())!=x:raise RuntimeError('receipt readback '+n)
 q=d/(n+'.sha256');fd=os.open(str(q),os.O_CREAT|os.O_EXCL|os.O_WRONLY,0o600);os.write(fd,(sha(p)+'  '+n+'\n').encode());os.fsync(fd);os.close(fd);fsd(d)
 if seal:
  for z in(p,q):os.chmod(z,0o444);r=subprocess.run(['chflags','uchg',str(z)],capture_output=True);assert not r.returncode
 return {'path':str(p),'sha256':sha(p),'sidecar':str(q)}
def fixture():
 d=Path('/Users/Shared')/('LearnfoldLF04CorrectedFixture-'+time.strftime('%Y%m%dT%H%M%SZ',time.gmtime()));os.umask(0o077);os.mkdir(d,0o700);attempts=[]
 for name,code,payload in [('valid',0,b'[]'),('empty',0,b''),('nonutf8',0,b'\xff'),('malformed',0,b'{'),('nonzero',7,b'[]')]:
  p=subprocess.Popen([PY,'-c',f'import sys;sys.stdout.buffer.write({payload!r});sys.exit({code})'],stdout=subprocess.PIPE,stderr=subprocess.PIPE);o,e=p.communicate();rc=p.returncode
  try:json.loads(o.decode());cl='json'
  except UnicodeDecodeError:cl='non_utf8'
  except Exception:cl='empty' if not o else 'malformed_json'
  attempts.append({'name':name,'returncode_captured_immediately':rc,'stdout_bytes':len(o),'stdout_sha256':hashlib.sha256(o).hexdigest(),'stderr_bytes':len(e),'stderr_sha256':hashlib.sha256(e).hexdigest(),'classification':cl})
 r=put(d,'fixture-receipt.json',{'schema_version':1,'branches':attempts,'bounded_poll_attempt_logging_proven':all('returncode_captured_immediately'in x for x in attempts),'diagnostic_status':'fixture_pass','cleanup_success':True},True);return d,r
def rect(x):
 try:return {k:float(x[k]) for k in ('x','y','width','height')}
 except:return None
def inside(a,b):return b and b['x']>=a['x'] and b['y']>=a['y'] and b['x']+b['width']<=a['x']+a['width'] and b['y']+b['height']<=a['y']+a['height']
def parse(raw):
 try:x=json.loads(raw.decode())
 except UnicodeDecodeError:return None,[],'non_utf8'
 except Exception:return None,[],'malformed_json' if raw else 'empty'
 apps=x if isinstance(x,list) else []
 def walk(o,out):
  if isinstance(o,dict):
   ident=next((o[k] for k in ('AXUniqueId','identifier','accessibilityIdentifier','AXIdentifier') if isinstance(o.get(k),str)),None); lab=next((o[k] for k in ('label','AXLabel','title','AXTitle') if isinstance(o.get(k),str)),None)
   if ident or lab:out.append({'id':ident,'label':lab,'type':o.get('type') or o.get('AXType'),'value':o.get('value') or o.get('AXValue'),'enabled':o.get('enabled',o.get('AXEnabled')),'frame':rect(o.get('frame') or o.get('AXFrame'))})
   for v in o.values():walk(v,out)
  elif isinstance(o,list):
   for v in o:walk(v,out)
 ns=[];walk(x,ns);aa=[a for a in apps if isinstance(a,dict) and a.get('type')=='Application' and rect(a.get('frame')) and a.get('frame',{}).get('width',0)>0 and a.get('frame',{}).get('height',0)>0 and isinstance(a.get('children'),list)]
 # Learnfold app is proven by its own accessibility IDs, never by a route override.
 lf=[a for a in aa if any(n['id'] in {'course-agent-setup-picker','course-agent-option-codex','course-agent-custom-provider','custom-provider-form'} for n in ns)]
 return (lf[0] if len(lf)==1 else None),ns,('valid' if len(lf)==1 else 'not_one_learnfold_application')
def main():
 fx,fxr=fixture(); stamp=time.strftime('%Y%m%dT%H%M%SZ',time.gmtime());d=Path('/Users/Shared')/('LearnfoldLF04Corrected-'+stamp+'-'+uuid.uuid4().hex[:8]);os.mkdir(d,0o700);os.umask(0o077)
 protected_before=subprocess.run(['xcrun','simctl','list','devices'],capture_output=True,text=True).stdout; udid=None;lease=None;cp=None;sock=None;raw=[];attempts=[];actions=[];status='not_started';runner=0;cleanup={}
 ids={'frozen_manifest_sha256':sha(ROOT/'sealed-authority/frozen-manifest.json'),'source_inventory_sha256':sha(ROOT/'sealed-authority/frozen-source-inventory.json'),'build_inventory_sha256':sha(ROOT/'sealed-authority/frozen-build-inventory.json'),'app_bundle_sha256':BH,'app_executable_sha256':sha(APP/'Litter'),'idb_sha256':sha(IDB),'python_sha256':sha(os.path.realpath(PY)),'companion_sha256':sha(os.path.realpath(COMP))}
 try:
  if ids['app_executable_sha256']!=EH:raise RuntimeError('frozen executable mismatch')
  udid=subprocess.run(['xcrun','simctl','create','Learnfold LF04 Corrected '+stamp,'iPhone 17 Pro','com.apple.CoreSimulator.SimRuntime.iOS-26-5'],capture_output=True,text=True,check=True).stdout.strip()
  if udid in PROTECTED:raise RuntimeError('protected-ID refusal')
  lease=d/'exclusive.lease';token=os.urandom(32);fd=os.open(str(lease),os.O_CREAT|os.O_EXCL|os.O_WRONLY,0o600);os.write(fd,token);os.fsync(fd);os.close(fd);fsd(d)
  r=subprocess.run(['xcrun','simctl','boot',udid],capture_output=True);actions.append({'argv':['xcrun','simctl','boot',udid],'rc':r.returncode});
  if r.returncode:raise RuntimeError('boot failed')
  r=subprocess.run(['xcrun','simctl','bootstatus',udid,'-b'],capture_output=True);actions.append({'argv':['xcrun','simctl','bootstatus',udid,'-b'],'rc':r.returncode});
  if r.returncode:raise RuntimeError('bootstatus failed')
  sock=str(d/'private.sock');env={'HOME':'/var/empty','LANG':'C','LC_ALL':'C','PATH':'/usr/bin:/bin:/usr/sbin:/sbin','TMPDIR':str(d/'tmp')};os.mkdir(env['TMPDIR'],0o700);co=open(d/'comp.raw.out','xb');ce=open(d/'comp.raw.err','xb');cp=subprocess.Popen([COMP,'--udid',udid,'--grpc-domain-sock',sock,'--only','simulator'],stdout=co,stderr=ce,env=env);co.close();ce.close()
  for _ in range(100):
   if os.path.exists(sock) and cp.poll() is None:break
   time.sleep(.1)
  if not os.path.exists(sock) or cp.poll() is not None:raise RuntimeError('companion readiness failed')
  r=subprocess.run(['xcrun','simctl','install',udid,str(APP)],capture_output=True);actions.append({'argv':['xcrun','simctl','install',udid,str(APP)],'rc':r.returncode,'stdout_sha256':hashlib.sha256(r.stdout).hexdigest(),'stderr_sha256':hashlib.sha256(r.stderr).hexdigest()});
  if r.returncode:raise RuntimeError('install failed')
  r=subprocess.run(['xcrun','simctl','launch',udid,BUNDLE],capture_output=True);actions.append({'argv':['xcrun','simctl','launch',udid,BUNDLE],'rc':r.returncode});
  if r.returncode:raise RuntimeError('launch failed')
  argv=[PY,IDB,'--companion',sock,'ui','describe-all','--udid',udid,'--json','--nested']
  def poll(tag,limit,pred):
   for i in range(limit):
    p=d/f'{tag}-{i:02d}.ax';e=d/f'{tag}-{i:02d}.err';fo=open(p,'xb');fe=open(e,'xb');q=subprocess.Popen(argv,stdout=fo,stderr=fe,env=env);rc=q.wait();fo.close();fe.close();o=p.read_bytes();er=e.read_bytes();raw += [p,e];a,ns,cl=parse(o);attempts.append({'tag':tag,'ordinal':i+1,'timestamp':now(),'argv':argv,'returncode_captured_immediately':rc,'stdout_bytes':len(o),'stdout_sha256':hashlib.sha256(o).hexdigest(),'stderr_bytes':len(er),'stderr_sha256':hashlib.sha256(er).hexdigest(),'classification':cl,'application_count':1 if a else 0})
    if rc==0 and a and pred(a,ns):return a,ns
    time.sleep(.4)
   raise RuntimeError(tag+' bounded poll exhausted')
  a,ns=poll('intro',60,lambda a,n:any(x['id']=='course-agent-option-codex' for x in n)); intro_png=d/'lf03-picker.png';subprocess.run(['xcrun','simctl','io',udid,'screenshot',str(intro_png)],check=True)
  cod=[x for x in ns if x['id']=='course-agent-option-codex'];
  if len(cod)!=1 or not inside(rect(a['frame']),cod[0]['frame']):raise RuntimeError('Codex CTA not unique/in-frame')
  f=cod[0]['frame'];xy=[round(f['x']+f['width']/2),round(f['y']+f['height']/2)];r=subprocess.run([PY,IDB,'--companion',sock,'ui','tap',str(xy[0]),str(xy[1]),'--udid',udid],capture_output=True,env=env);actions.append({'argv':['idb','tap','codex'],'rc':r.returncode,'coordinates':xy});
  if r.returncode:raise RuntimeError('codex tap failed')
  a,ns=poll('selected',40,lambda a,n:sum(x['id']=='course-agent-option-codex' and x['value']=='available-selected' for x in n)==1 and sum(x['id']=='course-agent-custom-provider' and x['value']=='not-configured' for x in n)==1)
  c=[x for x in ns if x['id']=='course-agent-custom-provider'][0];before=c['frame'];sw=[]
  for i in range(8):
   af=rect(a['frame'])
   if inside(af,c['frame']):break
   sx=round(af['x']+af['width']/2);sy=round(af['y']+af['height']*.82);ey=round(af['y']+af['height']*.22);r=subprocess.run([PY,IDB,'--companion',sock,'ui','swipe',str(sx),str(sy),str(sx),str(ey),'--duration','0.45','--udid',udid],capture_output=True,env=env);sw.append({'coordinates':[sx,sy,sx,ey],'rc':r.returncode});
   if r.returncode:raise RuntimeError('swipe failed')
   a,ns=poll('swipe'+str(i),10,lambda a,n:sum(x['id']=='course-agent-custom-provider' for x in n)==1);c=[x for x in ns if x['id']=='course-agent-custom-provider'][0]
  af=rect(a['frame']);
  if not inside(af,c['frame']):raise RuntimeError('CTA remains below viewport')
  after=c['frame'];xy=[round(after['x']+after['width']/2),round(after['y']+after['height']/2)]
  if not (af['x']<=xy[0]<=af['x']+af['width'] and af['y']<=xy[1]<=af['y']+af['height']):raise RuntimeError('tap bounds invalid')
  r=subprocess.run([PY,IDB,'--companion',sock,'ui','tap',str(xy[0]),str(xy[1]),'--udid',udid],capture_output=True,env=env);actions.append({'argv':['idb','tap','custom-provider'],'rc':r.returncode,'coordinates':xy});
  if r.returncode:raise RuntimeError('custom tap failed')
  a,ns=poll('form',40,lambda a,n:sum(x['id']=='custom-provider-form' for x in n)==1 and sum(x['label']=='Custom Provider' for x in n)>=1)
  form_png=d/'custom-provider-form.png';subprocess.run(['xcrun','simctl','io',udid,'screenshot',str(form_png)],check=True); need=['custom-provider-base-url','custom-provider-api-key','custom-provider-model-id','custom-provider-save'];m={k:[x for x in ns if x['id']==k] for k in need}
  if not all(len(m[k])==1 for k in need):raise RuntimeError('form field cardinality')
  empty={k:m[k][0]['value'] in (None,'') for k in need[:3]};disabled=(m['custom-provider-save'][0]['enabled'] is False or str(m['custom-provider-save'][0]['value']).lower() in ('disabled','not enabled'))
  if not all(empty.values()) or not disabled:raise RuntimeError('form empty/disabled mismatch')
  status='pass';runner=0
 except Exception as ex:
  status='external_or_runner_failure';runner=1;failure=str(ex)
 finally:
  safe=[]
  for p in raw+[d/'comp.raw.out',d/'comp.raw.err']:
   if p.exists():safe.append({'name':p.name,'bytes':p.stat().st_size,'sha256':sha(p)});p.unlink()
  if cp and cp.poll() is None:cp.terminate();cp.wait(timeout=15)
  if sock and os.path.exists(sock) and stat.S_ISSOCK(os.lstat(sock).st_mode):os.unlink(sock)
  if udid and udid not in PROTECTED:
   term=subprocess.run(['xcrun','simctl','terminate',udid,BUNDLE],capture_output=True);uni=subprocess.run(['xcrun','simctl','uninstall',udid,BUNDLE],capture_output=True);sh=subprocess.run(['xcrun','simctl','shutdown',udid],capture_output=True);dele=subprocess.run(['xcrun','simctl','delete',udid],capture_output=True);cleanup.update({'terminate_rc':term.returncode,'uninstall_rc':uni.returncode,'shutdown_rc':sh.returncode,'delete_rc':dele.returncode})
  if lease and lease.exists():lease.unlink()
  after=subprocess.run(['xcrun','simctl','list','devices'],capture_output=True,text=True).stdout;cleanup.update({'companion_reaped':cp is None or cp.poll() is not None,'socket_absent':not sock or not os.path.exists(sock),'lease_absent':not lease or not lease.exists(),'disposable_absent':not udid or udid not in after,'protected_unchanged':all(x in after for x in PROTECTED),'frozen_manifest_unchanged':sha(ROOT/'sealed-authority/frozen-manifest.json')==ids['frozen_manifest_sha256'],'raw_deleted_after_sanitization':safe});cleanup_success=all([cleanup.get('companion_reaped'),cleanup.get('socket_absent'),cleanup.get('lease_absent'),cleanup.get('disposable_absent'),cleanup.get('protected_unchanged'),cleanup.get('frozen_manifest_unchanged')])
  doc={'schema_version':1,'kind':'learnfold-lf04-corrected-disposable-diagnostic','fixture':{'root':str(fx),'receipt':fxr},'diagnostic_status':status,'runner_exit_code':runner,'failure':locals().get('failure'), 'cleanup_success':cleanup_success,'udid':udid,'identities':ids,'attempts':attempts,'actions':actions,'raw_ax_secret_scan':'deleted-after-hash; no raw content retained','cleanup':cleanup}
  put(d,'terminal-receipt.json',doc,True)
  if status!='pass':raise SystemExit(1)
if __name__=='__main__':main()

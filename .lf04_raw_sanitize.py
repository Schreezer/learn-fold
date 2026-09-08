#!/usr/bin/env python3
import os,hashlib,json,re,subprocess
from pathlib import Path
d=Path('/Users/Shared/LearnfoldLF04Corrected-20260823T134438Z-91089bc7');p=d/'intro-00.ax';e=d/'intro-00.err'
def sha(x):
 h=hashlib.sha256();
 with open(x,'rb') as f:
  for b in iter(lambda:f.read(1048576),b''):h.update(b)
 return h.hexdigest()
def put(n,x):
 q=d/n;raw=(json.dumps(x,sort_keys=True,separators=(',',':'))+'\n').encode();fd=os.open(str(q),os.O_CREAT|os.O_EXCL|os.O_WRONLY,0o600);os.write(fd,raw);os.fsync(fd);os.close(fd);fd=os.open(str(d),os.O_RDONLY);os.fsync(fd);os.close(fd);assert json.loads(q.read_text())==x;h=sha(q);s=d/(n+'.sha256');fd=os.open(str(s),os.O_CREAT|os.O_EXCL|os.O_WRONLY,0o600);os.write(fd,(h+'  '+n+'\n').encode());os.fsync(fd);os.close(fd);os.chmod(q,0o444);os.chmod(s,0o444);subprocess.run(['chflags','uchg',str(q)],check=True);subprocess.run(['chflags','uchg',str(s)],check=True);return h
rows=[]
for x in[p,e]:
 if x.exists():
  b=x.read_bytes();rows.append({'name':x.name,'bytes':len(b),'sha256':hashlib.sha256(b).hexdigest(),'secret_scan':{'patterns':['sk-','Bearer ','Authorization:','BEGIN PRIVATE KEY'],'matches':sum(b.count(z) for z in [b'sk-',b'Bearer ',b'Authorization:',b'BEGIN PRIVATE KEY'])},'deleted':True})
put('raw-sanitization-correction.json',{'schema_version':1,'kind':'lf04-raw-sanitization-correction','original_terminal_receipt_sha256':sha(d/'terminal-receipt.json'),'residual_raw':rows,'reason':'runner closure failure preceded raw-attempt bookkeeping; raw deleted without retention','device_mutation':False})
for x,row in zip([p,e],rows):
 if x.exists():x.unlink()
print(json.dumps({'receipt':str(d/'raw-sanitization-correction.json'),'sha256':sha(d/'raw-sanitization-correction.json'),'raw_deleted':rows}))

import http.cookiejar,urllib.request, json, re, time, csv, os
log=open(os.environ['WS_HOST_LOG']).read()
m=re.search(r'entry=https?://[^\s]+/w/([a-zA-Z0-9-]+)',log)
assert m, 'share entry missing'
wid=m.group(1); base='http://127.0.0.1:8777'; jar=http.cookiejar.CookieJar(); op=urllib.request.build_opener(urllib.request.HTTPCookieProcessor(jar),urllib.request.ProxyHandler({}))
req=urllib.request.Request(base+'/session',data=json.dumps({'window_id':wid}).encode(),headers={'Content-Type':'application/json','Origin':base})
with op.open(req,timeout=5) as r: assert r.status==200
out=os.environ['WS_RESULTS_DIR']
with op.open(base+'/w/'+wid+'/stream',timeout=10) as r, open(out+'/'+os.environ.get('WS_LABEL','view-default')+'-frames.csv','w') as f:
 w=csv.writer(f); w.writerow(['elapsed_s','jpeg_bytes']); t=time.monotonic(); end=t+62; i=0
 while time.monotonic()<end:
  line=r.readline()
  if not line: break
  if not line.startswith(b'--windowshare'): continue
  headers={}
  while True:
   line=r.readline()
   if line in (b'\r\n',b'\n',b''): break
   k,_,v=line.partition(b':'); headers[k.lower()]=v.strip()
  size=int(headers[b'content-length']); data=r.read(size); now=time.monotonic(); w.writerow([round(now-t,6),len(data)]); i+=1
  if i==1: open(out+'/'+os.environ.get('WS_LABEL','view-default')+'.jpg','wb').write(data)
print('frames=',i,'elapsed_s=',round(time.monotonic()-t,3))

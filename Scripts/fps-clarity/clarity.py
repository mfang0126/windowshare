import subprocess,os,signal,time,re,urllib.request,http.cookiejar,json,tempfile
out=os.environ['WS_RESULTS_DIR']; exe=os.environ['WS_HOST_BIN']
for label,scale,cap in [('1x','1',''),('2x','2',''),('cap768','2','768'),('cap1280','2','1280'),('cap2560','2','2560')]:
 env=dict(os.environ,WS_MEASURE_FPS='15',WS_MEASURE_SCALE=scale,WS_MEASURE_CAP=cap,WS_MEASURE_QUALITY='0.65')
 with tempfile.NamedTemporaryFile(mode='w+', prefix='ws-clarity-', delete=True) as log:
  p=subprocess.Popen([exe,'--window-id',os.environ['WS_WINDOW_ID'],'--persistent'],env=env,stdout=log,stderr=subprocess.STDOUT)
  try:
   wid=None
   for _ in range(100):
    if p.poll() is not None: raise RuntimeError('host exited '+str(p.returncode))
    time.sleep(.1);s=open(log.name).read(); m=re.search(r'entry=https?://[^\s]+/w/([a-zA-Z0-9-]+)',s)
    if m: wid=m.group(1);break
   if not wid: raise RuntimeError('share entry missing')
   time.sleep(2)
   base='http://127.0.0.1:8777';jar=http.cookiejar.CookieJar();op=urllib.request.build_opener(urllib.request.HTTPCookieProcessor(jar),urllib.request.ProxyHandler({}))
   req=urllib.request.Request(base+'/session',data=json.dumps({'window_id':wid}).encode(),headers={'Content-Type':'application/json','Origin':base})
   with op.open(req,timeout=5) as r: assert r.status==200
   with op.open(base+'/w/'+wid+'/snapshot',timeout=5) as r:
    assert r.status==200; data=r.read(); assert len(data)>1000;open(out+'/clarity-'+label+'.jpg','wb').write(data)
   print(label,'jpeg_bytes',len(data),flush=True)
  finally:
   if p.poll() is None: p.send_signal(signal.SIGINT)
   try:p.wait(timeout=5)
   except subprocess.TimeoutExpired:p.kill();p.wait()
   print(label,'host_exit',p.returncode,flush=True)

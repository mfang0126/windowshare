import http.cookiejar,urllib.request, json,re,time,csv,uuid,threading,websocket,os
log=open(os.environ['WS_HOST_LOG']).read(); wid=re.search(r'entry=https?://[^\s]+/w/([a-zA-Z0-9-]+)',log).group(1); base='http://127.0.0.1:8777'
jar=http.cookiejar.CookieJar(); op=urllib.request.build_opener(urllib.request.HTTPCookieProcessor(jar),urllib.request.ProxyHandler({}))
def post(path,data):
 req=urllib.request.Request(base+path,data=json.dumps(data).encode(),headers={'Content-Type':'application/json','Origin':base})
 with op.open(req,timeout=5) as r: return json.load(r)
post('/session',{'window_id':wid}); ticket=post('/w/'+wid+'/connect',{})
ws=websocket.create_connection('ws://127.0.0.1:8778'+ticket['resource'],origin=base,timeout=5,http_proxy_host=None)
ws.send(json.dumps({'t':'auth','ticket':ticket['ticket'],'resource':ticket['resource']}))
assert json.loads(ws.recv())['t']=='state'
ws.send(json.dumps({'t':'lease.acquire','operation_id':str(uuid.uuid4()),'lease_ttl_sec':300}))
lease=None
for _ in range(5):
 m=json.loads(ws.recv())
 if m.get('t')=='state' and m.get('mode')=='Interact': lease=m; break
assert lease, 'lease unavailable'
stop=threading.Event()
def keep():
 ws.settimeout(2)
 while not stop.is_set():
  try:
   m=json.loads(ws.recv())
   if m.get('t')=='heartbeat': ws.send(json.dumps({'t':'pong','nonce':m['nonce']}))
  except websocket.WebSocketTimeoutException: pass
  except Exception: break
thread=threading.Thread(target=keep,daemon=True);thread.start();time.sleep(2)
out=os.environ['WS_RESULTS_DIR']; seq=0;i=0;t=time.monotonic();end=t+62
with open(out+'/interact-frames.csv','w') as f:
 w=csv.writer(f);w.writerow(['elapsed_s','jpeg_bytes','sequence','status']);
 while time.monotonic()<end:
  with op.open(base+'/w/'+wid+'/snapshot/'+str(seq),timeout=5) as r:
   if r.status==204: w.writerow([round(time.monotonic()-t,6),0,seq,204]);continue
   data=r.read();seq=int(r.headers['X-WindowShare-Frame-Seq']);w.writerow([round(time.monotonic()-t,6),len(data),seq,r.status]);i+=1
   if i==1: open(out+'/interact.jpg','wb').write(data)
stop.set(); ws.send(json.dumps({'t':'lease.release','lease_id':lease['lease_id'],'lease_epoch':lease['lease_epoch'],'decision_id':str(uuid.uuid4())})); ws.close();thread.join(timeout=3)
print('frames=',i,'elapsed_s=',round(time.monotonic()-t,3))

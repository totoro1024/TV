#!/usr/bin/env python3
"""检查真实 APK 的 DEX，防止 R8 再次重命名或移除 Gson 同步字段。"""
from pathlib import Path
import zipfile,struct,re,sys
apk=Path(sys.argv[1] if len(sys.argv) > 1 else 'app/build/outputs/apk/leanback/release/leanback-arm64_v8a.apk')
expected={'Lcom/fongmi/android/tv/sync/SyncDocument;':{'schema','epoch','mode','reset','records'},'Lcom/fongmi/android/tv/sync/SyncDocument$Entry;':{'kind','modified','sequence','device','deleted','value'},'Lcom/fongmi/android/tv/sync/SyncReplica;':{'document','observed','acknowledgedEpoch','paused','acceptedReset','clock'}}
found={k:set() for k in expected}
with zipfile.ZipFile(apk) as z:
 for name in z.namelist():
  if not re.fullmatch(r'classes\d*\.dex',name):continue
  b=z.read(name)
  count,offset=struct.unpack_from('<II',b,0x38);strings=[]
  for i in range(count):
   p=struct.unpack_from('<I',b,offset+4*i)[0]
   while b[p]&128:p+=1
   p+=1;end=b.index(0,p);strings.append(b[p:end].decode('utf-8',errors='replace'))
  count,offset=struct.unpack_from('<II',b,0x40);types=[strings[struct.unpack_from('<I',b,offset+4*i)[0]] for i in range(count)]
  count,offset=struct.unpack_from('<II',b,0x50)
  for i in range(count):
   owner,_,field=struct.unpack_from('<HHI',b,offset+8*i)
   if types[owner] in found:found[types[owner]].add(strings[field])
for k,v in expected.items():
 assert v<=found[k],(k,v-found[k]);print(k.split('/')[-1][:-1],'协议字段完整保留',len(v))

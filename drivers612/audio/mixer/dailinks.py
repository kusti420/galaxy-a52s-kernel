#!/usr/bin/env python3
"""List dai-link arrays of a lahaina.c (name, stream_name, flags, enclosing #if stack). usage: dailinks.py lahaina.c"""
import re,sys
src=open(sys.argv[1],errors='replace').read()
src=re.sub(r'/\*.*?\*/',lambda m:'\n'*m.group(0).count('\n'),src,flags=re.S)
lines=src.split('\n'); stack=[]; arr=None; cur=None; depth=0; idx=0
for ln in lines:
    t=ln.strip()
    if t.startswith('#if'): stack.append(t)
    elif t.startswith('#else') and stack: stack[-1]='!('+stack[-1]+')'
    elif t.startswith('#elif') and stack: stack[-1]=t
    elif t.startswith('#endif') and stack: stack.pop()
    m=re.match(r'static struct snd_soc_dai_link (\w+)\[.*\]\s*=\s*\{',t)
    if m: arr=m.group(1); idx=0; depth=1; print(f'\n## {arr}  {" && ".join(stack)}'); continue
    if arr is None: continue
    if depth==1 and t.startswith('{'): cur={'if':' && '.join(stack)}
    depth+=t.count('{')-t.count('}')
    if cur is not None:
        for k in ('name','stream_name','no_pcm','dynamic','id','dpcm_playback','dpcm_capture'):
            mm=re.search(r'\.'+k+r'\s*=\s*([^,]+),',t)
            if mm and k not in cur: cur[k]=mm.group(1).strip().strip('"')
        mm=re.search(r'SND_SOC_DAILINK_REG\((\w+)\)',t)
        if mm: cur['reg']=mm.group(1)
        if depth==1 and '}' in t:
            print(f"{idx:3d} | {cur.get('name','?')} | {cur.get('stream_name','')} | {'BE' if cur.get('no_pcm') else 'FE'} | id={cur.get('id','')} | {cur.get('reg','')} | {cur['if']}")
            idx+=1; cur=None
    if depth<=0: arr=None

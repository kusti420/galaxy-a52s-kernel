#!/usr/bin/env python3
# Carries Samsung's CONFIG_SEC_SND_ADAPTATION hunks from the 5.4 techpack into b/.
# Each #ifdef block is inserted after the same anchor line (nearest preceding non-blank
# line of the 5.4 file) in the 6.12 file; reports blocks whose anchor is not unique.
import sys,re,shutil,os
K=os.path.expandvars('$ANDROID_TREE/kernel/samsung/sm7325/techpack/audio')
B=sys.argv[1]
files='''asoc/msm-pcm-voice-v2.c asoc/msm-pcm-routing-v2.h asoc/msm_dailink.h asoc/platform_init.c
asoc/platform_init.h asoc/lahaina.c asoc/msm-pcm-routing-v2.c dsp/q6_init.h dsp/q6_init.c dsp/q6voice.c
dsp/q6asm.c dsp/q6adm.c dsp/q6afe.c include/dsp/q6asm-v2.h include/dsp/q6voice.h'''.split()
for f in ['asoc/sec_audio_adaptation.c','asoc/sec_voice_adaptation.c','asoc/sec_voice_adaptation.h',
          'dsp/q6voice_adaptation.c','include/asoc/sec_audio_adaptation.h','include/dsp/q6voice_adaptation.h']:
    shutil.copy(f'{K}/{f}',f'{B}/{f}')
def blocks(lines):
    i=0
    while i<len(lines):
        if re.match(r'\s*#\s*ifdef\s+CONFIG_SEC_SND_ADAPTATION',lines[i]):
            d=0;j=i
            while True:
                if re.match(r'\s*#\s*if',lines[j]): d+=1
                if re.match(r'\s*#\s*endif',lines[j]):
                    d-=1
                    if d==0: break
                j+=1
            yield i,j
            i=j
        i+=1
for f in files:
    src=open(f'{K}/{f}',errors='replace').read().split('\n')
    dst=open(f'{B}/{f}',errors='replace').read().split('\n')
    if any('CONFIG_SEC_SND_ADAPTATION' in l for l in dst): print('already',f); continue
    for i,j in blocks(src):
        # anchor: up to 3 preceding lines, try longest first
        k=i-1
        while not src[k].strip(): k-=1
        blank=(k!=i-1)
        done=False
        for n in (3,2,1):
            anc=[l for l in src[k-n+1:k+1]]
            hits=[x for x in range(len(dst)-n+1) if dst[x:x+n]==anc]
            if len(hits)==1:
                at=hits[0]+n
                ins=([''] if blank else [])+src[i:j+1]
                dst[at:at]=ins; done=True; break
        print(('ok   ' if done else 'FAIL ')+f'{f}:{i+1}-{j+1} anchor={src[k].strip()[:60]!r}')
    open(f'{B}/{f}','w').write('\n'.join(dst))

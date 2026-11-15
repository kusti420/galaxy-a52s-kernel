#!/bin/bash
# Prints the insmod order of the built audio modules (topological sort over modinfo "depends").
# Modules not built here (soc-repo / GKI / mm-drivers) are listed first as "needs:".
H=$(cd "$(dirname "$0")" && pwd)
python3 - "$H/audio-kernel" <<'PY'
import subprocess,sys,os
root=sys.argv[1]; kos={}
for d,_,fs in os.walk(root):
    for f in fs:
        if f.endswith('.ko'): kos[f[:-3].replace('-','_')]=os.path.join(d,f)
deps={m:[x.replace('-','_') for x in subprocess.run(['modinfo','-F','depends',p],capture_output=True,text=True).stdout.strip().split(',') if x] for m,p in kos.items()}
ext=sorted({d for m in deps for d in deps[m] if d not in kos})
print('needs (not built here):',' '.join(ext))
done=[];
def visit(m):
    if m in done: return
    for d in deps[m]:
        if d in kos: visit(d)
    done.append(m)
pri=['snd_event_dlkm','q6_notifier_dlkm','q6_pdr_dlkm','apr_dlkm','adsp_loader_dlkm','q6_dlkm','native_dlkm','pinctrl_lpi_dlkm','swr_dlkm','swr_ctrl_dlkm','platform_dlkm','stub_dlkm','hdmi_dlkm','wcd_core_dlkm','wcd9xxx_dlkm','mbhc_dlkm','bolero_cdc_dlkm','va_macro_dlkm','rx_macro_dlkm','tx_macro_dlkm','wcd938x_slave_dlkm','wcd938x_dlkm','sec_audio_sysfs','tas256x_dlkm']
for m in pri+sorted(kos):
    if m in kos: visit(m)
last='machine_dlkm'
if last in done: done.remove(last); done.append(last)
for m in done: print('insmod', os.path.relpath(kos[m],root))
PY

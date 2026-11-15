import re,sys
sys.argv=['x']; exec(open('./drivers612/camera/dt-work/gen.py').read().split("proot, pph, ppath = parse(PHONE)")[0])
proot,pph,ppath=parse(PHONE)
def c(v): return [int(x,16) for x in v.strip('<>').split()] if v and v.startswith('<') else []
def lab(ph):
    n=pph.get(ph); return (n.labels[0] if n and n.labels else (n.name if n else hex(ph)))
rows=[]
for p,n in ppath.items():
    comp=n.get('compatible') or ''
    if comp not in ('"qcom,cam-sensor"','"qcom,eeprom"','"qcom,actuator"','"qcom,ois"'): continue
    names=re.findall(r'"([^"]+)"', n.get('regulator-names') or '')
    mn=c(n.get('rgltr-min-voltage')); mx=c(n.get('rgltr-max-voltage'))
    regs=[]
    for i,nm in enumerate(names):
        s=n.get(nm+'-supply'); 
        regs.append('%s=%s %s'%(nm, lab(c(s)[0]) if s else '?', ('%.3f'%(mn[i]/1e6) if mn[i]==mx[i] else '%.3f-%.3f'%(mn[i]/1e6,mx[i]/1e6)) if i<len(mn) and mn[i] else ''))
    g=c(n.get('gpios')); gl=re.findall(r'"([^"]+)"', n.get('gpio-req-tbl-label') or '')
    gp=['%s=%d'%(gl[i] if i<len(gl) else '?', g[3*i+1]) for i in range(len(g)//3)]
    def one(k):
        v=c(n.get(k)); return v[0] if v else '-'
    srcs=[k[:-4]+'='+lab(c(n.get(k))[0]) for k in ('eeprom-src','actuator-src','ois-src','led-flash-src') if n.get(k)]
    rows.append((p, '| %s | %s | %s | %s | %s | %s | %s | %s | %s | %s | %s |'%(n.labels[0] if n.labels else '', n.name, comp.strip('"').replace('qcom,',''), n.parent.name, one('cell-index'), one('cci-master'), one('csiphy-sd-index'), ('0x%x'%one('slave-addr')) if n.get('slave-addr') else (n.get('reg') or '-'), '; '.join(regs), ', '.join(gp), ' '.join(srcs)+ (' mclk=%d'%c(n.get('clock-rates'))[0] if n.get('clock-rates') else '') + (' '+lab(c(n.get('clocks'))[0])+':'+str(c(n.get('clocks'))[1]) if n.get('clocks') else '') + ((' status='+n.get('status')) if n.get('status') else ''))))
print('| label | node | type | bus | cell-index | cci-master | csiphy-sd-index | addr | regulators (V) | TLMM gpios | links / mclk |')
print('|---|---|---|---|---|---|---|---|---|---|---|')
for p,r in rows: print(r)
print()
for p,n in ppath.items():
    if 's2mpb03-ldo' in n.name or 's2mpb03-buck' in n.name:
        print('| %s | %s | %s | %s | %s |'%(n.labels[0] if n.labels else '', n.name, n.get('regulator-name'), c(n.get('regulator-min-microvolt'))[0], c(n.get('regulator-max-microvolt'))[0]))

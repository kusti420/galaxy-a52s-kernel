#!/usr/bin/env python3
"""Which DT properties of the phone does the ported driver still read?
For every property name in the extracted phone nodes: is the literal found in the 5.4
driver sources, and in the ported sources? Prints the ones 5.4 reads but the port does not."""
import re,sys,glob,os
W=os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
A=os.path.expandvars('$ANDROID_TREE/kernel/samsung/sm7325/drivers')
def strs(dirs):
    s=set()
    for d in dirs:
        for r,_,fs in os.walk(d):
            for f in fs:
                if f.endswith(('.c','.h')) and not f.endswith('.orig'):
                    s|=set(re.findall(r'"([A-Za-z0-9_,\-#]+)"',open(os.path.join(r,f),errors='ignore').read()))
    return s
old=strs([A+'/battery',A+'/mfd/sm',A+'/muic',A+'/usb/typec',A+'/usb/notify',A+'/regulator/s2mpb03',A+'/leds',A+'/sec_thermistor' if os.path.isdir(A+'/sec_thermistor') else A+'/hwmon'])
new=strs([W+'/src'])
props=[]
for l in open(W+'/dt-extract/nodes-r02.txt'):
    m=re.match(r'\s+([A-Za-z0-9_,\-#]+)( = |;)',l)
    if m: props.append(m.group(1))
std={'phandle','compatible','status','reg','pinctrl-0','pinctrl-names','io-channels','io-channel-names','io-channel-ranges','regulator-name','regulator-min-microvolt','regulator-max-microvolt','id'}
lost=[p for p in dict.fromkeys(props) if p not in std and p in old and p not in new]
never=[p for p in dict.fromkeys(props) if p not in std and p not in old and p not in new]
print('READ BY 5.4, NOT READ BY THE PORT (%d):'%len(lost)); print('  '+'\n  '.join(lost))
print('IN DT, READ BY NEITHER (%d):'%len(never)); print('  '+' '.join(never))

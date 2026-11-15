#!/usr/bin/env python3
"""Print the DT node enclosing a given line of a decompiled dts, verbatim, with its
parent path. Usage: extract.py file.dts LINE [LINE...]"""
import sys,re
lines=open(sys.argv[1]).read().split('\n')
def node_at(n):
    # walk back to the line opening the innermost node containing line n (1-based)
    depth=0;i=n-1
    while i>=0:
        l=lines[i]
        if l.rstrip().endswith('};') : depth+=1
        if l.rstrip().endswith('{'):
            if depth==0: break
            depth-=1
        i-=1
    start=i
    depth=0;j=start
    while True:
        l=lines[j].rstrip()
        if l.endswith('{'): depth+=1
        if l.endswith('};'):
            depth-=1
            if depth==0: break
        j+=1
    return start,j
def path(start):
    names=[];i=start;ind=len(lines[i])-len(lines[i].lstrip('\t'))
    names.append(lines[i].strip()[:-1].strip())
    while ind>0:
        i-=1
        l=lines[i]
        k=len(l)-len(l.lstrip('\t'))
        if k<ind and l.rstrip().endswith('{'):
            names.append(l.strip()[:-1].strip()); ind=k
    return '/'.join(x.split(':')[-1].strip() for x in reversed(names)).replace('//','/')
for a in sys.argv[2:]:
    s,e=node_at(int(a))
    print('/* ==== %s  (r02 lines %d-%d) ==== */'%(path(s),s+1,e+1))
    print('\n'.join(lines[s:e+1]))

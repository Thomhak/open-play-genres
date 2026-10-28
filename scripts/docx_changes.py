#!/usr/bin/env python3
"""List tracked changes and comments in a Word .docx (stdlib only).

Usage:
  python3 scripts/docx_changes.py reviews/coauthor_docx/manuscript_v3.2.docx

Prints every paragraph that carries a tracked insertion ({+...+}), deletion
([-...-]) or comment anchor (<<Cnn: ... >>), with author/date, followed by the
comment texts. Used for the co-author review rounds: implement the changes in
manuscript.qmd, re-render, and the co-author continues from the new render.
"""
import sys, os, zipfile, tempfile
import xml.etree.ElementTree as ET
if len(sys.argv) != 2 or not sys.argv[1].endswith(".docx"):
    sys.exit(__doc__)
_tmp = tempfile.mkdtemp()
with zipfile.ZipFile(sys.argv[1]) as z:
    z.extractall(_tmp)
sys.argv[1] = _tmp
W='{http://schemas.openxmlformats.org/wordprocessingml/2006/main}'
d=ET.parse(sys.argv[1]+'/word/document.xml').getroot()
try:
    c=ET.parse(sys.argv[1]+'/word/comments.xml').getroot()
    comments={cm.get(W+'id'):(cm.get(W+'author'),cm.get(W+'date'),''.join(t.text or '' for t in cm.iter(W+'t'))) for cm in c.iter(W+'comment')}
except Exception: comments={}
def render(p):
    out=[];flag=False
    def walk(e,mode):
        nonlocal flag
        for ch in e:
            tag=ch.tag
            if tag==W+'ins': flag=True; out.append('{+'); walk(ch,'ins'); out.append('+}')
            elif tag==W+'del': flag=True; out.append('[-'); walk(ch,'del'); out.append('-]')
            elif tag==W+'commentRangeStart': flag=True; out.append(f'<<C{ch.get(W+"id")}:')
            elif tag==W+'commentRangeEnd': out.append(f'>>')
            elif tag in (W+'t',W+'delText'): out.append(ch.text or '')
            elif tag==W+'tab': out.append('\t')
            else: walk(ch,mode)
    walk(p,None)
    return flag, ''.join(out)
n=0
for i,p in enumerate(d.iter(W+'p')):
    flag,txt=render(p)
    if flag:
        n+=1
        authors=set((e.get(W+'author'),e.get(W+'date','')[:10]) for e in p.iter() if e.tag in (W+'ins',W+'del'))
        print(f'\n### para {i} {sorted(authors)}\n{txt}')
print(f'\n=== {n} paragraphs with changes/comments')
for k,(a,dt,t) in comments.items(): print(f'\nC{k} [{a} {dt[:10]}]: {t}')

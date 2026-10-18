import json,re,glob,os,collections
runs={}
for d in sorted(glob.glob('runs/*')):
    runs[d.split('/')[1]]=open(d+'/transcript.md').read()
work={}
for w in glob.glob('tmp/e3d-debate.*'):
    t=open(w+'/transcript.md').read()
    for k,v in runs.items():
        if t.strip() and v.startswith(t[:2000]) or v==t: work[k]=w
rows=[]
for k,t in runs.items():
    w=work.get(k)
    inp=out=0; calls=0; models=collections.Counter()
    if w:
        for f in glob.glob(w+'/*.stderr'):
            for l in open(f):
                if l.startswith('e3d_provider_usage='):
                    u=json.loads(l.split('=',1)[1]); us=u.get('usage') or {}
                    i=us.get('prompt_tokens',us.get('input_tokens',0)); o=us.get('completion_tokens',us.get('output_tokens',0))
                    inp+=i; out+=o; calls+=1; models[u['provider']]+=1
    # sections
    secs=re.split(r'^## ',t,flags=re.M)[1:]
    ans={}
    for s in secs:
        h,_,b=s.partition('\n'); ans[h.strip()]=b
    narr=sum(1 for h,b in ans.items() if h.startswith('Round') and re.search(r"\b(I'll|I will|Let me|I'm going to|I need to) (read|check|look|verify|open|examine|review)",b))
    words=sum(len(b.split()) for h,b in ans.items() if h.startswith('Round'))
    synth=[b for h,b in ans.items() if h.startswith('Synthesis')][0]
    # attribution: quoted strings in synthesis present in transcript analyst text
    quotes=re.findall(r'"([^"]{12,200})"',synth)
    body='\n'.join(b for h,b in ans.items() if h.startswith('Round'))
    norm=lambda s:re.sub(r'\s+',' ',re.sub(r'[*_`]','',s)).lower().strip(' .')
    nb=norm(body)
    missing=[q for q in quotes if norm(q) not in nb]
    rows.append((k,calls,dict(models),inp,out,narr,words,len(quotes),len(missing),len(synth.split())))
print(f"{'run':22}{'calls':>6}{'in_tok':>9}{'out_tok':>9}{'narr':>5}{'words':>7}{'quotes':>7}{'bad':>4}{'synthW':>7}")
for r in rows: print(f"{r[0]:22}{r[1]:>6}{r[3]:>9}{r[4]:>9}{r[5]:>5}{r[6]:>7}{r[7]:>7}{r[8]:>4}{r[9]:>7}")
json.dump(rows,open('metrics.json','w'))

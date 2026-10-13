import sys, json
sys.argv = ["x"]
exec(open(r"tools/loop_trace.py", encoding="utf-8").read().split("# 4) Tarjan SCC")[0])
ANTI_D = {0:2, 1:3, 2:0, 3:1}
def input_dirs(b):
    if b.defn == "1bit寄存器": return [posmod(0+b.rot,4), posmod(3+b.rot,4)]
    if b.defn == "非门": return [ANTI_D[b.rot]]
    if b.defn == "灯泡": return [0,1,2,3]
    return []
game = {b.id: b.in_loop for b in builds}      # 存档里的红点
for b in builds: b.in_loop = False            # 清零后按规则重算
building=set(); built=set(); back=[]
def dfs(b, chain):
    if b in building or b in built: return
    building.add(b)
    for d in input_dirs(b):
        n = b.pin_net.get(d)
        if n is None: continue
        for (s,_sd) in n.drivers:
            if s is b: continue
            dfs(s, chain+[b])
            if s in building:
                back.append((s,b,list(chain)))
                s.in_loop=True; b.in_loop=True
    building.discard(b); built.add(b)
for b in builds:
    if not (b.is_wire or b.is_cross): dfs(b,[])
changed=True
while changed:
    changed=False
    for b in builds:
        if b.is_wire or b.is_cross or not b.in_loop: continue
        for d in input_dirs(b):
            n = b.pin_net.get(d)
            if n is None: continue
            if not any(s.in_loop for s,_ in n.drivers): continue
            for w in n.wires:
                if not w.in_loop: w.in_loop=True; changed=True
mine = {b.id for b in builds if b.in_loop}
g = {i for i,v in game.items() if v}
print(f"存档红点 {len(g)} 个；清零重算红点 {len(mine)} 个；两者交集 {len(g & mine)}")
print("重算标红:", ", ".join(sorted([b.tag() for b in builds if b.in_loop and (b.is_wire or b.is_cross)==False], key=lambda s:s)))
print("\n回边", len(back), "条：")
for s,b,ch in back:
    print(f"  {b.defn}@({b.x},{b.y})#{b.id} -> {s.defn}@({s.x},{s.y})#{s.id}")
    i = next((k for k,x in enumerate(ch) if x is s), 0)
    print("     环: " + " <- ".join(f"{x.defn}@({x.x},{x.y})#{x.id}{'(寄存器!)' if x.is_seq else ''}" for x in ch[i:]+[b,s]))
print("\n存档红点里、重算无法复现的:", len(g - mine), "个")
for b in [x for x in builds if game.get(x.id) and x.id not in mine][:12]:
    print("   ", b.tag())

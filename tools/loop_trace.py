# 临时分析脚本（非游戏运行代码）：离线复算存档的电路依赖图，定位 in_loop 的真实环路
# 规则照抄：SWBuildCompoentCircuit / CircuitWire / CircuitWireCross 的 getNet、connectWireGroup、getBuildExpr
import json, sys
from collections import defaultdict

SAVE = r"C:\Users\Administrator\AppData\Roaming\Godot\app_userdata\无限地图\saves\计数器.json"
GRID = (128, 128)
UP, RIGHT, DOWN, LEFT = 0, 1, 2, 3
VEC = {UP: (0, -1), RIGHT: (1, 0), DOWN: (0, 1), LEFT: (-1, 0)}
ANTI = {UP: DOWN, DOWN: UP, RIGHT: LEFT, LEFT: UP if False else RIGHT}
ANTI[UP] = DOWN

# def -> (ref_outputs, ref_inputs)，对应各组件 setPortFlag
PORTS = {
    "非门":       ([UP], [DOWN]),
    "开关":       ([UP], []),
    "按钮":       ([UP], []),
    "时钟":       ([UP], []),
    "灯泡":       ([], [UP, RIGHT, DOWN, LEFT]),
    "1bit寄存器": ([RIGHT], [UP, LEFT]),   # Q 输出；CLK=UP, D=LEFT
}
WIRE = {"电线A", "电线B"}
CROSS = {"电线桥梁"}


def posmod(a, b):
    return (a % b + b) % b


class B:
    def __init__(self, d):
        self.id = d["id"]; self.defn = d["def"]; self.rot = d["rot"]
        self.x = d["pos"]["x"] // GRID[0]; self.y = d["pos"]["y"] // GRID[1]
        self.comp = d.get("comp_type"); self.in_loop = bool(d.get("in_loop"))
        self.linked = set()
        self.net = None; self.v_net = None; self.h_net = None
        self.pin_net = {}
        self.is_wire = self.defn in WIRE
        self.is_cross = self.defn in CROSS
        self.is_seq = self.defn == "1bit寄存器"

    def ref_dirs(self):
        if self.is_wire or self.is_cross:
            return list(range(4)), []
        return PORTS.get(self.defn, ([], []))

    def w_out(self):
        o, _ = self.ref_dirs()
        return {posmod(d + self.rot, 4) for d in o}

    def w_in(self):
        _, i = self.ref_dirs()
        return {posmod(d + self.rot, 4) for d in i}

    def is_port(self, wdir):
        return wdir in self.w_out() or wdir in self.w_in()

    def port_is_input(self, wdir):
        if not self.is_port(wdir):
            return False
        return self.is_wire or self.is_cross or wdir in self.w_in()

    def port_is_output(self, wdir):
        if not self.is_port(wdir):
            return False
        return self.is_wire or self.is_cross or wdir in self.w_out()

    def pos(self):
        return (self.x, self.y)

    def tag(self):
        return f"{self.defn}@({self.x},{self.y}) rot={self.rot} id={self.id}{' [RED]' if self.in_loop else ''}"


data = json.load(open(SAVE, encoding="utf-8"))
builds = [B(d) for d in data["builds"]]
grid = {b.pos(): b for b in builds}
kinds = defaultdict(int)
for b in builds:
    kinds[b.defn] += 1
print(f"建筑 {len(builds)} 个，标红 in_loop {sum(1 for b in builds if b.in_loop)} 个")
print("种类:", dict(kinds))
if kinds.get("电线隧道"):
    print("!! 存档含电线隧道，本脚本未建模，结果可能不准")


def neighbor(b, wdir):
    vx, vy = VEC[wdir]
    return grid.get((b.x + vx, b.y + vy))


class Net:
    _n = 0

    def __init__(self, name):
        Net._n += 1
        self.nid = Net._n
        self.name = name
        self.drivers = []
        self.loads = []
        self.wires = []


def get_wire_group(start, src_dir):
    group = [(start, src_dir)]
    visited = {start.pos()}
    queue = [(start, src_dir)]
    while queue:
        w, d = queue.pop()
        for nd in range(3, -1, -1):
            if not w.is_port(nd):
                continue
            nb = neighbor(w, nd)
            if nb is None or not (nb.is_wire or nb.is_cross):
                continue
            if w.is_cross and nd != d and nd != ANTI[d]:
                continue
            if nb.pos() in visited:
                continue
            visited.add(nb.pos())
            queue.append((nb, nd))
            group.append((nb, nd))
    return group


def set_net(w, net, d):
    if w.is_cross:
        if d in (UP, DOWN):
            w.v_net = net; w.pin_net[UP] = net; w.pin_net[DOWN] = net
        else:
            w.h_net = net; w.pin_net[RIGHT] = net; w.pin_net[LEFT] = net
    else:
        w.net = net
        for k in range(4):
            w.pin_net[k] = net
    net.wires.append(w)


# 1) 电线分网
for b in builds:
    if not (b.is_wire or b.is_cross):
        continue
    if b.is_cross:
        if b.v_net is None:
            n = Net(b.defn)
            for w, d in get_wire_group(b, UP):
                set_net(w, n, d)
        if b.h_net is None:
            n = Net(b.defn)
            for w, d in get_wire_group(b, RIGHT):
                set_net(w, n, d)
    elif b.net is None:
        n = Net(b.defn)
        for w, d in get_wire_group(b, UP):
            set_net(w, n, d)


# 2) driver / load
def dir_build(b, wdir):
    nb = neighbor(b, wdir)
    if nb is None:
        return None
    anti = ANTI[wdir]
    if not nb.is_port(anti):
        return None
    if b.is_wire or b.is_cross or nb.is_wire or nb.is_cross:
        return nb
    if b.port_is_output(wdir) and nb.port_is_input(anti):
        return nb
    if b.port_is_input(wdir) and nb.port_is_output(anti):
        return nb
    return None


for b in builds:
    if b.is_wire or b.is_cross:
        for d in range(3, -1, -1):
            if d in b.linked:
                continue
            nb = dir_build(b, d)
            if nb is None or nb.is_wire or nb.is_cross:
                continue
            anti = ANTI[d]
            if not nb.port_is_input(anti):
                continue
            n = b.pin_net.get(d)
            if n is None:
                continue
            b.linked.add(d); nb.linked.add(anti)
            n.loads.append((nb, anti))
            nb.pin_net[anti] = n
    else:
        for d in range(3, -1, -1):
            if not b.is_port(d) or d in b.linked or b.port_is_input(d):
                continue
            nb = dir_build(b, d)
            if nb is None:
                continue
            anti = ANTI[d]
            b.linked.add(d); nb.linked.add(anti)
            if nb.is_wire or nb.is_cross:
                n = nb.pin_net.get(anti)
                if n is None:
                    continue
                n.drivers.append((b, d))
                b.pin_net[d] = n
            else:
                n = Net(b.defn + "->" + nb.defn)
                n.drivers.append((b, d)); n.loads.append((nb, anti))
                b.pin_net[d] = n; nb.pin_net[anti] = n

# 3) 依赖边：输入方向所在 net 的 drivers
edges = defaultdict(set)
for b in builds:
    if b.is_wire or b.is_cross:
        continue
    for d in range(4):
        if not b.port_is_input(d):
            continue
        n = b.pin_net.get(d)
        if n is None:
            continue
        for (src, _sd) in n.drivers:
            if src is not b:
                edges[b].add(src)

# 4) Tarjan SCC
sys.setrecursionlimit(200000)
idx = {}; low = {}; stack = []; onstack = set(); sccs = []; counter = [0]


def strongconnect(root):
    work = [(root, iter(edges[root]))]
    idx[root] = low[root] = counter[0]; counter[0] += 1
    stack.append(root); onstack.add(root)
    while work:
        node, it = work[-1]
        adv = False
        for w in it:
            if w not in idx:
                idx[w] = low[w] = counter[0]; counter[0] += 1
                stack.append(w); onstack.add(w)
                work.append((w, iter(edges[w])))
                adv = True
                break
            elif w in onstack:
                low[node] = min(low[node], idx[w])
        if adv:
            continue
        work.pop()
        if work:
            low[work[-1][0]] = min(low[work[-1][0]], low[node])
        if low[node] == idx[node]:
            comp = []
            while True:
                w = stack.pop(); onstack.discard(w); comp.append(w)
                if w == node:
                    break
            sccs.append(comp)


for b in builds:
    if b not in edges or b in idx:
        continue
    if not (b.is_wire or b.is_cross):
        strongconnect(b)

cyclic = [c for c in sccs if len(c) > 1]
in_cycle = set()
for c in cyclic:
    in_cycle.update(c)
flagged = [b for b in builds if b.in_loop]
unexplained = [b for b in flagged if b not in in_cycle]
print(f"\n真实组合环(SCC>1): {len(cyclic)} 个；标红 {len(flagged)} 个中位于真实环上的 {len(flagged)-len(unexplained)} 个，未解释 {len(unexplained)} 个")
if unexplained:
    print("未解释的标红建筑:", ", ".join(b.tag() for b in unexplained[:20]))

for i, c in enumerate(sorted(cyclic, key=lambda x: -len(x))[:8], 1):
    ids = {id(b) for b in c}
    fl = [b for b in c if b.in_loop]
    regs = [b for b in c if b.is_seq]
    print(f"\n=== 环 #{i}: {len(c)} 个元件，标红 {len(fl)} 个，含寄存器 {len(regs)} 个")
    start = max(c, key=lambda b: len({id(x) for x in edges[b]} & ids))
    path = [start]; seen = {id(start)}; cur = start
    for _ in range(len(c) + 2):
        cand = [t for t in edges[cur] if id(t) in ids]
        if not cand:
            break
        nxt = next((t for t in cand if id(t) not in seen), cand[0])
        cur = nxt
        path.append(cur)
        if id(cur) in seen:
            break
        seen.add(id(cur))
    print("  环路: " + " <- ".join(b.tag() for b in path))

print("\n--- 标红建筑及其四邻 ---")
for b in sorted(flagged, key=lambda b: (b.y, b.x)):
    ns = []
    for d in range(4):
        nb = neighbor(b, d)
        if nb:
            ns.append(f"{['U','R','D','L'][d]}:{nb.defn}{'(W)' if nb.is_wire or nb.is_cross else '(G)'}")
    print(f"  {b.tag()} comp={b.comp} | " + " ".join(ns))

# 局部网表转储：python tools/loop_trace.py --dump x y [半径]
if len(sys.argv) > 3 and sys.argv[1] == "--dump":
    cx, cy = int(sys.argv[2]), int(sys.argv[3])
    r = int(sys.argv[4]) if len(sys.argv) > 4 else 5
    DIRN = ["UP", "RIGHT", "DOWN", "LEFT"]
    for b in sorted(builds, key=lambda b: (b.y, b.x)):
        if abs(b.x - cx) > r or abs(b.y - cy) > r:
            continue
        parts = []
        for d in range(4):
            nb = neighbor(b, d)
            if nb is None:
                continue
            n = b.pin_net.get(d)
            role = ""
            if b.is_wire or b.is_cross:
                role = "W"
            elif b.port_is_output(d):
                role = "O"
            elif b.port_is_input(d):
                role = "I"
            else:
                role = "-"
            drv = ""
            if n:
                drv = "net%d{drv:%s}" % (
                    n.nid, ",".join(f"{s.defn}@({s.x},{s.y})#{s.id}" for s, _sd in n.drivers) or "-")
            parts.append(f"{DIRN[d]}{role}->{nb.defn}@({nb.x},{nb.y}){'*' if nb.in_loop else ''} {drv}")
        print(f"\n{b.tag()}:\n    " + "\n    ".join(parts))

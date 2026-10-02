# Draws the architecture documents' diagrams (see build.py).
#   Flow  - boxes, groups and elbow arrows on a fixed canvas
#   Seq   - a sequence diagram (participants, messages, notes)
# Each emits inline SVG (styled by the page's CSS classes, so it follows the
# theme) and Mermaid text (for the Markdown file, which GitHub renders).
import html

W_TITLE, W_SUB, W_EDGE, W_MSG = 7.3, 6.1, 5.9, 6.2


def esc(s):
    return html.escape(str(s), quote=True)


def mm(s):
    """Text made safe inside a Mermaid label."""
    s = str(s).replace('<', '\u2039').replace('>', '\u203a')
    return s.replace('"', "'").replace('\n', '<br/>').replace(';', ',').replace('#', 'no. ')


class Flow:
    def __init__(self, name, title, w, h, direction='LR'):
        self.name, self.title, self.w, self.h, self.direction = name, title, w, h, direction
        self.groups, self.nodes, self.order, self.edges = [], {}, [], []

    def group(self, gid, x, y, w, h, label, tone='plain'):
        self.groups.append(dict(id=gid, x=x, y=y, w=w, h=h, label=label, tone=tone))

    def node(self, nid, x, y, label, subs=(), tone='core', w=None):
        subs = list(subs)
        need = max([len(label) * W_TITLE] + [len(s) * W_SUB for s in subs]) + 22
        if w is None:
            w = int((need + 9) // 10 * 10)
        if need > w:
            raise ValueError(f'{self.name}.{nid}: needs width {need:.0f}, has {w}')
        h = 10 + 18 + 14 * len(subs) + (9 if subs else 10)
        if x < 0 or y < 0 or x + w > self.w or y + h > self.h:
            raise ValueError(f'{self.name}.{nid}: outside the canvas ({x},{y},{w},{h})')
        for other in self.nodes.values():
            if x < other['x'] + other['w'] and other['x'] < x + w and y < other['y'] + other['h'] and other['y'] < y + h:
                raise ValueError(f'{self.name}.{nid}: overlaps {other["id"]}')
        self.nodes[nid] = dict(id=nid, x=x, y=y, w=w, h=h, label=label, subs=subs, tone=tone)
        self.order.append(nid)
        return self.nodes[nid]

    def edge(self, a, b, label='', sa=None, sb=None, dashed=False, both=False, pts=None, lpos=0.5, ldx=0, ldy=0):
        self.edges.append(dict(a=a, b=b, label=label, sa=sa, sb=sb, dashed=dashed, both=both, pts=pts,
                               lpos=lpos, ldx=ldx, ldy=ldy))

    # ---- geometry
    def _anchor(self, n, side):
        s = side[0]
        frac = float(side[1:]) if len(side) > 1 else 0.5
        if s == 'l':
            return (n['x'], n['y'] + n['h'] * frac)
        if s == 'r':
            return (n['x'] + n['w'], n['y'] + n['h'] * frac)
        if s == 't':
            return (n['x'] + n['w'] * frac, n['y'])
        return (n['x'] + n['w'] * frac, n['y'] + n['h'])

    def _auto(self, A, B):
        if A['x'] + A['w'] <= B['x']:
            return 'r', 'l'
        if B['x'] + B['w'] <= A['x']:
            return 'l', 'r'
        if A['y'] + A['h'] <= B['y']:
            return 'b', 't'
        return 't', 'b'

    def _route(self, e):
        A, B = self.nodes[e['a']], self.nodes[e['b']]
        sa, sb = e['sa'], e['sb']
        if sa is None or sb is None:
            auto = self._auto(A, B)
            sa, sb = sa or auto[0], sb or auto[1]
        p1, p2 = self._anchor(A, sa), self._anchor(B, sb)
        if e['pts']:
            return [p1] + [tuple(p) for p in e['pts']] + [p2]
        ha, hb = sa[0] in 'lr', sb[0] in 'lr'
        (x1, y1), (x2, y2) = p1, p2
        if ha and hb:
            if abs(y1 - y2) < 1:
                return [p1, p2]
            xm = (x1 + x2) / 2
            return [p1, (xm, y1), (xm, y2), p2]
        if not ha and not hb:
            if abs(x1 - x2) < 1:
                return [p1, p2]
            ym = (y1 + y2) / 2
            return [p1, (x1, ym), (x2, ym), p2]
        if ha:
            return [p1, (x2, y1), p2]
        return [p1, (x1, y2), p2]

    @staticmethod
    def _along(pts, frac):
        segs = [((pts[i], pts[i + 1]), abs(pts[i + 1][0] - pts[i][0]) + abs(pts[i + 1][1] - pts[i][1]))
                for i in range(len(pts) - 1)]
        total = sum(length for _, length in segs) or 1
        want = total * frac
        for (a, b), length in segs:
            if want <= length or (a, b) == segs[-1][0]:
                t = 0 if length == 0 else min(1, want / length)
                return (a[0] + (b[0] - a[0]) * t, a[1] + (b[1] - a[1]) * t)
            want -= length
        return pts[-1]

    # ---- output
    def svg(self):
        o = []
        o.append(f'<svg class="dg" viewBox="0 0 {self.w} {self.h}" role="img" aria-label="{esc(self.title)}" '
                 f'style="max-width:{self.w}px;min-width:{int(self.w * 0.74)}px">')
        mid = f'{self.name}-arrow'
        o.append(f'<defs><marker id="{mid}" viewBox="0 0 10 10" refX="9" refY="5" markerWidth="7.5" markerHeight="7.5" '
                 f'orient="auto-start-reverse"><path d="M0 0.8L9.4 5L0 9.2z" class="dg-head"/></marker></defs>')
        for g in self.groups:
            o.append(f'<rect class="dg-group t-{g["tone"]}" x="{g["x"]}" y="{g["y"]}" width="{g["w"]}" height="{g["h"]}" rx="12"/>')
            o.append(f'<text class="dg-gl" x="{g["x"] + 12}" y="{g["y"] + 18}">{esc(g["label"].upper())}</text>')
        labels = []
        for e in self.edges:
            pts = self._route(e)
            d = 'M' + ' L'.join(f'{x:.1f} {y:.1f}' for x, y in pts)
            cls = 'dg-edge dashed' if e['dashed'] else 'dg-edge'
            start = f' marker-start="url(#{mid})"' if e['both'] else ''
            o.append(f'<path class="{cls}" d="{d}" marker-end="url(#{mid})"{start}/>')
            if e['label']:
                x, y = self._along(pts, e['lpos'])
                labels.append((x + e['ldx'], y + e['ldy'], e['label']))
        for nid in self.order:
            n = self.nodes[nid]
            cx = n['x'] + n['w'] / 2
            o.append(f'<g class="dg-node t-{n["tone"]}"><rect x="{n["x"]}" y="{n["y"]}" width="{n["w"]}" height="{n["h"]}" rx="9"/>')
            o.append(f'<text class="dg-t" x="{cx:.1f}" y="{n["y"] + 24}" text-anchor="middle">{esc(n["label"])}</text>')
            for i, s in enumerate(n['subs']):
                o.append(f'<text class="dg-s" x="{cx:.1f}" y="{n["y"] + 41 + 14 * i}" text-anchor="middle">{esc(s)}</text>')
            o.append('</g>')
        for x, y, text in labels:
            lines = text.split('\n')
            wide = max(len(line) for line in lines) * W_EDGE + 10
            high = 14 * len(lines) + 4
            x = min(max(x, wide / 2 + 2), self.w - wide / 2 - 2)
            o.append(f'<rect class="dg-lbg" x="{x - wide / 2:.1f}" y="{y - high / 2:.1f}" width="{wide:.1f}" height="{high}" rx="4"/>')
            for i, line in enumerate(lines):
                o.append(f'<text class="dg-e" x="{x:.1f}" y="{y - high / 2 + 13 + 14 * i:.1f}" text-anchor="middle">{esc(line)}</text>')
        o.append('</svg>')
        return '\n'.join(o)

    def mermaid(self):
        o = [f'flowchart {self.direction}']
        placed = set()

        def decl(n, indent):
            text = mm('\n'.join([n['label']] + n['subs']))
            return f'{indent}{n["id"]}["{text}"]'

        for g in sorted(self.groups, key=lambda g: g['w'] * g['h']):
            inside = [n for n in self.nodes.values() if n['id'] not in placed
                      and g['x'] <= n['x'] + n['w'] / 2 <= g['x'] + g['w'] and g['y'] <= n['y'] + n['h'] / 2 <= g['y'] + g['h']]
            if not inside:
                continue
            o.append(f'  subgraph g_{g["id"]}["{mm(g["label"])}"]')
            for n in inside:
                o.append(decl(n, '    '))
                placed.add(n['id'])
            o.append('  end')
        for nid in self.order:
            if nid not in placed:
                o.append(decl(self.nodes[nid], '  '))
        for e in self.edges:
            arrow = '<-.->' if e['both'] and e['dashed'] else '<-->' if e['both'] else '-.->' if e['dashed'] else '-->'
            label = f'|"{mm(e["label"])}"|' if e['label'] else ''
            o.append(f'  {e["a"]} {arrow}{label} {e["b"]}')
        return '\n'.join(o)


class Seq:
    def __init__(self, name, title, parts, col=170, left=80, right=80):
        self.name, self.title, self.parts = name, title, parts
        self.col, self.left, self.right = col, left, right
        self.ix = {p[0]: i for i, p in enumerate(parts)}
        self.steps = []
        self.w = left + (len(parts) - 1) * col + right

    def x(self, pid):
        return self.left + self.ix[pid] * self.col

    def msg(self, a, b, text, kind='call'):
        self.steps.append(('msg', a, b, text, kind))

    def reply(self, a, b, text):
        self.steps.append(('msg', a, b, text, 'reply'))

    def self_(self, a, text):
        self.steps.append(('self', a, text))

    def note(self, a, b, text):
        self.steps.append(('note', a, b, text))

    def band(self, text):
        self.steps.append(('band', text))

    def svg(self):
        body, y = [], 64
        for st in self.steps:
            if st[0] == 'msg':
                _, a, b, text, kind = st
                lines = text.split('\n')
                xa, xb = self.x(a), self.x(b)
                wide = max(len(line) for line in lines) * W_MSG + 12
                cx = min(max((xa + xb) / 2, wide / 2 + 4), self.w - wide / 2 - 4)
                body.append(f'<rect class="dg-lbg" x="{cx - wide / 2:.1f}" y="{y - 1}" width="{wide:.1f}" height="{14 * len(lines) + 3}" rx="4"/>')
                for i, line in enumerate(lines):
                    body.append(f'<text class="dg-m" x="{cx:.1f}" y="{y + 11 + 14 * i}" text-anchor="middle">{esc(line)}</text>')
                ay = y + 14 * len(lines) + 9
                pad = 2 if xb > xa else -2
                cls = 'dg-edge dashed' if kind == 'reply' else 'dg-edge'
                body.append(f'<path class="{cls}" d="M{xa + pad} {ay} L{xb - pad} {ay}" marker-end="url(#{self.name}-arrow)"/>')
                y = ay + 18
            elif st[0] == 'self':
                _, a, text = st
                lines = text.split('\n')
                xa = self.x(a)
                wide = max(len(line) for line in lines) * W_MSG + 10
                tx = xa + 34
                if tx + wide > self.w - 4:
                    raise ValueError(f'{self.name}: self note "{lines[0]}" leaves the canvas ({tx + wide:.0f} > {self.w})')
                high = max(22, 14 * len(lines) + 6)
                body.append(f'<path class="dg-edge" d="M{xa + 2} {y + 4} H{xa + 24} V{y + high - 2} H{xa + 4}" marker-end="url(#{self.name}-arrow)"/>')
                body.append(f'<rect class="dg-lbg" x="{tx - 4}" y="{y}" width="{wide:.1f}" height="{14 * len(lines) + 4}" rx="4"/>')
                for i, line in enumerate(lines):
                    body.append(f'<text class="dg-m" x="{tx}" y="{y + 12 + 14 * i}">{esc(line)}</text>')
                y += high + 14
            elif st[0] == 'note':
                _, a, b, text = st
                lines = text.split('\n')
                x1, x2 = sorted((self.x(a), self.x(b)))
                wide = max(max(len(line) for line in lines) * W_MSG + 24, x2 - x1 + 60)
                cx = min(max((x1 + x2) / 2, wide / 2 + 4), self.w - wide / 2 - 4)
                high = 14 * len(lines) + 12
                body.append(f'<rect class="dg-note" x="{cx - wide / 2:.1f}" y="{y}" width="{wide:.1f}" height="{high}" rx="6"/>')
                for i, line in enumerate(lines):
                    body.append(f'<text class="dg-m" x="{cx:.1f}" y="{y + 16 + 14 * i}" text-anchor="middle">{esc(line)}</text>')
                y += high + 14
            else:
                _, text = st
                body.append(f'<rect class="dg-band" x="8" y="{y}" width="{self.w - 16}" height="22" rx="5"/>')
                body.append(f'<text class="dg-gl" x="18" y="{y + 15}">{esc(text.upper())}</text>')
                y += 36
        h = y + 8
        o = [f'<svg class="dg" viewBox="0 0 {self.w} {h}" role="img" aria-label="{esc(self.title)}" '
             f'style="max-width:{self.w}px;min-width:{int(self.w * 0.74)}px">']
        o.append(f'<defs><marker id="{self.name}-arrow" viewBox="0 0 10 10" refX="9" refY="5" markerWidth="7.5" markerHeight="7.5" '
                 f'orient="auto-start-reverse"><path d="M0 0.8L9.4 5L0 9.2z" class="dg-head"/></marker></defs>')
        for pid, label, tone in self.parts:
            x = self.x(pid)
            o.append(f'<path class="dg-life" d="M{x} 46 V{h - 6}"/>')
        o.extend(body)
        for pid, label, tone in self.parts:
            x = self.x(pid)
            wide = max(len(label) * W_TITLE + 22, 84)
            if x - wide / 2 < 0 or x + wide / 2 > self.w:
                raise ValueError(f'{self.name}: participant "{label}" leaves the canvas')
            o.append(f'<g class="dg-node t-{tone}"><rect x="{x - wide / 2:.1f}" y="12" width="{wide:.1f}" height="34" rx="9"/>'
                     f'<text class="dg-t" x="{x}" y="34" text-anchor="middle">{esc(label)}</text></g>')
        o.append('</svg>')
        return '\n'.join(o)

    def mermaid(self):
        o = ['sequenceDiagram']
        for pid, label, _ in self.parts:
            o.append(f'  participant {pid} as {mm(label)}')
        first, last = self.parts[0][0], self.parts[-1][0]
        for st in self.steps:
            if st[0] == 'msg':
                _, a, b, text, kind = st
                arrow = '-->>' if kind == 'reply' else '->>'
                o.append(f'  {a}{arrow}{b}: {mm(text)}')
            elif st[0] == 'self':
                o.append(f'  {st[1]}->>{st[1]}: {mm(st[2])}')
            elif st[0] == 'note':
                _, a, b, text = st
                over = a if a == b else f'{a},{b}'
                o.append(f'  Note over {over}: {mm(text)}')
            else:
                o.append(f'  Note over {first},{last}: {mm(st[1].upper())}')
        return '\n'.join(o)

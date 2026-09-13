#!/usr/bin/env python3
"""Bake loopOut() expressions into keyframes the mobile Lottie players can play.

usage: python3 tools/lottie/bake_loop_expressions.py in.json out.json [--until FRAME]

After Effects files often animate one short stretch of keyframes and repeat it
with an expression; bodymovin writes it on the property as
"var $bm_rt;\\n$bm_rt = loopOut('pingpong');". lottie-web (the LottieFiles
preview, any browser) runs it. lottie-android and Flutter's lottie (3.5.1, what
the app ships) run no expressions at all, so on a phone every such property
stops at its last keyframe and the picture freezes the moment its keyframes run
out -- King froze after about a second: 37 looping properties, every one of
them out of keyframes by frame 32 of 187.

What it matches: a property whose expression is exactly that bodymovin wrapper
around loopOut(), loopOut('cycle') or loopOut('pingpong') (either quote, the
type in any case, as lottie-web lowercases it). Anything else -- 'offset',
'continue', a duration argument, loopIn, any other code -- is left in place and
listed, and so is a loop lottie-web itself cannot run (fewer than two
keyframes, or a cycle of zero length).

What it writes. lottie-web's loopOut (expressions plugin, addPropertyDecorator)
returns the plain keyframed value up to the last keyframe t_last; after it, it
reads the keyframes again at u = t_first + (t - t_first) % D, with
D = t_last - t_first, mirrored to u = t_last - ((t - t_first) % D) on the odd
iterations of a pingpong. Rather than sample that, the loop is written out as
copies of the original segments shifted by whole periods, so every copy keeps
the source easing to the digit and the phone's own interpolation does the rest:
  - a forward copy is the keyframe as it was, moved by c * D;
  - a mirrored copy runs from the segment's end value back to its start value
    with o' = 1 - i and i' = 1 - o per component (the easing curve turned half
    a revolution about its centre, the exact time reversal) and the spatial
    tangents swapped, to' = ti and ti' = to (the same path walked backwards);
    a hold segment stays a hold of the value it held; a legacy "n" easing name
    is dropped from it, since lottie-web caches curves by that name;
  - where a copy starts on a value other than the one the segment before it
    ends on (a cycle whose last value is not its first, or a mirrored hold), a
    zero-length hold keyframe at the join carries the ending value, so the
    previous segment still eases all the way into it and the jump lands on the
    join, exactly as lottie-web's modulo puts it there.
A segment's end value is what lottie-web reads, `nextKeyData.s || keyData.e`.
Every emitted keyframe carries "s", and where the source uses legacy "e" values
each is rewritten to that same end value, because lottie-android and Flutter's
lottie read "e" first. Keyframes before frame 0 are kept as they are. Copies
are written until the last one ends at or past until + D (until defaults to
the composition's op; a precomp is given the frame its layers reach,
(until - st) / sr, or its time remap's largest value).

The one thing keyframes cannot say: at exactly t_last of a cycle that jumps,
lottie-web still answers the last value (its `currentFrame <= lastKeyFrame`
test), while at every later join it answers the first; the keyframes answer
the first at all of them. A mirrored hold differs the same way at its opening
instant. Both are single instants; a frame off them matches.

How it is verified (King, 13 Sep 2026: 9 cycle + 28 pingpong baked, 0 left).
In headless Chrome, lottie-web with expressions on steps the original and the
baked file together and reads every keyframed property at 1,880 frames, 0 to
187.9 in tenths: they agree to 1.1e-14 everywhere except those cycle-join
instants -- frames 2, 17 and 32 here, where opacity reads 0% against 3% and a
trim path 100/100 against 0/0, which draws nothing either way. Rendered by
lottie-web at 53 frames (0..187, 30-40 and 180-187 among them, some of them
fractional) the two files are pixel-identical. The same probe on a copy of
King rewritten with asymmetric per-component easing, holds, legacy "e" values
and curved spatial tangents agrees just as closely, and it does catch a
mirror left unflipped. Flutter's lottie 3.5.1 plays the baked file moving
through the whole composition with no warning, where the original warns
"Lottie doesn't support expressions." and stands still after its keyframes.
"""
import argparse
import copy
import json
import re
import sys
from decimal import Decimal

LOOP_OUT = re.compile(
    r"""\s*var\s+\$bm_rt\s*;\s*\$bm_rt\s*=\s*loopOut\(\s*(?:(['"])(cycle|pingpong)\1\s*)?\)\s*;?\s*""",
    re.IGNORECASE)


def dec(x):
    """A JSON number as the decimal it was written as (4.937, not 4.93699...)."""
    return Decimal(repr(x)) if isinstance(x, float) else Decimal(x)


def num(d):
    """A decimal back to the JSON number nearest to it."""
    return int(d) if d == d.to_integral_value() else float(d)


def js_truthy(v):
    if v is None or v is False:
        return False
    if isinstance(v, (int, float)):
        return v != 0
    return v != ''


def flip_easing(e):
    """(x, y) -> (1 - x, 1 - y) per component, in decimal arithmetic."""
    out = {}
    for key, v in e.items():
        if key in ('x', 'y'):
            out[key] = [num(1 - dec(c)) for c in v] if isinstance(v, list) else num(1 - dec(v))
        else:
            out[key] = copy.deepcopy(v)
    return out


def is_keyframed(prop):
    k = prop.get('k')
    return isinstance(k, list) and len(k) > 0 and all(isinstance(kf, dict) and 't' in kf for kf in k)


class Segment:
    def __init__(self, key, nxt):
        self.key = key
        self.t0, self.t1 = dec(key['t']), dec(nxt['t'])
        self.start = key.get('s')
        self.end = nxt['s'] if js_truthy(nxt.get('s')) else key.get('e')
        self.hold = key.get('h') == 1


def forward(seg, t, use_e):
    """Segment `seg` as written, moved to start at t. Returns (keyframe, end value, is hold)."""
    kf = {}
    for key, v in seg.key.items():
        kf[key] = num(t) if key == 't' else copy.deepcopy(v)
    end = seg.end
    if use_e:
        kf['e'] = copy.deepcopy(seg.start if seg.hold else end)
    return kf, end, seg.hold


def mirrored(seg, t, use_e):
    """Segment `seg` played backwards, starting at t. Returns (keyframe, end value, is hold)."""
    start, end = (seg.start, seg.start) if seg.hold else (seg.end, seg.start)
    swap = {'o': 'i', 'i': 'o', 'to': 'ti', 'ti': 'to'}
    kf = {}
    for key, v in seg.key.items():
        if key == 't':
            kf[key] = num(t)
        elif key == 's':
            kf[key] = copy.deepcopy(start)
        elif key == 'e':
            continue
        elif key in ('o', 'i'):
            kf[key] = flip_easing(seg.key[swap[key]])
        elif key in ('to', 'ti'):
            kf[key] = copy.deepcopy(seg.key[swap[key]])
        elif key == 'n':
            continue
        else:
            kf[key] = copy.deepcopy(v)
    if use_e:
        kf['e'] = copy.deepcopy(start if seg.hold else end)
    return kf, end, seg.hold


def bake(prop, mode, until):
    """Replace prop's keyframes by the loop written out to until + one period.

    Returns a short description, or raises ValueError when the loop cannot be baked.
    """
    kfs = prop['k']
    if len(kfs) < 2:
        raise ValueError('fewer than two keyframes')
    segs = [Segment(a, b) for a, b in zip(kfs, kfs[1:])]
    t_first, t_last = segs[0].t0, segs[-1].t1
    period = t_last - t_first
    if period <= 0:
        raise ValueError('a loop of zero length')
    for s in segs:
        if s.start is None or s.end is None:
            raise ValueError('a keyframe without a start or end value')
        if not s.hold and s.t1 > s.t0 and not ('o' in s.key and 'i' in s.key):
            raise ValueError('an eased segment without o/i')
    use_e = any('e' in kf for kf in kfs)
    limit = dec(until) + period

    out = []
    pending = {'end': None, 'hold': True}  # what the last emitted segment ends on
    joins = 0

    def emit(made, t):
        nonlocal joins
        kf, end, hold = made
        if not pending['hold'] and pending['end'] != kf['s']:
            join = {'t': num(t), 's': copy.deepcopy(pending['end']), 'h': 1}
            if use_e:
                join['e'] = copy.deepcopy(pending['end'])
            out.append(join)
            joins += 1
        out.append(kf)
        pending['end'], pending['hold'] = end, hold

    # The original segments, before frame 0 included (only "e" is normalised).
    for s in segs:
        emit(forward(s, s.t0, use_e), s.t0)
    copies, c = 0, 1
    while t_last + (c - 1) * period < limit:
        base = t_last + (c - 1) * period
        if mode == 'pingpong' and c % 2 == 1:
            for s in reversed(segs):
                t = base + (t_last - s.t1)
                emit(mirrored(s, t, use_e), t)
        else:
            for s in segs:
                t = s.t0 + c * period
                emit(forward(s, t, use_e), t)
        copies, c = copies + 1, c + 1
    end_t = t_last + copies * period
    final = {'t': num(end_t), 's': copy.deepcopy(pending['end'])}
    out.append(final)

    prop['k'] = out
    del prop['x']
    return (f'{mode}, period {num(period)}, {len(kfs)} -> {len(out)} keyframes '
            f'to frame {num(end_t)}' + (f', {joins} jump join(s)' if joins else ''))


def label(node, key):
    name = node.get('nm') if isinstance(node, dict) else None
    return f'{key} "{name}"' if isinstance(name, str) else str(key)


def walk(node, path, until, report, parent_key=None, grandparent_key=None):
    if isinstance(node, dict):
        if isinstance(node.get('x'), str) and 'k' in node:
            text = node['x']
            m = LOOP_OUT.fullmatch(text)
            where = '.'.join(path)
            if m is None:
                report['left'].append((where, text))
            elif parent_key == 'd' and grandparent_key == 't':
                report['left'].append((where, text + '   [a text document; not baked]'))
            elif not is_keyframed(node):
                del node['x']  # lottie-web's loopOut returns the static value unchanged
                report['baked'].append((where, 'static value, expression removed'))
            else:
                mode = (m.group(2) or 'cycle').lower()
                try:
                    report['baked'].append((where, bake(node, mode, until)))
                    report[mode] += 1
                except ValueError as err:
                    report['left'].append((where, text + f'   [{err}]'))
        for key, v in node.items():
            if isinstance(v, (dict, list)):
                walk(v, path + [label(v, key)], until, report, key, parent_key)
    elif isinstance(node, list):
        for i, v in enumerate(node):
            if isinstance(v, (dict, list)):
                walk(v, path[:-1] + [f'{path[-1]}[{label(v, i)}]'], until, report, parent_key, grandparent_key)


def time_remap_reach(tm, fr):
    values = []
    if is_keyframed(tm):
        for kf in tm['k']:
            for key in ('s', 'e'):
                v = kf.get(key)
                values.extend(v if isinstance(v, list) else [v] if v is not None else [])
    else:
        k = tm.get('k')
        values.extend(k if isinstance(k, list) else [k])
    return max(values) * fr if values else 0


def main():
    ap = argparse.ArgumentParser(description=__doc__.split('\n\n')[0])
    ap.add_argument('src')
    ap.add_argument('dst')
    ap.add_argument('--until', type=float, help='last frame that must loop (default: the composition op)')
    args = ap.parse_args()

    doc = json.load(open(args.src))
    fr = doc.get('fr', 30)
    until = args.until if args.until is not None else doc['op']
    assets = {a['id']: a for a in doc.get('assets', []) if 'layers' in a}
    report = {'baked': [], 'left': [], 'cycle': 0, 'pingpong': 0}

    # Every composition is baked once, to the furthest frame any use of it reaches.
    reach = {None: until}
    queue = [None]
    while queue:
        comp = queue.pop()
        layers = doc['layers'] if comp is None else assets[comp]['layers']
        for layer in layers:
            ref = layer.get('refId')
            if layer.get('ty') != 0 or ref not in assets:
                continue
            if 'tm' in layer:
                local = time_remap_reach(layer['tm'], fr)
            else:
                local = (reach[comp] - layer.get('st', 0)) / (abs(layer.get('sr', 1)) or 1)
            if local > reach.get(ref, float('-inf')):
                reach[ref] = local
                queue.append(ref)
    walk(doc['layers'], ['layers'], reach[None], report)
    for ref, a in assets.items():
        if ref in reach:
            walk(a['layers'], [f'assets[{ref}].layers'], reach[ref], report)
        else:
            walk(a['layers'], [f'assets[{ref}].layers'], until, report)

    json.dump(doc, open(args.dst, 'w'), separators=(',', ':'))
    for where, what in report['baked']:
        print(f'baked  {where}: {what}')
    for where, text in report['left']:
        print(f'LEFT   {where}: {text!r}')
    print(f"baked {len(report['baked'])} (cycle {report['cycle']}, pingpong {report['pingpong']}); "
          f"expressions left: {len(report['left'])}; until frame {until}")


if __name__ == '__main__':
    sys.exit(main())

# Bake a Lottie layer's 3D orientation ("or") into 2D transforms the mobile
# players (lottie-android, Flutter's lottie) can play.
#
# lottie-web draws a flat comp orthographically: a layer's 2D matrix is the
# x/y part of  T(-a) · S · Rz(-or.z) · Ry(or.y) · Rx(or.x) · T(p)  (row
# vectors), with "or" keyframes interpolated by quaternion slerp. The mobile
# players ignore "or" entirely. Sampling lottie-web's own maths on every frame
# and splitting the 2x2 part as R(phi) · diag(sx, sy) · R(theta) gives a 2D-only
# equivalent: a null parent carries position, phi and the scale, the layer
# itself carries theta and its anchor.
import json, math, sys

src, dst = sys.argv[1], sys.argv[2]
j = json.load(open(src))
D = math.pi / 180

def quat(v):  # lottie-web createQuaternion
    h, a, b = v[0] * D, v[1] * D, v[2] * D
    c1, c2, c3 = math.cos(h / 2), math.cos(a / 2), math.cos(b / 2)
    s1, s2, s3 = math.sin(h / 2), math.sin(a / 2), math.sin(b / 2)
    return [s1 * s2 * c3 + c1 * c2 * s3, s1 * c2 * c3 + c1 * s2 * s3,
            c1 * s2 * c3 - s1 * c2 * s3, c1 * c2 * c3 - s1 * s2 * s3]

def slerp(a, b, t):  # lottie-web slerp
    cosom = sum(x * y for x, y in zip(a, b))
    if cosom < 0:
        cosom, b = -cosom, [-x for x in b]
    if 1 - cosom > 1e-6:
        om = math.acos(cosom); so = math.sin(om)
        k0, k1 = math.sin((1 - t) * om) / so, math.sin(t * om) / so
    else:
        k0, k1 = 1 - t, t
    return [k0 * x + k1 * y for x, y in zip(a, b)]

def euler(q):  # lottie-web quaternionToEuler
    qx, qy, qz, qw = q
    heading = math.atan2(2 * qy * qw - 2 * qx * qz, 1 - 2 * qy * qy - 2 * qz * qz)
    attitude = math.asin(max(-1, min(1, 2 * qx * qy + 2 * qz * qw)))
    bank = math.atan2(2 * qx * qw - 2 * qy * qz, 1 - 2 * qx * qx - 2 * qz * qz)
    return [heading / D, attitude / D, bank / D]

def orientation(prop, f):  # lottie-web interpolateValue with this.sh set
    if prop.get('a') != 1:
        return prop['k']
    kfs = prop['k']
    if f <= kfs[0]['t']:
        return kfs[0]['s']
    for k0, k1 in zip(kfs, kfs[1:]):
        if k0['t'] <= f < k1['t']:
            start, end = k0['s'], k1.get('s') or k0.get('e')
            if k0.get('h') == 1 or f <= k0['t']:
                return start
            return euler(slerp(quat(start), quat(end), (f - k0['t']) / (k1['t'] - k0['t'])))
    return kfs[-1]['s']

def mul(A, B):
    return [[sum(A[r][k] * B[k][c] for k in range(3)) for c in range(3)] for r in range(3)]

def rx(t): c, s = math.cos(t), math.sin(t); return [[1, 0, 0], [0, c, -s], [0, s, c]]
def ry(t): c, s = math.cos(t), math.sin(t); return [[c, 0, s], [0, 1, 0], [-s, 0, c]]
def rz(t): c, s = math.cos(t), math.sin(t); return [[c, -s, 0], [s, c, 0], [0, 0, 1]]

def static(prop, default):
    if prop is None:
        return default
    assert prop.get('a', 0) != 1, 'only orientation may be keyframed here'
    return prop['k'] if isinstance(prop['k'], list) else [prop['k']]

def unwrap(seq):
    out = [seq[0]]
    for x in seq[1:]:
        while x - out[-1] > math.pi: x -= 2 * math.pi
        while x - out[-1] < -math.pi: x += 2 * math.pi
        out.append(x)
    return out

def linear_kfs(frames, values):
    dims = len(values[0])
    kfs = []
    for i, (f, v) in enumerate(zip(frames, values)):
        kf = {'t': f, 's': [round(x, 4) for x in v]}
        if i < len(frames) - 1:
            kf['i'] = {'x': [1] * dims, 'y': [1] * dims}
            kf['o'] = {'x': [0] * dims, 'y': [0] * dims}
        kfs.append(kf)
    return kfs

layers = j['layers']
next_ind = max(l['ind'] for l in layers) + 1
nulls, worst, min_r = [], 0.0, float('inf')
for layer in layers:
    ks = layer['ks']
    if 'or' not in ks or ks['or'].get('a') != 1:
        continue
    for k in ('rx', 'ry', 'rz'):
        assert static(ks.get(k), [0])[0] == 0, f'{layer["nm"]}: {k} is not zero'
    a = static(ks.get('a'), [0, 0, 0]); p = static(ks.get('p'), [0, 0, 0]); s = static(ks.get('s'), [100, 100, 100])
    ip, op = int(layer['ip']), int(layer['op'])
    frames = list(range(ip, op))
    A = []
    for f in frames:
        o = orientation(ks['or'], f)
        S = [[s[0] / 100, 0, 0], [0, s[1] / 100, 0], [0, 0, (s[2] if len(s) > 2 else 100) / 100]]
        M = mul(mul(mul(S, rz(-o[2] * D)), ry(o[1] * D)), rx(o[0] * D))
        A.append((M[0][0], M[1][0], M[0][1], M[1][1]))  # column form [[a, b], [c, d]]
    a1s, a2s, sx, sy = [], [], [], []
    for (ma, mb, mc, md) in A:
        E, F, G, H = (ma + md) / 2, (ma - md) / 2, (mc + mb) / 2, (mc - mb) / 2
        Q, R = math.hypot(E, H), math.hypot(F, G)
        min_r = min(min_r, R)
        sx.append((Q + R) * 100); sy.append((Q - R) * 100)
        a1s.append(math.atan2(G, F)); a2s.append(math.atan2(H, E))
    a1s, a2s = unwrap(a1s), unwrap(a2s)
    theta = [(y - x) / 2 / D for x, y in zip(a1s, a2s)]
    phi = [(y + x) / 2 / D for x, y in zip(a1s, a2s)]

    # Check: the mobile chain T(p) R(phi) S R(theta) T(-a) must put every corner
    # of the layer exactly where lottie-web's 3D matrix does, on every frame.
    w = next((x['w'], x['h']) for x in j['assets'] if x['id'] == layer.get('refId')) if layer.get('refId') else (100, 100)
    for i, f in enumerate(frames):
        ma, mb, mc, md = A[i]
        cp, sp = math.cos(phi[i] * D), math.sin(phi[i] * D)
        ct, st = math.cos(theta[i] * D), math.sin(theta[i] * D)
        for vx, vy in ((0, 0), (w[0], 0), (0, w[1]), (w[0], w[1])):
            x, y = vx - a[0], vy - a[1]
            web = (x * ma + y * mb + p[0], x * mc + y * md + p[1])
            x, y = ct * x - st * y, st * x + ct * y
            x, y = x * sx[i] / 100, y * sy[i] / 100
            mob = (cp * x - sp * y + p[0], sp * x + cp * y + p[1])
            worst = max(worst, abs(web[0] - mob[0]), abs(web[1] - mob[1]))

    null = {'ddd': 0, 'ind': next_ind, 'ty': 3, 'nm': layer['nm'] + ' orientation', 'sr': 1,
            'ks': {'o': {'a': 0, 'k': 0},
                   'r': {'a': 1, 'k': linear_kfs(frames, [[v] for v in phi])},
                   'p': {'a': 0, 'k': [p[0], p[1], 0]},
                   'a': {'a': 0, 'k': [0, 0, 0]},
                   's': {'a': 1, 'k': linear_kfs(frames, [[x, y, 100] for x, y in zip(sx, sy)])}},
            'ao': 0, 'ip': layer['ip'], 'op': layer['op'], 'st': layer.get('st', 0), 'bm': 0}
    if 'parent' in layer:
        null['parent'] = layer['parent']
    nulls.append(null)
    layer['parent'] = next_ind
    next_ind += 1
    for k in ('or', 'rx', 'ry', 'rz'):
        ks.pop(k, None)
    ks['r'] = {'a': 1, 'k': linear_kfs(frames, [[v] for v in theta])}
    ks['p'] = {'a': 0, 'k': [0, 0, 0]}
    ks['s'] = {'a': 0, 'k': [100, 100, 100]}
    print(f"{layer['nm']}: {len(frames)} frames, phi {min(phi):.1f}..{max(phi):.1f}, theta {min(theta):.1f}..{max(theta):.1f}, "
          f"sx {min(sx):.1f}..{max(sx):.1f}, sy {min(sy):.1f}..{max(sy):.1f}")

layers.extend(nulls)
json.dump(j, open(dst, 'w'), separators=(',', ':'))
print(f'layers converted: {len(nulls)}; worst corner error {worst:.2e}px; smallest anisotropy {min_r:.3f}')
print('left in file: or =', json.dumps(j).count('"or"'), ' bytes', len(open(dst).read()))

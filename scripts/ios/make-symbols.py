"""Draws the Padel ID glyphs as custom symbol templates: a padel racket with the
six holes of the app icon and a padel court seen from above.

    python3 scripts/ios/make-symbols.py ios/PadelID/Resources/Assets.xcassets
"""
import math, os, sys, json
OUT = sys.argv[1]
X0 = 1400.0                           # left edge of the glyph box

def rot(p, a, c):
    x, y = p[0] - c[0], p[1] - c[1]
    return (c[0] + x * math.cos(a) - y * math.sin(a), c[1] + x * math.sin(a) + y * math.cos(a))

class Pen:
    def __init__(s, scale, angle, centre, origin):
        s.k, s.a, s.c, s.o, s.d, s.xs = scale, angle, centre, origin, [], []
    def pt(s, x, y):
        x, y = rot((x, y), s.a, s.c)
        x, y = s.o[0] + (x - s.c[0]) * s.k, s.o[1] + (y - s.c[1]) * s.k
        s.xs.append(x)
        return (x, y)
    def rrect(s, x, y, w, h, r, cw=True):
        r = min(r, w / 2, h / 2)
        if r <= 0:                                   # a plain rectangle: no zero-radius arcs
            corners = [(x, y), (x + w, y), (x + w, y + h), (x, y + h)]
            if not cw: corners = [corners[0]] + corners[:0:-1]
            q = [s.pt(*c) for c in corners]
            s.d.append("M" + "L".join(f"{a:.2f} {b:.2f}" for a, b in q) + "Z"); return
        pts = [(x + r, y), (x + w - r, y), (x + w, y + r), (x + w, y + h - r), (x + w - r, y + h), (x + r, y + h), (x, y + h - r), (x, y + r)]
        rr = r * s.k
        if cw:
            m = s.pt(*pts[0]); d = f"M{m[0]:.2f} {m[1]:.2f}"
            for i in range(1, 8, 2):
                l = s.pt(*pts[i]); n = s.pt(*pts[(i + 1) % 8])
                d += f"L{l[0]:.2f} {l[1]:.2f}A{rr:.2f} {rr:.2f} 0 0 1 {n[0]:.2f} {n[1]:.2f}"
        else:
            order = [0, 7, 6, 5, 4, 3, 2, 1]
            m = s.pt(*pts[0]); d = f"M{m[0]:.2f} {m[1]:.2f}"
            for i in range(1, 8, 2):
                n = s.pt(*pts[order[i]]); l = s.pt(*pts[order[(i + 1) % 8]])
                d += f"A{rr:.2f} {rr:.2f} 0 0 0 {n[0]:.2f} {n[1]:.2f}L{l[0]:.2f} {l[1]:.2f}"
        s.d.append(d + "Z")
    def circle(s, cx, cy, r, cw=True):
        s.rrect(cx - r, cy - r, 2 * r, 2 * r, r, cw)

SIZES = {"S": (696.0, 625.541, 0.783), "M": (1126.0, 1055.54, 1.0), "L": (1556.0, 1485.54, 1.29)}

def racket(k, cy):
    # Upright in a 100×100 box, then turned 45° with the head to the upper right.
    p = Pen(1.2 * k, math.radians(45), (50, 50), (X0 + 66 * k, cy))
    p.rrect(19, 0, 62, 63, 27)                       # the solid head of a padel racket
    p.rrect(42, 56, 16, 44, 7)                       # handle
    for cy_ in (22, 39):
        for cx in (34.5, 50, 65.5):
            p.circle(cx, cy_, 5.2, cw=False)         # the six holes of the app icon
    return p

def court(k, cy):
    p = Pen(k, 0, (62, 43), (X0 + 62 * k, cy))
    t = 9.5
    p.rrect(0, 0, 124, 86, 15)                       # walls
    p.rrect(t, t, 124 - 2 * t, 86 - 2 * t, 6.5, cw=False)
    p.rrect(62 - 4.5, 2, 9, 82, 0)                   # net
    for x in (33, 91):
        p.rrect(x - 3.25, 2, 6.5, 82, 0)             # service lines
    p.rrect(33, 43 - 3.25, 58, 6.5, 0)               # centre line between them
    return p

def svg(maker):
    guides, symbols = "", ""
    for size, (base, cap, k) in SIZES.items():
        pen = maker(k, (base + cap) / 2)
        paths = pen.d
        left, right = min(pen.xs) - 7 * k, max(pen.xs) + 7 * k
        guides += f'''  <line id="Baseline-{size}" style="fill:none;stroke:#27AAE1;opacity:1;stroke-width:0.5;" x1="263" x2="3036" y1="{base}" y2="{base}"/>
  <line id="Capline-{size}" style="fill:none;stroke:#27AAE1;opacity:1;stroke-width:0.5;" x1="263" x2="3036" y1="{cap}" y2="{cap}"/>
  <line id="left-margin-Regular-{size}" style="fill:none;stroke:#00AEEF;stroke-width:0.5;opacity:1.0;" x1="{left:.2f}" x2="{left:.2f}" y1="{cap - 25:.2f}" y2="{base + 24:.2f}"/>
  <line id="right-margin-Regular-{size}" style="fill:none;stroke:#00AEEF;stroke-width:0.5;opacity:1.0;" x1="{right:.2f}" x2="{right:.2f}" y1="{cap - 25:.2f}" y2="{base + 24:.2f}"/>
'''
        symbols += f'''  <g id="Regular-{size}">
   <path d="{" ".join(paths)}"/>
  </g>
'''
    return f'''<?xml version="1.0" encoding="UTF-8"?>
<svg version="1.1" xmlns="http://www.w3.org/2000/svg" width="3300" height="2200">
 <g id="Notes">
  <rect height="2200" id="artboard" style="fill:white;opacity:1" width="3300" x="0" y="0"/>
  <text id="template-version" style="stroke:none;fill:black;font-family:sans-serif;font-size:13;text-anchor:end;" transform="matrix(1 0 0 1 3036 1933)">Template v.3.0</text>
 </g>
 <g id="Guides">
{guides} </g>
 <g id="Symbols">
{symbols} </g>
</svg>
'''
for name, maker in (("padel.racket", racket), ("padel.court", court)):
    d = os.path.join(OUT, name + ".symbolset"); os.makedirs(d, exist_ok=True)
    open(os.path.join(d, name + ".svg"), "w").write(svg(maker))
    json.dump({"info": {"author": "xcode", "version": 1}, "symbols": [{"filename": name + ".svg", "idiom": "universal"}]},
              open(os.path.join(d, "Contents.json"), "w"), indent=2)
    print(name)

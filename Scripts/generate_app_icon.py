#!/usr/bin/env python3
"""Generate an opaque 1024x1024 PNG app icon using only the Python stdlib."""
import struct
import zlib
from pathlib import Path

W = H = 1024
BG = (20, 104, 200)
PANEL = (35, 130, 230)
WHITE = (255, 255, 255)
BIND = (214, 233, 252)
GREEN = (42, 190, 95)

pixels = [bytearray(BG * W) for _ in range(H)]

def inside_round_rect(x, y, x0, y0, x1, y1, r):
    if x0 + r <= x <= x1 - r or y0 + r <= y <= y1 - r:
        return x0 <= x <= x1 and y0 <= y <= y1
    cx = x0 + r if x < x0 + r else x1 - r
    cy = y0 + r if y < y0 + r else y1 - r
    return (x-cx)*(x-cx) + (y-cy)*(y-cy) <= r*r

def rect(x0,y0,x1,y1,color,r=0):
    for y in range(max(0,y0), min(H,y1+1)):
        row = pixels[y]
        for x in range(max(0,x0), min(W,x1+1)):
            if r == 0 or inside_round_rect(x,y,x0,y0,x1,y1,r):
                i=x*3; row[i:i+3]=bytes(color)

def circle(cx,cy,r,color):
    rr=r*r
    for y in range(max(0,cy-r), min(H,cy+r+1)):
        dy=(y-cy)*(y-cy); row=pixels[y]
        for x in range(max(0,cx-r), min(W,cx+r+1)):
            if (x-cx)*(x-cx)+dy <= rr:
                i=x*3; row[i:i+3]=bytes(color)

def thick_line(x0,y0,x1,y1,width,color):
    # draw circles along a line; sufficient for the checkmark
    steps=max(abs(x1-x0),abs(y1-y0))
    for s in range(steps+1):
        t=s/steps if steps else 0
        circle(round(x0+(x1-x0)*t), round(y0+(y1-y0)*t), width//2, color)

rect(145,145,879,879,PANEL,190)
rect(285,265,760,760,WHITE,72)
rect(245,300,335,725,BIND,34)
circle(525,450,103,BG)
rect(365,565,685,695,BG,64)
circle(728,715,82,GREEN)
thick_line(688,714,720,746,26,WHITE)
thick_line(720,746,773,682,26,WHITE)

raw = b''.join(b'\x00' + bytes(row) for row in pixels)
def chunk(kind, data):
    return struct.pack('>I', len(data)) + kind + data + struct.pack('>I', zlib.crc32(kind + data) & 0xffffffff)
png = b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', struct.pack('>IIBBBBB', W,H,8,2,0,0,0)) + chunk(b'IDAT', zlib.compress(raw, 9)) + chunk(b'IEND', b'')
out = Path(__file__).resolve().parents[1] / 'ContactCleaner' / 'Assets.xcassets' / 'AppIcon.appiconset' / 'AppIcon-1024.png'
out.parent.mkdir(parents=True, exist_ok=True)
out.write_bytes(png)
print(out)

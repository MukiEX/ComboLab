import json, sys
from PIL import Image, ImageDraw, ImageFont
bg, calls_path, out = sys.argv[1], sys.argv[2], sys.argv[3]
img = Image.open(bg).convert("RGBA").resize((1920, 1080))
layer = Image.new("RGBA", img.size, (0, 0, 0, 0))
d = ImageDraw.Draw(layer)
def col(c):
    c = int(c); return (c & 255, (c >> 8) & 255, (c >> 16) & 255, (c >> 24) & 255)
fonts = {}
def font(px):
    px = int(px)
    if px not in fonts:
        try: fonts[px] = ImageFont.truetype("/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf", int(px * 0.8))
        except Exception: fonts[px] = ImageFont.load_default()
    return fonts[px]
for c in json.load(open(calls_path)):
    k = c[0]
    if k == "rect":
        x, y, w, h, cc = c[1:]; d.rectangle([x, y, x + max(w, 1), y + max(h, 1)], fill=col(cc))
    elif k == "orect":
        x, y, w, h, cc = c[1:]; d.rectangle([x, y, x + w, y + h], outline=col(cc), width=2)
    elif k == "circle":
        x, y, r, cc = c[1:5]; d.ellipse([x - r, y - r, x + r, y + r], fill=col(cc))
    elif k == "ocircle":
        x, y, r, cc = c[1:5]; d.ellipse([x - r, y - r, x + r, y + r], outline=col(cc), width=2)
    elif k == "line":
        x1, y1, x2, y2, cc, t = c[1:7]; d.line([x1, y1, x2, y2], fill=col(cc), width=max(1, int(t)))
    elif k == "text":
        x, y, s, cc, px = c[1:]; d.text((x, y), s, fill=col(cc), font=font(px))
Image.alpha_composite(img, layer).convert("RGB").save(out)

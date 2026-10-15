# 生成 WatchPulse 应用图标（1024×1024，无透明通道）。用法：python3 tools/make_app_icon.py <输出.png>
# 需要 Pillow。iPhone 与 Apple Watch 使用同一张图（watchOS 会自动裁成圆形）。
import math, sys
from PIL import Image, ImageDraw, ImageFilter

S = 4096  # 超采样，最后缩到 1024
out = sys.argv[1]

def lerp(a, b, t): return tuple(int(a[i] + (b[i] - a[i]) * t) for i in range(3))

# 背景：深海军蓝 → 近黑的竖向渐变
bg = Image.new("RGB", (S, S))
top, bottom = (28, 33, 52), (9, 11, 18)
d = ImageDraw.Draw(bg)
for y in range(S):
    d.line([(0, y), (S, y)], fill=lerp(top, bottom, y / (S - 1)))

# 心形（参数方程），居中略偏上
pts = []
for i in range(720):
    t = 2 * math.pi * i / 720
    x = 16 * math.sin(t) ** 3
    y = 13 * math.cos(t) - 5 * math.cos(2 * t) - 2 * math.cos(3 * t) - math.cos(4 * t)
    pts.append((x, y))
scale = S * 0.0205
cx, cy = S / 2, S * 0.47
heart = [(cx + x * scale, cy - y * scale) for x, y in pts]

mask = Image.new("L", (S, S), 0)
ImageDraw.Draw(mask).polygon(heart, fill=255)

# 心形的柔和光晕
glow = mask.filter(ImageFilter.GaussianBlur(S * 0.05))
glow_layer = Image.new("RGB", (S, S), (255, 70, 90))
bg = Image.composite(glow_layer, bg, glow.point(lambda v: int(v * 0.35)))

# 心形填充：珊瑚红 → 玫红 斜向渐变
grad = Image.new("RGB", (S, S))
gd = ImageDraw.Draw(grad)
c1, c2 = (255, 107, 107), (214, 32, 84)
for y in range(S):
    gd.line([(0, y), (S, y)], fill=lerp(c1, c2, y / (S - 1)))
bg = Image.composite(grad, bg, mask)

# 白色心电脉冲线，穿过心形中部并延伸到两侧
d = ImageDraw.Draw(bg)
base = S * 0.50
u = S / 100
line = [
    (S * 0.12, base), (S * 0.33, base),
    (S * 0.37, base - 3 * u), (S * 0.40, base),
    (S * 0.44, base),
    (S * 0.48, base - 17 * u),   # 主峰
    (S * 0.53, base + 12 * u),   # 深谷
    (S * 0.57, base),
    (S * 0.61, base),
    (S * 0.65, base - 4 * u), (S * 0.69, base),
    (S * 0.88, base),
]
w = int(S * 0.034)
d.line(line, fill=(255, 255, 255), width=w, joint="curve")
for x, y in (line[0], line[-1]):
    r = w / 2
    d.ellipse([x - r, y - r, x + r, y + r], fill=(255, 255, 255))

bg.resize((1024, 1024), Image.LANCZOS).save(out, "PNG", optimize=True)
print("saved", out)

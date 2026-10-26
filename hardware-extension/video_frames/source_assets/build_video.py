import os
from PIL import Image, ImageDraw, ImageFont
import cv2
import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
FONT_DIR = "C:/Windows/Fonts"

def font(size, bold=False):
    path = os.path.join(FONT_DIR, "arialbd.ttf" if bold else "arial.ttf")
    return ImageFont.truetype(path, size)

W, H = 1280, 720

def avg_color(path):
    im = Image.open(path).convert("RGB")
    px = list(im.getdata())
    n = len(px)
    r = sum(p[0] for p in px) / n
    g = sum(p[1] for p in px) / n
    b = sum(p[2] for p in px) / n
    return (int(r), int(g), int(b))

def is_on(path):
    r, g, b = avg_color(path)
    return r > 150  # bright red ~ (237,28,36)ish vs dim ~ (60,10,10)ish

SCENARIOS = [
    {
        "key": "clear",
        "title": "1. Clear path ahead",
        "context": "What a blind user encounters: walking down an open corridor, nothing nearby",
        "sensors": "Front 200cm   Left 200cm   Right 200cm",
        "decision": 'DECISION state=CLEAR reason="no sensor within warning/danger range"',
        "feedback": "No vibration — safe to continue",
    },
    {
        "key": "left",
        "title": "2. Obstacle on the left",
        "context": "What a blind user encounters: a wall, parked bicycle, or furniture edge to their left",
        "sensors": "Front 200cm   Left 40cm   Right 200cm",
        "decision": 'DECISION state=LEFT reason="left sensor WARNING"',
        "feedback": "LEFT motor vibrates — steer right",
    },
    {
        "key": "right",
        "title": "3. Obstacle on the right",
        "context": "What a blind user encounters: a pillar, bench, or wall edge to their right",
        "sensors": "Front 200cm   Left 200cm   Right 40cm",
        "decision": 'DECISION state=RIGHT reason="right sensor WARNING"',
        "feedback": "RIGHT motor vibrates — steer left",
    },
    {
        "key": "stop",
        "title": "4. Obstacle directly ahead",
        "context": "What a blind user encounters: a wall, closed door, or person stopped right in front",
        "sensors": "Front 20cm   Left 200cm   Right 200cm",
        "decision": 'DECISION state=STOP reason="front sensor DANGER (immediate obstacle ahead)"',
        "feedback": "BOTH motors + buzzer — stop immediately",
    },
    {
        "key": "sos",
        "title": "5. Emergency SOS",
        "context": "What a blind user encounters: fall, panic, or needing help — presses the SOS button",
        "sensors": "SOS button pressed",
        "decision": 'DECISION state=SOS reason="SOS button active"',
        "feedback": "Fast alternating buzz/vibration pattern",
    },
]

def lerp(a, b, t):
    return tuple(int(a[i] + (b[i]-a[i])*t) for i in range(3))

def draw_motor(draw, cx, cy, radius, on, label):
    on_color = (220, 30, 30)
    off_color = (225, 225, 228)
    color = on_color if on else off_color
    draw.ellipse([cx-radius, cy-radius, cx+radius, cy+radius], fill=color, outline=(40,40,40), width=4)
    glow = "ON" if on else "off"
    f = font(30, bold=True)
    tw = draw.textlength(glow, font=f)
    text_color = (255,255,255) if on else (120,120,120)
    draw.text((cx - tw/2, cy - 18), glow, fill=text_color, font=f)
    f2 = font(26, bold=True)
    tw2 = draw.textlength(label, font=f2)
    draw.text((cx - tw2/2, cy + radius + 14), label, fill=(30,30,30), font=f2)

def build_frame(sc):
    img = Image.new("RGB", (W, H), (248, 248, 250))
    draw = ImageDraw.Draw(img)

    # Header bar
    draw.rectangle([0, 0, W, 90], fill=(20, 28, 48))
    f_head = font(34, bold=True)
    draw.text((40, 24), "INSIGHT Dissertation 1 \u2014 Live Wokwi Simulation", fill=(255,255,255), font=f_head)

    # Title
    f_title = font(44, bold=True)
    draw.text((50, 120), sc["title"], fill=(15,15,15), font=f_title)

    # Context (plain-language scenario)
    f_ctx = font(26)
    draw.text((50, 185), sc["context"], fill=(70,70,75), font=f_ctx)

    # Motors
    left_on = is_on(os.path.join(HERE, f'{sc["key"]}_left.png'))
    right_on = is_on(os.path.join(HERE, f'{sc["key"]}_right.png'))
    draw_motor(draw, W*0.32, 400, 90, left_on, "LEFT motor")
    draw_motor(draw, W*0.68, 400, 90, right_on, "RIGHT motor")

    # Sensor readings box
    f_mono = font(24)
    draw.rectangle([50, 540, W-50, 600], fill=(235,238,245))
    draw.text((65, 552), "Simulated sensor input:  " + sc["sensors"], fill=(20,20,20), font=f_mono)

    # Decision / reason (actual firmware Serial output)
    draw.rectangle([50, 615, W-50, 665], fill=(20, 28, 48))
    draw.text((65, 627), sc["decision"], fill=(140, 220, 140), font=font(22))

    # Feedback summary
    f_fb = font(28, bold=True)
    draw.text((50, 680), "Haptic feedback: " + sc["feedback"], fill=(150,20,20), font=f_fb)

    out_path = os.path.join(HERE, f'slide_{sc["key"]}.png')
    img.save(out_path)
    return out_path

frames = [build_frame(sc) for sc in SCENARIOS]

# Intro title card
intro = Image.new("RGB", (W, H), (20, 28, 48))
d = ImageDraw.Draw(intro)
f1 = font(50, bold=True)
f2 = font(28)
title_lines = ["INSIGHT Dissertation 1", "IoT/WSN Hardware Prototype"]
y = 240
for line in title_lines:
    tw = d.textlength(line, font=f1)
    d.text(((W-tw)/2, y), line, fill=(255,255,255), font=f1)
    y += 65
sub = "5 live Wokwi simulation scenarios a blind user may encounter"
tw = d.textlength(sub, font=f2)
d.text(((W-tw)/2, y+30), sub, fill=(200,205,220), font=f2)
sub2 = "Captured from an actual running simulation \u2014 not a mockup"
tw2 = d.textlength(sub2, font=f2)
d.text(((W-tw2)/2, y+75), sub2, fill=(150,200,150), font=font(22))
intro_path = os.path.join(HERE, "slide_intro.png")
intro.save(intro_path)

# Assemble video
fps = 30
seconds_per_slide = 4
intro_seconds = 3
video_path = os.path.join(HERE, "..", "INSIGHT_demo.mp4")  # one level up: video_frames/, not source_assets/
fourcc = cv2.VideoWriter_fourcc(*"mp4v")
writer = cv2.VideoWriter(video_path, fourcc, fps, (W, H))

def write_still(path, seconds):
    frame_bgr = cv2.cvtColor(np.array(Image.open(path).convert("RGB")), cv2.COLOR_RGB2BGR)
    for _ in range(int(fps*seconds)):
        writer.write(frame_bgr)

write_still(intro_path, intro_seconds)
for p in frames:
    write_still(p, seconds_per_slide)

writer.release()
print("Wrote", video_path)
total_seconds = intro_seconds + seconds_per_slide*len(frames)
print("Approx duration:", total_seconds, "seconds")

import matplotlib.pyplot as plt
import matplotlib.patches as patches
from matplotlib.patches import FancyArrowPatch

fig, ax = plt.subplots(figsize=(7.0, 4.2), dpi=220)
ax.set_xlim(0, 10)
ax.set_ylim(0, 6)
ax.axis("off")

def box(x, y, w, h, text, fc="white", ec="black", fontsize=8, bold=False):
    rect = patches.FancyBboxPatch(
        (x, y), w, h, boxstyle="round,pad=0.02,rounding_size=0.08",
        linewidth=1.1, edgecolor=ec, facecolor=fc
    )
    ax.add_patch(rect)
    ax.text(x + w / 2, y + h / 2, text, ha="center", va="center",
             fontsize=fontsize, fontweight="bold" if bold else "normal", wrap=True)

def arrow(x1, y1, x2, y2, style="-|>"):
    a = FancyArrowPatch((x1, y1), (x2, y2), arrowstyle=style,
                         mutation_scale=10, linewidth=1.0, color="black")
    ax.add_patch(a)

top_y = 4.6
bw, bh = 1.55, 0.8
labels = ["Voice\nInput", "Destination\nResolution", "Transit Routing\n(GTFS / RAPTOR)", "Navigation\nLoop", "Spoken\nGuidance"]
xs = [0.3, 2.1, 3.9, 5.9, 7.7]
for x, lab in zip(xs, labels):
    box(x, top_y, bw, bh, lab)
for i in range(len(xs) - 1):
    arrow(xs[i] + bw, top_y + bh / 2, xs[i + 1], top_y + bh / 2)

bot_y = 2.6
hz_labels = ["Hazard Detection\n(YOLOv8n)", "Temporal\nConfirmation", "Time-to-\nCollision", "Risk\nAssessment"]
hx = [1.5, 3.25, 5.0, 6.75]
for x, lab in zip(hx, hz_labels):
    box(x, bot_y, bw, bh, lab, fc="0.92")
for i in range(len(hx) - 1):
    arrow(hx[i] + bw, bot_y + bh / 2, hx[i + 1], bot_y + bh / 2)
arrow(hx[-1] + bw / 2, bot_y + bh, 5.9 + bw / 2, top_y, style="-|>")

box(0.3, 0.3, 4.3, 1.5, "Core A — Transit-Aware Camera Control\nStarts/stops hazard detection based on\ntransit journey phase (boarding/alighting)",
    fc="0.97", fontsize=7.5)
box(4.9, 0.3, 4.5, 1.5, "Core B — Behaviour-Adaptive Risk Profiling\nFeeds measured reaction latency into\nRisk Assessment to personalise warnings",
    fc="0.97", fontsize=7.5)
arrow(2.0, 1.8, 2.0, 2.6)
arrow(6.75 + bw / 2, 1.8, 6.75 + bw / 2, bot_y)

plt.tight_layout()
plt.savefig("figure1_architecture.png", bbox_inches="tight", facecolor="white")
print("wrote figure1_architecture.png")

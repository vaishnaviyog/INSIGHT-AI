import matplotlib.pyplot as plt
import matplotlib.patches as patches
from matplotlib.patches import FancyArrowPatch

fig, ax = plt.subplots(figsize=(7.0, 4.6), dpi=220)
ax.set_xlim(0, 10)
ax.set_ylim(0, 7.2)
ax.axis("off")

def box(x, y, w, h, text, fc="white", ec="black", fontsize=7.2, bold=False):
    rect = patches.FancyBboxPatch(
        (x, y), w, h, boxstyle="round,pad=0.02,rounding_size=0.09",
        linewidth=1.1, edgecolor=ec, facecolor=fc
    )
    ax.add_patch(rect)
    ax.text(x + w / 2, y + h / 2, text, ha="center", va="center",
             fontsize=fontsize, fontweight="bold" if bold else "normal", wrap=True)

def arrow(x1, y1, x2, y2, style="-|>", color="black", lw=1.0):
    a = FancyArrowPatch((x1, y1), (x2, y2), arrowstyle=style,
                         mutation_scale=9, linewidth=lw, color=color)
    ax.add_patch(a)

events = [
    "NavigationSessionStarted",
    "PositionSample",
    "ObstacleWarningIssued",
    "ObstacleCleared",
    "TurnTaken",
    "NavigationSessionEnded",
]
ey = [6.3, 5.3, 4.3, 3.3, 2.3, 1.3]
for lab, y in zip(events, ey):
    box(0.2, y, 2.3, 0.75, lab, fc="0.93", fontsize=7.0)

box(3.1, 3.2, 2.0, 1.3, "_applyEvent()\n(single dispatch\npoint; fail-soft if\nnot initialised)", fc="white", bold=True, fontsize=7.2)
for y in ey:
    arrow(2.5, y + 0.375, 3.1, 3.85, lw=0.8)

handlers = [
    ("_onObstacleWarningIssued()\nstores pendingWarningTime;\nnear-miss if distanceBand==veryNear", 6.0),
    ("_onObstacleCleared()\nclearanceLatency = clearedTime − pendingWarningTime\n(accepted only if 0 < Δt < 30 s)", 4.7),
    ("_updateWalkingSpeed() /\n_updateDistanceAndVisitedLocations()\n(PositionSample)", 3.4),
    ("_onSessionEnded()\nblends session familiarity into\nrouteFamiliarityScore (0.7 / 0.3)", 2.1),
]
for lab, y in handlers:
    box(5.5, y, 4.1, 1.05, lab, fc="0.97", fontsize=6.8)
arrow(5.1, 3.85, 5.5, 6.0 + 0.5, lw=0.8)
arrow(5.1, 3.85, 5.5, 4.7 + 0.5, lw=0.8)
arrow(5.1, 3.85, 5.5, 3.4 + 0.5, lw=0.8)
arrow(5.1, 3.85, 5.5, 2.1 + 0.5, lw=0.8)

box(5.5, 0.2, 4.1, 1.5,
    "_runningAverage(avg, n, x) =\n((avg × n) + x) / (n + 1)\n\n"
    "feeds: averageWalkingSpeed, averageReactionTime\n"
    "(persisted field name; user-facing label is\n“Hazard Clearance Latency”)",
    fc="0.90", fontsize=6.8)
arrow(6.3, 4.7, 6.3, 1.7, lw=0.8, color="0.4")
arrow(6.3, 3.4, 6.5, 1.7, lw=0.8, color="0.4")

box(3.1, 0.2, 2.0, 1.3, "_persist()\nHive box.put()\n(debounced /\nforced on\nsession end &\ndispose())", fc="0.93", fontsize=7.0)
arrow(4.1, 3.2, 4.1, 1.5, lw=0.8)

plt.tight_layout()
plt.savefig("figure3_core_b_pipeline.png", bbox_inches="tight", facecolor="white")
print("wrote figure3_core_b_pipeline.png")

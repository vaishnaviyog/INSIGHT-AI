import matplotlib.pyplot as plt
import matplotlib.patches as patches
from matplotlib.patches import FancyArrowPatch

fig, ax = plt.subplots(figsize=(7.0, 5.0), dpi=220)
ax.set_xlim(0, 10)
ax.set_ylim(0, 9.5)
ax.axis("off")

def box(x, y, w, h, text, fc="white", ec="black", fontsize=7.6, bold=False):
    rect = patches.FancyBboxPatch(
        (x, y), w, h, boxstyle="round,pad=0.02,rounding_size=0.09",
        linewidth=1.1, edgecolor=ec, facecolor=fc
    )
    ax.add_patch(rect)
    ax.text(x + w / 2, y + h / 2, text, ha="center", va="center",
             fontsize=fontsize, fontweight="bold" if bold else "normal", wrap=True)

def arrow(x1, y1, x2, y2, label=None, label_dx=0.0, label_dy=0.12, style="-|>", fontsize=6.6, color="black"):
    a = FancyArrowPatch((x1, y1), (x2, y2), arrowstyle=style,
                         mutation_scale=9, linewidth=1.0, color=color)
    ax.add_patch(a)
    if label:
        ax.text((x1 + x2) / 2 + label_dx, (y1 + y2) / 2 + label_dy, label,
                 ha="center", va="center", fontsize=fontsize, style="italic")

bw, bh = 2.55, 0.78

states = [
    ("walkingToBoardingStop", 0.35, 8.1),
    ("boarding", 0.35, 6.75),
    ("inTransit", 0.35, 5.4),
    ("alighting", 0.35, 4.05),
    ("finalWalking", 0.35, 2.7),
    ("arrived", 0.35, 1.35),
    ("nextDestination", 3.9, 1.35),
    ("ended", 7.1, 1.35),
]
state_fc = {"inTransit": "0.90"}
for name, x, y in states:
    box(x, y, bw, bh, name, fc=state_fc.get(name, "white"), bold=True, fontsize=7.8)

cx = 0.35 + bw / 2
arrow(cx, 8.1, cx, 6.75 + bh, label="reachedBoardingStop()")
arrow(cx, 6.75, cx, 5.4 + bh, label="confirmBoarding()\n[camera OFF]")
arrow(cx, 5.4, cx, 4.05 + bh, label="reachedDestinationStop()\n(auto via GPS or manual)")
arrow(cx, 4.05, cx, 2.7 + bh, label="confirmAlighting()\n[camera ON + reset TTC/filter]")
arrow(cx, 2.7, cx, 1.35 + bh, label="reachedFinalDestination()")

arrow(0.35 + bw, 1.35 + bh / 2, 3.9, 1.35 + bh / 2, label="promptForNextDestination()", label_dy=0.22)
arrow(3.9 + bw, 1.35 + bh / 2, 7.1, 1.35 + bh / 2, label="provideNextDestination()\n[end phrase]", label_dy=0.22)

corridor_x = 3.45
path_x = [3.9, corridor_x, corridor_x, 0.35 + bw / 2]
path_y = [1.35 + bh / 2, 1.35 + bh / 2, 8.1 + bh + 0.12, 8.1 + bh + 0.12]
ax.plot(path_x, path_y, color="0.35", linewidth=1.0, zorder=1)
ax.annotate("", xy=(0.35 + bw / 2, 8.1 + bh + 0.02), xytext=(0.35 + bw / 2, 8.1 + bh + 0.12),
            arrowprops=dict(arrowstyle="-|>", color="0.35", mutation_scale=9, linewidth=1.0))
ax.text(2.1, 9.18, "provideNextDestination() [new destination given] → new route",
        ha="center", va="center", fontsize=6.0, style="italic", color="0.25")

box(4.3, 6.5, 5.35, 2.15,
    "CAMERA CONTRACT (state machine emits commands only;\n"
    "integration layer drives the real CameraController):\n\n"
    "• startDetection on construction (entering\n   walkingToBoardingStop) and on finalWalking\n"
    "• stopDetection on confirmBoarding (entering inTransit)\n"
    "• resetDetectionState alongside finalWalking restart\n   (clears stale HazardTemporalFilter / CollisionTimeEstimator\n   state from before the vehicle leg)",
    fc="0.97", fontsize=6.9)

box(4.3, 4.55, 5.35, 1.55,
    "INVALID TRANSITIONS ARE REJECTED, NOT FUDGED:\n"
    "every method checks current state; calling it from the\n"
    "wrong state returns an empty event list (no state change,\n"
    "nothing spoken, no duplicate camera command).",
    fc="0.97", fontsize=6.9)

box(4.3, 3.05, 5.35, 1.3,
    "GPS-loss handling (does not change state):\n"
    "markLocationUnavailable() suppresses updateLocation()\n"
    "and speaks once; markLocationRestored() resumes silently.",
    fc="0.97", fontsize=6.9)

plt.tight_layout()
plt.savefig("figure2_core_a_states.png", bbox_inches="tight", facecolor="white")
print("wrote figure2_core_a_states.png")

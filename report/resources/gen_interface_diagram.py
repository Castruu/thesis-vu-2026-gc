"""Generate the fig-interface architecture diagram for the thesis (SVG via matplotlib).

Layout: IJVM host (left) <-> single gc_collector interface (middle) <-> five collectors (right).
Content is fact-checked against gc/include/gc_host.h.
"""
import matplotlib.pyplot as plt
import matplotlib.patches as mpatches

BG = "white"
INK = "#2B2B2B"
BOX_EDGE = "#8A8880"
BOX_FILL = "#FAFAF8"
IFACE_FILL = "#EFEDE8"
COLLECTORS = [
    ("baseline", "#7F8C8D"),
    ("mark-sweep", "#C0392B"),
    ("mark-compact", "#1F6FB2"),
    ("cheney", "#1E8449"),
    ("generational", "#8E44AD"),
]

fig, ax = plt.subplots(figsize=(9.6, 4.0), dpi=100)
ax.set_xlim(0, 96)
ax.set_ylim(0, 40)
ax.axis("off")
fig.patch.set_facecolor(BG)

def box(x, y, w, h, fill, edge, lw=1.0, radius=1.2):
    p = mpatches.FancyBboxPatch(
        (x, y), w, h,
        boxstyle=f"round,pad=0,rounding_size={radius}",
        facecolor=fill, edgecolor=edge, linewidth=lw)
    ax.add_patch(p)
    return p

# ---- left: IJVM host ----
LX, LY, LW, LH = 2, 3, 28, 34
box(LX, LY, LW, LH, BOX_FILL, BOX_EDGE, lw=1.2)
ax.text(LX + LW / 2, LY + LH - 3.2, "IJVM host (VM)", ha="center", va="center",
        fontsize=11, fontweight="bold", color=INK)
ax.plot([LX + 2, LX + LW - 2], [LY + LH - 6.2, LY + LH - 6.2], color=BOX_EDGE, lw=0.8)
ax.text(LX + LW / 2, LY + LH - 8.6, "host primitives", ha="center", va="center",
        fontsize=8.5, style="italic", color=INK)
host_groups = [
    "raw allocation & block split",
    "root enumeration",
    "object-reference enumeration",
    "linear heap walk",
    "mark / free header bits",
    "forwarding pointers",
    "object relocation",
]
for i, g in enumerate(host_groups):
    ax.text(LX + LW / 2, LY + LH - 11.6 - i * 3.1, g, ha="center", va="center",
            fontsize=8.5, color=INK)

# ---- middle: the interface ----
MX, MY, MW, MH = 45, 8, 17, 24
box(MX, MY, MW, MH, IFACE_FILL, INK, lw=1.4)
ax.text(MX + MW / 2, MY + MH - 3.0, "one interface", ha="center", va="center",
        fontsize=10.5, fontweight="bold", color=INK)
ax.plot([MX + 2, MX + MW - 2], [MY + MH - 5.6, MY + MH - 5.6], color=INK, lw=0.8)
for i, op in enumerate(["alloc", "collect", "write barrier", "destroy"]):
    ax.text(MX + MW / 2, MY + MH - 8.6 - i * 3.6, op, ha="center", va="center",
            fontsize=9, family="monospace", color=INK)

# ---- right: five collectors ----
RX, RW, RH, GAP = 74, 20, 5.4, 1.6
total = 5 * RH + 4 * GAP
RY0 = 20 - total / 2
for i, (name, color) in enumerate(COLLECTORS):
    y = RY0 + (4 - i) * (RH + GAP)
    box(RX, y, RW, RH, BOX_FILL, color, lw=1.6)
    ax.text(RX + RW / 2, y + RH / 2, name, ha="center", va="center",
            fontsize=9.5, color=color, fontweight="bold")
    # connector interface -> collector
    ax.annotate("", xy=(RX - 0.4, y + RH / 2), xytext=(MX + MW + 0.4, MY + MH / 2),
                arrowprops=dict(arrowstyle="-", color=BOX_EDGE, lw=0.9,
                                connectionstyle="arc3,rad=0.0"))

# ---- arrows VM <-> interface ----
ax.annotate("", xy=(MX - 0.6, 24), xytext=(LX + LW + 0.6, 24),
            arrowprops=dict(arrowstyle="-|>", color=INK, lw=1.2))
ax.text((LX + LW + MX) / 2, 26.0, "VM invokes", ha="center", va="bottom",
        fontsize=8.5, style="italic", color=INK)
ax.annotate("", xy=(LX + LW + 0.6, 15), xytext=(MX - 0.6, 15),
            arrowprops=dict(arrowstyle="-|>", color=INK, lw=1.2))
ax.text((LX + LW + MX) / 2, 13.4, "collectors consume\nhost primitives", ha="center",
        va="top", fontsize=8, style="italic", color=INK)

ax.text(RX + RW / 2, RY0 + total + 2.2, "implemented by", ha="center", va="bottom",
        fontsize=8.5, style="italic", color=INK)

out = "/Users/vfcastro/VU - Computer Science/thesis/thesis-repo/report-outline/resources/interface.svg"
fig.savefig(out, format="svg", bbox_inches="tight", facecolor=BG)
print("written:", out)

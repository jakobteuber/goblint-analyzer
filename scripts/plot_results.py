#!/usr/bin/env python3
"""Plot the results of scripts/compare_solvers.sh, scripts/solver_work.sh and scripts/solver_timing.sh.

Usage: ./scripts/plot_results.py [--work CSV ...] [--compare CSV ...] [--timing CSV ...] [--out DIR] [--format svg,pdf,png]

Without CSV arguments, all results under tests/suite_result are plotted:
  */compare.csv                    precision: per solver pair, the tests on which one solver is more precise than the other
  */work.csv (or work_partial.csv) work: per-test ratio of right-hand side evaluations (or eval+iterate calls, for older
                                   results without rhs) to the baseline td_simplified_ref, and failed runs
  */timing.csv                     time: wall time of solve per input, solver and run
The plots are written to tests/suite_result/plots (default), named after the directory of the CSV file.
Requires matplotlib and pandas.
"""

import argparse
import math
from pathlib import Path

import matplotlib

matplotlib.use("Agg")
import matplotlib.pyplot as plt
import numpy as np
import pandas as pd

ROOT = Path(__file__).resolve().parent.parent
RESULTS = ROOT / "tests" / "suite_result"
BASELINE = "td_simplified_ref"

# Colors (a validated categorical palette, see the dataviz guidelines). A solver keeps its color in every plot.
# The baseline is gray, as it is drawn as a reference (the ratio 1) rather than as a series.
SOLVER_COLORS = {
    "td_worklist_lifo": "#2a78d6",  # blue
    "td_worklist_fifo": "#eb6834",  # orange
    "td_parallel_base": "#1baf7a",  # aqua
    "td_worklist_random": "#eda100",  # yellow
    BASELINE: "#898781",  # gray
}
EXTRA_COLORS = ["#e87ba4", "#008300", "#6250d6", "#e34948"]  # further slots, for other solvers
INK = "#0b0b0b"
INK_SECONDARY = "#52514e"
INK_MUTED = "#898781"
GRID = "#e1e0d9"
AXIS = "#c3c2b7"
SURFACE = "#fcfcfb"
# Precision: more precise on the left/right are opposite poles, everything else neutral.
LEFT_COLOR = "#2a78d6"  # blue
RIGHT_COLOR = "#e34948"  # red
MIXED_COLOR = "#52514e"
FAILED_COLOR = "#c3c2b7"
# Run status (ok, timeout, error).
STATUS_COLORS = {"ok": "#0ca30c", "timeout": "#fab219", "error": "#d03b3b"}

plt.rcParams.update({
    "figure.facecolor": SURFACE,
    "axes.facecolor": SURFACE,
    "savefig.facecolor": SURFACE,
    "axes.edgecolor": AXIS,
    "axes.labelcolor": INK_SECONDARY,
    "axes.titlecolor": INK,
    "axes.titlesize": 11,
    "axes.titleweight": "bold",
    "axes.titlelocation": "left",
    "axes.spines.top": False,
    "axes.spines.right": False,
    "axes.grid": True,
    "grid.color": GRID,
    "grid.linewidth": 0.6,
    "axes.axisbelow": True,
    "xtick.color": INK_MUTED,
    "ytick.color": INK_MUTED,
    "xtick.labelcolor": INK_SECONDARY,
    "ytick.labelcolor": INK_SECONDARY,
    "legend.frameon": False,
    "legend.labelcolor": INK_SECONDARY,
    "font.size": 9,
    "lines.linewidth": 2,
})


def solver_color(solver, _assigned={}):
    if solver in SOLVER_COLORS:
        return SOLVER_COLORS[solver]
    if solver not in _assigned:
        _assigned[solver] = EXTRA_COLORS[len(_assigned) % len(EXTRA_COLORS)]
    return _assigned[solver]


def solver_order(solvers):
    """Baseline first, then the known solvers in their usual order, then the others alphabetically."""
    known = list(SOLVER_COLORS)
    return sorted(solvers, key=lambda s: (s != BASELINE, known.index(s) if s in known else len(known), s))


def footnote(ax, text):
    """Note below the x axis of ax (including its tick labels and label), placed when the figure is saved."""
    ax.figure._footnote = (ax, text)


def legend_above(ax, ncol):
    """Legend between the title and the plot."""
    ax.legend(loc="lower left", bbox_to_anchor=(0, 1.0), ncol=ncol, borderaxespad=0.3, handletextpad=0.4, columnspacing=1.5)


def place_footnote(fig):
    if not hasattr(fig, "_footnote"):
        return
    ax, text = fig._footnote
    renderer = fig.canvas.get_renderer()
    bottom = min(a.xaxis.get_tightbbox(renderer).y0 for a in fig.axes)  # lowest x axis, in pixels
    left = ax.get_position().x0
    fig.text(left, bottom / fig.bbox.height - 0.01, text, color=INK_MUTED, fontsize=8, ha="left", va="top")


def save(fig, out, name, formats):
    fig.canvas.draw()
    place_footnote(fig)
    for fmt in formats:
        path = out / f"{name}.{fmt}"
        fig.savefig(path, bbox_inches="tight", dpi=200)
        print(f"  {path.relative_to(ROOT) if path.is_relative_to(ROOT) else path}")
    plt.close(fig)


def log2_ratio_axis(ax, axis="x"):
    """Ratios on a log scale, labelled as ratios (0.5, 1, 2, ...)."""
    set_scale = ax.set_xscale if axis == "x" else ax.set_yscale
    set_scale("log", base=2)
    formatter = matplotlib.ticker.FuncFormatter(lambda v, _: f"{v:g}")
    (ax.xaxis if axis == "x" else ax.yaxis).set_major_formatter(formatter)
    (ax.xaxis if axis == "x" else ax.yaxis).set_minor_formatter(matplotlib.ticker.NullFormatter())


# Work (solver_work.sh)

def plot_work(csv, out, formats):
    name = csv.parent.name
    df = pd.read_csv(csv)
    metric = "rhs" if "rhs" in df.columns and df["rhs"].notna().any() else "eval+iterate"
    metric_label = "right-hand side evaluations" if metric == "rhs" else "eval + iterate calls"
    df["work"] = df["rhs"] if metric == "rhs" else df["eval"] + df["iterate"]
    solvers = solver_order(df["solver"].unique())
    base = BASELINE if BASELINE in solvers else solvers[0]
    others = [s for s in solvers if s != base]
    df["group"] = df["test"].str.split("/").str[0]

    # Each solver is compared with the baseline on the tests on which both succeeded (and did some work).
    ok = df[df["status"] == "ok"].pivot(index="test", columns="solver", values="work")
    pairs = {s: ok[[base, s]].dropna().query(f"`{base}` > 0 and `{s}` > 0") for s in others}
    ratios = {s: p[s] / p[base] for s, p in pairs.items()}
    n_tests = df["test"].nunique()
    data = csv.relative_to(ROOT) if csv.is_relative_to(ROOT) else csv
    counts_note = ", ".join(f"{s} {len(p)}" for s, p in pairs.items())
    note = f"Tests on which the solver and {base} succeeded (of {n_tests}): {counts_note}.\nData: {data}"
    print(f"{name}: {metric}, baseline {base}, common tests: {counts_note}")

    # 1. Distribution of the per-test ratios: how often and by how much each solver does more or less work.
    fig, ax = plt.subplots(figsize=(7, 4))
    for s in others:
        r = np.sort(ratios[s].to_numpy())
        y = np.arange(1, len(r) + 1) / len(r)
        gm = math.exp(np.log(r).mean())
        ax.step(r, y, where="post", color=solver_color(s), label=f"{s} (geometric mean {gm:.2f})")
    ax.axvline(1, color=INK_MUTED, linewidth=1)
    log2_ratio_axis(ax)
    ax.set_xlabel(f"{metric_label} relative to {base} (per test, log scale)")
    ax.set_ylabel("fraction of tests")
    ax.set_ylim(0, 1)
    ax.set_title(f"Work relative to {base}: {name}")
    ax.legend(loc="lower right")
    footnote(ax, "Left of 1: less work than the baseline.\n" + note)
    save(fig, out, f"{name}-ratio", formats)

    # 2. Work of each solver against the baseline, per test: does the difference grow with the size of the problem?
    fig, axes = plt.subplots(1, len(others), figsize=(3.2 * len(others), 3.4), sharex=True, sharey=True, squeeze=False)
    lo = max(1, min(p.min().min() for p in pairs.values()))
    hi = max(p.max().max() for p in pairs.values())
    for ax, s in zip(axes[0], others):
        ax.plot([lo, hi], [lo, hi], color=AXIS, linewidth=1, zorder=1)
        ax.scatter(pairs[s][base], pairs[s][s], s=10, color=solver_color(s), alpha=0.6, linewidths=0, zorder=2)
        ax.set_xscale("log")
        ax.set_yscale("log")
        ax.set_title(s, fontsize=10)
        ax.set_xlabel(base)
    axes[0][0].set_ylabel(f"{metric_label} of the solver")
    fig.suptitle(f"{metric_label.capitalize()} per test: {name}", x=0.01, ha="left", fontweight="bold", color=INK, fontsize=11)
    fig.tight_layout()
    footnote(axes[0][0], "Above the diagonal: more work than the baseline.\n" + note)
    save(fig, out, f"{name}-scatter", formats)

    # 3. Per test group (e.g. SV-COMP directory), if there are few enough to read.
    groups = df["group"].unique()
    if 1 < len(groups) <= 25:
        gm = pd.DataFrame({s: np.exp(np.log(r).groupby(r.index.str.split("/").str[0]).mean()) for s, r in ratios.items()})
        sizes = df.groupby("group")["test"].nunique()
        gm = gm.reindex(sizes.sort_values().index)  # largest groups on top
        fig, ax = plt.subplots(figsize=(7, 0.32 * len(gm) + 1.4))
        y = np.arange(len(gm))
        offsets = np.linspace(-0.2, 0.2, len(others)) if len(others) > 1 else [0]
        for off, s in zip(offsets, others):
            ax.scatter(gm[s], y + off, s=30, color=solver_color(s), label=s, zorder=3, edgecolors=SURFACE, linewidths=1)
        ax.axvline(1, color=INK_MUTED, linewidth=1)
        ax.set_yticks(y, [f"{g} ({sizes[g]})" for g in gm.index])
        ax.set_ylim(-0.6, len(gm) - 0.4)
        ax.grid(axis="y", visible=False)
        log2_ratio_axis(ax)
        ax.set_xlabel(f"geometric mean of {metric_label} relative to {base} (log scale)")
        ax.set_title(f"Work relative to {base} per group: {name}", pad=24)
        legend_above(ax, len(others))
        footnote(ax, "Number of tests per group in parentheses; groups without a dot for a solver: it failed on all tests there.\n" + note)
        save(fig, out, f"{name}-groups", formats)

    # 4. Failed runs (timeouts and errors) per solver, if any.
    status = df.groupby(["solver", "status"]).size().unstack(fill_value=0)
    if (status.drop(columns="ok", errors="ignore").to_numpy() > 0).any():
        status = status.reindex(solver_order(status.index))
        fig, ax = plt.subplots(figsize=(7, 0.45 * len(status) + 1))
        left = np.zeros(len(status))
        y = np.arange(len(status))[::-1]
        for st in ["ok", "timeout", "error"]:
            if st not in status.columns:
                continue
            ax.barh(y, status[st], left=left, color=STATUS_COLORS[st], label=st, height=0.6, edgecolor=SURFACE, linewidth=2)
            for yi, l, v in zip(y, left, status[st]):
                if st != "ok" and v >= 0.03 * status.sum(axis=1).max():  # only where the label fits
                    ax.text(l + v / 2, yi, str(v), ha="center", va="center", color=INK, fontsize=8)
            left += status[st].to_numpy()
        ax.set_yticks(y, status.index)
        ax.grid(axis="y", visible=False)
        ax.set_xlabel("runs")
        ax.set_title(f"Run status: {name}", pad=24)
        legend_above(ax, 3)
        footnote(ax, f"Data: {csv.relative_to(ROOT) if csv.is_relative_to(ROOT) else csv}")
        save(fig, out, f"{name}-status", formats)


# Precision (compare_solvers.sh)

def plot_compare(csv, out, formats):
    name = csv.parent.name
    df = pd.read_csv(csv)
    l = df["globals_left"] + df["locals_left"] + df["ctx_left"]
    r = df["globals_right"] + df["locals_right"] + df["ctx_right"]
    inc = df["globals_incomparable"] + df["locals_incomparable"] + df["ctx_incomparable"]
    miss = df["ctx_missing_in_right"] + df["ctx_missing_in_left"]
    failed = df["status"] != "ok"
    # Each test in exactly one category. As in compare_solvers.sh, race and deadlock globals are already excluded.
    df["category"] = np.select(
        [failed, (l + r + inc + miss) == 0, (l > 0) & (r == 0) & (inc == 0) & (miss == 0), (r > 0) & (l == 0) & (inc == 0) & (miss == 0)],
        ["failed", "identical", "left", "right"], default="mixed")
    pairs = df.groupby(["left", "right"], sort=False)
    print(f"{name}: {pairs.ngroups} solver pair(s)")

    labels = {"left": "left solver more precise", "right": "right solver more precise",
              "mixed": "both, incomparable or missing contexts", "failed": "failed (error/timeout)"}
    colors = {"left": LEFT_COLOR, "right": RIGHT_COLOR, "mixed": MIXED_COLOR, "failed": FAILED_COLOR}
    cats = list(labels)
    fig, ax = plt.subplots(figsize=(7, 0.9 * pairs.ngroups + 1.4))
    ylabels = []
    height = 0.8 / len(cats)
    for i, ((left, right), g) in enumerate(pairs):
        counts = g["category"].value_counts()
        for j, c in enumerate(cats):
            y = i + (j - (len(cats) - 1) / 2) * height
            v = counts.get(c, 0)
            ax.barh(y, v, height=height, color=colors[c], edgecolor=SURFACE, linewidth=1, label=labels[c] if i == 0 else None)
            if v > 0:
                ax.text(v, y, f" {v}", va="center", ha="left", color=INK_SECONDARY, fontsize=7)
        ylabels.append(f"{left}  vs  {right}\n{counts.get('identical', 0)} of {len(g)} tests identical")
    ax.set_yticks(range(pairs.ngroups), ylabels)
    ax.invert_yaxis()
    ax.grid(axis="y", visible=False)
    ax.set_xlabel("tests")
    ax.set_title(f"Precision differences between solvers: {name}", pad=40)
    legend_above(ax, 2)
    footnote(ax, "Per test, comparing all unknowns of the left solver with those of the right one (comparesolver).\n"
             f"Data: {csv.relative_to(ROOT) if csv.is_relative_to(ROOT) else csv}")
    save(fig, out, f"{name}-precision", formats)


# Time (solver_timing.sh)

def plot_timing(csv, out, formats):
    name = csv.parent.name
    df = pd.read_csv(csv)
    ok = df[df["status"] == "ok"]
    inputs = list(dict.fromkeys(df["input"]))
    print(f"{name}: {len(inputs)} input(s)")
    fig, axes = plt.subplots(1, len(inputs), figsize=(3.4 * len(inputs), 3.8), squeeze=False)
    rng = np.random.default_rng(0)
    for ax, inp in zip(axes[0], inputs):
        d = ok[ok["input"] == inp]
        solvers = solver_order(df[df["input"] == inp]["solver"].unique())
        medians = d.groupby("solver")["walltime"].median()
        for x, s in enumerate(solvers):
            t = d[d["solver"] == s]["walltime"]
            if t.empty:
                ax.text(x, 0, "failed", ha="center", va="bottom", color=INK_MUTED, fontsize=8, rotation=90)
                continue
            ax.scatter(x + rng.uniform(-0.15, 0.15, len(t)), t, s=12, color=solver_color(s), alpha=0.7, linewidths=0, zorder=2)
            ax.hlines(medians[s], x - 0.3, x + 0.3, color=INK, linewidth=1.5, zorder=3)
        # Few large differences: log scale, so that the small solvers stay readable.
        if medians.max() / medians.min() > 10:
            ax.set_yscale("log")
            ax.yaxis.set_major_formatter(matplotlib.ticker.FuncFormatter(lambda v, _: f"{v:g}"))
        else:
            ax.set_ylim(bottom=0)
        ax.set_xticks(range(len(solvers)), [s.removeprefix("td_") for s in solvers], rotation=30, ha="right")
        ax.grid(axis="x", visible=False)
        title = inp if len(inp) <= 32 else inp[:30] + "…"
        ax.set_title(title, fontsize=9)
    axes[0][0].set_ylabel("wall time of solve (s)")
    fig.suptitle(f"Solve time per run: {name}", x=0.01, ha="left", fontweight="bold", color=INK, fontsize=11)
    fig.tight_layout()
    runs = df.groupby(["input", "solver"]).size().max()
    footnote(axes[0][0], f"Dots: single runs (up to {runs} per solver), bars: medians. "
             f"Data: {csv.relative_to(ROOT) if csv.is_relative_to(ROOT) else csv}")
    save(fig, out, f"{name}-time", formats)


def discover(pattern):
    return sorted(RESULTS.glob(pattern))


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--work", nargs="*", type=Path, default=None, help="work.csv files of solver_work.sh")
    parser.add_argument("--compare", nargs="*", type=Path, default=None, help="compare.csv files of compare_solvers.sh")
    parser.add_argument("--timing", nargs="*", type=Path, default=None, help="timing.csv files of solver_timing.sh")
    parser.add_argument("--out", type=Path, default=RESULTS / "plots", help="output directory (default: tests/suite_result/plots)")
    parser.add_argument("--format", default="svg", help="comma-separated file formats, e.g. svg,pdf,png (default: svg)")
    args = parser.parse_args()

    if args.work is None and args.compare is None and args.timing is None:
        work = discover("*/work.csv")
        # Interrupted runs of solver_work.sh only have a work_partial.csv (merged from their rows by hand).
        work += [p for p in discover("*/work_partial.csv") if not (p.parent / "work.csv").exists()]
        compare, timing = discover("*/compare.csv"), discover("*/timing.csv")
    else:
        work, compare, timing = args.work or [], args.compare or [], args.timing or []
    work, compare, timing = ([p.resolve() for p in ps] for ps in (work, compare, timing))

    args.out.mkdir(parents=True, exist_ok=True)
    formats = args.format.split(",")
    for csv in compare:
        plot_compare(csv, args.out, formats)
    for csv in work:
        plot_work(csv, args.out, formats)
    for csv in timing:
        plot_timing(csv, args.out, formats)


if __name__ == "__main__":
    main()

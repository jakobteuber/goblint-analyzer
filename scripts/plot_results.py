#!/usr/bin/env python3
"""Plot the results of scripts/compare_solvers.sh, scripts/solver_work.sh and scripts/solver_timing.sh.

Usage: ./scripts/plot_results.py [--work CSV ...] [--compare CSV ...] [--timing CSV ...] [--out DIR] [--format svg,pdf,png]

Without CSV arguments, all results under tests/suite_result are plotted:
  */compare.csv                    precision: per pair of solvers, on how many tests one is more precise than the other
  */work.csv (or work_partial.csv) work: per-test ratio of right-hand side evaluations (or eval+iterate calls, for older
                                   results without rhs) to the baseline td_simplified_ref, and failed runs.
                                   Repeated runs of a solver appear as its best and worst run per test (e.g. td_worklist_random#best),
                                   the number of runs is taken from work_runs.csv next to work.csv.
  */timing.csv                     time: wall time of solve per input, solver and run; the random orders (one per seed) side by side
The plots are written to tests/suite_result/plots (default) as <result directory>_<plot>.<format>:
  <dir>_work-ratio-cdf     distribution of the per-test work relative to the baseline
  <dir>_work-per-test      work of each solver against the baseline, one dot per test
  <dir>_work-per-group     geometric mean of the ratio per test group
  <dir>_run-status         ok, timeout and error runs per solver (only if a run failed)
  <dir>_precision-matrix   per pair of solvers: tests on which one is strictly more precise, and tests where they differ otherwise
  <dir>_solve-time         wall time of solve per run
The dataset (which tests) is named in each plot's footnote, from dataset.txt next to the CSV file.
Requires matplotlib and pandas.
"""

import argparse
import math
import re
from pathlib import Path

import matplotlib

matplotlib.use("Agg")
import matplotlib.pyplot as plt
import numpy as np
import pandas as pd
from matplotlib.colors import LinearSegmentedColormap

ROOT = Path(__file__).resolve().parent.parent
RESULTS = ROOT / "tests" / "suite_result"
BASELINE = "td_simplified_ref"

# Colors: the validated categorical palette of the dataviz guidelines, in its slot order. A solver keeps its color in
# every plot; all runs of td_worklist_random share one color. The order of the entries is the order of the solvers in the plots.
# The baseline is gray, as it is drawn as a reference (the ratio 1) rather than as a series.
SOLVER_COLORS = {
    "td_worklist_lifo": "#2a78d6",  # blue
    "td_worklist_fifo": "#eb6834",  # orange
    "td_worklist_most_invalidated": "#1baf7a",  # aqua
    "td_worklist_random": "#eda100",  # yellow
    "td_worklist_least_invalidated": "#e87ba4",  # magenta
    "td_worklist_shallowest_created": "#008300",  # green
    "td_worklist_cheapest_first": "#6250d6",  # violet
    "td_worklist_producers_first": "#e34948",  # red
    BASELINE: "#898781",  # gray
}
OTHER_COLOR = "#52514e"  # solvers without a slot, e.g. td_parallel_base
# Short names for the plots.
SOLVER_LABELS = {
    "td_simplified_ref": "simplified_ref (no work list)",
    "td_worklist_lifo": "LIFO",
    "td_worklist_fifo": "FIFO",
    "td_worklist_most_invalidated": "most invalidated",
    "td_worklist_least_invalidated": "least invalidated",
    "td_worklist_shallowest_created": "shallowest created",
    "td_worklist_cheapest_first": "cheapest first",
    "td_worklist_producers_first": "producers first",
    "td_worklist_random": "random",
}
INK = "#0b0b0b"
INK_SECONDARY = "#52514e"
INK_MUTED = "#898781"
GRID = "#e1e0d9"
AXIS = "#c3c2b7"
SURFACE = "#fcfcfb"
# Precision matrix: the sequential blue ramp, from near zero to many tests.
SEQUENTIAL = ["#cde2fb", "#86b6ef", "#3987e5", "#1c5cab", "#0d366b"]
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


def base_name(solver):
    return solver.split("#")[0]


def solver_color(solver):
    return SOLVER_COLORS.get(base_name(solver), OTHER_COLOR)


def solver_label(solver, runs=None):
    """Readable name; runs: the number of runs behind #best/#worst."""
    name, _, tag = solver.partition("#")
    label = SOLVER_LABELS.get(name, name.removeprefix("td_"))
    of = f" of {runs}" if runs else ""
    if tag == "best":
        return f"{label}, best{of}"
    if tag == "worst":
        return f"{label}, worst{of}"
    if tag.isdigit() and name == "td_worklist_random":
        return f"{label}, seed {tag}"
    return f"{label} #{tag}" if tag else label


def solver_style(solver):
    """Line style and marker fill: the best of repeated runs solid and filled, the worst dashed and hollow."""
    worst = solver.endswith("#worst")
    return {"linestyle": "--" if worst else "-", "filled": not worst}


def solver_order(solvers):
    """Baseline first, then the known solvers in their slot order (best before worst, seeds numerically), then the others."""
    known = list(SOLVER_COLORS)

    def key(s):
        name, _, tag = s.partition("#")
        tag_key = (0, int(tag), "") if tag.isdigit() else (1, 0, tag)
        return (s != BASELINE, known.index(name) if name in known else len(known), name, tag_key)
    return sorted(solvers, key=key)


def dataset(csv):
    """Description of the inputs, written by the scripts; the result directory for older results."""
    f = csv.parent / "dataset.txt"
    return f.read_text().strip() if f.exists() else csv.parent.name


def data_note(csv):
    path = csv.relative_to(ROOT) if csv.is_relative_to(ROOT) else csv
    return f"Dataset: {dataset(csv)}. Data: {path}"


def footnote(ax, text):
    """Note below the x axis of ax (including its tick labels and label), placed when the figure is saved."""
    ax.figure._footnote = (ax, text)


def legend_above(ax, ncol, **kwargs):
    """Legend between the title and the plot."""
    ax.legend(loc="lower left", bbox_to_anchor=(0, 1.0), ncol=ncol, borderaxespad=0.3, handletextpad=0.4, columnspacing=1.5, **kwargs)


def place_footnote(fig):
    if not hasattr(fig, "_footnote"):
        return
    ax, text = fig._footnote
    renderer = fig.canvas.get_renderer()
    boxes = [a.xaxis.get_tightbbox(renderer) for a in fig.axes if a.get_visible()]
    bottom = min(b.y0 for b in boxes if b is not None)  # lowest x axis, in pixels
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
    """Ratios on a log scale, labelled as ratios: 0.5, 0.75, 1, 1.25, ... for small ranges, powers of 2 for large ones.
    Call after plotting, as the ticks depend on the range of the data."""
    set_scale = ax.set_xscale if axis == "x" else ax.set_yscale
    set_scale("log", base=2)
    a = ax.xaxis if axis == "x" else ax.yaxis
    lo, hi = ax.get_xlim() if axis == "x" else ax.get_ylim()
    if math.log2(hi / lo) > 3:
        ticks = [2.0 ** k for k in range(-10, 11)]
    else:
        ticks = [0.125, 0.25, 0.5, 0.75, 1, 1.25, 1.5, 2, 3, 4, 6, 8]
    a.set_major_locator(matplotlib.ticker.FixedLocator(ticks))
    a.set_major_formatter(matplotlib.ticker.FuncFormatter(lambda v, _: f"{v:.3g}"))
    a.set_minor_locator(matplotlib.ticker.NullLocator())


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

    # Number of repeated runs behind #best/#worst, per solver.
    runs = {}
    runs_csv = csv.parent / "work_runs.csv"
    if runs_csv.exists():
        r = pd.read_csv(runs_csv, usecols=["solver"])["solver"].drop_duplicates()
        runs = r[r.str.contains("#")].str.split("#").str[0].value_counts().to_dict()

    def label(s):
        return solver_label(s, runs.get(base_name(s)))
    base_label = label(base)

    # Each solver is compared with the baseline on the tests on which both succeeded (and did some work).
    ok = df[df["status"] == "ok"].pivot(index="test", columns="solver", values="work")
    pairs = {s: p[(p[base] > 0) & (p[s] > 0)] for s in others for p in [ok[[base, s]].dropna()]}
    ratios = {s: p[s] / p[base] for s, p in pairs.items()}
    n_tests = df["test"].nunique()
    counts = sorted({len(p) for p in pairs.values()})
    counts_note = (f"{counts[0]}" if len(counts) == 1 else f"{counts[0]} to {counts[-1]}") + f" of {n_tests}"
    note = "".join(f"{label(s + '#best')}/worst: per test, the best and the worst of {n} runs by {metric_label}.\n" for s, n in runs.items())
    note += f"Tests on which the solver and the baseline succeeded: {counts_note}.\n{data_note(csv)}"
    print(f"{name}: {metric}, baseline {base}, common tests {counts_note}")

    # 1. Distribution of the per-test ratios: how often and by how much each solver does more or less work.
    fig, ax = plt.subplots(figsize=(7, 4.6))
    for s in others:
        r = np.sort(ratios[s].to_numpy())
        y = np.arange(1, len(r) + 1) / len(r)
        gm = math.exp(np.log(r).mean())
        ax.step(r, y, where="post", color=solver_color(s), linestyle=solver_style(s)["linestyle"], linewidth=1.6,
                label=f"{label(s)} ({gm:.3f})")
    ax.axvline(1, color=INK_MUTED, linewidth=1)
    log2_ratio_axis(ax)
    ax.set_xlabel(f"{metric_label} relative to {base_label}, per test (log scale)")
    ax.set_ylabel("fraction of tests")
    ax.set_ylim(0, 1)
    ax.set_title(f"Work of the work-list heuristics relative to {base_label}", pad=8)
    ax.legend(loc="upper left", bbox_to_anchor=(1.02, 1), title="solver (geometric mean\nof the ratio)", title_fontsize=8, fontsize=8,
              alignment="left")
    footnote(ax, "Left of 1: less work than the baseline.\n" + note)
    save(fig, out, f"{name}_work-ratio-cdf", formats)

    # 2. Work of each solver against the baseline, per test: does the difference grow with the size of the problem?
    ncols = min(3, len(others))
    nrows = math.ceil(len(others) / ncols)
    fig, axes = plt.subplots(nrows, ncols, figsize=(3.1 * ncols, 2.9 * nrows), sharex=True, sharey=True, squeeze=False)
    lo = max(1, min(p.min().min() for p in pairs.values()))
    hi = max(p.max().max() for p in pairs.values())
    for ax in axes.flat[len(others):]:
        ax.set_visible(False)
    for ax, s in zip(axes.flat, others):
        ax.plot([lo, hi], [lo, hi], color=AXIS, linewidth=1, zorder=1)
        filled = solver_style(s)["filled"]
        ax.scatter(pairs[s][base], pairs[s][s], s=10, zorder=2, alpha=0.6,
                   color=solver_color(s) if filled else "none", edgecolors=solver_color(s), linewidths=0 if filled else 0.8)
        ax.set_xscale("log")
        ax.set_yscale("log")
        ax.set_title(label(s), fontsize=10)
    for ax in axes[-1]:
        ax.set_xlabel(base_label)
    for row in axes:
        row[0].set_ylabel("solver")
    fig.suptitle(f"{metric_label.capitalize()} per test, against {base_label}", x=0.01, ha="left", fontweight="bold", color=INK, fontsize=11)
    fig.tight_layout()
    footnote(axes[-1][0], "One dot per test, both axes log scale. Above the diagonal: more work than the baseline.\n" + note)
    save(fig, out, f"{name}_work-per-test", formats)

    # 3. Per test group (e.g. SV-COMP directory), if there are few enough to read.
    groups = df["group"].unique()
    if 1 < len(groups) <= 25:
        gm = pd.DataFrame({s: np.exp(np.log(r).groupby(r.index.str.split("/").str[0]).mean()) for s, r in ratios.items()})
        sizes = df.groupby("group")["test"].nunique()
        gm = gm.reindex(sizes.sort_values().index)  # largest groups on top
        fig, ax = plt.subplots(figsize=(7.5, 0.4 * len(gm) + 1.8))
        y = np.arange(len(gm))
        offsets = np.linspace(-0.3, 0.3, len(others)) if len(others) > 1 else [0]
        for off, s in zip(offsets, others):
            filled = solver_style(s)["filled"]
            ax.scatter(gm[s], y + off, s=22, zorder=3, label=label(s),
                       color=solver_color(s) if filled else SURFACE, edgecolors=solver_color(s) if not filled else SURFACE,
                       linewidths=1.2 if not filled else 0.8)
        ax.axvline(1, color=INK_MUTED, linewidth=1)
        ax.set_yticks(y, [f"{g} ({sizes[g]})" for g in gm.index])
        ax.set_ylim(-0.6, len(gm) - 0.4)
        ax.grid(axis="y", visible=False)
        log2_ratio_axis(ax)
        ax.set_xlabel(f"geometric mean of {metric_label} relative to {base_label} (log scale)")
        ax.set_title(f"Work relative to {base_label}, per test group", pad=8 + 14 * math.ceil(len(others) / 3))
        legend_above(ax, 3, fontsize=8)
        footnote(ax, "Number of tests per group in parentheses; no dot for a solver: it failed on all tests of the group.\n" + note)
        save(fig, out, f"{name}_work-per-group", formats)

    # 4. Failed runs (timeouts and errors) per solver, if any.
    status = df.groupby(["solver", "status"]).size().unstack(fill_value=0)
    if (status.drop(columns="ok", errors="ignore").to_numpy() > 0).any():
        status = status.reindex(solver_order(status.index))
        fig, ax = plt.subplots(figsize=(7.5, 0.4 * len(status) + 1.2))
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
        ax.set_yticks(y, [label(s) for s in status.index])
        ax.grid(axis="y", visible=False)
        ax.set_xlabel("tests")
        ax.set_title("Run status per solver", pad=24)
        legend_above(ax, 3)
        footnote(ax, data_note(csv))
        save(fig, out, f"{name}_run-status", formats)


# Precision (compare_solvers.sh)

def plot_compare(csv, out, formats):
    name = csv.parent.name
    df = pd.read_csv(csv)
    ok = df[df["status"] == "ok"].copy()
    l = ok["globals_left"] + ok["locals_left"] + ok["ctx_left"]
    r = ok["globals_right"] + ok["locals_right"] + ok["ctx_right"]
    inc = ok["globals_incomparable"] + ok["locals_incomparable"] + ok["ctx_incomparable"]
    miss = ok["ctx_missing_in_right"] + ok["ctx_missing_in_left"]
    # Each test of a pair in exactly one category.
    ok["category"] = np.select(
        [(l + r + inc + miss) == 0, (l > 0) & (r == 0) & (inc == 0) & (miss == 0), (r > 0) & (l == 0) & (inc == 0) & (miss == 0)],
        ["identical", "left", "right"], default="mixed")
    solvers = solver_order(pd.unique(pd.concat([df["left"], df["right"]])))
    idx = {s: i for i, s in enumerate(solvers)}
    n = len(solvers)
    better = np.zeros((n, n), dtype=int)  # [row, column]: tests on which row is strictly more precise than column
    mixed = np.zeros((n, n), dtype=int)   # symmetric: tests on which both are more precise somewhere, incomparable or missing contexts
    for (left, right), g in ok.groupby(["left", "right"]):
        c = g["category"].value_counts()
        i, j = idx[left], idx[right]
        better[i, j], better[j, i] = c.get("left", 0), c.get("right", 0)
        mixed[i, j] = mixed[j, i] = c.get("mixed", 0)
    n_tests = df["test"].nunique()
    failed_tests = df[df["status"] != "ok"]["test"].nunique()
    print(f"{name}: {n} solvers, {n_tests} tests")

    labels = [solver_label(s) for s in solvers]
    vmax = max(1, better.max(), mixed.max())
    cmap = LinearSegmentedColormap.from_list("blues", SEQUENTIAL)
    size = 0.42 * n + 2.4
    fig, axes = plt.subplots(1, 2, figsize=(2 * size + 0.6, size + 0.4))
    panels = [(better, "Strictly more precise: row solver than column solver", "more precise", "than"),
              (mixed, "Differing otherwise: both directions, incomparable or missing contexts", "", "")]
    for ax, (m, title, ylab, xlab) in zip(axes, panels):
        shown = np.ma.masked_where((m == 0) | np.eye(n, dtype=bool), m)
        ax.imshow(shown, cmap=cmap, vmin=0, vmax=vmax, aspect="equal")
        for i in range(n):
            for j in range(n):
                if i == j:
                    ax.add_patch(plt.Rectangle((j - 0.5, i - 0.5), 1, 1, color=GRID, linewidth=0))
                elif m[i, j] > 0:
                    dark = m[i, j] > 0.45 * vmax
                    ax.text(j, i, str(m[i, j]), ha="center", va="center", fontsize=7, color=SURFACE if dark else INK)
        ax.set_xticks(range(n), labels, rotation=45, ha="right", rotation_mode="anchor")
        ax.set_yticks(range(n), labels)
        ax.set_xticks(np.arange(-0.5, n), minor=True)
        ax.set_yticks(np.arange(-0.5, n), minor=True)
        ax.grid(False)
        ax.grid(which="minor", color=SURFACE, linewidth=1.5)
        ax.tick_params(which="minor", length=0)
        ax.spines[:].set_visible(False)
        ax.set_title(title, fontsize=9.5, pad=8)
        if ylab:
            ax.set_ylabel(ylab)
            ax.set_xlabel(xlab)
    fig.suptitle("Precision of the solvers, compared pairwise: number of tests", x=0.01, ha="left", fontweight="bold", color=INK, fontsize=11)
    fig.tight_layout()
    footnote(axes[0], "A test counts if any unknown (global, or local per node or per context) differs. Empty cells: no such test.\n"
             f"Tests: {n_tests}, of which {failed_tests} failed (error or timeout) and are not counted.\n" + data_note(csv))
    save(fig, out, f"{name}_precision-matrix", formats)


# Time (solver_timing.sh)

def plot_timing(csv, out, formats):
    name = csv.parent.name
    df = pd.read_csv(csv)
    ok = df[df["status"] == "ok"]
    inputs = list(dict.fromkeys(df["input"]))
    print(f"{name}: {len(inputs)} input(s)")
    fig, axes = plt.subplots(1, len(inputs), figsize=(4.4 * len(inputs), 4.2), squeeze=False)
    rng = np.random.default_rng(0)
    for ax, inp in zip(axes[0], inputs):
        d = ok[ok["input"] == inp]
        solvers = solver_order(df[df["input"] == inp]["solver"].unique())
        # One slot per solver; the runs of one solver with several labels (the random seeds) share a slot side by side.
        slots = list(dict.fromkeys(base_name(s) for s in solvers))
        medians = d.groupby("solver")["walltime"].median()
        for x, slot in enumerate(slots):
            members = [s for s in solvers if base_name(s) == slot]
            width = 0.7 / len(members)
            for k, s in enumerate(members):
                cx = x - 0.35 + width * (k + 0.5)
                t = d[d["solver"] == s]["walltime"]
                if t.empty:
                    ax.text(cx, 0, "failed", ha="center", va="bottom", color=INK_MUTED, fontsize=7, rotation=90)
                    continue
                ax.scatter(cx + rng.uniform(-0.25, 0.25, len(t)) * width, t, s=10, color=solver_color(s), alpha=0.7, linewidths=0, zorder=2)
                ax.hlines(medians[s], cx - 0.4 * width, cx + 0.4 * width, color=INK, linewidth=1.5, zorder=3)
        if medians.max() / medians.min() > 10:  # few large differences: log scale, so that the small ones stay readable
            ax.set_yscale("log")
            ax.yaxis.set_major_formatter(matplotlib.ticker.FuncFormatter(lambda v, _: f"{v:g}"))
        else:
            ax.set_ylim(bottom=0)
        ticks = []
        for slot in slots:
            k = sum(base_name(s) == slot for s in solvers)
            ticks.append(solver_label(slot) + (f" ({k} seeds)" if slot == "td_worklist_random" and k > 1 else ""))
        ax.set_xticks(range(len(slots)), ticks, rotation=35, ha="right", rotation_mode="anchor")
        ax.grid(axis="x", visible=False)
        ax.set_title(inp if len(inp) <= 40 else inp[:38] + "…", fontsize=9)
    axes[0][0].set_ylabel("wall time of solve (s)")
    fig.suptitle("Solve time per run", x=0.01, ha="left", fontweight="bold", color=INK, fontsize=11)
    fig.tight_layout()
    runs = df.groupby(["input", "solver"]).size().max()
    footnote(axes[0][0], f"Dots: single runs (up to {runs} per solver), bars: medians. Random orders: one column per seed, "
             "each seed is the same order in all its runs.\n" + data_note(csv))
    save(fig, out, f"{name}_solve-time", formats)


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

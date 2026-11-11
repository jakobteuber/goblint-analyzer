#!/usr/bin/env python3
"""Plot the results of scripts/compare_solvers.sh, scripts/solver_work.sh and scripts/solver_timing.sh.

Usage: ./scripts/plot_results.py [--work CSV ...] [--compare CSV ...] [--timing CSV ...] [--out DIR] [--format svg,pdf,png]

Without CSV arguments, all results under tests/suite_result are plotted:
  */compare.csv                    precision: per pair of solvers, on how many tests one is more precise than the other
  */work.csv (or work_partial.csv) work: per-test ratio of right-hand side evaluations (or eval+iterate calls, for older
                                   results without rhs) to the baseline td_worklist_fifo, and failed runs.
                                   The solvers are split into panels, one per heuristic with both its directions (see PANELS).
                                   Repeated runs of a solver appear as its best and worst run per test (e.g. td_worklist_random#best),
                                   the number of runs is taken from work_runs.csv next to work.csv.
  */timing.csv                     time: wall time of solve per input, solver and run; the random orders (one per seed) side by side
The plots are written to tests/suite_result/plots (default) as <result directory>_<plot>.<format>:
  <dir>_work-ratio-cdf     distribution of the per-test work relative to the baseline
  <dir>_work-per-test      work of each solver against the baseline, one dot per test
  <dir>_work-per-test_vs-<solver>  the same with another solver as the baseline, for each solver
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
import textwrap
from pathlib import Path

import matplotlib

matplotlib.use("Agg")
import matplotlib.pyplot as plt
import numpy as np
import pandas as pd
from matplotlib.colors import LinearSegmentedColormap

ROOT = Path(__file__).resolve().parent.parent
RESULTS = ROOT / "tests" / "suite_result"
BASELINE = "td_worklist_fifo"
RANDOM = "td_worklist_random"

# The solvers are shown in panels (small multiples), not all in one plot: there are more solvers than categorical hues,
# and the dataviz guidelines validate only the first three slots of the palette all-pairs (for lines, dots and small
# multiples, where every pair of colors in a panel can meet). Each panel holds one heuristic in both directions
# (FIFO and LIFO are the two directions of insertion order), so a panel never has more than three hues.
# td_simplified_ref has a panel of its own: it has no work list and is unrelated to the heuristics.
# Colors therefore mark the role in a panel, not the solver: the first-named direction is blue, its opposite orange
# (also dotted with triangles, so that the direction does not depend on color alone), a third solver aqua.
# The random orders are a neutral band (from their best to their worst run) behind every panel, and the baseline is
# the reference line at 1 (or the x axis), so that every panel is read against the same references.
PANELS = [
    ("Insertion order", ["td_worklist_fifo", "td_worklist_lifo"]),
    ("No work list", ["td_simplified_ref"]),
    ("Invalidations", ["td_worklist_most_invalidated", "td_worklist_least_invalidated"]),
    ("Creation depth", ["td_worklist_shallowest_created", "td_worklist_deepest_created"]),
    ("Cost of the last task", ["td_worklist_cheapest_first", "td_worklist_costliest_first"]),
    ("Destabilizations", ["td_worklist_destabilizers_first", "td_worklist_destabilizers_last"]),
    ("Recency", ["td_worklist_least_recently_fired", "td_worklist_most_recently_fired"]),
]
ROLE_COLORS = ["#2a78d6", "#eb6834", "#1baf7a"]  # categorical slots 1-3: blue, orange, aqua
# The second solver of a heuristic panel: the opposite direction of the first.
OPPOSITES = {members[1] for _, members in PANELS if len(members) > 1}
# Plot order: the panels in order, the random orders after the reference solvers (insertion order, no work list).
ORDER = PANELS[0][1] + PANELS[1][1] + [RANDOM] + [s for _, members in PANELS[2:] for s in members]
RANDOM_BAND = "#e1e0d9"  # neutral, behind the series
# Short names for the plots.
SOLVER_LABELS = {
    "td_simplified_ref": "simplified_ref (no work list)",
    "td_worklist_lifo": "LIFO",
    "td_worklist_fifo": "FIFO",
    "td_worklist_most_invalidated": "most invalidated",
    "td_worklist_least_invalidated": "least invalidated",
    "td_worklist_shallowest_created": "shallowest created",
    "td_worklist_deepest_created": "deepest created",
    "td_worklist_cheapest_first": "cheapest first",
    "td_worklist_costliest_first": "costliest first",
    "td_worklist_destabilizers_first": "destabilizers first",
    "td_worklist_destabilizers_last": "destabilizers last",
    "td_worklist_least_recently_fired": "least recently fired",
    "td_worklist_most_recently_fired": "most recently fired",
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
    """Color of the role of a solver in its panel (see PANELS); the random orders: the first slot."""
    name = base_name(solver)
    for _, members in PANELS:
        if name in members:
            return ROLE_COLORS[members.index(name)]
    return ROLE_COLORS[0]


def panels(solvers):
    """The panels (title, members) with the given solvers, in the order of PANELS, without empty panels and random orders.
    Each member keeps its role (its index in the panel); a missing member is None, so that the roles stay aligned.
    Solvers that are in no panel (e.g. td_parallel_base) follow in panels of up to three."""
    present = set(solvers)
    result = []
    for title, members in PANELS:
        shown = [s if s in present else None for s in members]
        while shown and shown[-1] is None:
            shown.pop()
        if any(shown):
            result.append((title, shown))
    known = {s for _, members in PANELS for s in members}
    rest = [s for s in solvers if s not in known and base_name(s) != RANDOM]
    for i in range(0, len(rest), 3):
        result.append(("Other", rest[i:i + 3]))
    return result


def role_color(i):
    return ROLE_COLORS[i % len(ROLE_COLORS)]


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
    """Line style, marker and marker fill: the best of repeated runs solid and filled, the worst dashed and hollow;
    opposite variants (sharing the color of their heuristic) dotted, with triangles."""
    worst = solver.endswith("#worst")
    opposite = base_name(solver) in OPPOSITES
    return {"linestyle": "--" if worst else ":" if opposite else "-", "marker": "^" if opposite else "o", "filled": not worst}


def solver_order(solvers):
    """Baseline first, then the known solvers in the order of the panels (best before worst, seeds numerically), then the others."""
    known = ORDER

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
    # Wrap to the width of the figure, so that a long dataset description does not widen it (about 0.5 em per character).
    width = max(40, int(fig.get_figwidth() * (0.98 - left) * 72 / (8 * 0.5)))
    text = "\n".join(textwrap.fill(line, width) for line in text.split("\n"))
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
    # Solvers that did the same work as an earlier one on every test hide behind it in the plots: name them.
    same = []
    for i, s in enumerate(others):
        twin = next((t for t in others[:i] if ok[s].equals(ok[t])), None)
        if twin:
            same.append(f"{label(s)}: the same as {label(twin)} on every test, hidden behind it.\n")
    note = "".join(same) + note
    note += f"Tests on which the solver and the baseline succeeded: {counts_note}.\n{data_note(csv)}"
    print(f"{name}: {metric}, baseline {base}, common tests {counts_note}")

    # The random orders, as a band from their best to their worst run behind the panels (if there are both).
    band = None
    if f"{RANDOM}#best" in ratios and f"{RANDOM}#worst" in ratios:
        band = (ratios[f"{RANDOM}#best"], ratios[f"{RANDOM}#worst"], f"random, best–worst of {runs.get(RANDOM, '?')}")
    grid = panels(others)
    pairs_note = ("Colors mark the direction within a panel, not the heuristic: blue the first-named, "
                  "orange (dotted lines, triangles) the opposite.\n")

    # 1. Distribution of the per-test ratios: how often and by how much each solver does more or less work.
    plot_ratio_cdf(ratios, grid, band, base_label, metric_label, label,
                   "Left of 1: less work than the baseline. " + pairs_note + note, out, f"{name}_work-ratio-cdf", formats)

    # 2. Work of each solver against a baseline, per test: does the difference grow with the size of the problem?
    # Once against the default baseline, and once against each other solver.
    for b in solvers:
        plot_work_per_test(ok, b, [s for s in solvers if s != b], label, metric_label, runs, n_tests, csv, out,
                           f"{name}_work-per-test" + ("" if b == base else f"_vs-{file_label(b)}"), formats)

    # 3. Per test group (e.g. SV-COMP directory), if there are few enough to read.
    groups = df["group"].unique()
    if 1 < len(groups) <= 25:
        gm = pd.DataFrame({s: np.exp(np.log(r).groupby(r.index.str.split("/").str[0]).mean()) for s, r in ratios.items()})
        sizes = df.groupby("group")["test"].nunique()
        gm = gm.reindex(sizes.sort_values().index)  # largest groups on top
        plot_per_group(gm, sizes, grid, band is not None and f"random, best–worst of {runs.get(RANDOM, '?')}", base_label,
                       metric_label, label,
                       "Number of tests per group in parentheses; no dot for a solver: it failed on all tests of the group.\n"
                       + pairs_note + note, out, f"{name}_work-per-group", formats)

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


def file_label(solver):
    """Solver name for file names, e.g. td_worklist_random#best -> random-best."""
    return solver.removeprefix("td_worklist_").removeprefix("td_").replace("#", "-")


def panel_grid(n, ncols, width, height):
    """Figure with n panels in ncols columns, shared axes; the unused cells are hidden.
    Returns the figure and the visible axes; each visible panel at the bottom of its column shows its x tick labels."""
    nrows = math.ceil(n / ncols)
    fig, axes = plt.subplots(nrows, ncols, figsize=(width * ncols, height * nrows), sharex=True, sharey=True, squeeze=False)
    for ax in axes.flat[n:]:
        ax.set_visible(False)
    visible = list(axes.flat[:n])
    bottom = [ax for i, ax in enumerate(visible) if i + ncols >= n]
    for ax in bottom:
        ax.tick_params(labelbottom=True)
    return fig, visible, bottom


def plot_ratio_cdf(ratios, grid, band, base_label, metric_label, label, note, out, filename, formats):
    """One panel per heuristic (see PANELS): the distribution of its per-test ratios to the baseline, in both directions,
    in front of the band of the random orders. ratios: per solver, the ratio per test."""
    fig, axes, bottom = panel_grid(len(grid), 2, 4.6, 2.7)
    values = [r for s, r in ratios.items()]
    lo = min(r.min() for r in values)
    hi = max(r.max() for r in values)
    q = np.linspace(0, 1, 401)
    for ax, (title, members) in zip(axes, grid):
        if band:
            best, worst, band_label = band
            ax.fill_betweenx(q, np.quantile(best, q), np.quantile(worst, q), color=RANDOM_BAND, linewidth=0, zorder=1,
                             label=band_label)
        for i, s in enumerate(members):
            if s is None:
                continue
            r = np.sort(ratios[s].to_numpy())
            y = np.arange(1, len(r) + 1) / len(r)
            gm = math.exp(np.log(r).mean())
            ax.step(r, y, where="post", color=role_color(i), linestyle=solver_style(s)["linestyle"], linewidth=1.6, zorder=3,
                    label=f"{label(s)} ({gm:.3f})")
        ax.axvline(1, color=INK_MUTED, linewidth=1, zorder=2)
        ax.set_title(title, fontsize=10)
        ax.legend(loc="lower right", fontsize=7.5, handlelength=2.2)  # right of 1 at the bottom: no curves there
    axes[0].set_xlim(lo / 1.05, hi * 1.05)
    axes[0].set_ylim(0, 1)
    log2_ratio_axis(axes[0])
    for ax in bottom:
        ax.set_xlabel(f"{metric_label} relative to {base_label}\nper test (log scale)")
    for ax in axes[::2]:
        ax.set_ylabel("fraction of tests")
    fig.suptitle(f"Work of the work-list heuristics relative to {base_label}", x=0.01, ha="left", fontweight="bold", color=INK,
                 fontsize=11)
    fig.tight_layout()
    footnote(min(bottom, key=lambda a: a.get_position().x0), "In parentheses: geometric mean of the ratio. " + note)
    save(fig, out, filename, formats)


def plot_per_group(gm, sizes, grid, band_label, base_label, metric_label, label, note, out, filename, formats):
    """One panel per heuristic (see PANELS): per test group, the geometric mean of the ratio to the baseline,
    in front of the range of the random orders. gm: per group (rows) and solver (columns)."""
    fig, axes, bottom = panel_grid(len(grid), 2, 4.6, 0.32 * len(gm) + 1.2)
    y = np.arange(len(gm))
    for ax, (title, members) in zip(axes, grid):
        if band_label:
            ax.hlines(y, gm[f"{RANDOM}#best"], gm[f"{RANDOM}#worst"], color=RANDOM_BAND, linewidth=5, zorder=1, label=band_label)
        shown = [(i, s) for i, s in enumerate(members) if s is not None]
        offsets = np.linspace(-0.15, 0.15, len(shown)) if len(shown) > 1 else [0]
        for off, (i, s) in zip(offsets, shown):
            ax.scatter(gm[s], y + off, s=22, zorder=3, label=label(s), marker=solver_style(s)["marker"], color=role_color(i),
                       edgecolors=SURFACE, linewidths=0.8)
        ax.axvline(1, color=INK_MUTED, linewidth=1, zorder=2)
        ax.set_yticks(y, [f"{g} ({sizes[g]})" for g in gm.index])
        ax.set_ylim(-0.6, len(gm) - 0.4)
        ax.grid(axis="y", visible=False)
        ax.set_title(title, fontsize=10, pad=6 + 12 * math.ceil((len(shown) + bool(band_label)) / 2))
        legend_above(ax, 2, fontsize=7.5)
    log2_ratio_axis(axes[0])
    for ax in bottom:
        ax.set_xlabel(f"geometric mean of {metric_label}\nrelative to {base_label} (log scale)")
    fig.suptitle(f"Work relative to {base_label}, per test group", x=0.01, ha="left", fontweight="bold", color=INK, fontsize=11)
    fig.tight_layout()
    fig.subplots_adjust(top=fig.subplotpars.top - 0.4 / fig.get_figheight())  # room for the title above the panel titles
    footnote(min(bottom, key=lambda a: a.get_position().x0), note)
    save(fig, out, filename, formats)


def scatter_rows(others):
    """Layout of the scatter plots: one panel per solver, four per row. The panels of PANELS (and the random orders,
    best and worst) follow in pairs, two pairs per row, each direction in its column; other solvers fill rows of their own.
    Returns rows of (solver, role) or None for an empty cell."""
    grid = panels(others)
    rows = []
    blocks = []
    for title, members in grid:
        cells = [(s, i) if s else None for i, s in enumerate(members)]
        if title == "Other":
            rows.append(cells + [None] * (4 - len(cells)))
        else:
            blocks.append(cells + [None] * (2 - len(cells)))
    random = [(s, i) if s in others else None for i, s in enumerate([f"{RANDOM}#best", f"{RANDOM}#worst"])]
    if any(random):
        blocks.insert(2 if len(blocks) >= 2 else len(blocks), random)  # after insertion order and no work list
    for i in range(0, len(blocks), 2):
        row = blocks[i] + (blocks[i + 1] if i + 1 < len(blocks) else [None, None])
        rows.append(row)
    return rows


def plot_work_per_test(ok, base, others, label, metric_label, runs, n_tests, csv, out, filename, formats):
    """Scatter plot per solver of its work against the work of base, per test; ok: work per test (rows) and solver (columns).
    The panels are laid out as in scatter_rows, so that both directions of a heuristic sit side by side."""
    base_label = label(base)
    pairs = {s: p[(p[base] > 0) & (p[s] > 0)] for s in others for p in [ok[[base, s]].dropna()]}
    counts = sorted({len(p) for p in pairs.values()})
    counts_note = (f"{counts[0]}" if len(counts) == 1 else f"{counts[0]} to {counts[-1]}") + f" of {n_tests}"
    note = "".join(f"{label(s + '#best')}/worst: per test, the best and the worst of {n} runs by {metric_label}.\n" for s, n in runs.items())
    note += f"Tests on which the solver and the baseline succeeded: {counts_note}.\n{data_note(csv)}"
    rows = scatter_rows(others)
    nrows, ncols = len(rows), 4
    fig, axes = plt.subplots(nrows, ncols, figsize=(2.7 * ncols, 2.6 * nrows), sharex=True, sharey=True, squeeze=False)
    lo = max(1, min(p.min().min() for p in pairs.values()))
    hi = max(p.max().max() for p in pairs.values())
    for r, row in enumerate(rows):
        for c, cell in enumerate(row):
            ax = axes[r][c]
            if cell is None:
                ax.set_visible(False)
                continue
            s, role = cell
            ax.plot([lo, hi], [lo, hi], color=AXIS, linewidth=1, zorder=1)
            filled = solver_style(s)["filled"]
            ax.scatter(pairs[s][base], pairs[s][s], s=9, zorder=2, alpha=0.6, marker=solver_style(s)["marker"],
                       color=role_color(role) if filled else "none", edgecolors=role_color(role), linewidths=0 if filled else 0.8)
            ax.set_xscale("log")
            ax.set_yscale("log")
            ax.set_title(label(s), fontsize=9.5)
    # x tick labels and label for every panel at the bottom of its column, y label in the first visible panel of a row.
    for c in range(ncols):
        col = [axes[r][c] for r in range(nrows) if rows[r][c] is not None]
        if col:
            col[-1].tick_params(labelbottom=True)
            col[-1].set_xlabel(base_label)
    for r in range(nrows):
        first = next((axes[r][c] for c in range(ncols) if rows[r][c] is not None), None)
        if first:
            first.tick_params(labelleft=True)
            first.set_ylabel("solver")
    fig.suptitle(f"{metric_label.capitalize()} per test, against {base_label}", x=0.01, ha="left", fontweight="bold", color=INK, fontsize=11)
    fig.tight_layout()
    bottom = next(axes[r][c] for r in reversed(range(nrows)) for c in range(ncols) if rows[r][c] is not None)
    footnote(bottom, "One dot per test, both axes log scale. Above the diagonal: more work than the baseline.\n"
             "Both directions of a heuristic side by side; blue the first-named direction, orange (triangles) the opposite.\n"
             + note)
    save(fig, out, filename, formats)


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

    # The random orders (one per seed) are combined into one row and column: per cell the median over the seeds
    # (or over the pairs of different seeds, on the diagonal), and the range from the fewest to the most tests.
    seeds = [i for i, s in enumerate(solvers) if base_name(s) == "td_worklist_random" and s.partition("#")[2].isdigit()]
    groups = [[i] for i in range(n) if i not in seeds]
    labels = [solver_label(solvers[g[0]]) for g in groups]
    random_group = None
    if len(seeds) > 1:
        random_group = sorted(groups + [seeds], key=lambda g: g[0]).index(seeds)
        groups.insert(random_group, seeds)
        labels.insert(random_group, f"random, {len(seeds)} seeds")
    elif seeds:
        groups = [[i] for i in range(n)]
        labels = [solver_label(s) for s in solvers]

    def collapse(m):
        """Median, min and max per cell over the members of the groups; NaN where there is nothing to compare."""
        k = len(groups)
        med, lo, hi = (np.full((k, k), np.nan) for _ in range(3))
        for a, ga in enumerate(groups):
            for b, gb in enumerate(groups):
                v = [m[i, j] for i in ga for j in gb if i != j]
                if v:
                    med[a, b], lo[a, b], hi[a, b] = np.median(v), min(v), max(v)
        return med, lo, hi

    better, mixed = collapse(better), collapse(mixed)
    n = len(groups)
    vmax = max(1, np.nanmax(better[0]), np.nanmax(mixed[0]))
    cmap = LinearSegmentedColormap.from_list("blues", SEQUENTIAL)
    size = 0.42 * n + 2.4
    fig, axes = plt.subplots(1, 2, figsize=(2 * size + 0.6, size + 0.4))
    panels = [(better, "Strictly more precise: row solver than column solver", "more precise", "than"),
              (mixed, "Differing otherwise: both directions, incomparable or missing contexts", "", "")]
    for ax, ((m, lo, hi), title, ylab, xlab) in zip(axes, panels):
        shown = np.ma.masked_where(np.isnan(m) | (m == 0), m)
        ax.imshow(shown, cmap=cmap, vmin=0, vmax=vmax, aspect="equal")
        for i in range(n):
            for j in range(n):
                if np.isnan(m[i, j]):
                    ax.add_patch(plt.Rectangle((j - 0.5, i - 0.5), 1, 1, color=GRID, linewidth=0))
                elif hi[i, j] > 0:
                    dark = m[i, j] > 0.45 * vmax
                    text = f"{m[i, j]:g}"
                    if lo[i, j] != hi[i, j]:
                        text += f"\n{lo[i, j]:g}–{hi[i, j]:g}"
                    ax.text(j, i, text, ha="center", va="center", fontsize=7, color=SURFACE if dark else INK)
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
    random_note = ""
    if random_group is not None:
        random_note = (f"random, {len(seeds)} seeds: median over the seeds and below it the range (fewest–most tests); "
                       "on the diagonal over the pairs of different seeds, i.e. how much two random orders differ.\n")
    footnote(axes[0], "A test counts if any unknown (global, or local per node or per context) differs. Empty cells: no such test.\n"
             + random_note +
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

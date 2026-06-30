"""
Stage K — Charting  (the seven core charts)
============================================
Generates the brief's seven core charts from the Stage E/F/G parquet outputs.
Each chart takes the project name from config, applies the navy / Carlito house
style, and annotates directly on the figure where that replaces caption text.

Charts (output_root/stage_k/):
  1. forecast_trend.png        — forecast completion week-by-week vs baseline
  2. bucket_trajectories.png   — bucket variance build-up (Site Work + top buildings)
  3. driving_resource.png      — driving-path forecast, colored by controlling resource
  4. delay_waterfall.png       — chronological control-period waterfall (red add / green recover)
  5. resource_net_bar.png      — net days by controlling resource, ranked
  6. building_lollipop.png     — building turnover baseline→forecast lollipop
  7. float_histogram.png       — float-health bands

Inputs (reads whatever is present; skips a chart with a note if its stage
output is missing):
  - Stage F: output_root/stage_f/{snapshot_controlling,waterfall_periods,by_resource_net}.parquet
  - Stage G: output_root/stage_g/{building_turnover,float_health}.parquet
  - Stage E: reused live for the per-snapshot bucket trajectory
  - Stage C: snapshots, for the trajectory

Usage:
  python generate_charts.py [--config project_config.json]
"""

import argparse
import json
import sys
from pathlib import Path

import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
import matplotlib.dates as mdates
import matplotlib.font_manager as fm
import numpy as np
import pandas as pd


# ---------------------------------------------------------------------------
# House style
# ---------------------------------------------------------------------------

NAVY = "#1F4E78"
RED = "#C0392B"      # adds days
GREEN = "#27632A"    # recovers days
GRID = "#D9D9D9"
GRAYTXT = "#606060"
# muted supporting palette for multi-series / categorical
PALETTE = ["#1F4E78", "#E67E22", "#27632A", "#7D5BA6", "#C0392B", "#2C7BB6",
           "#9B59B6", "#16A085", "#D4AC0D", "#A0522D", "#5D6D7E", "#34495E"]

CARLITO_DIR = Path("/usr/share/fonts/truetype/crosextra")


def register_fonts():
    """Register Carlito (regular + bold) and set it as the default family."""
    registered = False
    for fn in ["Carlito-Regular.ttf", "Carlito-Bold.ttf", "Carlito-Italic.ttf",
               "Carlito-BoldItalic.ttf"]:
        p = CARLITO_DIR / fn
        if p.exists():
            fm.fontManager.addfont(str(p))
            registered = True
    if not registered:
        print("  NOTE: Carlito not found; using Calibri/DejaVu Sans fallback.")
    # Use a sans-serif fallback CHAIN rather than a single family name. Setting
    # font.family to a specific missing font (e.g. "Liberation Sans", which is
    # not present on stock Windows) makes matplotlib emit a "findfont: Font
    # family not found" warning for EVERY text element drawn - hundreds per run.
    # A chain ending in DejaVu Sans (always bundled with matplotlib) resolves
    # silently: Carlito if registered, else Calibri on Windows, else DejaVu Sans.
    plt.rcParams["font.family"] = "sans-serif"
    plt.rcParams["font.sans-serif"] = ["Carlito", "Calibri", "Liberation Sans", "DejaVu Sans", "Arial"]
    plt.rcParams.update({
        "font.size": 10,
        "axes.titlesize": 13,
        "axes.titleweight": "bold",
        "axes.titlecolor": NAVY,
        "axes.labelcolor": GRAYTXT,
        "axes.edgecolor": "#BFBFBF",
        "axes.grid": True,
        "grid.color": GRID,
        "grid.linewidth": 0.6,
        "xtick.color": GRAYTXT,
        "ytick.color": GRAYTXT,
        "figure.dpi": 150,
        "savefig.dpi": 150,
        "savefig.bbox": "tight",
    })


def load_config(config_path: str) -> dict:
    with open(config_path, "r", encoding="utf-8") as f:
        return json.load(f)


def _to_dt(series):
    return pd.to_datetime(series, errors="coerce")


def _save(fig, path):
    fig.savefig(path, facecolor="white")
    plt.close(fig)
    print(f"    saved {path.name}")


# ---------------------------------------------------------------------------
# 1. Forecast completion trend vs baseline
# ---------------------------------------------------------------------------

def chart_forecast_trend(cfg, paths, out_dir, project):
    src = paths["stage_f"] / "snapshot_controlling.parquet"
    if not src.exists():
        print("    [skip] forecast_trend — Stage F output missing")
        return
    df = pd.read_parquet(src)
    df = df[df["milestone_finish"].notna()].copy()
    df["date"] = _to_dt(df["date"])
    df["finish"] = _to_dt(df["milestone_finish"])
    df = df.sort_values("date")

    fig, ax = plt.subplots(figsize=(10, 5.2))
    ax.plot(df["date"], df["finish"], color=NAVY, lw=2, marker="o", ms=4,
            label="Forecast completion (each weekly snapshot)")

    baseline = cfg["schedule"].get("baseline_date")
    if baseline:
        bdt = pd.Timestamp(baseline)
        ax.axhline(bdt, color=RED, ls="--", lw=1.5,
                   label=f"Baseline completion ({bdt.strftime('%b %#d, %Y')})")

    # annotate configured breakpoints
    for bp in cfg.get("charting", {}).get("forecast_trend_chart", {}).get("annotation_breakpoints", []):
        try:
            bpd = pd.Timestamp(bp["date"])
            row = df.iloc[(df["date"] - bpd).abs().argsort().iloc[0]]
            ax.annotate(bp.get("label", ""), xy=(row["date"], row["finish"]),
                        xytext=(0, 28), textcoords="offset points", ha="center",
                        fontsize=8, color=GRAYTXT,
                        arrowprops=dict(arrowstyle="->", color=GRAYTXT, lw=0.8))
        except Exception:
            continue

    ax.set_title(f"{project} — Forecast Completion Date, Week by Week")
    ax.set_ylabel("Forecast completion date")
    ax.set_xlabel("Snapshot date")
    ax.yaxis.set_major_formatter(mdates.DateFormatter("%b %Y"))
    ax.xaxis.set_major_formatter(mdates.DateFormatter("%b %Y"))
    ax.legend(loc="upper left", fontsize=8, framealpha=0.9)
    fig.autofmt_xdate(rotation=0, ha="center")
    _save(fig, out_dir / "forecast_trend.png")


# ---------------------------------------------------------------------------
# 2. Bucket variance trajectories  (reuses Stage E per snapshot)
# ---------------------------------------------------------------------------

def chart_bucket_trajectories(cfg, paths, out_dir, project):
    try:
        from construction_variance import build_construction_variance
        from critical_path import discover_snapshots
    except ImportError:
        print("    [skip] bucket_trajectories — needs construction_variance.py + critical_path.py")
        return
    try:
        snaps = discover_snapshots(cfg, None)
    except Exception as e:
        print(f"    [skip] bucket_trajectories — {e}")
        return

    # compute each snapshot's per-bucket net variance
    records = []
    for snap in snaps:
        try:
            tdf = pd.read_parquet(snap["tasks_path"])
            _, _, _, bsum, _ = build_construction_variance(tdf, cfg)
            if bsum.empty:
                continue
            for _, r in bsum.iterrows():
                records.append({"date": snap["date"], "bucket": r["bucket"],
                                "net": r["net_variance"]})
        except Exception:
            continue
    if not records:
        print("    [skip] bucket_trajectories — no bucket data computed")
        return
    traj = pd.DataFrame(records)
    traj["date"] = _to_dt(traj["date"])

    # pick Site Work + the top building buckets by latest absolute variance
    latest = traj.sort_values("date").groupby("bucket").last()
    building_names = set(cfg["buildings"]["names"])
    site = [b for b in latest.index if b not in building_names]
    top_buildings = (latest[latest.index.isin(building_names)]["net"].abs()
                     .sort_values(ascending=False).head(4).index.tolist())
    keep = [b for b in ["Site Work"] if b in latest.index] + \
           [b for b in site if b != "Site Work"][:2] + top_buildings
    keep = list(dict.fromkeys(keep))

    fig, ax = plt.subplots(figsize=(10, 5.2))
    for i, b in enumerate(keep):
        sub = traj[traj["bucket"] == b].sort_values("date")
        ax.plot(sub["date"], sub["net"], lw=1.8, marker="o", ms=3,
                color=PALETTE[i % len(PALETTE)], label=b)
    ax.axhline(0, color="#999999", lw=0.8)
    ax.set_title(f"{project} — Variance Build-Up by Bucket")
    ax.set_ylabel("Net bucket variance (working days)")
    ax.set_xlabel("Snapshot date")
    ax.xaxis.set_major_formatter(mdates.DateFormatter("%b %Y"))
    ax.legend(loc="upper left", fontsize=8, ncol=2, framealpha=0.9)
    fig.autofmt_xdate(rotation=0, ha="center")
    _save(fig, out_dir / "bucket_trajectories.png")


# ---------------------------------------------------------------------------
# 3. Driving-resource colored scatter
# ---------------------------------------------------------------------------

def chart_driving_resource(cfg, paths, out_dir, project):
    src = paths["stage_f"] / "snapshot_controlling.parquet"
    if not src.exists():
        print("    [skip] driving_resource — Stage F output missing")
        return
    df = pd.read_parquet(src)
    df = df[df["milestone_finish"].notna()].copy()
    df["date"] = _to_dt(df["date"])
    df["finish"] = _to_dt(df["milestone_finish"])
    df["res"] = df["controlling_resources"].fillna("(unassigned)").replace("", "(unassigned)")
    df = df.sort_values("date")

    # resources controlling more than one week get a color; singletons -> "other"
    counts = df["res"].value_counts()
    main = counts[counts > 1].index.tolist()
    color_map = {r: PALETTE[i % len(PALETTE)] for i, r in enumerate(main)}

    fig, ax = plt.subplots(figsize=(10, 5.2))
    ax.plot(df["date"], df["finish"], color="#BBBBBB", lw=1, zorder=1)
    for r in main:
        sub = df[df["res"] == r]
        ax.scatter(sub["date"], sub["finish"], s=42, color=color_map[r],
                   edgecolor="white", lw=0.5, label=r, zorder=3)
    other = df[~df["res"].isin(main)]
    if not other.empty:
        ax.scatter(other["date"], other["finish"], s=30, color="#AAB7B8",
                   edgecolor="white", lw=0.5, label="other (1 wk each)", zorder=2)

    baseline = cfg["schedule"].get("baseline_date")
    if baseline:
        ax.axhline(pd.Timestamp(baseline), color=RED, ls="--", lw=1.2, zorder=1)

    ax.set_title(f"{project} — Which Resource Controls the Finish Date, Week by Week")
    ax.set_ylabel("Forecast completion (driving path)")
    ax.set_xlabel("Snapshot date")
    ax.yaxis.set_major_formatter(mdates.DateFormatter("%b %Y"))
    ax.xaxis.set_major_formatter(mdates.DateFormatter("%b %Y"))
    ax.legend(loc="upper left", fontsize=7.5, ncol=2, title="Controlling resource",
              title_fontsize=8, framealpha=0.9)
    fig.autofmt_xdate(rotation=0, ha="center")
    _save(fig, out_dir / "driving_resource.png")


# ---------------------------------------------------------------------------
# 4. Delay-ledger waterfall
# ---------------------------------------------------------------------------

def chart_delay_waterfall(cfg, paths, out_dir, project):
    src = paths["stage_f"] / "waterfall_periods.parquet"
    if not src.exists():
        print("    [skip] delay_waterfall — Stage F output missing")
        return
    df = pd.read_parquet(src)
    if df.empty:
        print("    [skip] delay_waterfall — no control-periods")
        return

    fig, ax = plt.subplots(figsize=(11, 5.6))
    running = 0
    for i, (_, r) in enumerate(df.iterrows()):
        delta = r["net_days"]
        color = RED if delta > 0 else (GREEN if delta < 0 else "#999999")
        bottom = running if delta >= 0 else running + delta
        ax.bar(i, abs(delta), bottom=bottom, color=color, width=0.7,
               edgecolor="white", lw=0.4)
        running += delta
    ax.axhline(running, color=NAVY, ls="--", lw=1.2)
    ax.annotate(f"net {'+' if running>=0 else ''}{running} days",
                xy=(len(df) - 1, running), xytext=(0, 8),
                textcoords="offset points", ha="right", fontsize=9,
                color=NAVY, fontweight="bold")
    ax.axhline(0, color="#666666", lw=0.8)

    labels = [f"{r['controlling_name'][:26]}" for _, r in df.iterrows()]
    ax.set_xticks(range(len(df)))
    ax.set_xticklabels(labels, rotation=90, fontsize=6.5, ha="center")
    ax.set_title(f"{project} — Delay Ledger: Days Added to the Finish, by Controlling Activity")
    ax.set_ylabel("Calendar days added (red) / recovered (green)")
    _save(fig, out_dir / "delay_waterfall.png")


# ---------------------------------------------------------------------------
# 5. Net days by controlling resource  (horizontal bar)
# ---------------------------------------------------------------------------

def chart_resource_net_bar(cfg, paths, out_dir, project):
    src = paths["stage_f"] / "by_resource_net.parquet"
    if not src.exists():
        print("    [skip] resource_net_bar — Stage F output missing")
        return
    df = pd.read_parquet(src)
    if df.empty:
        print("    [skip] resource_net_bar — no resource data")
        return
    df = df.reindex(df["net_days"].abs().sort_values(ascending=True).index)

    fig, ax = plt.subplots(figsize=(9, max(4, 0.4 * len(df) + 1)))
    colors = [RED if v > 0 else (GREEN if v < 0 else "#999999") for v in df["net_days"]]
    ax.barh(df["controlling_resources"], df["net_days"], color=colors,
            edgecolor="white", lw=0.4)
    ax.axvline(0, color="#666666", lw=0.8)
    for y, v in enumerate(df["net_days"]):
        ax.annotate(f"{'+' if v>0 else ''}{int(v)}",
                    xy=(v, y), xytext=(4 if v >= 0 else -4, 0),
                    textcoords="offset points", va="center",
                    ha="left" if v >= 0 else "right", fontsize=8, color=GRAYTXT)
    ax.set_title(f"{project} — Net Finish-Date Movement by Controlling Resource")
    ax.set_xlabel("Net calendar days contributed to finish (contemporaneous)")
    ax.grid(axis="y", visible=False)
    _save(fig, out_dir / "resource_net_bar.png")


# ---------------------------------------------------------------------------
# 6. Building turnover lollipop
# ---------------------------------------------------------------------------

def chart_building_lollipop(cfg, paths, out_dir, project):
    src = paths["stage_g"] / "building_turnover.parquet"
    if not src.exists():
        print("    [skip] building_lollipop — Stage G output missing")
        return
    df = pd.read_parquet(src)
    df = df[df["baseline_finish"].notna() & df["forecast_finish"].notna()].copy()
    if df.empty:
        print("    [skip] building_lollipop — no turnover data")
        return
    df["bf"] = _to_dt(df["baseline_finish"])
    df["ff"] = _to_dt(df["forecast_finish"])
    df["slip"] = (df["ff"] - df["bf"]).dt.days
    df = df.sort_values("slip")

    fig, ax = plt.subplots(figsize=(10, max(4.5, 0.34 * len(df) + 1)))
    y = range(len(df))
    ax.hlines(y, df["bf"], df["ff"], color="#C9C9C9", lw=2, zorder=1)
    ax.scatter(df["bf"], y, color="#9AA7B1", s=45, zorder=2, label="Baseline turnover")
    ax.scatter(df["ff"], y, color=RED, s=55, zorder=3, label="Forecast turnover")
    for yi, (_, r) in zip(y, df.iterrows()):
        ax.annotate(f"+{int(r['slip'])}d", xy=(r["ff"], yi), xytext=(8, 0),
                    textcoords="offset points", va="center", fontsize=7.5, color=RED)
    ax.set_yticks(list(y))
    ax.set_yticklabels(df["building"])

    baseline = cfg["schedule"].get("baseline_date")
    if baseline:
        ax.axvline(pd.Timestamp(baseline), color=GRAYTXT, ls=":", lw=1,
                   label=f"baseline {pd.Timestamp(baseline).strftime('%b %#d')}")

    ax.set_title(f"{project} — Building Turnover: Baseline vs Forecast")
    ax.xaxis.set_major_formatter(mdates.DateFormatter("%b %Y"))
    ax.legend(loc="lower right", fontsize=8, framealpha=0.9)
    ax.grid(axis="y", visible=False)
    _save(fig, out_dir / "building_lollipop.png")


# ---------------------------------------------------------------------------
# 7. Float-health histogram
# ---------------------------------------------------------------------------

def chart_float_histogram(cfg, paths, out_dir, project):
    src = paths["stage_g"] / "float_health.parquet"
    if not src.exists():
        print("    [skip] float_histogram — Stage G output missing")
        return
    df = pd.read_parquet(src)
    if df.empty:
        print("    [skip] float_histogram — no float data")
        return

    # critical band gets the alert color, others a graded navy
    colors = []
    for b in df["band"]:
        colors.append(RED if "Critical" in str(b) else NAVY)

    fig, ax = plt.subplots(figsize=(9, 5))
    bars = ax.bar(df["band"], df["count"], color=colors, edgecolor="white", lw=0.5)
    total = df["count"].sum()
    for bar, (_, r) in zip(bars, df.iterrows()):
        pct = r["count"] / total * 100 if total else 0
        ax.annotate(f"{int(r['count'])}\n{pct:.0f}%",
                    xy=(bar.get_x() + bar.get_width() / 2, bar.get_height()),
                    xytext=(0, 4), textcoords="offset points", ha="center",
                    fontsize=8, color=GRAYTXT)
    ax.set_title(f"{project} — Float Health: Remaining Cushion")
    ax.set_ylabel("Incomplete construction tasks")
    ax.set_xlabel("Total slack band (working days)")
    ax.grid(axis="x", visible=False)
    _save(fig, out_dir / "float_histogram.png")


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

def main():
    parser = argparse.ArgumentParser(description="Stage K — generate the seven core charts")
    parser.add_argument("--config", default="project_config.json")
    args = parser.parse_args()

    cfg = load_config(args.config)
    project = cfg["project"]["name"]
    output_root = Path(cfg["paths"]["output_root"])
    out_dir = output_root / "stage_k"
    out_dir.mkdir(parents=True, exist_ok=True)

    paths = {
        "stage_e": output_root / "stage_e",
        "stage_f": output_root / "stage_f",
        "stage_g": output_root / "stage_g",
        "stage_c": output_root / "stage_c",
    }

    print(f"\n{'='*60}")
    print(f"  Stage K — Charting")
    print(f"  Project : {project}")
    print(f"  Output  : {out_dir}")
    print(f"{'='*60}\n")

    register_fonts()

    print("  Generating charts:")
    chart_forecast_trend(cfg, paths, out_dir, project)
    chart_bucket_trajectories(cfg, paths, out_dir, project)
    chart_driving_resource(cfg, paths, out_dir, project)
    chart_delay_waterfall(cfg, paths, out_dir, project)
    chart_resource_net_bar(cfg, paths, out_dir, project)
    chart_building_lollipop(cfg, paths, out_dir, project)
    chart_float_histogram(cfg, paths, out_dir, project)

    print(f"\n{'='*60}")
    print(f"  Charts written to {out_dir}")
    print(f"{'='*60}\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())

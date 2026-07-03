"""
Stage L — PDF Assembly, Cover, and TOC  (Methodology: Harrison house style)
============================================================================
Two-pass build:
  Pass 1 — body.pdf  (Parts I–VI + Appendix A, with page numbers)
  Pass 2 — cover_toc.pdf  (1 cover + 1 TOC, page refs = body page + 2)
  Final  — merged via pypdf: cover_toc.pdf prepended to body.pdf

Narrative text comes from stage_j/narrative.json (produced by Stage J /
Claude Opus).  If that file is absent, placeholder text is inserted so the
body PDF still renders with correct structure and data.

Data sourced from Stage E/F/G/H parquet outputs.
Charts sourced from Stage K PNGs (embedded as Image flowables).

Usage:
  python assemble_pdf.py [--config project_config.json]
"""

import argparse
import json
import sys
from datetime import datetime
from io import BytesIO
from pathlib import Path

import pandas as pd

# ReportLab
from reportlab.lib import colors
from reportlab.lib.pagesizes import letter
from reportlab.lib.styles import ParagraphStyle, getSampleStyleSheet
from reportlab.lib.units import inch
from reportlab.pdfbase import pdfmetrics
from reportlab.pdfbase.ttfonts import TTFont
from reportlab.platypus import (
    BaseDocTemplate, Flowable, Frame, Image, PageBreak, PageTemplate,
    Paragraph, Spacer, Table, TableStyle, HRFlowable, KeepTogether,
)
from reportlab.lib.enums import TA_LEFT, TA_CENTER, TA_JUSTIFY

# pypdf for merging
from pypdf import PdfReader, PdfWriter


# ─────────────────────────────────────────────────────────────────────────────
# Constants
# ─────────────────────────────────────────────────────────────────────────────

NAVY      = colors.HexColor("#1F4E78")
LT_NAVY   = colors.HexColor("#D6E4F0")  # tile background
RED       = colors.HexColor("#C00000")
RED_TINT  = colors.HexColor("#FCE4E4")
ZEBRA     = colors.HexColor("#F2F6FB")
GRAY_TXT  = colors.HexColor("#606060")
WHITE     = colors.white
BLACK     = colors.black

PW, PH = letter          # 612 × 792 pt
LM = RM = 0.85 * inch
TM = BM = 0.75 * inch
BODY_W = PW - LM - RM   # ≈ 442 pt

# Installer bundles the 4 Carlito TTFs into a "fonts" folder alongside this
# script (see PA-Pipeline-Setup.cs's CARLITO_FONTS_RESOURCE_NAME) - resolve
# relative to this file's own location, not a Linux-only system font path.
CARLITO_DIR = Path(__file__).resolve().parent / "fonts"


# ─────────────────────────────────────────────────────────────────────────────
# Font registration
# ─────────────────────────────────────────────────────────────────────────────

def register_fonts():
    """Register Carlito; fall back to Helvetica family if absent.

    The fallback must actually REGISTER something under the Carlito names,
    not just skip registration - every style/setFont call in this file
    references "Carlito"/"Carlito-Bold"/etc. by name, and reportlab raises
    KeyError on first use of an unregistered name rather than silently
    substituting a default font."""
    wanted = {
        "Carlito":        ("Carlito-Regular.ttf",   "Helvetica"),
        "Carlito-Bold":   ("Carlito-Bold.ttf",       "Helvetica-Bold"),
        "Carlito-It":     ("Carlito-Italic.ttf",     "Helvetica-Oblique"),
        "Carlito-BoldIt": ("Carlito-BoldItalic.ttf", "Helvetica-BoldOblique"),
    }
    for name, (fn, fallback) in wanted.items():
        p = CARLITO_DIR / fn
        if p.exists():
            pdfmetrics.registerFont(TTFont(name, str(p)))
        else:
            print(f"  NOTE: {fn} not found — using {fallback} for {name}")
            pdfmetrics.registerFont(pdfmetrics.Font(name, fallback, "WinAnsiEncoding"))

    # register a family so reportlab <b> / <i> tags work in Paragraphs
    try:
        from reportlab.pdfbase.pdfmetrics import registerFontFamily
        registerFontFamily("Carlito",
                           normal="Carlito", bold="Carlito-Bold",
                           italic="Carlito-It", boldItalic="Carlito-BoldIt")
    except Exception:
        pass


# ─────────────────────────────────────────────────────────────────────────────
# Section titles — single source of truth for both the in-body Part header
# (_part_header calls below) and the TOC entry (TOC_SECTIONS in main()).
# Previously each was hardcoded separately and had drifted apart: the TOC
# claimed Part I covered a "Nine-Month" schedule trend (true of no project in
# particular - it's not derived from any project's actual snapshot count),
# and Parts II/IV/VI's real headers carried parenthetical subtitles the TOC
# entries silently dropped. Keying both off the same dict makes that class of
# drift impossible.
# ─────────────────────────────────────────────────────────────────────────────
SECTION_TITLES = {
    "part_i":     "Part I — How We Got Here: the Schedule Trend",
    "part_ii":    "Part II — What Drove the Finish Date (Critical-Path Delay Analysis)",
    "part_iii":   "Part III — Where the Variance Sits Now",
    "part_iv":    "Part IV — Path to Completion (Where the Job Is Headed)",
    "part_v":     "Part V — Method & Governance",
    "part_vi":    "Part VI — Buyout Delay Analysis (How the Delays Happened)",
    "appendix_a": "Appendix A — Full Task-Level Data (All Buckets)",
}


# ─────────────────────────────────────────────────────────────────────────────
# Style sheet
# ─────────────────────────────────────────────────────────────────────────────

def make_styles():
    base = getSampleStyleSheet()
    F = "Carlito"
    FB = "Carlito-Bold"

    def s(name, **kw):
        defaults = dict(fontName=F, fontSize=10, leading=14,
                        textColor=BLACK, spaceAfter=4)
        defaults.update(kw)
        return ParagraphStyle(name, **defaults)

    return {
        # doc title on cover
        "cover_title": s("cover_title", fontName=FB, fontSize=28, textColor=NAVY,
                          leading=34, spaceAfter=6),
        "cover_sub":   s("cover_sub", fontSize=11, textColor=GRAY_TXT, leading=15),
        # Part header band (used as a Table)
        "part_label":  s("part_label", fontName=FB, fontSize=14, textColor=WHITE,
                          leading=18, spaceAfter=0),
        # Section heading (navy, bold)
        "h1": s("h1", fontName=FB, fontSize=13, textColor=NAVY, leading=17,
                 spaceBefore=14, spaceAfter=6),
        "h2": s("h2", fontName=FB, fontSize=11, textColor=NAVY, leading=15,
                 spaceBefore=10, spaceAfter=4),
        "h3": s("h3", fontName=FB, fontSize=10, textColor=NAVY, leading=14,
                 spaceBefore=7, spaceAfter=3),
        # Body
        "body":    s("body", alignment=TA_JUSTIFY, leading=15, spaceAfter=6),
        "body_c":  s("body_c", alignment=TA_CENTER, leading=14),
        "caption": s("caption", fontSize=8.5, textColor=GRAY_TXT, leading=12,
                      alignment=TA_CENTER, spaceAfter=8),
        # Table cells
        "th": s("th", fontName=FB, fontSize=9, textColor=WHITE, leading=12,
                 alignment=TA_CENTER),
        "td": s("td", fontSize=9, leading=12),
        "td_r": s("td_r", fontSize=9, leading=12, alignment=TA_CENTER),
        "td_bold": s("td_bold", fontName=FB, fontSize=9, leading=12),
        # KPI tile
        "kpi_val": s("kpi_val", fontName=FB, fontSize=20, textColor=NAVY,
                      leading=24, alignment=TA_CENTER),
        "kpi_lbl": s("kpi_lbl", fontSize=8.5, textColor=GRAY_TXT,
                      leading=12, alignment=TA_CENTER),
        # TOC
        "toc_h": s("toc_h", fontName=FB, fontSize=10, textColor=NAVY,
                    spaceBefore=10, spaceAfter=2),
        "toc":   s("toc", fontSize=10, leading=16),
        # bullet
        "bullet": s("bullet", leading=15, leftIndent=14, firstLineIndent=-14,
                    spaceAfter=4, spaceBefore=2),
    }


# ─────────────────────────────────────────────────────────────────────────────
# Page templates (body pages: header line + footer page number)
# ─────────────────────────────────────────────────────────────────────────────

class _Bookmark(Flowable):
    """Zero-size flowable that records which page it landed on.

    Used for automatic TOC page numbers: inserted as the first item of each
    section's flowables, it draws nothing, but _BriefDoc.afterFlowable() reads
    its .key once reportlab has actually placed it, so the recorded page is
    correct even if layout pushes the section's real content to a new page."""
    def __init__(self, key):
        Flowable.__init__(self)
        self.key = key

    def wrap(self, availWidth, availHeight):
        return (0, 0)

    def draw(self):
        pass


class _BriefDoc(BaseDocTemplate):
    """Custom doc template that stores the total page count for the footer,
    and (via afterFlowable) which page each _Bookmark landed on."""
    def __init__(self, filename, total_pages, section_pages=None, **kw):
        super().__init__(filename, **kw)
        self.total_pages = total_pages
        self.section_pages = section_pages if section_pages is not None else {}

    def afterFlowable(self, flowable):
        if isinstance(flowable, _Bookmark):
            self.section_pages[flowable.key] = self.page


def _make_page_fns(cfg, total_pages, page_offset=0):
    project = cfg["project"]["name"]
    status  = cfg["project"].get("analysis_status_date", "")

    def _draw(canvas, doc):
        canvas.saveState()
        # header rule
        canvas.setStrokeColor(NAVY)
        canvas.setLineWidth(0.5)
        canvas.line(LM, PH - TM + 4, PW - RM, PH - TM + 4)
        # header text
        canvas.setFont("Carlito", 8.5)
        canvas.setFillColor(GRAY_TXT)
        canvas.drawString(LM, PH - TM + 7, f"{project}  |  Executive Schedule Brief  |  {status}")
        # footer page number. page_offset = number of front-matter pages
        # (cover + TOC) that precede the body in the merged PDF, so the printed
        # number matches the page's true position in the final file AND the
        # TOC's page references (which are on the merged basis).
        canvas.setFillColor(GRAY_TXT)
        canvas.drawCentredString(PW / 2, BM - 14,
                                 f"Page {doc.page + page_offset} of {total_pages}")
        canvas.restoreState()

    return _draw, _draw


def build_body_doc(path, story, cfg, total_pages=999, page_offset=0, section_pages=None):
    """Build and save the body PDF. If section_pages (a dict) is passed, it is
    populated in place with {bookmark_key: body-relative page number}."""
    draw_fn, _ = _make_page_fns(cfg, total_pages, page_offset)
    doc = _BriefDoc(str(path), total_pages, section_pages=section_pages,
                    pagesize=letter,
                    leftMargin=LM, rightMargin=RM,
                    topMargin=TM, bottomMargin=BM)
    frame = Frame(LM, BM, BODY_W, PH - TM - BM, id="body")
    tmpl  = PageTemplate(id="main", frames=[frame],
                         onPage=draw_fn, onPageEnd=draw_fn)
    doc.addPageTemplates([tmpl])
    doc.build(story)
    # return actual page count
    return len(PdfReader(str(path)).pages)


# ─────────────────────────────────────────────────────────────────────────────
# Shared helpers
# ─────────────────────────────────────────────────────────────────────────────

def _load_parquet(path):
    if path.exists():
        return pd.read_parquet(path)
    return pd.DataFrame()


def buyout_in_scope(output_root) -> bool:
    """Read Stage H's definitive out-of-scope signal. Part VI (buyout) is
    included only when Stage H reported buyout_in_scope=true. A missing or
    unreadable report is treated as out of scope, so a no-buyout project (or a
    project where Stage H was skipped) produces a clean brief with no empty
    Part VI shell. Stage H writes buyout_in_scope=false explicitly whenever
    the project has no buyout phase."""
    rpt = output_root / "stage_h" / "buyout_report.json"
    if not rpt.exists():
        return False
    try:
        return bool(json.loads(rpt.read_text(encoding="utf-8")).get("buyout_in_scope", False))
    except Exception:
        return False


def _chart(path, width=BODY_W, caption=None, ST=None):
    """Return [Image, caption_para] flowables if the PNG exists."""
    out = []
    if Path(path).exists():
        img = Image(str(path), width=width, height=width * 0.52)
        img.hAlign = "CENTER"
        out.append(img)
        if caption and ST:
            out.append(Paragraph(caption, ST["caption"]))
    return out


def _part_header(title, ST):
    """Navy band with Part title."""
    t = Table([[Paragraph(title, ST["part_label"])]],
              colWidths=[BODY_W])
    t.setStyle(TableStyle([
        ("BACKGROUND", (0, 0), (-1, -1), NAVY),
        ("TOPPADDING",    (0, 0), (-1, -1), 8),
        ("BOTTOMPADDING", (0, 0), (-1, -1), 8),
        ("LEFTPADDING",   (0, 0), (-1, -1), 10),
    ]))
    return [Spacer(1, 8), t, Spacer(1, 8)]


def _var_table(df, col_specs, ST, show_header=True):
    """
    Generic styled variance table.
    col_specs: list of (header_str, df_col, width_pt, align, is_var)
    """
    headers  = [c[0] for c in col_specs]
    cols_w   = [c[2] for c in col_specs]
    is_var   = [c[4] for c in col_specs]
    aligns   = [c[3] for c in col_specs]

    data = []
    if show_header:
        data.append([Paragraph(h, ST["th"]) for h in headers])
    for _, row in df.iterrows():
        r = []
        for i, (_, col, _, align, _) in enumerate(col_specs):
            v = row.get(col, "")
            if pd.isna(v) or v is None:
                v = "n/a"
            elif isinstance(v, float):
                v = f"{v:+.1f}" if is_var[i] else f"{v:.1f}"
            elif isinstance(v, int) and is_var[i]:
                v = f"{v:+d}"
            st = ST["td_r"] if align == "c" else ST["td"]
            r.append(Paragraph(str(v), st))
        data.append(r)

    if not data:
        return []
    t = Table(data, colWidths=cols_w, repeatRows=1 if show_header else 0)
    style_cmds = [
        ("GRID",       (0, 0), (-1, -1), 0.25, colors.HexColor("#D0D0D0")),
        ("TOPPADDING",    (0, 0), (-1, -1), 3),
        ("BOTTOMPADDING", (0, 0), (-1, -1), 3),
        ("LEFTPADDING",   (0, 0), (-1, -1), 4),
        ("RIGHTPADDING",  (0, 0), (-1, -1), 4),
    ]
    if show_header:
        style_cmds += [
            ("BACKGROUND",   (0, 0), (-1, 0), NAVY),
            ("ROWBACKGROUNDS", (0, 1), (-1, -1), [WHITE, ZEBRA]),
        ]
    # red-tint variance columns
    for col_i, (_, _, _, _, isv) in enumerate(col_specs):
        if isv and show_header:
            for row_i in range(1, len(data)):
                style_cmds.append(
                    ("BACKGROUND", (col_i, row_i), (col_i, row_i), RED_TINT))
    t.setStyle(TableStyle(style_cmds))
    return [t, Spacer(1, 6)]


def _fmt_date(v):
    try:
        return pd.Timestamp(v).strftime("%b %#d, %Y")
    except Exception:
        return str(v) if v else ""


# ─────────────────────────────────────────────────────────────────────────────
# Load narrative
# ─────────────────────────────────────────────────────────────────────────────

PLACEHOLDER = ("[NARRATIVE PLACEHOLDER — run Stage J (Opus) to generate "
               "the executive narrative for this section.]")

def load_narrative(output_root):
    p = output_root / "stage_j" / "narrative.json"
    if p.exists():
        return json.loads(p.read_text(encoding="utf-8"))
    return {}


def narr(key, narrative, ST):
    text = narrative.get(key, PLACEHOLDER)
    return [Paragraph(text, ST["body"]), Spacer(1, 4)]


# ─────────────────────────────────────────────────────────────────────────────
# KPI derivation from stage outputs
# ─────────────────────────────────────────────────────────────────────────────

def derive_kpis(output_root, cfg):
    """Pull headline KPI values from stage parquet outputs."""
    kpis = {
        "forecast_completion": "—",
        "credible_range":      "—",
        "construction_pct":    "—",
        "weeks_behind":        "—",
        "buildings_in_progress": "—",
        "tight_float_pct":     "—",
    }
    try:
        sc = _load_parquet(output_root / "stage_f" / "snapshot_controlling.parquet")
        if not sc.empty and "milestone_finish" in sc.columns:
            latest = sc.dropna(subset=["milestone_finish"]).iloc[-1]
            ts = pd.Timestamp(latest["milestone_finish"])
            kpis["forecast_completion"] = ts.strftime("%#d %b %Y") if pd.notna(ts) else "—"
        cr = output_root / "stage_g" / "completion_range.json"
        if cr.exists():
            crj = json.loads(cr.read_text())
            if crj.get("available"):
                e = pd.Timestamp(crj["earliest_forecast"]).strftime("%#d %b")
                l = pd.Timestamp(crj["latest_forecast"]).strftime("%#d %b")
                kpis["credible_range"] = f"{e} – {l}"
    except Exception:
        pass
    try:
        # construction % complete — average across buildings from turnover
        bt = _load_parquet(output_root / "stage_g" / "building_turnover.parquet")
        if not bt.empty and "pct_complete" in bt.columns:
            pct = bt["pct_complete"].mean()
            kpis["construction_pct"] = f"{pct:.0f}%"
        # weeks behind
        baseline = cfg["schedule"].get("baseline_date")
        sc_filt = _load_parquet(output_root / "stage_f" / "snapshot_controlling.parquet")
        if baseline and not sc_filt.empty and "milestone_finish" in sc_filt.columns:
            row = sc_filt.dropna(subset=["milestone_finish"]).iloc[-1]
            slip = (pd.Timestamp(row["milestone_finish"]) - pd.Timestamp(baseline)).days
            if slip > 0:
                kpis["weeks_behind"] = f"~{round(slip / 7)} wks"
        # buildings
        if not bt.empty:
            total = len(bt)
            done  = int((bt["status"] == "Complete").sum())
            kpis["buildings_in_progress"] = str(total - done)
    except Exception:
        pass
    try:
        fh = _load_parquet(output_root / "stage_g" / "float_health.parquet")
        if not fh.empty:
            tb = cfg.get("charting", {}).get("float_health_bands_days", [0, 5])[1]
            key = f"within_{tb}_days_pct"
            fs  = output_root / "stage_g" / "forward_report.json"
            if fs.exists():
                rep = json.loads(fs.read_text())
                pct = rep.get("float_summary", {}).get(key)
                if pct is not None:
                    kpis["tight_float_pct"] = f"{pct:.0f}%"
    except Exception:
        pass
    return kpis


# ─────────────────────────────────────────────────────────────────────────────
# Section builders
# ─────────────────────────────────────────────────────────────────────────────

def section_dashboard(cfg, output_root, narrative, ST, kpis):
    """Page 1 — Executive Status Dashboard."""
    project = cfg["project"]["name"]
    status  = cfg["project"].get("analysis_status_date", "")

    story = []
    story.append(Paragraph(project, ST["cover_title"]))
    story.append(Paragraph(
        f"Executive Status Dashboard  |  Construction Phase  |  As of {status}  |  "
        "<b>Read this page first; Parts I–VI follow</b>", ST["cover_sub"]))
    story.append(HRFlowable(width=BODY_W, thickness=1.5, color=NAVY, spaceAfter=10))

    # KPI tiles — 6 cells in one row
    tile_w = BODY_W / 6
    labels = ["Forecast completion", "Credible range", "Construction complete",
              "Behind baseline", "Buildings in progress", "Remaining work\n≤5 days float"]
    values = [kpis["forecast_completion"], kpis["credible_range"],
              kpis["construction_pct"], kpis["weeks_behind"],
              kpis["buildings_in_progress"], kpis["tight_float_pct"]]
    tiles  = [[Paragraph(v, ST["kpi_val"]), Paragraph(l, ST["kpi_lbl"])]
              for v, l in zip(values, labels)]
    flat   = [[cell for pair in tiles for cell in pair]]  # 12 cols
    t = Table([flat[0]], colWidths=[tile_w] * 6)
    t.setStyle(TableStyle([
        ("BACKGROUND", (0, 0), (-1, -1), LT_NAVY),
        ("BOX",        (0, 0), (-1, -1), 0.5, NAVY),
        ("INNERGRID",  (0, 0), (-1, -1), 0.5, NAVY),
        ("VALIGN",     (0, 0), (-1, -1), "MIDDLE"),
        ("TOPPADDING",    (0, 0), (-1, -1), 10),
        ("BOTTOMPADDING", (0, 0), (-1, -1), 10),
    ]))
    # actual tile table: 2-row (value / label) repeated 6 times → nested
    tile_rows = [[Paragraph(v, ST["kpi_val"])] for v in values]
    lbl_rows  = [[Paragraph(l, ST["kpi_lbl"])] for l in labels]
    all_tiles = []
    for val_p, lbl_p in zip(tile_rows, lbl_rows):
        sub = Table([val_p, lbl_p], colWidths=[tile_w - 4])
        sub.setStyle(TableStyle([
            ("TOPPADDING",    (0, 0), (-1, -1), 5),
            ("BOTTOMPADDING", (0, 0), (-1, -1), 5),
            ("LEFTPADDING",   (0, 0), (-1, -1), 4),
            ("RIGHTPADDING",  (0, 0), (-1, -1), 4),
        ]))
        all_tiles.append(sub)
    tile_t = Table([all_tiles], colWidths=[tile_w] * 6)
    tile_t.setStyle(TableStyle([
        ("BACKGROUND", (0, 0), (-1, -1), LT_NAVY),
        ("INNERGRID",  (0, 0), (-1, -1), 0.5, NAVY),
        ("BOX",        (0, 0), (-1, -1), 1.0, NAVY),
        ("VALIGN",     (0, 0), (-1, -1), "MIDDLE"),
    ]))
    story.append(tile_t)
    story.append(Spacer(1, 10))

    # Bottom line
    story.append(Paragraph("Bottom Line", ST["h1"]))
    story += narr("bottom_line", narrative, ST)

    # Top risks
    story.append(Paragraph("Top Risks Right Now", ST["h1"]))
    for bullet_key in ["risk_1", "risk_2", "risk_3", "risk_4"]:
        txt = narrative.get(bullet_key, "")
        if txt:
            story.append(Paragraph(f"• {txt}", ST["bullet"]))
    if not any(narrative.get(k) for k in ["risk_1","risk_2","risk_3","risk_4"]):
        story.append(Paragraph(PLACEHOLDER, ST["body"]))

    # Status by dimension table
    story.append(Spacer(1, 8))
    story.append(Paragraph("Status by Dimension", ST["h1"]))
    dims = narrative.get("status_by_dimension", [
        ["Schedule",                  "—",    "—"],
        ["Critical path",             "—",    "—"],
        ["Float / risk",              "—",    "—"],
        ["Turnover",                  "—",    "—"],
        ["Cost / budget",             "Not in this brief", "Requires Sage 300 CRE integration"],
        ["Open items (RFI/submittal)","Not in this brief", "Available in ACC / Autodesk Build"],
    ])
    dim_data = [[Paragraph(h, ST["th"]) for h in ["Dimension", "Status", "Note"]]] + \
               [[Paragraph(c, ST["td"]) for c in r] for r in dims]
    dim_t = Table(dim_data, colWidths=[1.2*inch, 1.5*inch, BODY_W-2.7*inch])
    dim_t.setStyle(TableStyle([
        ("BACKGROUND",  (0, 0), (-1, 0), NAVY),
        ("ROWBACKGROUNDS", (0, 1), (-1, -1), [WHITE, ZEBRA]),
        ("GRID",        (0, 0), (-1, -1), 0.25, colors.HexColor("#D0D0D0")),
        ("TOPPADDING",    (0, 0), (-1, -1), 4),
        ("BOTTOMPADDING", (0, 0), (-1, -1), 4),
        ("LEFTPADDING",   (0, 0), (-1, -1), 5),
    ]))
    story.append(dim_t)

    # Decisions requested (5.9) — 2-4 lines, Opus-synthesized alongside
    # questions-for-next-review under the same anti-hallucination rules
    decisions = [d for d in (narrative.get("decisions_requested") or []) if str(d).strip()]
    if decisions:
        story.append(Paragraph("Decisions Requested / Recommended Actions", ST["h1"]))
        for d in decisions[:4]:
            story.append(Paragraph(f"• {d}", ST["body"]))

    # What changed since the last brief (5.9) — conditional element for
    # recurring briefs; absent entirely on a first brief (paths.prior_brief unset)
    wc = str(narrative.get("what_changed_since_last_brief", "") or "").strip()
    if wc:
        story.append(Paragraph("What Changed Since the Last Brief", ST["h1"]))
        story.append(Paragraph(wc, ST["body"]))

    story.append(PageBreak())
    return story


def section_overview(narrative, ST):
    story = []
    story.append(Paragraph("Executive Overview", ST["h1"]))
    story += narr("executive_overview", narrative, ST)
    story.append(PageBreak())
    return story


def section_part_i(output_root, narrative, ST):
    story = _part_header(SECTION_TITLES["part_i"], ST)
    story += narr("part_i_intro", narrative, ST)
    k = output_root / "stage_k"
    story += _chart(k / "forecast_trend.png", BODY_W,
                    "Forecast completion vs. the baseline, each weekly snapshot.", ST)
    story += narr("part_i_trend_analysis", narrative, ST)
    story += _chart(k / "bucket_trajectories.png", BODY_W,
                    "Cumulative net variance by bucket across all snapshots.", ST)
    story += narr("part_i_bucket_analysis", narrative, ST)
    story.append(PageBreak())
    return story


def section_part_ii(output_root, narrative, ST):
    story = _part_header(SECTION_TITLES["part_ii"], ST)
    story += narr("part_ii_intro", narrative, ST)

    # Controlling timeline table
    tl = _load_parquet(output_root / "stage_f" / "controlling_timeline.parquet")
    if not tl.empty:
        story.append(Paragraph("Controlling Activity & Resource — Timeline", ST["h2"]))
        cols = [
            ("Period", "from_date", 1.1*inch, "c", False),
            ("Controlling activity", "controlling_name", 1.9*inch, "l", False),
            ("Resource", "controlling_resources", 1.1*inch, "l", False),
            ("Building", "controlling_bucket", 1.1*inch, "l", False),
            ("Driving finish", "driving_finish", 1.1*inch, "c", False),
        ]
        display = tl.copy()
        display["from_date"] = display.apply(
            lambda r: f"{_fmt_date(r['from_date'])} – {_fmt_date(r['to_date'])}"
                      if str(r["from_date"]) != str(r["to_date"])
                      else _fmt_date(r["from_date"]), axis=1)
        display["driving_finish"] = display["driving_finish"].map(_fmt_date)
        story += _var_table(display, cols, ST)

    k = output_root / "stage_k"
    story += _chart(k / "delay_waterfall.png", BODY_W,
                    "Each bar is one control-period's net effect on the finish; "
                    "red adds days, green recovers them.", ST)
    story += _chart(k / "resource_net_bar.png", BODY_W * 0.85,
                    "Net calendar days while each resource controlled the finish.", ST)
    story += narr("part_ii_ledger_analysis", narrative, ST)
    story.append(PageBreak())
    return story


def section_part_iii(output_root, narrative, ST, cfg):
    story = _part_header(SECTION_TITLES["part_iii"], ST)
    status = cfg["project"].get("analysis_status_date", "")
    story += narr("part_iii_intro", narrative, ST)

    # Bucket summary
    bs = _load_parquet(output_root / "stage_e" / "bucket_summary.parquet")
    if not bs.empty:
        story.append(Paragraph("Variance by Bucket", ST["h2"]))
        cols = [
            ("Bucket",    "bucket",      2.0*inch, "l", False),
            ("Lines",     "lines",       0.5*inch, "c", False),
            ("Over (n)",  "over_count",  0.6*inch, "c", False),
            ("Over (d)",  "over_days",   0.7*inch, "c", True),
            ("Under (n)", "under_count", 0.6*inch, "c", False),
            ("Under (d)", "under_days",  0.7*inch, "c", True),
            ("Net (d)",   "net_variance",0.7*inch, "c", True),
        ]
        story += _var_table(bs, cols, ST)

    # Top-N
    tn = _load_parquet(output_root / "stage_e" / "top_n_all_buckets.parquet")
    if not tn.empty:
        story.append(Paragraph(f"Top {len(tn)} Duration Variances — Across All Buckets", ST["h2"]))
        story.append(Paragraph(
            f"Ranked by absolute span variance (Actual − Baseline working days). As of {status}.", ST["caption"]))
        cols = [
            ("Rank",       "rank",          0.38*inch, "c", False),
            ("Bucket",     "bucket",        1.1*inch,  "l", False),
            ("Task Name",  "task_name",     1.5*inch,  "l", False),
            ("Resources",  "resources",     0.9*inch,  "l", False),
            ("Inst.",      "instances",     0.36*inch, "c", False),
            ("Base (d)",   "baseline_span", 0.52*inch, "c", False),
            ("Act. (d)",   "actual_span",   0.52*inch, "c", False),
            ("Var (d)",    "abs_variance",  0.52*inch, "c", True),
        ]
        story += _var_table(tn, cols, ST)
        story.append(PageBreak())

    # Per-building top-N tables
    pb = _load_parquet(output_root / "stage_e" / "per_building_top.parquet")
    if not pb.empty:
        story.append(Paragraph("Per-Building Top Variances", ST["h2"]))
        story += narr("part_iii_per_building_note", narrative, ST)
        for bucket, grp in pb.groupby("bucket", sort=False):
            story.append(Paragraph(bucket, ST["h3"]))
            cols = [
                ("#",          "building_rank", 0.28*inch, "c", False),
                ("Task Name",  "task_name",     2.3*inch,  "l", False),
                ("Resources",  "resources",     1.0*inch,  "l", False),
                ("Inst.",      "instances",     0.35*inch, "c", False),
                ("Base (d)",   "baseline_span", 0.52*inch, "c", False),
                ("Act. (d)",   "actual_span",   0.52*inch, "c", False),
                ("Var (d)",    "abs_variance",  0.52*inch, "c", True),
            ]
            story += _var_table(grp, cols, ST)
            story.append(KeepTogether([Spacer(1, 2)]))

    story.append(PageBreak())
    return story


def section_part_iv(output_root, narrative, ST, cfg):
    story = _part_header(SECTION_TITLES["part_iv"], ST)
    story += narr("part_iv_intro", narrative, ST)
    k = output_root / "stage_k"

    # Building turnover table
    bt = _load_parquet(output_root / "stage_g" / "building_turnover.parquet")
    if not bt.empty:
        story.append(Paragraph("Building Turnover — Baseline vs Forecast", ST["h2"]))
        story += _chart(k / "building_lollipop.png", BODY_W,
                        "Grey marker = baseline completion; red = forecast.", ST)
        display = bt.copy()
        display["baseline_finish"] = display["baseline_finish"].map(_fmt_date)
        display["forecast_finish"] = display["forecast_finish"].map(_fmt_date)
        cols = [
            ("Building",  "building",        1.3*inch, "l", False),
            ("% Done",    "pct_complete",    0.5*inch, "c", False),
            ("Baseline",  "baseline_finish", 0.9*inch, "c", False),
            ("Forecast",  "forecast_finish", 0.9*inch, "c", False),
            ("Slip (d)",  "slip_days",       0.6*inch, "c", True),
            ("Status",    "status",          0.9*inch, "c", False),
        ]
        story += _var_table(display, cols, ST)

    # Float health
    fh = _load_parquet(output_root / "stage_g" / "float_health.parquet")
    if not fh.empty:
        story.append(Paragraph("Float Health — Remaining Cushion", ST["h2"]))
        story += _chart(k / "float_histogram.png", BODY_W * 0.75,
                        "Incomplete construction tasks by total slack band.", ST)

    # Completion range
    cr_path = output_root / "stage_g" / "completion_range.json"
    if cr_path.exists():
        cr = json.loads(cr_path.read_text())
        if cr.get("available"):
            story.append(Paragraph("Completion Forecast — A Range, Not a Point", ST["h2"]))
            story.append(Paragraph(
                f"Over the last {cr['snapshots_used']} weekly snapshots the driving-path forecast "
                f"finish spanned <b>{cr['earliest_forecast']}</b> to <b>{cr['latest_forecast']}</b> "
                f"({cr['range_days']} calendar days), with a maximum week-to-week swing of "
                f"{cr['max_week_swing_days']} days. Current forecast: <b>{cr['current_forecast']}</b>.",
                ST["body"]))

    # Slip velocity (5.8) — explicitly an empirical trend read, not a forecast
    fwd_path = output_root / "stage_g" / "forward_report.json"
    if fwd_path.exists():
        try:
            vel = json.loads(fwd_path.read_text()).get("slip_velocity", {})
        except Exception:
            vel = {}
        if vel.get("available"):
            if vel.get("diverging"):
                vtxt = (f"The forecast finish has been moving <b>{vel['slope_days_per_week']:+.1f} days "
                        f"per week</b> over the trend window — slipping at or faster than one day per "
                        f"day, so the current trend does not converge on a completion date. This is an "
                        f"empirical read of recent movement, not a forecast.")
            else:
                vtxt = (f"At the current trend ({vel['slope_days_per_week']:+.1f} days of finish movement "
                        f"per week over the trend window), completion projects to "
                        f"<b>{vel['projected_completion']}</b>. This is an empirical trend read — the same "
                        f"epistemics as the completion range above — not a forecast.")
            story.append(Paragraph(vtxt, ST["body"]))

    # S-curve + float erosion (5.8 / 5.10)
    story += _chart(k / "s_curve.png", BODY_W * 0.85,
                    "Planned vs actual percent complete (baseline-duration weighted).", ST)
    story += _chart(k / "float_erosion.png", BODY_W * 0.85,
                    "Total-float trajectory across snapshots — the time-series companion "
                    "to the float histogram.", ST)

    # Per-building driving paths (5.7)
    bp = _load_parquet(output_root / "stage_g" / "building_driving_paths.parquet")
    if not bp.empty:
        story.append(Paragraph("Per-Building Driving Paths — What Each Building Is Waiting On", ST["h2"]))
        display = bp.copy()
        for c in ("anchor_finish", "controlling_finish"):
            display[c] = display[c].map(lambda v: _fmt_date(v))
        cols = [
            ("Building",   "building",              1.15*inch, "l", False),
            ("Controls",   "controlling_activity",  1.7*inch,  "l", False),
            ("Resource",   "controlling_resources", 1.0*inch,  "l", False),
            ("Ctrl Finish","controlling_finish",    0.8*inch,  "c", False),
            ("Remaining",  "remaining_on_path",     0.7*inch,  "c", False),
            ("Bldg Finish","anchor_finish",         0.8*inch,  "c", False),
        ]
        story += _var_table(display, cols, ST)

    story.append(PageBreak())
    return story


def section_part_v(output_root, narrative, ST, cfg):
    """Methodology A–C — text templated from playbook; Opus can override via narrative."""
    story = _part_header(SECTION_TITLES["part_v"], ST)

    # Methodology A
    story.append(Paragraph("Methodology A — How Each Variance Figure Is Calculated", ST["h2"]))
    meth_a = narrative.get("methodology_a", (
        "Every figure is derived from the MS Project schedule, comparing the saved Baseline against "
        "the current/actual schedule. Durations are measured as <b>span</b> — elapsed working time "
        "from the earliest start to the latest finish across a rolled-up line's instances, on the "
        "Mon–Fri 8-hour calendar. Absolute Variance = Actual Span − Baseline Span. Percent Variance "
        "is suppressed to n/a when the baseline span is below 0.5 working days. Net bucket variance "
        "is the arithmetic sum of task absolute variances (not an elapsed-calendar figure). "
        "The Top-N table ranks every rolled-up task across all buckets by absolute variance. "
        "In-progress task rule: completed tasks use actuals; in-progress tasks use the current "
        "scheduled (forecast) finish, so their variances are forecasts that move as work completes; "
        "not-yet-started tasks carry no actual span."
    ))
    story.append(Paragraph(meth_a, ST["body"]))

    # Methodology B
    attribution = (cfg.get("critical_path", {}) or {}).get("attribution_convention", "later")
    attr_sentence = (
        "The <b>day change</b> between consecutive snapshots is attributed to the activity "
        "controlling at the later snapshot — whatever was on the driving path when the movement "
        "appeared (contemporaneous / windows attribution)."
        if attribution == "later" else
        "The <b>day change</b> between consecutive snapshots is attributed to the activity "
        "controlling at the earlier snapshot — the incumbent that held the path during the window "
        "in which the slip occurred (standard windows-analysis practice)."
    )
    story.append(Paragraph("Methodology B — How the Critical-Path Delay Analysis Was Derived", ST["h2"]))
    meth_b = narrative.get("methodology_b", (
        "For each weekly snapshot, the analysis locates the finish milestone (Project Complete; "
        "falls back to the latest-finishing leaf if absent) and walks <b>backward</b> through the "
        "predecessor network to reconstruct the driving path — the single chain that sets the finish "
        "date. At each step, the driving predecessor is identified via the MS Project driving flag; "
        "where no flag is set, the latest-finishing predecessor is used as a best estimate. "
        "A visited-set prevents loops. Where a task's dates are governed by a hard constraint or "
        "deadline rather than logic, the trace records that terminus as constraint-controlled "
        "instead of estimating through it. The controlling activity is the earliest-finishing "
        "construction task on the path that is not yet complete. " + attr_sentence +
        " Day changes are summed by resource and chronologically."
    ))
    story.append(Paragraph(meth_b, ST["body"]))

    # Methodology C
    story.append(Paragraph("Methodology C — The Forward (Path-to-Completion) Figures", ST["h2"]))
    meth_c = narrative.get("methodology_c", (
        "Building turnover: each building's summary task percent complete, baseline finish, and "
        "current scheduled finish; slip = calendar-day difference. Float health: incomplete "
        "construction tasks banded by MS Project total slack. Completion range: the span of "
        "driving-path forecast finish over the last N weekly snapshots — an empirical uncertainty "
        "band, not a modeled confidence interval. Look-ahead: not-yet-complete construction tasks "
        "on the current driving path. Slip velocity: a trailing regression of forecast-finish "
        "movement over the same window, reported as an empirical trend, not a forecast."
    ))
    story.append(Paragraph(meth_c, ST["body"]))

    # Schedule-health panel (5.6, DCMA-style) — from the last Stage M QC run
    qc_path = output_root / "stage_m" / "qc_report.json"
    if qc_path.exists():
        try:
            sh = json.loads(qc_path.read_text(encoding="utf-8")) \
                .get("checks", {}).get("schedule_health", {})
        except Exception:
            sh = {}
        if sh and "error" not in sh:
            story.append(Paragraph("Schedule Health Panel (latest snapshot)", ST["h2"]))
            def _v(x):
                return "n/a" if x is None else str(x)
            rows = pd.DataFrame([
                {"metric": "Open ends — tasks with no predecessor", "value": _v(sh.get("open_ends_no_predecessor"))},
                {"metric": "Open ends — tasks with no successor",   "value": _v(sh.get("open_ends_no_successor"))},
                {"metric": "Hard constraints (non-ASAP)",           "value": _v(sh.get("hard_constraint_count"))},
                {"metric": "Negative-float tasks (incomplete)",     "value": _v(sh.get("negative_float_count"))},
                {"metric": "Relationship leads (negative lag)",     "value": _v(sh.get("leads_count"))},
                {"metric": "Relationship lags (positive lag)",      "value": _v(sh.get("lags_count"))},
                {"metric": "Out-of-sequence progress",              "value": _v(sh.get("out_of_sequence_progress"))},
                {"metric": "Actuals beyond status date",            "value": _v(sh.get("actuals_beyond_status_date"))},
                {"metric": "High-duration remaining (>20 wd left)", "value": _v(sh.get("high_duration_remaining"))},
            ])
            cols = [
                ("Metric", "metric", 3.6*inch, "l", False),
                ("Count",  "value",  1.0*inch, "c", False),
            ]
            story += _var_table(rows, cols, ST)
            story.append(Paragraph(
                "Computed from the latest snapshot's task and relationship data. These are standard "
                "schedule-quality indicators (DCMA-style): they qualify how much confidence the "
                "logic-driven analyses above deserve, not the project's performance itself.",
                ST["caption"]))

    story.append(PageBreak())
    return story


def section_part_vi(output_root, narrative, ST, cfg):
    story = _part_header(SECTION_TITLES["part_vi"], ST)
    story += narr("part_vi_bottom_line", narrative, ST)

    # Bucket summary
    bsum = _load_parquet(output_root / "stage_h" / "buyout_summary.parquet")
    if not bsum.empty:
        story.append(Paragraph("VI.2  Package Count and Activity Count by Bucket", ST["h2"]))
        cols = [
            ("Bucket",           "bucket",        2.2*inch, "l", False),
            ("Packages",         "packages",      0.65*inch,"c", False),
            ("Activities",       "activities",    0.65*inch,"c", False),
            ("Baseline Σ (d)",   "baseline_span", 0.9*inch, "c", False),
            ("Actual Σ (d)",     "actual_span",   0.85*inch,"c", False),
            ("Abs Var (d)",      "abs_var",        0.85*inch,"c", True),
        ]
        story += _var_table(bsum, cols, ST)

    # Stage breakdown
    sb = _load_parquet(output_root / "stage_h" / "buyout_stage_breakdown.parquet")
    if not sb.empty:
        story.append(Paragraph("VI.3  How the Delay Accumulated, Step by Step", ST["h2"]))
        story += narr("part_vi_stage_breakdown_note", narrative, ST)
        cols = [
            ("Activity Stage", "stage",       2.0*inch, "l", False),
            ("Occurrences",    "occurrences", 0.75*inch,"c", False),
            ("Avg Base (d)",   "avg_baseline",0.75*inch,"c", False),
            ("Avg Act (d)",    "avg_actual",  0.75*inch,"c", False),
            ("Avg Var (d)",    "avg_var",     0.75*inch,"c", True),
            ("Total Var (d)",  "total_var",   0.8*inch, "c", True),
        ]
        story += _var_table(sb, cols, ST)

    # Two-measurement scatter + PO-cycle trend (5.10) — skip cleanly when the
    # charts weren't generated (no buyout scope / too little data)
    k = output_root / "stage_k"
    story += _chart(k / "buyout_scatter.png", BODY_W * 0.85,
                    "Each point is one package: start-date slip (x) vs duration variance (y). "
                    "The quadrants separate delay that was generated from delay that was inherited.", ST)
    story += _chart(k / "po_cycle_trend.png", BODY_W * 0.85,
                    "Purchase-order cycle duration over time, with rolling median.", ST)

    # Top packages
    tp = _load_parquet(output_root / "stage_h" / "buyout_packages_ranked.parquet")
    if not tp.empty:
        n = min(len(tp), cfg.get("buyout_analysis", {}).get("top_packages_count", 25))
        story.append(Paragraph(f"VI.4  Top {n} Packages by Duration Variance", ST["h2"]))
        display = tp.head(n).copy()
        display["rank"] = range(1, n + 1)
        display["pct_var"] = display["pct_var"].map(
            lambda v: "n/a" if pd.isna(v) else f"{v*100:.0f}%")
        cols = [
            ("#",         "rank",     0.28*inch,"c", False),
            ("Section",   "section",  0.8*inch, "l", False),
            ("Group",     "group",    0.85*inch,"l", False),
            ("Package",   "category", 1.4*inch, "l", False),
            ("Acts.",     "activities",0.38*inch,"c", False),
            ("Base (d)",  "baseline", 0.55*inch,"c", False),
            ("Act. (d)",  "actual",   0.55*inch,"c", False),
            ("Var (d)",   "abs_var",  0.55*inch,"c", True),
            ("% Var",     "pct_var",  0.5*inch, "c", False),
        ]
        story += _var_table(display, cols, ST)

    story += narr("part_vi_methodology_d_note", narrative, ST)
    story.append(PageBreak())
    return story


def section_appendix_a(output_root, narrative, ST):
    story = _part_header(SECTION_TITLES["appendix_a"], ST)
    story += narr("appendix_a_note", narrative, ST)

    full = _load_parquet(output_root / "stage_e" / "construction_variance_full.parquet")
    if not full.empty:
        full_s = full.sort_values(["bucket", "abs_variance"], ascending=[True, False])
        cols = [
            ("Bucket",    "bucket",        1.3*inch, "l", False),
            ("Task Name", "task_name",     2.0*inch, "l", False),
            ("Resources", "resources",     0.9*inch, "l", False),
            ("Inst.",     "instances",     0.35*inch,"c", False),
            ("Base (d)",  "baseline_span", 0.5*inch, "c", False),
            ("Act. (d)",  "actual_span",   0.5*inch, "c", False),
            ("Var (d)",   "abs_variance",  0.5*inch, "c", True),
        ]
        story += _var_table(full_s, cols, ST)
    return story


# ─────────────────────────────────────────────────────────────────────────────
# Cover + TOC
# ─────────────────────────────────────────────────────────────────────────────

def build_cover_toc(path, cfg, toc_entries, ST):
    """Two-page PDF: cover (p1) + TOC (p2). Page refs already include +2 offset."""
    from reportlab.platypus import SimpleDocTemplate

    project = cfg["project"]["name"]
    subtitle = cfg.get("pdf_assembly", {}).get("brief_subtitle",
               "Schedule Analytics & Buyout Duration Analysis")
    status   = cfg["project"].get("analysis_status_date", "")
    company  = cfg.get("pdf_assembly", {}).get("company_name", "SCI")

    doc = SimpleDocTemplate(str(path), pagesize=letter,
                            leftMargin=LM, rightMargin=RM,
                            topMargin=TM, bottomMargin=BM)
    story = []

    # ── Cover ────────────────────────────────────────────────────────────
    story.append(Spacer(1, 1.5 * inch))
    story.append(Paragraph(project, ST["cover_title"]))
    story.append(Paragraph(subtitle, ST["cover_sub"]))
    story.append(Spacer(1, 12))
    story.append(HRFlowable(width=BODY_W, thickness=2, color=NAVY))
    story.append(Spacer(1, 8))
    story.append(Paragraph(
        f"Schedule Performance — Executive Briefing  |  As of {status}  |  "
        f"Prepared for Internal Leadership  |  {company}",
        ST["cover_sub"]))
    story.append(PageBreak())

    # ── TOC ─────────────────────────────────────────────────────────────
    story.append(Paragraph("Table of Contents", ST["h1"]))
    story.append(HRFlowable(width=BODY_W, thickness=0.5, color=NAVY, spaceAfter=8))
    story.append(Paragraph("MAIN SECTIONS", ST["toc_h"]))
    for title, page in toc_entries:
        dots = "." * max(4, 80 - len(title) - len(str(page)))
        story.append(Paragraph(f"{title} {dots} {page}", ST["toc"]))

    doc.build(story)


# ─────────────────────────────────────────────────────────────────────────────
# Main
# ─────────────────────────────────────────────────────────────────────────────

def main():
    parser = argparse.ArgumentParser(description="Stage L — PDF assembly")
    parser.add_argument("--config", default="project_config.json")
    args = parser.parse_args()

    cfg          = json.loads(Path(args.config).read_text(encoding="utf-8"))
    project      = cfg["project"]["name"]
    output_root  = Path(cfg["paths"]["output_root"])
    stage_dir    = output_root / "stage_l"
    stage_dir.mkdir(parents=True, exist_ok=True)

    print(f"\n{'='*60}")
    print(f"  Stage L — PDF Assembly")
    print(f"  Project : {project}")
    print(f"  Output  : {stage_dir}")
    print(f"{'='*60}\n")

    register_fonts()
    ST = make_styles()
    narrative = load_narrative(output_root)
    kpis      = derive_kpis(output_root, cfg)

    # Buyout is optional. When the project has no buyout phase, Stage H writes
    # buyout_in_scope=false and Part VI drops out of the document entirely —
    # TOC entry, bookmark, and body — rather than rendering an empty shell.
    # SECTION_TITLES stays the single source of truth; Part VI is a conditional
    # include, never a second title list. No renumbering is needed: Part VI is
    # the last numbered part, so omitting it leaves a clean I–V + Appendix A.
    include_part_vi = buyout_in_scope(output_root)

    print(f"  KPIs derived: {kpis}")
    print(f"  Narrative keys: {list(narrative.keys()) or ['(none — placeholders will be used)']}")
    print(f"  Part VI (buyout): {'included' if include_part_vi else 'omitted — no buyout scope'}\n")

    # (title, bookmark_key, fallback_page) — fallback is only used if a section's
    # bookmark somehow never recorded a page (defensive; shouldn't happen since
    # every section always renders, even with placeholder text).
    TOC_SECTIONS = [
        ("Executive Status Dashboard",   "dashboard",  3),
        (SECTION_TITLES["part_i"],       "part_i",     4),
        (SECTION_TITLES["part_ii"],      "part_ii",    6),
        (SECTION_TITLES["part_iii"],     "part_iii",   9),
        (SECTION_TITLES["part_iv"],      "part_iv",   19),
        (SECTION_TITLES["part_v"],       "part_v",    21),
        (SECTION_TITLES["part_vi"],      "part_vi",   25),
        (SECTION_TITLES["appendix_a"],   "appendix_a",32),
    ]
    if not include_part_vi:
        TOC_SECTIONS = [t for t in TOC_SECTIONS if t[1] != "part_vi"]

    def build_story(section_pages=None):
        """Fresh flowables every call — Platypus flowables are stateful.
        section_pages, if given, gets a _Bookmark inserted before each
        section so afterFlowable() can record which page it landed on."""
        def mark(key):
            return [_Bookmark(key)] if section_pages is not None else []
        s = []
        s += mark("dashboard")  + section_dashboard(cfg, output_root, narrative, ST, kpis)
        s +=                      section_overview(narrative, ST)
        s += mark("part_i")     + section_part_i(output_root, narrative, ST)
        s += mark("part_ii")    + section_part_ii(output_root, narrative, ST)
        s += mark("part_iii")   + section_part_iii(output_root, narrative, ST, cfg)
        s += mark("part_iv")    + section_part_iv(output_root, narrative, ST, cfg)
        s += mark("part_v")     + section_part_v(output_root, narrative, ST, cfg)
        if include_part_vi:
            s += mark("part_vi") + section_part_vi(output_root, narrative, ST, cfg)
        s += mark("appendix_a") + section_appendix_a(output_root, narrative, ST)
        return s

    toc_offset = cfg.get("pdf_assembly", {}).get("cover_toc_page_offset", 2)

    # ── Pass 1: discover body page count + where each section starts ──────
    body_tmp = stage_dir / "_body_tmp.pdf"
    print("  Pass 1: building body PDF (placeholder page count)...")
    section_pages = {}
    n_body = build_body_doc(body_tmp, build_story(section_pages), cfg,
                            total_pages=999, section_pages=section_pages)

    # ── Cover + TOC, build #1: reference numbers, just to measure n_front ──
    toc_entries = [(title, fallback) for title, _key, fallback in TOC_SECTIONS]
    if "toc_overrides" in narrative:
        toc_entries = [(t, p) for t, p in narrative["toc_overrides"]]

    cover_toc_path = stage_dir / "_cover_toc.pdf"
    print("  Building cover + TOC (measuring front-matter length)...")
    build_cover_toc(cover_toc_path, cfg, toc_entries, ST)

    # Count the ACTUAL cover+TOC pages rather than trusting cover_toc_page_offset.
    # The total and the per-page footer number both derive from this so they
    # always agree with the final merged file (the old code guessed the offset,
    # which made the footer total say e.g. 20 while page numbers ran only 1..18).
    n_front = len(PdfReader(str(cover_toc_path)).pages)
    if n_front <= 0:
        n_front = toc_offset
    n_total = n_front + n_body
    print(f"  Body pages: {n_body}  |  Front matter: {n_front}  |  Total: {n_total}")

    # ── Cover + TOC, build #2: real auto-computed page numbers ────────────
    # (skipped when toc_overrides is set — that's a full manual override,
    # title AND page number both taken verbatim from narrative.json)
    if "toc_overrides" not in narrative:
        # fallback values are already-absolute reference numbers (from the
        # Harrison reference project) - only add n_front when using a REAL
        # computed body-relative page, or the fallback would be double-offset.
        toc_entries = [
            (title, section_pages[key] + n_front if key in section_pages else fallback)
            for title, key, fallback in TOC_SECTIONS
        ]
        print("  Rebuilding TOC with auto-computed page numbers: "
              + ", ".join(f"{t}={p}" for t, p in toc_entries))
        build_cover_toc(cover_toc_path, cfg, toc_entries, ST)

    # ── Pass 2: body with correct total + page offset in footer ───────────
    body_path = stage_dir / "_body.pdf"
    print("  Pass 2: rebuilding body with correct page numbering...")
    build_body_doc(body_path, build_story(), cfg, total_pages=n_total, page_offset=n_front)
    n_body_actual = len(PdfReader(str(body_path)).pages)

    # ── Merge: cover_toc prepended to body ───────────────────────────────
    snapshot_stem = cfg["project"].get("analysis_status_date", "").replace("-", "")
    final_path = stage_dir / f"{project.replace(' ','_')}_Executive_Brief_{snapshot_stem}.pdf"
    print("  Merging cover+TOC + body with pypdf...")
    writer = PdfWriter()
    for src in [cover_toc_path, body_path]:
        for page in PdfReader(str(src)).pages:
            writer.add_page(page)
    writer.add_metadata({
        "/Title":   f"{project} — Executive Schedule Brief",
        "/Subject": f"As of {cfg['project'].get('analysis_status_date', '')}",
        "/Creator": "SCI Schedule Analytics Pipeline — Stage L",
    })
    with open(final_path, "wb") as f:
        writer.write(f)

    # Cleanup temps
    for p in [body_tmp, body_path, cover_toc_path]:
        try: p.unlink()
        except Exception: pass

    total_pages = len(PdfReader(str(final_path)).pages)
    print(f"\n  Final PDF: {total_pages} pages")
    print(f"\n{'='*60}")
    print(f"  Output : {final_path}")
    print(f"{'='*60}\n")

    (stage_dir / "assembly_report.json").write_text(json.dumps({
        "generated":      datetime.now().isoformat(timespec="seconds"),
        "project":        project,
        "total_pages":    total_pages,
        "body_pages":     n_body_actual,
        "kpis":           kpis,
        "narrative_keys": list(narrative.keys()),
    }, indent=2), encoding="utf-8")
    return 0


if __name__ == "__main__":
    sys.exit(main())

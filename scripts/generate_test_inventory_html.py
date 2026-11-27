#!/usr/bin/env python3
# Copyright (c) Qualcomm Technologies, Inc. and/or its subsidiaries.
# SPDX-License-Identifier: BSD-3-Clause

import html
import json
import os
import sys
from collections import defaultdict
from datetime import datetime, timezone
from pathlib import Path

import requests
import yaml

REPO = "qualcomm-linux/qcom-linux-testkit"
API = f"https://api.github.com/repos/{REPO}"
REPO_WEB = f"https://github.com/{REPO}"
MAIN_TREE = f"{REPO_WEB}/tree/main"

TOKEN = os.getenv("GITHUB_TOKEN", "")
HEADERS = {"Accept": "application/vnd.github+json"}
if TOKEN:
    HEADERS["Authorization"] = f"Bearer {TOKEN}"

MAX_SEGMENTS_PER_AREA = 99
MIN_SLICE_PCT = 8.0
LABEL_SLICE_PCT = 6.0
PALETTE = [
    (214, "#93c5fd"),
    (160, "#86efac"),
    (36, "#fcd34d"),
    (280, "#d8b4fe"),
    (345, "#f9a8d4"),
    (14, "#fdba74"),
    (190, "#67e8f9"),
    (95, "#bef264"),
]


def find_repo_root():
    candidates = []
    cwd = Path.cwd().resolve()
    script_dir = Path(__file__).resolve().parent

    for base in (cwd, script_dir):
        candidates.append(base)
        candidates.extend(base.parents)

    seen = set()
    for candidate in candidates:
        candidate = candidate.resolve()
        if candidate in seen:
            continue
        seen.add(candidate)
        if (candidate / "Runner" / "suites").is_dir():
            return candidate

    raise SystemExit(
        "Could not locate repo root containing Runner/suites. "
        "Run this script from inside qcom-linux-testkit or place it under that repo."
    )


REPO_ROOT = find_repo_root()
BASE = REPO_ROOT / "Runner" / "suites"



def gh_get(url, params=None):
    response = requests.get(url, headers=HEADERS, params=params, timeout=30)
    response.raise_for_status()
    return response.json()


def get_open_prs():
    return gh_get(f"{API}/pulls", params={"state": "open", "per_page": 100})


def get_pr_files(pr_number):
    return gh_get(f"{API}/pulls/{pr_number}/files", params={"per_page": 100})


def h(text):

    return html.escape(str(text))


def html_link(text, url):
    return (
        f'<a href="{html.escape(url, quote=True)}" '
        f'target="_blank" rel="noopener noreferrer">{html.escape(text)}</a>'
    )


def parse_suite_path(runsh: Path):
    rel_dir = runsh.parent.relative_to(REPO_ROOT).as_posix()
    parts = runsh.relative_to(BASE).parts
    area = parts[0] if len(parts) >= 1 else ""
    functional_area = parts[1] if len(parts) >= 2 else ""
    test_name = parts[-2] if len(parts) >= 2 else ""

    subarea = ""
    if len(parts) > 4:
        subarea = "/".join(parts[2:-2])

    folder_url = f"{MAIN_TREE}/{rel_dir}"

    return {
        "Area": area,
        "Functional Area": functional_area,
        "Subarea": subarea,
        "Test Case Name": test_name,
        "Test Case Link": html_link(test_name, folder_url),
        "Suite Path": rel_dir,
        "Present on main": "yes",
        "Open PR": "",
        "Update PR": "",
    }


def discover_tests():
    tests = []
    if not BASE.exists():
        raise SystemExit(f"Missing repo path: {BASE}")

    for runsh in sorted(BASE.rglob("run.sh")):
        tests.append(parse_suite_path(runsh))
    return tests


def discover_definitions():
    """Inventory runnable suite YAMLs without counting plans or configuration data."""
    definitions = []
    paths = sorted(path for path in BASE.rglob("*") if path.suffix in {".yaml", ".yml"})
    for path in paths:
        try:
            document = yaml.safe_load(path.read_text(encoding="utf-8"))
        except yaml.YAMLError as error:
            raise ValueError(f"Cannot parse test definition {path}: {error}") from error
        if not isinstance(document, dict):
            continue
        metadata = document.get("metadata")
        run = document.get("run")
        if not isinstance(metadata, dict) or not isinstance(run, dict):
            continue
        steps = run.get("steps")
        if not isinstance(steps, list) or not steps or not all(isinstance(step, str) for step in steps):
            raise ValueError(f"Expected nonempty run.steps containing strings in {path}")
        params = document.get("params")
        if params is None:
            params = {}
        if not isinstance(params, dict):
            raise ValueError(f"Expected a params mapping in {path}")
        definition = parse_suite_path(path)
        definition.update({
            "Definition Name": metadata.get("name") or path.stem,
            "Definition Path": path.relative_to(REPO_ROOT).as_posix(),
            "Description": metadata.get("description") or "",
            "Parameters": params,
            "Steps": steps,
        })
        definitions.append(definition)
    return definitions


def mark_open_pr_tests(tests):
    by_path = {t["Suite Path"]: t for t in tests}
    open_pr_numbers = set()

    prs = get_open_prs()
    if not prs:
        return open_pr_numbers

    for pr in prs:
        pr_number = pr["number"]
        pr_link = html_link(f"PR #{pr_number}", pr["html_url"])
        files = get_pr_files(pr_number)
        if not files:
            continue

        touched_dirs = set()
        for file_info in files:
            filename = file_info.get("filename", "")
            if filename.startswith("Runner/suites/") and filename.endswith("/run.sh"):
                touched_dirs.add(filename.rsplit("/", 1)[0])

        if not touched_dirs:
            continue

        open_pr_numbers.add(pr_number)

        for suite_dir in touched_dirs:
            if suite_dir not in by_path:
                fake_runsh = REPO_ROOT / suite_dir / "run.sh"
                meta = parse_suite_path(fake_runsh)
                meta["Present on main"] = "no"
                meta["Open PR"] = pr_link
                tests.append(meta)
                by_path[suite_dir] = meta

        if len(touched_dirs) == 1:
            suite_dir = next(iter(touched_dirs))
            if suite_dir in by_path and by_path[suite_dir]["Present on main"] == "yes":
                existing = by_path[suite_dir]["Update PR"]
                if existing:
                    by_path[suite_dir]["Update PR"] = existing + ", " + pr_link
                else:
                    by_path[suite_dir]["Update PR"] = pr_link

    return open_pr_numbers


def group_tests(tests):
    grouped = defaultdict(lambda: defaultdict(list))
    for test in tests:
        grouped[test["Area"]][test["Functional Area"]].append(test)
    return grouped


def build_area_summary(tests):
    by_area = defaultdict(int)
    for test in tests:
        by_area[test["Area"]] += 1

    rows = []
    for area, count in sorted(by_area.items()):
        rows.append(f"<tr><td>{h(area)}</td><td>{count}</td></tr>")
    return "\n".join(rows)


def aggregate_area_segments(tests):
    by_area = defaultdict(lambda: defaultdict(lambda: {"merged": 0, "open_pr": 0}))
    for test in tests:
        area = test["Area"] or "Other"
        functional_area = test["Functional Area"] or "Other"
        bucket = by_area[area][functional_area]
        if test["Present on main"] == "yes":
            bucket["merged"] += 1
        elif test["Open PR"]:
            bucket["open_pr"] += 1

    result = []
    for area, fa_map in sorted(by_area.items()):
        items = []
        for functional_area, counts in fa_map.items():
            total = counts["merged"] + counts["open_pr"]
            if total <= 0:
                continue
            items.append(
                {
                    "functional_area": functional_area,
                    "merged": counts["merged"],
                    "open_pr": counts["open_pr"],
                    "total": total,
                }
            )

        items.sort(key=lambda item: (-item["total"], item["functional_area"].lower()))

        area_total = sum(item["total"] for item in items)
        result.append({"area": area, "total": area_total, "segments": items})

    result.sort(key=lambda item: (-item["total"], item["area"].lower()))
    return result



def build_functional_area_chart(tests):
    areas = aggregate_area_segments(tests)
    if not areas:
        return '<div class="empty-state">No functional area data available.</div>'

    columns = []
    for area_index, area_info in enumerate(areas):
        area = area_info["area"]
        total = area_info["total"]
        segments = area_info["segments"]

        normalized_segments = []
        for seg_index, segment in enumerate(segments):
            hue, chip = PALETTE[(area_index + seg_index) % len(PALETTE)]
            seg_total = segment["total"]
            actual_pct = (seg_total * 100.0) / total if total > 0 else 0.0
            display_pct = max(actual_pct, MIN_SLICE_PCT if seg_total > 0 else 0.0)

            normalized_segments.append(
                {
                    "segment": segment,
                    "hue": hue,
                    "chip": chip,
                    "actual_pct": actual_pct,
                    "display_pct": display_pct,
                }
            )

        display_sum = sum(item["display_pct"] for item in normalized_segments) or 1.0
        for item in normalized_segments:
            item["display_pct"] = (item["display_pct"] * 100.0) / display_sum

        seg_html = []
        list_html = []
        for item in normalized_segments:
            segment = item["segment"]
            seg_total = segment["total"]
            merged_width_pct = (segment["merged"] * 100.0) / seg_total if seg_total > 0 else 0.0
            open_width_pct = (segment["open_pr"] * 100.0) / seg_total if seg_total > 0 else 0.0
            label = segment["functional_area"]

            label_html = ""
            if item["display_pct"] >= LABEL_SLICE_PCT:
                label_class = "area-stack-seg-label"
                if item["display_pct"] < 8.5:
                    label_class += " small"
                label_html = f'<span class="{label_class}">{seg_total}</span>'

            seg_html.append(
                f'''
<div class="area-stack-seg" style="height: {item["display_pct"]:.2f}%" title="{h(area)} / {h(label)} | Total {seg_total}, Merged {segment['merged']}, Open PR {segment['open_pr']}">
  <div class="area-stack-seg-split">
    <div class="area-stack-merged" style="width: {merged_width_pct:.2f}%; --seg-hue: {item["hue"]};"></div>
    <div class="area-stack-open" style="width: {open_width_pct:.2f}%; --seg-hue: {item["hue"]};"></div>
  </div>
  {label_html}
</div>
'''
            )
            list_html.append(
                f'''
<div class="area-breakdown-item">
  <span class="area-breakdown-swatch" style="--seg-chip: {item["chip"]};"></span>
  <span class="area-breakdown-name">{h(label)}</span>
  <span class="area-breakdown-count">{seg_total}</span>
  <span class="area-breakdown-meta">M {segment['merged']} | PR {segment['open_pr']}</span>
</div>
'''
            )

        columns.append(
            f'''
<div class="area-chart-col">
  <div class="area-chart-total">{total}</div>
  <div class="area-chart-bars">
    <div class="area-chart-stack">
      {''.join(seg_html)}
    </div>
  </div>
  <div class="area-chart-name">{h(area)}</div>
  <div class="area-chart-meta">{len(segments)} segment(s)</div>
  <div class="area-breakdown-list">
    {''.join(list_html)}
  </div>
</div>
'''
        )

    return "\n".join(columns)


def build_test_table_rows(items):

    rows = []
    for test in items:
        rows.append(
            "<tr>"
            f"<td>{h(test['Subarea'])}</td>"
            f"<td>{test['Test Case Link']}</td>"
            f"<td>{h(test['Present on main'])}</td>"
            f"<td>{test['Open PR']}</td>"
            f"<td>{test['Update PR']}</td>"
            f"<td><code>{h(test['Suite Path'])}</code></td>"
            "</tr>"
        )
    return "\n".join(rows)


def build_definition_table_rows(items):
    rows = []
    for definition in items:
        path = definition["Definition Path"]
        parameters = definition["Parameters"]
        params_html = '<span class="hint">No YAML parameters</span>'
        if parameters:
            values = "".join(
                f"<dt><code>{h(name)}</code></dt><dd><code>{h(json.dumps(value, ensure_ascii=False))}</code></dd>"
                for name, value in parameters.items()
            )
            params_html = (
                f'<details class="definition-detail"><summary>Defaults ({len(parameters)})</summary>'
                f'<dl class="parameter-list">{values}</dl></details>'
            )
        steps = "".join(f"<li><pre><code>{h(step)}</code></pre></li>" for step in definition["Steps"])
        rows.append(
            "<tr>"
            f"<td>{h(definition['Subarea'])}</td>"
            f"<td>{definition['Test Case Link']}</td>"
            f"<td>{html_link(str(definition['Definition Name']), f'{REPO_WEB}/blob/main/{path}')}"
            f"<div class=\"hint\"><code>{h(path)}</code></div></td>"
            f"<td>{h(definition['Description'])}</td>"
            f"<td>{params_html}</td>"
            '<td><details class="definition-detail"><summary>Run steps</summary>'
            f'<ol class="run-steps">{steps}</ol></details></td>'
            "</tr>"
        )
    return "\n".join(rows)


def build_sections(tests, definitions=False):
    grouped = group_tests(tests)
    sections = []
    unit = "definition(s)" if definitions else "suite(s)"
    columns = (
        ("Subarea", "Suite", "Test definition", "Description", "YAML parameters", "Launch")
        if definitions else
        ("Subarea", "Suite", "Present on main", "Open PR", "Update PR", "Suite Path")
    )
    headings = "".join(f"<th>{h(column)}</th>" for column in columns)

    for area in sorted(grouped.keys()):
        functional_area_map = grouped[area]
        area_count = sum(len(values) for values in functional_area_map.values())

        functional_area_blocks = []
        for functional_area in sorted(functional_area_map.keys()):
            items = sorted(
                functional_area_map[functional_area],
                key=lambda x: (x["Subarea"], x["Test Case Name"], x.get("Definition Path", x["Suite Path"])),
            )
            functional_area_count = len(items)
            rows_html = build_definition_table_rows(items) if definitions else build_test_table_rows(items)

            functional_area_blocks.append(
                f"""
<details class="fa-block" open data-functional-area="{h(functional_area)}">
  <summary>
    <span class="summary-title">{h(functional_area)}</span>
    <span class="summary-count">{functional_area_count} {unit}</span>
  </summary>
  <div class="table-wrap inventory-table-wrap">
    <table class="inventory-table">
      <thead>
        <tr>
          {headings}
        </tr>
      </thead>
      <tbody>
        {rows_html}
      </tbody>
    </table>
  </div>
</details>
"""
            )

        sections.append(
            f"""
<section class="area-section" data-area="{h(area)}">
  <details class="area-block" open>
    <summary>
      <span class="summary-title">{h(area)}</span>
      <span class="summary-count">{area_count} {unit}</span>
    </summary>
    <div class="fa-container">
      {''.join(functional_area_blocks)}
    </div>
  </details>
</section>
"""
        )

    return "\n".join(sections)


def build_html(
    generated_at_utc,
    repo_home,
    repo_actions,
    repo_suites,
    total_tests,
    merged_tests,
    open_pr_count,
    new_test_suites_in_open_prs,
    existing_suites_updated_in_open_prs,
    functional_area_chart_html,
    sections_html,
    definitions,
):
    template = """<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width,initial-scale=1">
  <title>qcom-linux-testkit Test Inventory</title>
  <style>
    :root {
      --bg: #0b1020;
      --panel: #121a30;
      --panel-2: #0f1730;
      --text: #e8ecf6;
      --muted: #aeb9d1;
      --line: #2a3556;
      --accent: #7aa2ff;
      --accent-2: #9be7c4;
      --hover: rgba(122, 162, 255, 0.05);
      --badge: #0a1228;
    }
    * { box-sizing: border-box; }
    body {
      margin: 0;
      font-family: Arial, Helvetica, sans-serif;
      background: var(--bg);
      color: var(--text);
      line-height: 1.4;
    }
    .container {
      max-width: 1550px;
      margin: 0 auto;
      padding: 24px;
    }
    h1, h2, h3 {
      margin: 0 0 12px 0;
    }
    p {
      color: var(--muted);
      margin: 0 0 16px 0;
    }
    .hero {
      background: linear-gradient(180deg, var(--panel), var(--panel-2));
      border: 1px solid var(--line);
      border-radius: 16px;
      padding: 22px;
      margin-bottom: 24px;
    }
    .hero-top {
      display: flex;
      flex-wrap: wrap;
      align-items: center;
      justify-content: space-between;
      gap: 12px;
      margin-bottom: 10px;
    }
    .hero-title {
      font-size: 30px;
      font-weight: 700;
      margin: 0;
    }
    .hero-subtitle {
      color: var(--muted);
      margin: 0 0 12px 0;
    }
    .badges {
      display: flex;
      flex-wrap: wrap;
      gap: 10px;
      margin-top: 10px;
    }
    .badge {
      background: var(--badge);
      border: 1px solid var(--line);
      border-radius: 999px;
      padding: 8px 12px;
      color: var(--text);
      font-size: 13px;
      white-space: nowrap;
    }
    .hero-links {
      display: flex;
      flex-wrap: wrap;
      gap: 12px;
      margin-top: 14px;
    }
    .hero-links a {
      display: inline-block;
      padding: 8px 12px;
      border-radius: 10px;
      border: 1px solid var(--line);
      background: #0a1228;
      text-decoration: none;
    }
    .cards {
      display: grid;
      grid-template-columns: repeat(auto-fit, minmax(220px, 1fr));
      gap: 16px;
      margin: 20px 0 28px;
    }
    .card {
      background: linear-gradient(180deg, var(--panel), var(--panel-2));
      border: 1px solid var(--line);
      border-radius: 14px;
      padding: 18px;
    }
    .card .label {
      color: var(--muted);
      font-size: 14px;
      margin-bottom: 8px;
    }
    .card .value {
      font-size: 30px;
      font-weight: 700;
      color: var(--accent-2);
    }
    .section {
      background: var(--panel);
      border: 1px solid var(--line);
      border-radius: 14px;
      padding: 18px;
      margin-bottom: 24px;
    }
    .summary-grid {
      display: grid;
      grid-template-columns: 1fr;
      gap: 20px;
    }
    .toolbar {
      display: flex;
      flex-wrap: wrap;
      gap: 12px;
      align-items: center;
      margin-bottom: 14px;
    }
    .toolbar input {
      width: min(100%, 560px);
      min-width: 0;
      padding: 10px 12px;
      border-radius: 10px;
      border: 1px solid var(--line);
      background: #0a1228;
      color: var(--text);
    }
    .toolbar .count {
      color: var(--muted);
      font-size: 14px;
    }
    .table-wrap {
      overflow: auto;
      border: 1px solid var(--line);
      border-radius: 12px;
    }
    .inventory-table-wrap {
      width: 100%;
    }
    table {
      width: 100%;
      border-collapse: collapse;
      background: #0d142b;
    }
    .inventory-table {
      min-width: 950px;
    }
    th, td {
      padding: 10px 12px;
      border-bottom: 1px solid var(--line);
      vertical-align: top;
      text-align: left;
    }
    th {
      background: #121b38;
      cursor: pointer;
      user-select: none;
      white-space: nowrap;
    }
    tr:hover td {
      background: var(--hover);
    }
    a {
      color: var(--accent);
      text-decoration: none;
    }
    a:hover {
      text-decoration: underline;
    }
    code {
      color: #d9e1ff;
      font-size: 12px;
    }
    .hint {
      color: var(--muted);
      font-size: 13px;
      margin-top: 8px;
    }
    .chart-wrap {
      border: 1px solid var(--line);
      border-radius: 12px;
      background: #0d142b;
      padding: 14px 10px 10px 10px;
      overflow-x: auto;
      overflow-y: hidden;
    }
    .chart-legend {
      display: flex;
      flex-wrap: wrap;
      gap: 8px;
      margin-bottom: 14px;
    }
    .legend-pill {
      display: inline-flex;
      align-items: center;
      gap: 6px;
      border-radius: 999px;
      padding: 6px 10px;
      border: 1px solid var(--line);
      background: #0a1228;
      font-size: 12px;
      color: var(--text);
      white-space: nowrap;
    }
    .legend-swatch {
      width: 12px;
      height: 12px;
      border-radius: 3px;
      display: inline-block;
    }
    .legend-swatch.merged {
      background: linear-gradient(180deg, hsl(214 84% 75%), hsl(214 84% 68%));
    }
    .legend-swatch.open {
      background: repeating-linear-gradient(
        135deg,
        hsl(214 84% 75%) 0px,
        hsl(214 84% 75%) 4px,
        rgba(255,255,255,0.15) 4px,
        rgba(255,255,255,0.15) 8px
      );
    }
    .fa-chart {
      display: inline-flex;
      align-items: flex-start;
      justify-content: flex-start;
      gap: 18px;
      min-width: 100%;
      width: max-content;
      padding: 10px 0 4px 0;
    }
    
.area-chart-col {
  min-width: 176px;
  display: flex;
  flex-direction: column;
  align-items: center;
  gap: 7px;
}
.area-chart-total {
  font-size: 16px;
  font-weight: 700;
  color: var(--text);
  line-height: 1;
  min-height: 18px;
}
.area-chart-bars {
  height: 320px;
  width: 100%;
  display: flex;
  align-items: flex-end;
  justify-content: center;
  padding: 0 18px;
  border-bottom: 1px solid var(--line);
  position: relative;
  background:
    linear-gradient(to top, transparent 24.5%, rgba(255,255,255,0.04) 25%, transparent 25.5%),
    linear-gradient(to top, transparent 49.5%, rgba(255,255,255,0.04) 50%, transparent 50.5%),
    linear-gradient(to top, transparent 74.5%, rgba(255,255,255,0.04) 75%, transparent 75.5%);
}
.area-chart-stack {
  width: 78px;
  height: 100%;
  min-height: 100%;
  display: flex;
  flex-direction: column-reverse;
  border: 1px solid var(--line);
  border-radius: 10px 10px 0 0;
  background: #0a1228;
  overflow: hidden;
  box-shadow: 0 0 0 1px rgba(255,255,255,0.02) inset;
}
.area-stack-seg {
  width: 100%;
  min-height: 10px;
  border-top: 1px solid rgba(255,255,255,0.08);
  display: block;
  position: relative;
  overflow: hidden;
}
.area-stack-seg-split {
  width: 100%;
  height: 100%;
  display: flex;
}
.area-stack-merged {
  height: 100%;
  background: linear-gradient(
    180deg,
    hsl(var(--seg-hue) 90% 76%),
    hsl(var(--seg-hue) 78% 54%)
  );
}
.area-stack-open {
  height: 100%;
  background:
    repeating-linear-gradient(
      135deg,
      rgba(255,255,255,0.70) 0px,
      rgba(255,255,255,0.70) 3px,
      rgba(255,255,255,0.10) 3px,
      rgba(255,255,255,0.10) 6px
    ),
    linear-gradient(
      180deg,
      hsl(var(--seg-hue) 58% 44%),
      hsl(var(--seg-hue) 52% 30%)
    );
  box-shadow: inset 1px 0 0 rgba(11, 16, 32, 0.40);
}
.area-stack-seg-label {
  position: absolute;
  inset: 0;
  display: flex;
  align-items: center;
  justify-content: center;
  font-size: 10px;
  font-weight: 700;
  color: #08101f;
  text-shadow: 0 1px 0 rgba(255,255,255,0.20);
  pointer-events: none;
  line-height: 1;
}
.area-stack-seg-label.small {
  font-size: 9px;
}
.area-chart-name {
  font-size: 13px;
  font-weight: 700;
  color: var(--text);
  text-align: center;
  line-height: 1.2;
  min-height: 16px;
}
.area-chart-meta {
  font-size: 11px;
  color: var(--muted);
  text-align: center;
  line-height: 1.15;
  min-height: 12px;
}
.area-breakdown-list {
  width: 100%;
  display: grid;
  gap: 5px;
  margin-top: 4px;
  padding-top: 4px;
}
.area-breakdown-item {
  display: grid;
  grid-template-columns: 10px 1fr auto auto;
  gap: 6px;
  align-items: center;
  font-size: 11px;
  color: var(--muted);
}
.area-breakdown-swatch {
  width: 10px;
  height: 10px;
  border-radius: 2px;
  background: var(--seg-chip);
  display: inline-block;
}
.area-breakdown-name {
  color: var(--text);
  overflow: hidden;
  text-overflow: ellipsis;
  white-space: nowrap;
}

    .area-breakdown-count {
      color: var(--text);
      font-weight: 700;
      padding-left: 4px;
    }
    .area-breakdown-meta {
      white-space: nowrap;
    }
    details {
      border: 1px solid var(--line);
      border-radius: 12px;
      background: #0f1730;
    }
    summary {
      list-style: none;
      cursor: pointer;
      padding: 14px 16px;
      display: flex;
      justify-content: space-between;
      align-items: center;
      gap: 12px;
    }
    summary::-webkit-details-marker {
      display: none;
    }
    .summary-title {
      font-weight: 700;
      font-size: 16px;
    }
    .summary-count {
      color: var(--muted);
      font-size: 14px;
      white-space: nowrap;
    }
    .area-section {
      margin-bottom: 16px;
    }
    .fa-container {
      padding: 0 16px 16px 16px;
      display: grid;
      gap: 14px;
    }
    .fa-block {
      margin-top: 8px;
    }
    .hidden {
      display: none !important;
    }
    .empty-state {
      color: var(--muted);
      padding: 20px 0 4px;
    }
    .view-switch {
      display: flex;
      flex-wrap: wrap;
      gap: 12px;
      margin: 0 0 20px;
    }
    .view-switch a {
      padding: 12px 18px;
      border: 1px solid var(--line);
      border-radius: 10px;
      background: var(--panel);
    }
    .view-switch a[aria-current="page"] {
      border-color: var(--accent);
      background: #20335c;
      color: var(--text);
    }
    .definition-detail {
      min-width: 160px;
      max-width: 540px;
    }
    .definition-detail summary {
      padding: 8px 10px;
      font-size: 13px;
    }
    .parameter-list {
      margin: 0;
      padding: 10px;
    }
    .parameter-list dt {
      color: var(--muted);
    }
    .parameter-list dd {
      margin: 0 0 10px;
    }
    .run-steps {
      padding: 0 14px 0 30px;
    }
    pre, .parameter-list code, .hint code {
      white-space: pre-wrap;
      overflow-wrap: anywhere;
    }
  </style>
</head>
<body>
  <div class="container">
    <div class="hero">
      <div class="hero-top">
        <h1 class="hero-title">qcom-linux-testkit Test Inventory</h1>
      </div>
      <p class="hero-subtitle">
        Explore each YAML test definition and its configuration. Switch to Suites to see the runners shared by those definitions.
      </p>

      <div class="badges">
        <div class="badge"><strong>Repository:</strong> __REPO__</div>
        <div class="badge"><strong>Generated:</strong> __GENERATED__</div>
        <div class="badge"><strong>Definitions on main:</strong> __DEFINITION_COUNT__</div>
        <div class="badge"><strong>Suites on main:</strong> __ON_MAIN__</div>
      </div>

      <div class="hero-links">
        <a href="__REPO_HOME__" target="_blank" rel="noopener noreferrer">Repository</a>
        <a href="__REPO_SUITES__" target="_blank" rel="noopener noreferrer">Runner/suites</a>
        <a href="__REPO_ACTIONS__" target="_blank" rel="noopener noreferrer">Actions</a>
      </div>
    </div>

    <nav class="view-switch" aria-label="Inventory view">
      <a href="#definitions" aria-current="page">Test definitions (YAML)</a>
      <a href="#suites">Suites (run.sh)</a>
    </nav>

    <div id="inventory-suites" class="inventory-view hidden">
    <div class="cards">
      <div class="card">
        <div class="label">Suites, including open PRs</div>
        <div class="value">__TOTAL__</div>
      </div>
      <div class="card">
        <div class="label">Present on main</div>
        <div class="value">__ON_MAIN__</div>
      </div>
      <div class="card">
        <div class="label">Open PRs touching tests</div>
        <div class="value">__OPEN_PR_COUNT__</div>
      </div>
      <div class="card">
        <div class="label">New suites in open PRs</div>
        <div class="value">__NEW_OPEN__</div>
      </div>
      <div class="card">
        <div class="label">Existing suites updated in open PRs</div>
        <div class="value">__UPDATED_OPEN__</div>
      </div>
    </div>

    <div class="section">
      <h2>Suite summary</h2>
      <p>One entry per <code>run.sh</code> under <code>Runner/suites</code>. Counts describe available suites, not executed testcase results.</p>
      <div class="summary-grid">
        <div>
          <h3>By Functional Area</h3>
          <div class="chart-wrap">
            <div class="chart-legend">
              <span class="legend-pill"><span class="legend-swatch merged"></span> Merged</span>
              <span class="legend-pill"><span class="legend-swatch open"></span> Open PR</span>
              <span class="legend-pill">Bars grouped by Area</span>
              <span class="legend-pill">Stacks show Functional Areas</span>
            </div>
            <div class="fa-chart">
              __FUNCTIONAL_AREA_CHART_HTML__
            </div>
          </div>
        </div>
      </div>
    </div>

    <div class="section">
      <h2>Suite inventory</h2>
      <div class="toolbar">
        <input class="filter-input" type="search" aria-label="Filter suites" placeholder="Filter by area, suite, path or PR...">
        <div class="count">Visible suites: <span class="visible-count">__TOTAL__</span></div>
      </div>

      <div class="inventory-sections">
        __SECTIONS_HTML__
      </div>

      <div class="empty-state hidden">No suites match the current filter.</div>
      <div class="hint">Click a table header to sort within a functional area. Filtering auto-expands matching groups.</div>
    </div>
    </div>

    <div id="inventory-definitions" class="inventory-view">
      <div class="cards">
        <div class="card"><div class="label">Test definitions on main</div><div class="value">__DEFINITION_COUNT__</div></div>
        <div class="card"><div class="label">Suite directories with definitions</div><div class="value">__DEFINED_SUITE_COUNT__</div></div>
      </div>
      <div class="section">
        <h2>Test definition summary</h2>
        <p>One entry per runnable YAML under <code>Runner/suites</code>, including variants sharing the same runner. Plans and configuration data are excluded. These are available definitions, not a count of executed testcases or current CI usage.</p>
        <details open><summary>Definitions by functional area</summary>
          <div class="chart-wrap"><div class="fa-chart">__DEFINITION_CHART_HTML__</div></div>
        </details>
      </div>
      <div class="section">
        <h2>Test definition inventory</h2>
        <p>Each row links to its YAML. Expand defaults and run steps to compare configurations. Values are declared YAML defaults, jobs can override them. Run steps retain shell expressions as written.</p>
        <div class="toolbar">
          <input class="filter-input" type="search" aria-label="Filter test definitions" placeholder="Filter by area, suite, definition, parameter or command...">
          <div class="count">Visible definitions: <span class="visible-count">__DEFINITION_COUNT__</span></div>
        </div>
        <div class="inventory-sections">__DEFINITION_SECTIONS_HTML__</div>
        <div class="empty-state hidden">No definitions match the current filter.</div>
        <div class="hint">Null, empty strings, zero and false are shown separately. A YAML definition can emit multiple testcase results at runtime.</div>
      </div>
    </div>
  </div>

  <script>
    (function() {
      const views = document.querySelectorAll('.inventory-view');

      function sortTable(table, colIdx, asc) {
        const tbody = table.tBodies[0];
        const rows = Array.from(tbody.rows);
        rows.sort((a, b) => {
          const av = a.cells[colIdx].textContent.trim().toLowerCase();
          const bv = b.cells[colIdx].textContent.trim().toLowerCase();
          if (av < bv) return asc ? -1 : 1;
          if (av > bv) return asc ? 1 : -1;
          return 0;
        });
        rows.forEach((row) => tbody.appendChild(row));
      }

      function initSorters() {
        document.querySelectorAll('.inventory-table').forEach((table) => {
          Array.from(table.tHead.rows[0].cells).forEach((th, idx) => {
            let asc = true;
            th.addEventListener('click', () => {
              sortTable(table, idx, asc);
              asc = !asc;
            });
          });
        });
      }

      function applyFilter(view) {
        const input = view.querySelector('.filter-input');
        const visibleCount = view.querySelector('.visible-count');
        const emptyState = view.querySelector('.empty-state');
        const inventorySections = view.querySelector('.inventory-sections');
        const q = input.value.trim().toLowerCase();
        let visibleTests = 0;

        inventorySections.querySelectorAll('.area-section').forEach((areaSection) => {
          let areaHasVisible = false;
          let areaVisibleRows = 0;
          const areaDetails = areaSection.querySelector('.area-block');

          areaSection.querySelectorAll('.fa-block').forEach((faBlock) => {
            let faVisibleRows = 0;
            const table = faBlock.querySelector('table');
            const rows = Array.from(table.tBodies[0].rows);

            rows.forEach((row) => {
              const text = (areaSection.dataset.area + ' ' + faBlock.dataset.functionalArea + ' ' + row.textContent).toLowerCase();
              const match = q === '' || text.includes(q);
              row.classList.toggle('hidden', !match);
              if (match) {
                faVisibleRows += 1;
              }
            });

            const countEl = faBlock.querySelector('.summary-count');
            countEl.textContent = faVisibleRows + ' visible';

            const faHasVisible = faVisibleRows > 0;
            faBlock.classList.toggle('hidden', !faHasVisible);

            if (faHasVisible) {
              areaHasVisible = true;
              areaVisibleRows += faVisibleRows;
              visibleTests += faVisibleRows;
              if (q !== '') {
                faBlock.open = true;
                areaDetails.open = true;
              }
            }
          });

          areaSection.classList.toggle('hidden', !areaHasVisible);
          areaDetails.querySelector('.summary-count').textContent = areaVisibleRows + ' visible';
        });

        visibleCount.textContent = visibleTests;
        emptyState.classList.toggle('hidden', visibleTests !== 0);
        inventorySections.classList.toggle('hidden', visibleTests === 0 && q !== '');
      }

      function selectView() {
        const selected = location.hash === '#suites' ? 'suites' : 'definitions';
        views.forEach((view) => view.classList.toggle('hidden', view.id !== 'inventory-' + selected));
        document.querySelectorAll('.view-switch a').forEach((link) => {
          if (link.hash === '#' + selected) link.setAttribute('aria-current', 'page');
          else link.removeAttribute('aria-current');
        });
      }

      views.forEach((view) => {
        view.querySelector('.filter-input').addEventListener('input', () => applyFilter(view));
        applyFilter(view);
      });
      window.addEventListener('hashchange', selectView);
      initSorters();
      selectView();
    })();
  </script>
</body>
</html>
"""
    return (
        template
        .replace("__REPO__", h(REPO))
        .replace("__GENERATED__", h(generated_at_utc))
        .replace("__TOTAL__", str(total_tests))
        .replace("__ON_MAIN__", str(merged_tests))
        .replace("__OPEN_PR_COUNT__", str(open_pr_count))
        .replace("__NEW_OPEN__", str(new_test_suites_in_open_prs))
        .replace("__UPDATED_OPEN__", str(existing_suites_updated_in_open_prs))
        .replace("__REPO_HOME__", h(repo_home))
        .replace("__REPO_ACTIONS__", h(repo_actions))
        .replace("__REPO_SUITES__", h(repo_suites))
        .replace("__FUNCTIONAL_AREA_CHART_HTML__", functional_area_chart_html)
        .replace("__SECTIONS_HTML__", sections_html)
        .replace("__DEFINITION_COUNT__", str(len(definitions)))
        .replace("__DEFINED_SUITE_COUNT__", str(len({row["Suite Path"] for row in definitions})))
        .replace("__DEFINITION_CHART_HTML__", build_functional_area_chart(definitions))
        .replace("__DEFINITION_SECTIONS_HTML__", build_sections(definitions, definitions=True))
    )


def main():
    tests = discover_tests()
    definitions = discover_definitions()
    open_pr_numbers = mark_open_pr_tests(tests)

    tests = sorted(
        tests,
        key=lambda x: (
            x["Area"],
            x["Functional Area"],
            x["Subarea"],
            x["Suite Path"],
        ),
    )

    total_tests = len(tests)
    merged_tests = sum(1 for test in tests if test["Present on main"] == "yes")
    open_pr_count = len(open_pr_numbers)
    new_test_suites_in_open_prs = sum(
        1 for test in tests if test["Present on main"] == "no" and test["Open PR"]
    )
    existing_suites_updated_in_open_prs = sum(
        1 for test in tests if test["Present on main"] == "yes" and test["Update PR"]
    )

    generated_at_utc = datetime.now(timezone.utc).strftime("%Y-%m-%d %H:%M:%S UTC")
    repo_home = REPO_WEB
    repo_actions = f"{REPO_WEB}/actions"
    repo_suites = f"{MAIN_TREE}/Runner/suites"

    functional_area_chart_html = build_functional_area_chart(tests)
    sections_html = build_sections(tests)

    print(
        build_html(
            generated_at_utc=generated_at_utc,
            repo_home=repo_home,
            repo_actions=repo_actions,
            repo_suites=repo_suites,
            total_tests=total_tests,
            merged_tests=merged_tests,
            open_pr_count=open_pr_count,
            new_test_suites_in_open_prs=new_test_suites_in_open_prs,
            existing_suites_updated_in_open_prs=existing_suites_updated_in_open_prs,
            functional_area_chart_html=functional_area_chart_html,
            sections_html=sections_html,
            definitions=definitions,
        )
    )


if __name__ == "__main__":
    main()

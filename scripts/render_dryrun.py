#!/usr/bin/env python3
"""
Render `docs/STUDY_DEVICE_DRYRUN.md` into a self-contained
`docs/STUDY_DEVICE_DRYRUN.html` that opens via file:// with no
tooling and prints cleanly to paper.

Why: Markdown opens as plain text in most editors on this machine —
headings, tables and lists render as literal `#`/`|`/`-` characters,
unreadable as a step-by-step procedure. This mirrors
`scripts/render_checklist.py`'s approach (same self-contained,
zero-dependency shape) but extends it with two things the dry-run doc
needs that the checklist doesn't: pipe TABLES (the failure catalogue)
and soft-wrapped list/paragraph TEXT (this doc's prose bullets wrap
across multiple source lines; the checklist's are one line each). No
checkboxes, no localStorage — this is a procedure to follow and print,
not a tickable list.

Re-run after editing STUDY_DEVICE_DRYRUN.md:

    python3 scripts/render_dryrun.py

Output: docs/STUDY_DEVICE_DRYRUN.html (overwrites).
"""
from __future__ import annotations

import html
import re
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SRC  = ROOT / "docs" / "STUDY_DEVICE_DRYRUN.md"
OUT  = ROOT / "docs" / "STUDY_DEVICE_DRYRUN.html"


# ----- Inline-mark converters (run on already-escaped HTML) -----

def _inline(text: str) -> str:
    text = re.sub(r"`([^`]+?)`", r"<code>\1</code>", text)
    text = re.sub(r"\*\*([^*]+?)\*\*", r"<strong>\1</strong>", text)
    text = re.sub(r"(?<!\*)\*([^*\n]+?)\*(?!\*)", r"<em>\1</em>", text)
    text = re.sub(r"\[([^\]]+?)\]\(([^)]+?)\)", r'<a href="\2">\1</a>', text)
    return text


def _escape(line: str) -> str:
    return html.escape(line, quote=False)


def _fmt(text: str) -> str:
    return _inline(_escape(text))


# ----- Soft-wrap merge: join a list/paragraph item's wrapped lines -----

_BLOCK_START = re.compile(
    r"^(#{1,6}\s|>|-\s|\d+\.\s|\|)"
)


def merge_soft_wraps(md: str) -> str:
    """Join a paragraph/list-item's word-wrapped source lines into one
    logical line, WITHOUT gluing the next block's first line onto
    whatever text (even a blank line) preceded it — only a line that is
    itself plain, wrapped prose (or a bullet/numbered item's own first
    line) may receive a continuation."""
    out: list[str] = []
    in_code = False
    prev_continuable = False
    for raw in md.splitlines():
        stripped = raw.strip()
        if stripped.startswith("```"):
            in_code = not in_code
            out.append(raw)
            prev_continuable = False
            continue
        if in_code:
            out.append(raw)
            continue
        if stripped == "":
            out.append(raw)
            prev_continuable = False
            continue
        starts_new_block = bool(_BLOCK_START.match(stripped)) or stripped == "---"
        if starts_new_block or not prev_continuable:
            out.append(raw)
        else:
            out[-1] = out[-1].rstrip() + " " + stripped
        # A heading/quote/hr/table row never accepts a continuation line;
        # a bullet, numbered item, or bare paragraph line always does.
        prev_continuable = not (
            stripped.startswith("#") or stripped.startswith(">")
            or stripped == "---" or stripped.startswith("|")
        )
    return "\n".join(out)


# ----- Table helpers -----

_TABLE_SEP = re.compile(r"^\|[\s:\-]+\|[\s:\-|]*$")


def _split_row(line: str) -> list[str]:
    inner = line.strip()
    if inner.startswith("|"):
        inner = inner[1:]
    if inner.endswith("|"):
        inner = inner[:-1]
    return [cell.strip() for cell in inner.split("|")]


# ----- Block-level converter -----

def render(md: str) -> str:
    lines = merge_soft_wraps(md).splitlines()
    out: list[str] = []
    in_list = False
    in_ol = False
    in_code = False
    i = 0
    n = len(lines)

    def close_lists() -> None:
        nonlocal in_list, in_ol
        if in_list:
            out.append("</ul>")
            in_list = False
        if in_ol:
            out.append("</ol>")
            in_ol = False

    while i < n:
        line = lines[i].rstrip()

        if line.startswith("```"):
            close_lists()
            if in_code:
                out.append("</code></pre>")
                in_code = False
            else:
                out.append("<pre><code>")
                in_code = True
            i += 1
            continue
        if in_code:
            out.append(_escape(line))
            i += 1
            continue

        if line == "---":
            close_lists()
            out.append("<hr>")
            i += 1
            continue

        m = re.match(r"^(#{1,6})\s+(.*)$", line)
        if m:
            close_lists()
            level = len(m.group(1))
            out.append(f"<h{level}>{_fmt(m.group(2))}</h{level}>")
            i += 1
            continue

        # Table: a `| ... |` row immediately followed by a separator row.
        if line.strip().startswith("|") and i + 1 < n and _TABLE_SEP.match(lines[i + 1].strip()):
            close_lists()
            header = _split_row(line)
            out.append('<div class="table-wrap"><table><thead><tr>')
            out.extend(f"<th>{_fmt(c)}</th>" for c in header)
            out.append("</tr></thead><tbody>")
            i += 2
            while i < n and lines[i].strip().startswith("|"):
                row = _split_row(lines[i])
                out.append("<tr>")
                out.extend(f"<td>{_fmt(c)}</td>" for c in row)
                out.append("</tr>")
                i += 1
            out.append("</tbody></table></div>")
            continue

        if line.startswith(">"):
            close_lists()
            content = line[1:].lstrip()
            out.append(f"<blockquote><p>{_fmt(content)}</p></blockquote>")
            i += 1
            continue

        m = re.match(r"^(\s*)-\s+(.*)$", line)
        if m:
            if in_ol:
                out.append("</ol>")
                in_ol = False
            if not in_list:
                out.append("<ul>")
                in_list = True
            indent = len(m.group(1))
            cls = ' class="sub"' if indent >= 2 else ""
            out.append(f"<li{cls}>{_fmt(m.group(2))}</li>")
            i += 1
            continue

        m = re.match(r"^\d+\.\s+(.*)$", line)
        if m:
            if in_list:
                out.append("</ul>")
                in_list = False
            if not in_ol:
                out.append("<ol>")
                in_ol = True
            out.append(f"<li>{_fmt(m.group(1))}</li>")
            i += 1
            continue

        if not line.strip():
            close_lists()
            i += 1
            continue

        close_lists()
        out.append(f"<p>{_fmt(line)}</p>")
        i += 1

    close_lists()
    if in_code:
        out.append("</code></pre>")
    return "\n".join(out)


HTML_SHELL = """<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Primae · Study Device Dry-Run</title>
<style>
  :root {
    --paper: #FDF8EE;
    --paper-deep: #F6EFDD;
    --paper-edge: #ECE2C8;
    --ink: #0F172A;
    --ink-soft: #475569;
    --ink-faint: #94A3B8;
    --brand: #2563EB;
    --brand-soft: #DBEAFE;
    --danger: #B91C1C;
  }
  * { box-sizing: border-box; }
  body {
    font-family: -apple-system, BlinkMacSystemFont, "Segoe UI",
                 "Helvetica Neue", system-ui, sans-serif;
    max-width: 880px;
    margin: 0 auto;
    padding: 0 1.5rem 4rem;
    color: var(--ink);
    background: var(--paper);
    line-height: 1.55;
  }
  h1 { color: var(--brand); margin: 1.6rem 0 0.5rem; font-size: 2rem; }
  h2 {
    margin-top: 2.4rem;
    border-bottom: 1px solid var(--paper-edge);
    padding-bottom: 0.4rem;
    color: var(--ink);
  }
  h3 { color: var(--brand); margin-top: 1.8rem; }
  code {
    background: var(--paper-deep);
    padding: 0.08rem 0.34rem;
    border-radius: 4px;
    font-size: 0.92em;
    border: 1px solid var(--paper-edge);
  }
  pre code { display: block; padding: 0.6rem 0.8rem; overflow-x: auto; border: 1px solid var(--paper-edge); border-radius: 8px; }
  pre { margin: 1rem 0; }
  blockquote {
    background: var(--paper-deep);
    border-left: 4px solid var(--brand);
    margin: 1rem 0;
    padding: 0.6rem 1rem;
    border-radius: 0 8px 8px 0;
  }
  blockquote p { margin: 0.4rem 0; color: var(--ink-soft); }
  ul, ol { padding-left: 1.4rem; margin: 0.6rem 0; }
  ul { list-style: none; padding-left: 0; }
  li { margin: 0.5rem 0; padding-left: 1.6rem; position: relative; }
  li::before { content: "•"; position: absolute; left: 0.3rem; color: var(--brand); }
  li.sub { color: var(--ink-soft); padding-left: 2.4rem; }
  li.sub::before { content: "—"; left: 1.4rem; color: var(--ink-faint); }
  ol li { padding-left: 0.3rem; }
  ol li::before { content: none; }
  hr { border: 0; border-top: 1px solid var(--paper-edge); margin: 2rem 0; }
  a { color: var(--brand); }
  .table-wrap { overflow-x: auto; margin: 1rem 0; }
  table { border-collapse: collapse; width: 100%; font-size: 0.92rem; }
  th, td { border: 1px solid var(--paper-edge); padding: 0.5rem 0.7rem; text-align: left; vertical-align: top; }
  th { background: var(--paper-deep); }
  tbody tr:nth-child(even) { background: rgba(0,0,0,0.015); }
  .toolbar {
    position: sticky; top: 0; background: var(--paper);
    border-bottom: 1px solid var(--paper-edge);
    padding: 0.6rem 1.5rem; margin: 0 -1.5rem 1rem;
    z-index: 10; display: flex; align-items: center; gap: 0.6rem;
  }
  .toolbar button {
    padding: 0.35rem 0.9rem; border: 1px solid var(--paper-edge);
    background: white; border-radius: 999px; color: var(--ink);
    cursor: pointer; font: inherit;
  }
  .toolbar button:hover { background: var(--brand-soft); border-color: var(--brand); }
  .toolbar .hint { color: var(--ink-faint); font-size: 0.85rem; }
  @media print {
    .toolbar { display: none; }
    body { background: white; max-width: none; padding: 0 0.4in; }
    a { color: inherit; text-decoration: none; }
    h2 { break-after: avoid; }
    h3 { break-after: avoid; }
    table, li { break-inside: avoid; }
  }
</style>
</head>
<body>
<div class="toolbar">
  <button onclick="window.print()" type="button">Print / Save as PDF</button>
  <span class="hint">Static page — open directly from Finder, no server needed.</span>
</div>
__CONTENT__
</body>
</html>
"""


def main() -> int:
    if not SRC.exists():
        print(f"Source not found: {SRC}")
        return 1
    md = SRC.read_text(encoding="utf-8")
    body = render(md)
    page = HTML_SHELL.replace("__CONTENT__", body)
    OUT.write_text(page, encoding="utf-8")
    print(f"Wrote {OUT.relative_to(ROOT)}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

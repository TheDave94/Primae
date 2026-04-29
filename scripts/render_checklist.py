#!/usr/bin/env python3
"""
Render `docs/TESTING_CHECKLIST.md` into a self-contained
`docs/testing_checklist.html` with real, persistent checkboxes.

Why: Markdown checkboxes (`- [ ]`) only render as *interactive*
checkboxes inside GitHub Issues / PRs / Discussions. In a repo
`.md` file they're shown as visual squares but are not clickable.
This script generates a sibling HTML page that:

  * renders the same content
  * makes every checkbox a real `<input type="checkbox">`
  * persists checked state to `localStorage` so progress survives
    refreshes and accidental tab closes
  * shows a sticky progress counter ("X / Y")
  * has a "Copy unchecked" button that drops the list of unticked
    items onto the clipboard so you can paste failures back to me
    without retyping
  * includes a "Reset" button (with confirm)

Self-contained: zero external CSS/JS, opens via file://.

Re-run after editing TESTING_CHECKLIST.md:

    python3 scripts/render_checklist.py

Output: docs/testing_checklist.html (overwrites).
"""
from __future__ import annotations

import html
import re
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SRC  = ROOT / "docs" / "TESTING_CHECKLIST.md"
OUT  = ROOT / "docs" / "testing_checklist.html"


# ----- Inline-mark converters (run on plain-text fragments) -----

def _inline(text: str) -> str:
    """Bold / italic / inline-code / links. Run on already-escaped HTML."""
    # Inline code first so its contents aren't further mangled.
    text = re.sub(r"`([^`]+?)`", r"<code>\1</code>", text)
    # Bold (**...**)
    text = re.sub(r"\*\*([^*]+?)\*\*", r"<strong>\1</strong>", text)
    # Italic (*...* but not part of **) — naive but matches the doc.
    text = re.sub(r"(?<!\*)\*([^*\n]+?)\*(?!\*)", r"<em>\1</em>", text)
    # Markdown links [text](url)
    text = re.sub(
        r"\[([^\]]+?)\]\(([^)]+?)\)",
        r'<a href="\2">\1</a>',
        text,
    )
    return text


def _escape(line: str) -> str:
    return html.escape(line, quote=False)


# ----- Block-level converter -----

def render(md: str) -> str:
    out: list[str] = []
    cb_id = 0
    in_blockquote = False
    in_list = False
    in_code = False

    def close_list() -> None:
        nonlocal in_list
        if in_list:
            out.append("</ul>")
            in_list = False

    def close_blockquote() -> None:
        nonlocal in_blockquote
        if in_blockquote:
            out.append("</blockquote>")
            in_blockquote = False

    for raw in md.splitlines():
        line = raw.rstrip()

        # Fenced code blocks (``` ... ```).
        if line.startswith("```"):
            close_list()
            close_blockquote()
            if in_code:
                out.append("</code></pre>")
                in_code = False
            else:
                out.append('<pre><code>')
                in_code = True
            continue
        if in_code:
            out.append(_escape(line))
            continue

        # Horizontal rule.
        if line == "---":
            close_list()
            close_blockquote()
            out.append("<hr>")
            continue

        # Heading.
        m = re.match(r"^(#{1,6})\s+(.*)$", line)
        if m:
            close_list()
            close_blockquote()
            level = len(m.group(1))
            content = _inline(_escape(m.group(2)))
            out.append(f"<h{level}>{content}</h{level}>")
            continue

        # Blockquote.
        if line.startswith("> "):
            close_list()
            if not in_blockquote:
                out.append("<blockquote>")
                in_blockquote = True
            out.append(f"<p>{_inline(_escape(line[2:]))}</p>")
            continue
        if line.startswith(">"):
            # `>` alone or `> ` (above) — handled.
            continue
        else:
            close_blockquote()

        # List item with checkbox.
        m = re.match(r"^- \[( |x|X)\]\s+(.*)$", line)
        if m:
            if not in_list:
                out.append("<ul>")
                in_list = True
            cb_id += 1
            checked = m.group(1).lower() == "x"
            content = _inline(_escape(m.group(2)))
            out.append(
                '<li class="check">'
                f'<input class="cb" type="checkbox" id="cb-{cb_id}"'
                f'{" checked" if checked else ""}>'
                f'<label for="cb-{cb_id}">{content}</label>'
                "</li>"
            )
            continue

        # Plain bullet list item (sub-bullets under a checkbox count too).
        m = re.match(r"^(\s*)-\s+(.*)$", line)
        if m:
            if not in_list:
                out.append("<ul>")
                in_list = True
            indent = len(m.group(1))
            content = _inline(_escape(m.group(2)))
            cls = ' class="sub"' if indent >= 2 else ""
            out.append(f"<li{cls}>{content}</li>")
            continue

        # Numbered list item — render as paragraph with the number
        # inline (the source uses these only inside reporting steps,
        # not for tickable items).
        m = re.match(r"^\s*(\d+)\.\s+(.*)$", line)
        if m:
            close_list()
            num = m.group(1)
            content = _inline(_escape(m.group(2)))
            out.append(f"<p><strong>{num}.</strong> {content}</p>")
            continue

        # Blank line — flush current list, paragraph break.
        if not line:
            close_list()
            out.append("")
            continue

        # Default: paragraph.
        close_list()
        out.append(f"<p>{_inline(_escape(line))}</p>")

    close_list()
    close_blockquote()
    if in_code:
        out.append("</code></pre>")
    return "\n".join(out)


HTML_SHELL = """<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Primae · Testing Checklist</title>
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
    --success: #10B981;
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
  h1 {
    color: var(--brand);
    margin: 1.5rem 0 0.5rem;
    font-size: 2.2rem;
  }
  h2 {
    margin-top: 2.4rem;
    border-bottom: 1px solid var(--paper-edge);
    padding-bottom: 0.4rem;
    color: var(--ink);
  }
  h3 { color: var(--ink-soft); margin-top: 1.6rem; }
  h4 { color: var(--ink-soft); margin-top: 1.2rem; font-size: 1rem; }
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
  ul { list-style: none; padding-left: 0; margin: 0.6rem 0; }
  li {
    margin: 0.45rem 0;
    padding-left: 1.6rem;
    position: relative;
  }
  li.sub {
    color: var(--ink-soft);
    padding-left: 2.4rem;
  }
  li.sub::before {
    content: "—";
    position: absolute;
    left: 1.4rem;
    color: var(--ink-faint);
  }
  li.check {
    margin: 0.55rem 0;
    padding-left: 1.9rem;
  }
  li.check input.cb {
    position: absolute;
    left: 0;
    top: 0.32rem;
    width: 1.1rem;
    height: 1.1rem;
    cursor: pointer;
    accent-color: var(--success);
  }
  li.check label { cursor: pointer; }
  li.check.checked label {
    color: var(--ink-faint);
    text-decoration: line-through;
  }
  hr { border: 0; border-top: 1px solid var(--paper-edge); margin: 2rem 0; }
  a { color: var(--brand); }
  .toolbar {
    position: sticky;
    top: 0;
    background: var(--paper);
    border-bottom: 1px solid var(--paper-edge);
    padding: 0.6rem 0;
    margin: 0 -1.5rem 1rem;
    padding-left: 1.5rem;
    padding-right: 1.5rem;
    z-index: 10;
    display: flex;
    align-items: center;
    gap: 0.6rem;
    flex-wrap: wrap;
  }
  .progress {
    font-weight: 600;
    color: var(--brand);
    font-variant-numeric: tabular-nums;
    min-width: 5rem;
  }
  .progress.complete { color: var(--success); }
  .toolbar button {
    padding: 0.35rem 0.8rem;
    border: 1px solid var(--paper-edge);
    background: white;
    border-radius: 999px;
    color: var(--ink);
    cursor: pointer;
    font: inherit;
  }
  .toolbar button:hover { background: var(--brand-soft); border-color: var(--brand); }
  .toolbar .hint { color: var(--ink-faint); font-size: 0.85rem; margin-left: auto; }
</style>
</head>
<body>
<div class="toolbar">
  <span class="progress" id="progress">0 / 0</span>
  <button id="btn-copy" type="button">Copy unchecked</button>
  <button id="btn-reset" type="button">Reset</button>
  <span class="hint">State is saved in your browser (localStorage).</span>
</div>
__CONTENT__
<script>
(function() {
  const KEY = 'primae-testing-checklist-v1';
  const boxes = Array.from(document.querySelectorAll('input.cb'));
  const progressEl = document.getElementById('progress');

  function loadSaved() {
    let saved = {};
    try { saved = JSON.parse(localStorage.getItem(KEY) || '{}'); } catch (e) {}
    boxes.forEach(cb => {
      if (saved[cb.id] !== undefined) cb.checked = !!saved[cb.id];
      cb.parentElement.classList.toggle('checked', cb.checked);
    });
    update();
  }

  function save() {
    const state = {};
    boxes.forEach(cb => { state[cb.id] = cb.checked; });
    try { localStorage.setItem(KEY, JSON.stringify(state)); } catch (e) {}
  }

  function update() {
    const total = boxes.length;
    const checked = boxes.filter(b => b.checked).length;
    progressEl.textContent = `${checked} / ${total}`;
    progressEl.classList.toggle('complete', total > 0 && checked === total);
  }

  boxes.forEach(cb => {
    cb.addEventListener('change', () => {
      cb.parentElement.classList.toggle('checked', cb.checked);
      save();
      update();
    });
  });

  document.getElementById('btn-reset').addEventListener('click', () => {
    if (!confirm('Reset all ticks?')) return;
    boxes.forEach(cb => {
      cb.checked = false;
      cb.parentElement.classList.remove('checked');
    });
    try { localStorage.removeItem(KEY); } catch (e) {}
    update();
  });

  document.getElementById('btn-copy').addEventListener('click', () => {
    let currentSection = '';
    const lines = [];
    boxes.forEach(cb => {
      if (cb.checked) return;
      // Find the nearest preceding h2/h3 to give context.
      let node = cb.parentElement.previousElementSibling;
      let parentNode = cb.parentElement.parentElement;
      while (node || parentNode) {
        if (node && (node.tagName === 'H2' || node.tagName === 'H3' || node.tagName === 'H4')) {
          currentSection = node.textContent.trim();
          break;
        }
        if (node) { node = node.previousElementSibling; }
        else if (parentNode) {
          node = parentNode.previousElementSibling;
          parentNode = parentNode.parentElement;
        }
      }
      const label = cb.parentElement.querySelector('label')?.textContent.trim() || '';
      lines.push(`[${currentSection}] ${label}`);
    });
    if (lines.length === 0) {
      alert('Everything is ticked.');
      return;
    }
    const out = lines.join('\\n');
    if (navigator.clipboard) {
      navigator.clipboard.writeText(out).then(
        () => alert(`Copied ${lines.length} unchecked item(s) to clipboard.`),
        () => prompt('Could not copy automatically. Select and copy:', out)
      );
    } else {
      prompt('Copy these unchecked items:', out);
    }
  });

  loadSaved();
})();
</script>
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
    n_checkboxes = body.count('class="cb"')
    print(f"Wrote {OUT.relative_to(ROOT)} with {n_checkboxes} checkboxes.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

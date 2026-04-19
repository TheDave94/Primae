#!/usr/bin/env python3
"""
Render docs/APP_OVERVIEW.md to a print-quality PDF.

WeasyPrint handles HTML + CSS → PDF. Markdown is converted to HTML first,
relative image paths are rewritten to absolute, and a CSS stylesheet
gives the PDF a clean academic look (cover page, page breaks, table
styling, monospace code).
"""
import os
import re
import sys
import markdown
import weasyprint

DOCS = "/opt/repos/Buchstaben-Lernen-App/docs"
SRC  = os.path.join(DOCS, "APP_OVERVIEW.md")
OUT  = os.path.join(DOCS, "APP_OVERVIEW.pdf")


def md_to_html(md_text: str) -> str:
    return markdown.markdown(
        md_text,
        extensions=["tables", "fenced_code", "toc", "sane_lists"],
        output_format="html5",
    )


CSS = """
@page {
    size: A4;
    margin: 22mm 18mm 22mm 18mm;
    @bottom-center {
        content: counter(page);
        font-family: -apple-system, system-ui, sans-serif;
        font-size: 9pt;
        color: #888;
    }
    @top-right {
        content: "Buchstaben-Lernen-App · App Overview & Reference";
        font-family: -apple-system, system-ui, sans-serif;
        font-size: 8pt;
        color: #aaa;
    }
}

@page :first {
    margin: 0;
    @top-right { content: none; }
    @bottom-center { content: none; }
}

* { box-sizing: border-box; }

html, body {
    font-family: -apple-system, "Segoe UI", "DejaVu Sans", sans-serif;
    font-size: 10.5pt;
    line-height: 1.55;
    color: #1c1c1e;
}

/* Cover */
.cover {
    page: cover;
    page-break-after: always;
    height: 297mm;  /* A4 height */
    padding: 60mm 30mm 30mm 30mm;
    background: linear-gradient(135deg, #fef3c7 0%, #fde68a 60%, #fcd34d 100%);
    color: #422006;
}
.cover h1 {
    font-size: 32pt;
    font-weight: 800;
    margin: 0 0 8mm 0;
    line-height: 1.1;
}
.cover .subtitle {
    font-size: 14pt;
    font-weight: 500;
    margin-bottom: 24mm;
}
.cover .meta {
    font-size: 10pt;
    color: #78350f;
    margin-top: auto;
}
.cover .meta p { margin: 2mm 0; }

/* Headings */
h1 {
    font-size: 22pt;
    font-weight: 700;
    margin-top: 18pt;
    margin-bottom: 8pt;
    color: #111;
    page-break-after: avoid;
    border-bottom: 1.5pt solid #d4d4d8;
    padding-bottom: 4pt;
}
h2 {
    font-size: 16pt;
    font-weight: 700;
    margin-top: 22pt;
    margin-bottom: 8pt;
    color: #1f2937;
    page-break-after: avoid;
    page-break-before: always;
}
h2:first-of-type { page-break-before: auto; }
h3 {
    font-size: 13pt;
    font-weight: 700;
    margin-top: 16pt;
    margin-bottom: 4pt;
    color: #1f2937;
    page-break-after: avoid;
}
h4 {
    font-size: 11pt;
    font-weight: 700;
    margin-top: 10pt;
    margin-bottom: 3pt;
    color: #374151;
    page-break-after: avoid;
}

p { margin: 4pt 0 6pt 0; }
em { color: #6b7280; }
strong { color: #111; }

/* Lists */
ul, ol { margin: 4pt 0 6pt 0; padding-left: 18pt; }
li { margin: 1pt 0; }

/* Tables */
table {
    width: 100%;
    border-collapse: collapse;
    margin: 8pt 0 12pt 0;
    font-size: 9.5pt;
    page-break-inside: avoid;
}
th, td {
    border: 0.5pt solid #d4d4d8;
    padding: 4pt 6pt;
    text-align: left;
    vertical-align: top;
}
th {
    background-color: #f4f4f5;
    font-weight: 600;
    color: #1f2937;
}
tr:nth-child(even) td { background-color: #fafafa; }

/* Code */
code {
    font-family: "SF Mono", "DejaVu Sans Mono", Consolas, monospace;
    font-size: 9pt;
    background-color: #f4f4f5;
    padding: 1pt 3pt;
    border-radius: 2pt;
    color: #be185d;
}
pre {
    background-color: #1f2937;
    color: #f9fafb;
    padding: 8pt;
    border-radius: 4pt;
    font-size: 8.5pt;
    line-height: 1.4;
    overflow-x: auto;
    page-break-inside: avoid;
}
pre code {
    background: none;
    color: inherit;
    padding: 0;
}

/* Block quotes */
blockquote {
    border-left: 3pt solid #fcd34d;
    margin: 8pt 0;
    padding: 4pt 12pt;
    color: #6b7280;
    background-color: #fffbeb;
}

/* Images */
img {
    max-width: 100%;
    height: auto;
    margin: 6pt auto;
    display: block;
    page-break-inside: avoid;
}
img + em {
    display: block;
    text-align: center;
    font-size: 9pt;
    color: #6b7280;
    margin-top: -3pt;
    margin-bottom: 8pt;
}

/* Horizontal rules */
hr {
    border: none;
    border-top: 0.5pt solid #d4d4d8;
    margin: 14pt 0;
}

/* Anchor links shouldn't underline in print */
a { color: #1d4ed8; text-decoration: none; }
"""

COVER = """
<div class="cover">
    <h1>Buchstaben-Lernen-App</h1>
    <div class="subtitle">App Overview &amp; Reference<br>
        for thesis defence and product positioning
    </div>
    <div class="meta" style="margin-top: 80mm;">
        <p>iPad app · German letter-tracing for ages 5–6</p>
        <p>Three-phase pedagogical model · A/B/C research design</p>
        <p>Generated from <code>docs/APP_OVERVIEW.md</code></p>
    </div>
</div>
"""


def rewrite_image_paths(html: str, base: str) -> str:
    """Make all <img src="diagrams/foo.png"> absolute file:// paths so
    WeasyPrint can resolve them irrespective of CWD."""
    def repl(match):
        src = match.group(1)
        if src.startswith(("http://", "https://", "/", "file:")):
            return match.group(0)
        abs_path = os.path.abspath(os.path.join(base, src))
        return f'src="file://{abs_path}"'
    return re.sub(r'src="([^"]+)"', repl, html)


def main():
    with open(SRC, "r", encoding="utf-8") as f:
        md_text = f.read()

    body_html = md_to_html(md_text)
    body_html = rewrite_image_paths(body_html, DOCS)

    full = f"""<!doctype html>
<html lang="en">
<head>
    <meta charset="utf-8">
    <title>Buchstaben-Lernen-App — App Overview &amp; Reference</title>
    <style>{CSS}</style>
</head>
<body>
{COVER}
{body_html}
</body>
</html>"""

    weasyprint.HTML(string=full, base_url=DOCS).write_pdf(OUT)
    size_kb = os.path.getsize(OUT) // 1024
    print(f"  wrote {OUT} ({size_kb:,} KB)")


if __name__ == "__main__":
    main()

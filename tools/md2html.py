#!/usr/bin/env python
# -*- coding: utf-8 -*-
#
# md2html.py - render a Markdown document as a standalone HTML page.
#
# fetchconfig ships its programming manual as Markdown and as HTML; this
# script produces the HTML. It deliberately has NO dependencies beyond the
# standard library and runs unchanged on Python 2.7 and Python 3.x, so it
# works on an AIX host with only the toolbox Python.
#
# Supported Markdown (the subset the manuals use):
#   # .. ###### headings (with anchor ids)         paragraphs
#   ``` fenced code blocks (language ignored)      `inline code`
#   **bold**  *italic*  ***bold italic***           [text](url)
#   - / * unordered lists, 1. ordered lists,       - [ ] / - [x] task items
#   | tables | with | header row (alignment row honoured)
#   --- horizontal rule                             > blockquote
#   two trailing spaces = line break               HTML-escaping everywhere
#
# Usage:  python md2html.py input.md output.html [--title "Page title"]
#         python md2html.py input.md            (writes input.html)
#
from __future__ import print_function, unicode_literals

import io
import re
import sys

try:                       # Python 3
    from html import escape as _escape
except ImportError:        # Python 2
    from cgi import escape as _escape


def escape(text):
    # Python 3's html.escape also encodes the apostrophe, Python 2's cgi.escape
    # does not; do it ourselves so both interpreters produce identical HTML.
    return _escape(text, True).replace("'", '&#x27;')


# ---------------------------------------------------------------- inline ----

_INLINE_CODE = re.compile(r'`([^`]+)`')
_BOLD_ITALIC = re.compile(r'\*\*\*(.+?)\*\*\*')
_BOLD = re.compile(r'\*\*(.+?)\*\*')
_ITALIC = re.compile(r'(?<![\w*])\*(?!\s)(.+?)(?<!\s)\*(?![\w*])')
_LINK = re.compile(r'\[([^\]]+)\]\(([^)\s]+)\)')
_CHECKBOX = re.compile(r'^\[([ xX])\]\s+')


def render_inline(text):
    """Escape text and convert inline markup. Code spans are protected first
    so their content is never interpreted as markup."""
    codes = []

    def keep_code(m):
        codes.append('<code>%s</code>' % escape(m.group(1)))
        return '\x00%d\x00' % (len(codes) - 1)

    text = _INLINE_CODE.sub(keep_code, text)
    text = escape(text)
    text = _BOLD_ITALIC.sub(r'<strong><em>\1</em></strong>', text)
    text = _BOLD.sub(r'<strong>\1</strong>', text)
    text = _ITALIC.sub(r'<em>\1</em>', text)
    text = _LINK.sub(r'<a href="\2">\1</a>', text)
    text = re.sub(r'  $', '<br>', text)

    def restore(m):
        return codes[int(m.group(1))]

    return re.sub('\x00(\\d+)\x00', restore, text)


def slugify(text):
    text = re.sub(r'`', '', text)
    text = re.sub(r'[^\w\s-]', '', text).strip().lower()
    return re.sub(r'[\s_]+', '-', text) or 'section'


# ----------------------------------------------------------------- block ----

class Renderer(object):
    def __init__(self):
        self.out = []
        self.used_ids = {}
        self.headings = []      # (level, id, text) for the table of contents

    def unique_id(self, base):
        n = self.used_ids.get(base, 0)
        self.used_ids[base] = n + 1
        return base if n == 0 else '%s-%d' % (base, n)

    # -- helpers ------------------------------------------------------------
    @staticmethod
    def is_table_row(line):
        s = line.strip()
        return s.startswith('|') and s.endswith('|') and s.count('|') >= 2

    @staticmethod
    def split_row(line):
        s = line.strip()
        s = s[1:-1]
        cells, cur, i = [], '', 0
        while i < len(s):
            c = s[i]
            if c == '\\' and i + 1 < len(s):
                cur += s[i:i + 2]
                i += 2
                continue
            if c == '|':
                cells.append(cur.strip())
                cur = ''
            else:
                cur += c
            i += 1
        cells.append(cur.strip())
        return [re.sub(r'\\\|', '|', c) for c in cells]

    @staticmethod
    def alignment(cell):
        c = cell.strip()
        if c.startswith(':') and c.endswith(':'):
            return 'center'
        if c.endswith(':'):
            return 'right'
        return 'left'

    @staticmethod
    def list_item(line):
        m = re.match(r'^(\s*)([-*]|\d+\.)\s+(.*)$', line)
        if not m:
            return None
        indent = len(m.group(1).replace('\t', '    '))
        ordered = m.group(2)[0].isdigit()
        return indent, ordered, m.group(3)

    # -- main loop ----------------------------------------------------------
    def render(self, lines):
        i, n = 0, len(lines)
        while i < n:
            line = lines[i]
            stripped = line.strip()

            if not stripped:
                i += 1
                continue

            # fenced code
            if stripped.startswith('```'):
                lang = stripped[3:].strip()
                i += 1
                buf = []
                while i < n and not lines[i].strip().startswith('```'):
                    buf.append(lines[i])
                    i += 1
                i += 1  # closing fence
                cls = ' class="lang-%s"' % escape(lang) if lang else ''
                self.out.append('<pre><code%s>%s</code></pre>' % (cls, escape('\n'.join(buf))))
                continue

            # heading
            m = re.match(r'^(#{1,6})\s+(.*?)\s*#*\s*$', line)
            if m:
                level = len(m.group(1))
                text = m.group(2)
                hid = self.unique_id(slugify(text))
                self.headings.append((level, hid, text))
                self.out.append('<h%d id="%s">%s</h%d>' % (level, hid, render_inline(text), level))
                i += 1
                continue

            # horizontal rule
            if re.match(r'^(-{3,}|\*{3,}|_{3,})\s*$', stripped):
                self.out.append('<hr>')
                i += 1
                continue

            # table
            if self.is_table_row(line) and i + 1 < n and re.match(r'^\s*\|?\s*:?-{3,}', lines[i + 1]):
                header = self.split_row(line)
                aligns = [self.alignment(c) for c in self.split_row(lines[i + 1])]
                i += 2
                rows = []
                while i < n and self.is_table_row(lines[i]):
                    rows.append(self.split_row(lines[i]))
                    i += 1
                html = ['<table>', '<thead><tr>']
                for k, cell in enumerate(header):
                    a = aligns[k] if k < len(aligns) else 'left'
                    html.append('<th style="text-align:%s">%s</th>' % (a, render_inline(cell)))
                html.append('</tr></thead><tbody>')
                for row in rows:
                    html.append('<tr>')
                    for k, cell in enumerate(row):
                        a = aligns[k] if k < len(aligns) else 'left'
                        html.append('<td style="text-align:%s">%s</td>' % (a, render_inline(cell)))
                    html.append('</tr>')
                html.append('</tbody></table>')
                self.out.append(''.join(html))
                continue

            # blockquote
            if stripped.startswith('>'):
                buf = []
                while i < n and lines[i].strip().startswith('>'):
                    buf.append(re.sub(r'^\s*>\s?', '', lines[i]))
                    i += 1
                inner = Renderer()
                inner.used_ids = self.used_ids
                inner.render(buf)
                self.out.append('<blockquote>%s</blockquote>' % ''.join(inner.out))
                continue

            # list (possibly nested by indentation)
            if self.list_item(line):
                i = self.render_list(lines, i)
                continue

            # paragraph: collect until blank line or a block starter
            buf = []
            while i < n and lines[i].strip() and not self.list_item(lines[i]) \
                    and not lines[i].strip().startswith('```') \
                    and not re.match(r'^#{1,6}\s', lines[i]) \
                    and not self.is_table_row(lines[i]) \
                    and not lines[i].strip().startswith('>'):
                buf.append(lines[i].rstrip('\n'))
                i += 1
            if buf:
                self.out.append('<p>%s</p>' % '\n'.join(render_inline(b) for b in buf))
            else:
                i += 1  # safety: never loop forever on an unrecognised line

    def render_list(self, lines, i):
        """Render one list starting at lines[i]; returns the index after it.
        Nesting is by indentation; a nested list belongs to the previous item."""
        n = len(lines)
        first = self.list_item(lines[i])
        base_indent, ordered = first[0], first[1]
        tag = 'ol' if ordered else 'ul'
        html = ['<%s>' % tag]
        while i < n:
            item = self.list_item(lines[i])
            if not item or item[0] < base_indent:
                break
            if item[0] > base_indent:
                # nested list: render it and append to the previous <li>
                sub = Renderer()
                sub.used_ids = self.used_ids
                j = sub.render_list(lines, i)
                if html[-1].endswith('</li>'):
                    html[-1] = html[-1][:-5] + ''.join(sub.out) + '</li>'
                else:
                    html.append('<li>%s</li>' % ''.join(sub.out))
                i = j
                continue
            text = item[2]
            cb = _CHECKBOX.match(text)
            if cb:
                checked = ' checked' if cb.group(1) in 'xX' else ''
                text = text[cb.end():]
                text_html = '<input type="checkbox" disabled%s> %s' % (checked, render_inline(text))
            else:
                text_html = render_inline(text)
            # continuation lines (indented, not a new item) belong to this item
            i += 1
            while i < n and lines[i].strip() and not self.list_item(lines[i]) \
                    and lines[i].startswith(' ' * (base_indent + 2)):
                text_html += ' ' + render_inline(lines[i].strip())
                i += 1
            html.append('<li>%s</li>' % text_html)
        html.append('</%s>' % tag)
        self.out.append(''.join(html))
        return i


# ------------------------------------------------------------------ page ----

CSS = """
:root { --fg:#1f2328; --bg:#ffffff; --muted:#59636e; --line:#d1d9e0; --code:#f6f8fa; --link:#0969da; --accent:#1f6feb; }
@media (prefers-color-scheme: dark) {
  :root { --fg:#e6edf3; --bg:#0d1117; --muted:#9198a1; --line:#3d444d; --code:#161b22; --link:#4493f8; --accent:#4493f8; }
}
html { -webkit-text-size-adjust: 100%; }
body { margin:0; background:var(--bg); color:var(--fg);
  font: 16px/1.55 -apple-system, "Segoe UI", Roboto, Helvetica, Arial, sans-serif; }
main { max-width: 900px; margin: 0 auto; padding: 32px 24px 64px; }
nav.toc { border:1px solid var(--line); border-radius:6px; padding:12px 18px; margin:24px 0 32px; background:var(--code); }
nav.toc strong { display:block; margin-bottom:6px; }
nav.toc ul { margin:0; padding-left:18px; }
nav.toc li { margin:2px 0; }
h1, h2, h3, h4 { line-height:1.25; margin:1.6em 0 .6em; font-weight:600; }
h1 { font-size:2em; border-bottom:1px solid var(--line); padding-bottom:.3em; margin-top:0; }
h2 { font-size:1.5em; border-bottom:1px solid var(--line); padding-bottom:.3em; }
h3 { font-size:1.2em; }
h4 { font-size:1em; }
h2 a.anchor, h3 a.anchor { visibility:hidden; text-decoration:none; color:var(--muted); margin-left:.3em; }
h2:hover a.anchor, h3:hover a.anchor { visibility:visible; }
p { margin: 0 0 1em; }
a { color: var(--link); }
code { font: 0.9em/1.45 ui-monospace, SFMono-Regular, Menlo, Consolas, "Liberation Mono", monospace;
  background: var(--code); padding: .15em .35em; border-radius: 4px; }
pre { background: var(--code); border:1px solid var(--line); border-radius: 6px; padding: 14px 16px; overflow-x: auto; margin: 0 0 1.2em; }
pre code { background: none; padding: 0; font-size: 0.85em; }
table { border-collapse: collapse; width: 100%; margin: 0 0 1.2em; display:block; overflow-x:auto; }
th, td { border: 1px solid var(--line); padding: 6px 12px; vertical-align: top; }
th { background: var(--code); }
tr:nth-child(even) td { background: rgba(127,127,127,.06); }
blockquote { border-left: 4px solid var(--line); margin: 0 0 1em; padding: 0 1em; color: var(--muted); }
hr { border: 0; border-top: 1px solid var(--line); margin: 2em 0; }
ul, ol { margin: 0 0 1em; padding-left: 2em; }
li { margin: .2em 0; }
input[type=checkbox] { margin-right: .4em; }
footer { color: var(--muted); font-size: .85em; border-top: 1px solid var(--line); margin-top: 3em; padding-top: 1em; }
"""


def build_page(title, body_html, toc_html, source_name):
    return ('<!DOCTYPE html>\n<html lang="en">\n<head>\n<meta charset="utf-8">\n'
            '<meta name="viewport" content="width=device-width, initial-scale=1">\n'
            '<title>%s</title>\n<style>%s</style>\n</head>\n<body>\n<main>\n%s\n%s\n'
            '<footer>Generated from <code>%s</code> by <code>md2html.py</code>.</footer>\n'
            '</main>\n</body>\n</html>\n') % (escape(title), CSS, toc_html, body_html, escape(source_name))


def build_toc(headings):
    items = [(lvl, hid, txt) for (lvl, hid, txt) in headings if 2 <= lvl <= 3]
    if not items:
        return ''
    html = ['<nav class="toc"><strong>Contents</strong><ul>']
    depth = 2
    for lvl, hid, txt in items:
        while depth < lvl:
            html.append('<ul>')
            depth += 1
        while depth > lvl:
            html.append('</ul>')
            depth -= 1
        html.append('<li><a href="#%s">%s</a></li>' % (hid, render_inline(txt)))
    while depth > 2:
        html.append('</ul>')
        depth -= 1
    html.append('</ul></nav>')
    return ''.join(html)


def convert(md_text, source_name, title=None):
    lines = md_text.replace('\r\n', '\n').replace('\r', '\n').split('\n')
    r = Renderer()
    r.render(lines)
    if title is None:
        h1 = [t for (lvl, _, t) in r.headings if lvl == 1]
        title = re.sub(r'[`*]', '', h1[0]) if h1 else source_name
    return build_page(title, '\n'.join(r.out), build_toc(r.headings), source_name)


def _u(value):
    """Return value as text. Under Python 2, argv items are bytes; decode them
    as UTF-8 so a non-ASCII --title (e.g. an em dash) is handled correctly."""
    if isinstance(value, bytes):
        return value.decode('utf-8')
    return value


def main(argv):
    argv = [_u(a) for a in argv]
    args = [a for a in argv[1:] if not a.startswith('--')]
    title = None
    if '--title' in argv:
        k = argv.index('--title')
        if k + 1 < len(argv):
            title = argv[k + 1]
            args = [a for a in args if a != title]
    if not args:
        print('usage: md2html.py input.md [output.html] [--title "Title"]', file=sys.stderr)
        return 2
    src = args[0]
    dst = args[1] if len(args) > 1 else re.sub(r'\.(md|markdown)$', '', src) + '.html'
    with io.open(src, 'r', encoding='utf-8') as f:
        md = f.read()
    html = convert(md, src.split('/')[-1], title)
    with io.open(dst, 'w', encoding='utf-8') as f:
        f.write(html)
    print('%s -> %s' % (src, dst))
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv))

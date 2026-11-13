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
#         python md2html.py -V | --version      (print version and exit)
#
from __future__ import print_function, unicode_literals

import io
import re
import sys

# Kept in step with fetchconfig's version by hand. NOT imported from
# fetchconfig::Constants, so this tool is self-contained and can be copied
# and run on its own.
VERSION = '9.74'

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
        self.uses_mermaid = False
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
                if lang == 'mermaid':
                    # Mermaid source rendered client-side (CDN). The diagram
                    # text is escaped so it is valid HTML, but kept as the
                    # textContent of <pre class="mermaid"> for mermaid.run().
                    # Mermaid needs the RAW diagram source: arrows like -->>,
                    # quoted labels and the & fan-out must not be HTML-escaped
                    # (escaping turns -->> into --&gt;&gt;, which the stricter
                    # mermaid.ink parser rejects as a syntax error). Guard only
                    # the two characters that could break HTML parsing of the
                    # <pre> itself - & and < - and leave >, " and the rest raw.
                    self.uses_mermaid = True
                    raw = '\n'.join(buf).replace('&', '&amp;').replace('<', '&lt;')
                    self.out.append('<pre class="mermaid">%s</pre>' % raw)
                else:
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
@media print {
  /* smaller, print-native type -- match the fetchconfig-web / render-doc.py docs on paper */
  html { font-size:10pt; }
  body { font-size:10pt; }
  nav.toc { display:none; }
  a { color:inherit; text-decoration:none; }
  pre { font-size:8.5pt; white-space:pre-wrap; }
}
"""


MERMAID_HEAD = (
    '<script type="module">\n'
    'import mermaid from "https://cdn.jsdelivr.net/npm/mermaid@11.6.0/dist/mermaid.esm.min.mjs";\n'
    'mermaid.initialize({ startOnLoad: true, securityLevel: "strict" });\n'
    '</script>\n')


def build_page(title, body_html, toc_html, source_name, uses_mermaid=False):
    return ('<!DOCTYPE html>\n<html lang="en">\n<head>\n<meta charset="utf-8">\n'
            '<meta name="viewport" content="width=device-width, initial-scale=1">\n'
            '<title>%s</title>\n<style>%s</style>\n%s</head>\n<body>\n<main>\n%s\n%s\n'
            '<footer>Generated from <code>%s</code> by <code>md2html.py</code>.</footer>\n'
            '</main>\n</body>\n</html>\n') % ((title[5:] if title.startswith('\x00RAW\x00') else escape(title)), CSS, (MERMAID_HEAD if uses_mermaid else ''), toc_html, body_html, escape(source_name))


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



def _preprocess_mermaid(md_text):
    """For HTML generation: replace each <!--MERMAID ... MERMAID--> comment with
    a ```mermaid fenced block, and drop an immediately-preceding ```text ... ```
    ASCII fence (its role is the .md / offline fallback only). The Markdown
    source is unchanged; only the text handed to the HTML renderer is rewritten.
    So the .md shows ASCII (+ an invisible comment) and the HTML shows Mermaid."""
    import re as _re
    # drop a ```text ... ``` fence that sits right before a <!--MERMAID ...-->
    md_text = _re.sub(
        r"```text\n.*?\n```\n(\s*)<!--MERMAID\n",
        r"\1<!--MERMAID\n",
        md_text, flags=_re.S)
    # turn the comment into a mermaid fence
    md_text = _re.sub(
        r"<!--MERMAID\n(.*?)\nMERMAID-->",
        lambda m: "```mermaid\n" + m.group(1) + "\n```",
        md_text, flags=_re.S)
    return md_text



def _ascii_entities(html_text):
    """Convert every non-ASCII character to a numeric HTML entity (&#NNNN;),
    so the generated .html is pure 7-bit ASCII and safe to edit in a
    non-Unicode editor (vi without Unicode support). ASCII bytes pass through
    unchanged; a browser renders the entities identically to the characters."""
    return "".join(
        ch if ord(ch) < 128 else "&#%d;" % ord(ch) for ch in html_text)


def convert(md_text, source_name, title=None, help_subtitle=None):
    md_text = _preprocess_mermaid(md_text)
    lines = md_text.replace('\r\n', '\n').replace('\r', '\n').split('\n')
    r = Renderer()
    r.render(lines)
    if title is None:
        h1 = [t for (lvl, _, t) in r.headings if lvl == 1]
        h1text = re.sub(r'[`*]', '', h1[0]) if h1 else source_name
        # Help-menu title convention: an H1 written "fetchconfig -- <Subtitle>"
        # (ASCII double hyphen - the single source of the title, shared with the
        # plain-text render) becomes <title>fetchconfig &mdash; <Subtitle></title>.
        # An explicit --help-subtitle still overrides. The RAW marker keeps the
        # literal &mdash; entity through escape() and _ascii_entities().
        m = re.match(r'^\s*fetchconfig\s*--\s*(.+?)\s*$', h1text)
        if help_subtitle is not None:
            title = "\x00RAW\x00fetchconfig &mdash; " + help_subtitle
        elif m:
            title = "\x00RAW\x00fetchconfig &mdash; " + escape(m.group(1))
        else:
            title = h1text
    return build_page(title, '\n'.join(r.out), build_toc(r.headings), source_name, r.uses_mermaid)


def _u(value):
    """Return value as text. Under Python 2, argv items are bytes; decode them
    as UTF-8 so a non-ASCII --title (e.g. an em dash) is handled correctly."""
    if isinstance(value, bytes):
        return value.decode('utf-8')
    return value


def _verbatim_passthrough(md):
    """If the document is nothing but a single H1 title followed by one fenced
    code block (a wrapped verbatim artifact, e.g. a license in LICENSE.md),
    return the fence body EXACTLY as-is for the plain-text render: no heading,
    no indentation, no transliteration. This keeps a verbatim legal text
    byte-identical through the .md -> text conversion. Returns None if the
    document is not of that shape (then to_text renders it normally)."""
    s = re.sub(r'<!--MERMAID.*?MERMAID-->', '', md, flags=re.DOTALL)
    s = re.sub(r'<!--.*?-->', '', s, flags=re.DOTALL)
    lines = s.replace('\r\n', '\n').split('\n')
    k = 0
    while k < len(lines) and lines[k].strip() == '':      # leading blanks
        k += 1
    if k >= len(lines) or not re.match(r'^#\s+\S', lines[k]):   # need an H1
        return None
    k += 1
    while k < len(lines) and lines[k].strip() == '':      # blanks after title
        k += 1
    if k >= len(lines) or not lines[k].lstrip().startswith('```'):  # opening fence
        return None
    k += 1
    body = []
    while k < len(lines) and not lines[k].lstrip().startswith('```'):
        body.append(lines[k])
        k += 1
    if k >= len(lines):                                    # unterminated fence
        return None
    k += 1                                                 # closing fence
    while k < len(lines):                                  # only blanks may follow
        if lines[k].strip() != '':
            return None
        k += 1
    return '\n'.join(body) + '\n'


def to_text(md, wrap_width=None):
    """Render Markdown to a readable plain-text version: strip the inline and
    block markup, keep the structure (headings underlined, list bullets,
    fenced code indented, pipe tables as aligned columns). Good enough for a
    README.foo companion to the README.foo.html, from a single README.foo.md
    source. With wrap_width set, prose (paragraphs, list items, blockquotes)
    is wrapped to that column count; code blocks, tables and headings are left
    verbatim, and an over-long token (e.g. a URL) is never broken."""
    verbatim = _verbatim_passthrough(md)
    if verbatim is not None:
        return verbatim
    import textwrap
    def _wrap(text, initial='', subsequent=''):
        if wrap_width is None:
            return [initial + text]
        text = _ascii(text)                  # measure width on the final ASCII
        if not text.strip():
            return ['']
        return textwrap.wrap(text, width=wrap_width,
                             initial_indent=initial, subsequent_indent=subsequent,
                             break_long_words=False, break_on_hyphens=False)
    out = []
    # drop HTML comment blocks so they never leak into the plain-text render.
    # The <!--MERMAID ... MERMAID--> diagram sources are matched first and by
    # their own end marker, because a Mermaid arrow ("-->") would otherwise end
    # a generic <!-- ... --> match early. Each diagram's readable ASCII fallback
    # is a separate fenced block and is kept.
    # the <!--stats--> ... <!--/stats--> hero tiles are a styled-HTML-only
    # element (consumed by render-doc.py); drop the whole block, content and
    # all, so it never appears in the plain-text companion.
    md = re.sub(r'<!--stats-->.*?<!--/stats-->', '', md, flags=re.DOTALL)
    md = re.sub(r'<!--MERMAID.*?MERMAID-->', '', md, flags=re.DOTALL)
    md = re.sub(r'<!--.*?-->', '', md, flags=re.DOTALL)
    lines = md.replace('\r\n', '\n').split('\n')
    in_code = False
    i = 0
    n = len(lines)
    while i < n:
        raw = lines[i]
        line = raw
        # fenced code blocks: keep verbatim, indented, drop the fences. A
        # ```railroad fence is an SVG-only syntax diagram -- drop its body (the SVG
        # name + caption) and leave a short placeholder for the plain-text render.
        m = re.match(r'^\s*```(.*)$', line)
        if m and not in_code and m.group(1).strip().lower() == 'railroad':
            i += 1
            body = []
            while i < n and not re.match(r'^\s*```', lines[i]):
                body.append(lines[i]); i += 1
            i += 1  # closing fence
            name = body[0].strip() if body else ''
            caption = ' '.join(b.strip() for b in body[1:] if b.strip())
            out.append('[syntax diagram: %s - see the HTML documentation]' % name
                       if name else '[syntax diagram]')
            if caption:
                out.append(caption)
            continue
        if m:
            in_code = not in_code
            i += 1
            continue
        if in_code:
            out.append('    ' + line)
            i += 1
            continue
        # pipe table: a row of |...| followed by a |---|---| separator
        if (line.strip().startswith('|') and i + 1 < n
                and re.match(r'^\s*\|?[\s:|-]*-{3,}[\s:|-]*\|?\s*$', lines[i + 1])):
            rows = []
            header = _split_row(line)
            i += 2  # skip header and separator
            while i < n and lines[i].strip().startswith('|'):
                rows.append(_split_row(lines[i]))
                i += 1
            if wrap_width and _should_wrap_last(header, rows, wrap_width):
                out.extend(_format_table_wrapped(header, rows, wrap_width))
            else:
                out.extend(_format_table(header, rows))
            continue
        # ASCII "####..." info box (rule line of >=8 '#'): keep verbatim so the
        # box is not mis-parsed as headings.
        if re.match(r'^#{8,}\s*$', line):
            out.append(line.rstrip()); i += 1
            while i < n and not re.match(r'^#{8,}\s*$', lines[i]):
                out.append(lines[i].rstrip()); i += 1
            if i < n:
                out.append(lines[i].rstrip()); i += 1
            continue
        # headings: text then an underline of = or -
        h = re.match(r'^(#{1,6})\s+(.*)$', line)
        if h:
            level = len(h.group(1))
            # strip trailing styled-heading attributes ({#id}, {nav: ...},
            # {.class}) that render-doc.py consumes; they are not plain text.
            htext = re.sub(r'(?:\s*\{[^}]*\})+\s*$', '', h.group(2))
            text = _inline_text(htext)
            out.append('')
            out.append(text)
            out.append(('=' if level <= 2 else '-') * max(3, len(text)))
            i += 1
            continue
        # list items: keep the original marker (-, *, + or "N.") and indent, so
        # a changelog written with "+" bullets round-trips as "+" in the text.
        li = re.match(r'^(\s*)([-*+]|\d+\.)\s+(.*)$', line)
        if li:
            indent, marker, text = li.group(1), li.group(2), li.group(3)
            prefix = '%s%s ' % (indent, marker)
            cont = '%s%s' % (indent, ' ' * (len(marker) + 1))
            out.extend(_wrap(_inline_text(text), initial=prefix, subsequent=cont))
            i += 1
            continue
        # horizontal rule
        if re.match(r'^\s*([-*_])\1{2,}\s*$', line):
            out.append('-' * 60)
            i += 1
            continue
        # blockquote
        bq = re.match(r'^\s*>\s?(.*)$', line)
        if bq:
            content = bq.group(1)
            # A GitHub-alert marker on the first line ("> [!NOTE] Title",
            # "> [!WARNING] ...") is not literal text: render it as a plain
            # label in the text twin instead of leaking "[!note]".
            am = re.match(r'^\[!(\w+)\]\s*(.*)$', content)
            if am:
                t = am.group(1).upper()
                label = ('WARNING' if t in ('WARNING', 'CAUTION', 'WARN')
                         else '' if t in ('PLAIN', 'BOX', 'NEUTRAL')
                         else 'NOTE')
                title = am.group(2).strip()
                hdr = (label + (': ' + title if title else '')) if label else title
                if hdr:
                    out.extend(_wrap(_inline_text(hdr), initial='    ', subsequent='    '))
                i += 1
                continue
            out.extend(_wrap(_inline_text(content), initial='    ', subsequent='    '))
            i += 1
            continue
        out.extend(_wrap(_inline_text(line)))
        i += 1
    text = '\n'.join(out)
    text = re.sub(r'\n{3,}', '\n\n', text)   # collapse blank runs
    text = _ascii(text)                        # READMEs are US-ASCII
    return text.lstrip('\n') + '\n'


def _split_row(line):
    """Split a Markdown table row into cell texts (inline markup stripped)."""
    s = line.strip()
    s = re.sub(r'^\|', '', s)
    s = re.sub(r'\|$', '', s)
    # split on unescaped pipes, then unescape \|. Cells are transliterated to
    # ASCII here so table column widths are measured on the final text (a cell
    # like "&#10003;" -> "yes" must be its final width before alignment).
    cells = re.split(r'(?<!\\)\|', s)
    return [_ascii(_inline_text(c.strip().replace('\\|', '|'))) for c in cells]


def _format_table(header, rows):
    """Format a table as aligned plain-text columns."""
    cols = max([len(header)] + [len(r) for r in rows]) if rows else len(header)
    def pad(r):
        return r + [''] * (cols - len(r))
    header = pad(header)
    rows = [pad(r) for r in rows]
    widths = [len(header[c]) for c in range(cols)]
    for r in rows:
        for c in range(cols):
            widths[c] = max(widths[c], len(r[c]))
    def fmt(r):
        return '  '.join(r[c].ljust(widths[c]) for c in range(cols)).rstrip()
    out = ['']
    out.append(fmt(header))
    out.append('  '.join('-' * widths[c] for c in range(cols)))
    for r in rows:
        out.append(fmt(r))
    out.append('')
    return out


def _should_wrap_last(header, rows, width, gap=2):
    """True when a table's LAST column is a wide prose column that should be
    wrapped to fit `width` (a Key/Requirement/Description style table), and
    False when the table is wide only because it has many short columns (the
    per-model option matrix), which is left unwrapped."""
    cols = max([len(header)] + [len(r) for r in rows]) if rows else len(header)
    if cols < 2:
        return False
    w = [0] * cols
    for r in [header] + rows:
        rr = [_ascii(x) for x in r] + [''] * (cols - len(r))
        for c in range(cols):
            w[c] = max(w[c], len(rr[c]))
    fixed = cols - 1
    prefix_w = sum(w[:fixed]) + gap * fixed
    last_avail = width - prefix_w
    return last_avail >= 30 and w[fixed] > last_avail


def _format_table_wrapped(header, rows, width=80):
    """Render a table to `width` columns: every column but the last is left-
    justified at its natural width; the last (description) column is word-
    wrapped, with continuation lines aligned under it. Matches the README
    option-table style and keeps the text companion within `width` columns.
    An unbreakable token (e.g. a URL) may still exceed `width`."""
    gap = 2
    cols = max([len(header)] + [len(r) for r in rows]) if rows else len(header)

    def pad(r):
        return [_ascii(x) for x in r] + [''] * (cols - len(r))
    H = pad(header)
    R = [pad(r) for r in rows]
    fixed = cols - 1
    w = [len(H[c]) for c in range(cols)]
    for r in R:
        for c in range(cols):
            w[c] = max(w[c], len(r[c]))
    prefix_w = sum(w[:fixed]) + gap * fixed
    last_avail = max(30, width - prefix_w)

    def wrap_last(text):
        words = text.split()
        if not words:
            return ['']
        lines = []
        cur = ''
        for wd in words:
            if cur == '':
                cur = wd
            elif len(cur) + 1 + len(wd) <= last_avail:
                cur += ' ' + wd
            else:
                lines.append(cur); cur = wd
        if cur:
            lines.append(cur)
        return lines

    def rowfmt(cells):
        prefix = ''.join(cells[c].ljust(w[c]) + ' ' * gap for c in range(fixed))
        wl = wrap_last(cells[fixed])
        res = [prefix + wl[0]]
        for ln in wl[1:]:
            res.append(' ' * len(prefix) + ln)
        return res

    out = ['']
    out.extend(rowfmt(H))
    out.append(''.join('-' * w[c] + ' ' * gap for c in range(fixed))
               + '-' * last_avail)
    for r in R:
        out.extend(rowfmt(r))
    out.append('')
    return out


def _ascii(s):
    """Transliterate the common non-ASCII typographic characters to ASCII so
    the generated plain-text README stays US-ASCII."""
    for a, b in ((u'\u2014', ' - '), (u'\u2013', '-'), (u'\u2018', "'"),
                 (u'\u2019', "'"), (u'\u201c', '"'), (u'\u201d', '"'),
                 (u'\u2192', '->'), (u'\u2190', '<-'), (u'\u2026', '...'),
                 (u'\u00a0', ' '), (u'\u00b7', '*'), (u'\u2713', 'yes'),
                 (u'\u2717', 'no'), (u'\u2265', '>='), (u'\u2264', '<='),
                 (u'\u00d7', 'x'), (u'\u2010', '-'), (u'\u2011', '-'),
                 (u'\u2012', '-'), (u'\u2015', '-')):
        s = s.replace(a, b)
    return s


try:
    _unichr = unichr          # Python 2
except NameError:
    _unichr = chr             # Python 3


def _unescape(s):
    """Decode the HTML entities the docs use, into their characters (which
    _ascii() then transliterates to ASCII). Dependency-free and portable to
    Python 2.7 and 3.x, so it does not rely on html.unescape()."""
    def _num(m):
        code = m.group(1)
        try:
            n = int(code[1:], 16) if code[:1] in ('x', 'X') else int(code)
            return _unichr(n)
        except (ValueError, OverflowError):
            return m.group(0)
    s = re.sub(r'&#([xX]?[0-9a-fA-F]+);', _num, s)
    for name, ch in (('lt', '<'), ('gt', '>'), ('quot', '"'), ('apos', "'"),
                     ('mdash', u'\u2014'), ('ndash', u'\u2013'),
                     ('rarr', u'\u2192'), ('larr', u'\u2190'),
                     ('hellip', u'\u2026'), ('middot', u'\u00b7'),
                     ('nbsp', u'\u00a0'), ('ge', u'\u2265'), ('le', u'\u2264'),
                     ('times', u'\u00d7'), ('check', u'\u2713'),
                     ('rsquo', u'\u2019'), ('lsquo', u'\u2018'),
                     ('ldquo', u'\u201c'), ('rdquo', u'\u201d'),
                     ('amp', '&')):      # amp last, so &amp;lt; does not re-decode
        s = s.replace('&%s;' % name, ch)
    return s


def _inline_text(s):
    """Strip inline Markdown markup for the plain-text render."""
    # Protect code-span contents FIRST, before the emphasis passes: a literal
    # run of asterisks inside `...` (e.g. the password mask `****`) must not be
    # treated as bold/italic once the backticks are gone. Stash each span behind
    # a placeholder, run the emphasis/link passes on the rest, then restore it.
    spans = []
    def _stash(m):
        spans.append(m.group(1))
        return '\x00%d\x00' % (len(spans) - 1)
    s = re.sub(r'`([^`]*)`', _stash, s)                      # code spans
    s = re.sub(r'\*\*([^*]+)\*\*', r'\1', s)                 # bold
    s = re.sub(r'__([^_]+)__', r'\1', s)                     # bold
    s = re.sub(r'(?<!\*)\*([^*]+)\*(?!\*)', r'\1', s)        # italic
    # links -> "text (url)", except a same-document anchor ([x](#id)) which has
    # no meaning in plain text -> just "text".
    def _link(m):
        text, url = m.group(1), m.group(2)
        if url.startswith('#'):
            return text                          # same-doc anchor: no meaning in text
        if re.match(r'^[A-Za-z0-9_.-]+\.md$', url):
            # Relative sibling doc link: name the plain-text twin (X.md -> X).
            twin = url[:-3]
            return twin if text == url else '%s (%s)' % (text, twin)
        return '%s (%s)' % (text, url)
    s = re.sub(r'\[([^\]]+)\]\(([^)]+)\)', _link, s)
    s = _unescape(s)                                         # &#NNNN; / &name; -> char
    # Restore code-span contents verbatim (still entity-decoded, as before, so a
    # code span that used an entity keeps rendering it).
    s = re.sub(r'\x00(\d+)\x00', lambda m: _unescape(spans[int(m.group(1))]), s)
    return s


def convert_file(src, want_html=True, want_text=True, title=None, help_subtitle=None):
    """Convert one .md to .html and/or .txt (companion names)."""
    with io.open(src, 'r', encoding='utf-8') as f:
        md = f.read()
    base = re.sub(r'\.(md|markdown)$', '', src)
    made = []
    if want_html:
        dst = base + '.html'
        with io.open(dst, 'w', encoding='ascii') as f:
            f.write(_ascii_entities(convert(md, src.split('/')[-1], title, help_subtitle)))
        made.append(dst)
    if want_text:
        dst = base           # README.foo.md -> README.foo (plain text)
        if dst == src:       # avoid overwriting the source if no .md suffix
            dst = base + '.txt'
        # README and DEVELOPER-GUIDE: wrap the plain-text companion to 80
        # columns (prose only); the other companions keep their source line
        # structure.
        import os
        stem = os.path.basename(base)
        wrap_width = 80 if stem in ('README', 'DEVELOPER-GUIDE') else None
        with io.open(dst, 'w', encoding='utf-8') as f:
            f.write(to_text(md, wrap_width=wrap_width))
        made.append(dst)
    return made


def main(argv):
    argv = [_u(a) for a in argv]
    if '--version' in argv or '-V' in argv:
        print('md2html.py (fetchconfig) %s' % VERSION)
        print('Copyright (c) 2026 Rainer Tammer')
        print('License GPL-2.0-or-later: GNU GPL version 2 or later.')
        print('This is free software; see the source for copying conditions. '
              'There is NO')
        print('warranty; not even for MERCHANTABILITY or FITNESS FOR A '
              'PARTICULAR PURPOSE.')
        return 0
    opts = set(a for a in argv[1:] if a.startswith('--'))
    args = [a for a in argv[1:] if not a.startswith('--')]
    title = None
    if '--title' in argv:
        k = argv.index('--title')
        if k + 1 < len(argv):
            title = argv[k + 1]
            args = [a for a in args if a != title]
    help_subtitle = None
    if '--help-subtitle' in argv:
        k = argv.index('--help-subtitle')
        if k + 1 < len(argv):
            help_subtitle = argv[k + 1]
            args = [a for a in args if a != help_subtitle]

    # --all DIR : convert every *.md under DIR to .html and .txt companions
    if '--all' in opts:
        import os
        root = args[0] if args else '.'
        found = 0
        for dirpath, _dirs, files in os.walk(root):
            for name in sorted(files):
                if name.endswith('.md') or name.endswith('.markdown'):
                    src = os.path.join(dirpath, name)
                    made = convert_file(src,
                                        want_html='--text-only' not in opts,
                                        want_text='--html-only' not in opts)
                    print('%s -> %s' % (src, ', '.join(made)))
                    found += 1
        if not found:
            print('no .md files found under %s' % root, file=sys.stderr)
            return 1
        return 0

    if not args:
        print('usage: md2html.py input.md [output.html] [--title "Title"]', file=sys.stderr)
        print('       md2html.py --all DIR [--html-only|--text-only]', file=sys.stderr)
        print('       md2html.py -V|--version', file=sys.stderr)
        return 2

    # single-file: keep the historical behaviour (input.md [output.html]);
    # also honour --text-only / --html-only.
    src = args[0]
    want_html = '--text-only' not in opts
    want_text = '--text-only' in opts or '--both' in opts
    if len(args) > 1 and want_html:
        # explicit output name given: single html output (historical)
        dst = args[1]
        with io.open(src, 'r', encoding='utf-8') as f:
            md = f.read()
        with io.open(dst, 'w', encoding='ascii') as f:
            f.write(_ascii_entities(convert(md, src.split('/')[-1], title,
                                             help_subtitle)))
        print('%s -> %s' % (src, dst))
        return 0
    made = convert_file(src, want_html=want_html, want_text=want_text,
                        title=title, help_subtitle=help_subtitle)
    print('%s -> %s' % (src, ', '.join(made)))
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv))

#!/usr/bin/env python
# render-doc.py -- render a Markdown document to HTML and plain text (ASCII).
#
# One build tool for every project document (it absorbs the former
# render-changes.py). From an <input>.md it writes:
#   * a self-contained HTML page (embedded CSS, only Google Fonts external), and
#   * an ASCII plain-text rendering (ALWAYS, named after the input with the .md
#     suffix stripped: CHANGES.md -> CHANGES, INSTALL.md -> INSTALL, etc.).
#
# Two HTML styles are chosen automatically from the input:
#   * manual   -- the full sidebar/hero manual, used for EVERY Markdown document
#     (README.md, INSTALL.md, CHANGES.md, DEVELOPER.md, LICENSE-ADDITIONS.md,
#     PRIVACY.md, and any other doc). A document whose H1 starts "fetchconfig"
#     additionally gets the app version/stat tiles and the fetchconfig-specific
#     warning callouts; any other doc gets a clean hero. ```mermaid fences are
#     rendered as diagrams (Mermaid is loaded from a CDN only when a doc uses it).
#   * license  -- a verbatim <pre> of a LICENSE file (byte-exact legal text).
#
#   Usage:  python render-doc.py [input.md] [output.html]
#     e.g.  python render-doc.py                         # README -> manual
#           python render-doc.py INSTALL.md             # -> INSTALL.html + INSTALL
#           python render-doc.py CHANGES.md             # -> CHANGES.html + CHANGES
#           python render-doc.py README.imageconvert.md # -> .html + README.imageconvert
#
# The output HTML name defaults from the input (README.md -> README.html); the
# ASCII name is the input without .md.
# Standard library only, and runs unchanged on Python 3 and Python 2.7.18.
#
# It parses the README's Markdown (## sections, ###/#### headings, GitHub
# pipe tables, fenced code blocks, ordered/unordered lists with wrapped
# continuation lines, blockquote callouts, inline code/bold/italic/links) and
# emits a sticky-sidebar layout with scroll-spy navigation, a hero with stat
# tiles, numbered section kickers, callouts and styled tables. The version
# shown in the sidebar pill / hero and the minimum fetchconfig version in the
# hero warning are read from the APP_VERSION / MIN_FETCHCONFIG_VERSION
# constants in fetchconfig.cgi (same directory as this script), so they
# cannot drift from the code.
#
# fetchconfig - Web interface for the fetchconfig network configuration tool
# Copyright (C) 2026  Rainer Tammer
# Licensed under the GNU GPL v2 or later (see the LICENSE file).

import sys, re, io, os, textwrap

# --- Python 2.7 / 3 compatibility -----------------------------------------
# html.escape (Py3) vs cgi.escape (Py2); io.open gives an encoding= kwarg on
# both. escape() quotes &, <, >, and (with quote=True) " and '.
try:
    from html import escape as _html_escape          # Python 3
except ImportError:                                   # Python 2.7
    from cgi import escape as _cgi_escape
    def _html_escape(s, quote=True):
        s = _cgi_escape(s, quote)
        if quote:
            s = s.replace("'", "&#x27;")              # cgi.escape leaves ' alone
        return s

class _HtmlShim(object):
    escape = staticmethod(_html_escape)
html = _HtmlShim()

def _open_utf8(path, mode='r'):
    return io.open(path, mode, encoding='utf-8')

# io.open(..., 'w', encoding=...) accepts only unicode on Python 2, so make
# sure whatever we write is unicode (a no-op on Python 3, where str is text).
try:
    _text_type = unicode          # Python 2
except NameError:
    _text_type = str              # Python 3
def to_text(s):
    if isinstance(s, bytes) and not isinstance(s, _text_type):
        return s.decode('utf-8')
    return s if isinstance(s, _text_type) else _text_type(s)

def _ascii_entities(s):
    # 7-bit-ASCII the HTML (VI-safe): non-ASCII -> numeric entity, same render.
    return ''.join(ch if ord(ch) < 128 else '&#%d;' % ord(ch) for ch in s)

# --- I/O filenames (argv-overridable) --------------------------------------
# Correct invocation:  python render-doc.py [input.md] [output.html]
# A common mistake is to omit the script name, e.g. `python INSTALL.md out.html`,
# which makes Python try to EXECUTE the Markdown and fail with a confusing
# SyntaxError. Guard against it: if this file is not the program being run (so
# our own usage/help never fires), or the "input" is an .html while the
# "output" is a .md, explain the correct command and exit cleanly.
def _usage(msg):
    sys.stderr.write(
        "render-doc.py: %s\n"
        "Usage:  python render-doc.py [input.md] [output.html]\n"
        "  e.g.  python render-doc.py README.md  README.html\n"
        "        python render-doc.py CHANGES.md CHANGES.html\n"
        "Note: the SCRIPT name (render-doc.py) comes first, then the Markdown\n"
        "input, then the HTML output. Do not run 'python INSTALL.md ...'.\n"
        % msg)
    sys.exit(2)

# --all DIR : render every *.md under DIR to styled HTML. LICENSE.md is skipped
# (its verbatim HTML/text come from md2html.py); plain-text companions are left
# to md2html.py too. Each doc is rendered by re-invoking this script in
# single-file mode, so the default output naming applies (README.md ->
# README.html, X.md -> X.html).
if '--all' in sys.argv:
    import subprocess, os as _os
    _rest=[a for a in sys.argv[1:] if not a.startswith('--')]
    _root=_rest[0] if _rest else '.'
    _count=0
    for _dp,_dd,_ff in _os.walk(_root):
        for _name in sorted(_ff):
            if not (_name.endswith('.md') or _name.endswith('.markdown')):
                continue
            if _name.lower()=='license.md':
                continue
            subprocess.check_call([sys.executable, _os.path.abspath(__file__),
                                   _os.path.join(_dp,_name)])
            _count+=1
    if not _count:
        sys.stderr.write('render-doc.py: no .md files under %s\n'%_root)
        sys.exit(1)
    sys.exit(0)

README_IN = sys.argv[1] if len(sys.argv) > 1 else 'README.md'
# Output HTML name: explicit 2nd arg wins; else derive from the input, so
# X.md defaults to X.html (README.md -> README.html, CHANGES.md -> CHANGES.html)
# and `render-doc.py CHANGES.md` works without a second argument.
if len(sys.argv) > 2:
    HTML_OUT = sys.argv[2]
else:
    HTML_OUT = re.sub(r'\.(md|markdown)$', '', README_IN, flags=re.I) + '.html'

# Plain-text (ASCII) output name: the input with its .md/.markdown suffix
# stripped (CHANGES.md -> CHANGES, INSTALL.md -> INSTALL, README.md -> README,
# README.imageconvert.md -> README.imageconvert). A .txt is appended if the
# input had no Markdown suffix, so we never overwrite the source.
TXT_OUT = re.sub(r'\.(md|markdown)$', '', README_IN, flags=re.I)
if TXT_OUT == README_IN:
    TXT_OUT = README_IN + '.txt'

if README_IN.lower().endswith('.html') and HTML_OUT.lower().endswith(('.md', '.markdown')):
    _usage("arguments look reversed (input should be Markdown, output HTML)")
if not os.path.exists(README_IN):
    _usage("input file not found: %s" % README_IN)

# --- Embedded stylesheet + <style> wrapper (upstream doc's design system) --
STYLE = r"""<style>
  :root{
    --bg:#fbfbf9;
    --surface:#f1f4f4;
    --surface-2:#e9edee;
    --border:#dde3e3;
    --text:#141a1f;
    --text-muted:#5b6770;
    --text-faint:#8a949b;
    --accent:#0e7c8c;
    --accent-bright:#22aabb;
    --accent-soft:#e3f3f5;
    --danger:#c4432b;
    --danger-soft:#fbeae6;
    --success:#1c8a5b;
    --success-soft:#e8f5ee;
    --changed:#2451c4;
    --changed-soft:#e8edfb;
    --code-bg:#10171c;
    --code-text:#dce8ec;
    --code-accent:#7fe0cc;
    --code-muted:#7f929b;
    --radius:6px;
    --font-sans:'IBM Plex Sans',-apple-system,BlinkMacSystemFont,'Segoe UI',sans-serif;
    --font-mono:'IBM Plex Mono',ui-monospace,SFMono-Regular,Consolas,monospace;
    --sidebar-w:280px;
  }

  *{box-sizing:border-box;}
  html{scroll-behavior:smooth;}
  body{
    margin:0;
    font-family:var(--font-sans);
    color:var(--text);
    background:var(--bg);
    font-size:16px;
    line-height:1.6;
    -webkit-font-smoothing:antialiased;
  }

  a{color:var(--accent);text-decoration:none;}
  a:hover{text-decoration:underline;}
  a:focus-visible,button:focus-visible,input:focus-visible,summary:focus-visible{
    outline:2px solid var(--accent-bright);
    outline-offset:2px;
  }

  code, kbd{
    font-family:var(--font-mono);
    font-size:0.88em;
    background:var(--surface-2);
    border:1px solid var(--border);
    border-radius:4px;
    padding:0.1em 0.4em;
    color:var(--text);
    white-space:nowrap;
  }

  pre{
    font-family:var(--font-mono);
    background:var(--code-bg);
    color:var(--code-text);
    border-radius:var(--radius);
    padding:16px 18px;
    overflow-x:auto;
    font-size:0.86rem;
    line-height:1.65;
    margin:16px 0;
    border:1px solid #05090c;
  }
  pre code{
    background:none;
    border:none;
    padding:0;
    white-space:pre;
    color:inherit;
    font-size:1em;
  }
  pre .c{color:var(--code-muted);} /* comment */
  pre .s{color:var(--code-accent);} /* string / value */
  pre .k{color:#e8b95f;} /* keyword / flag */

  h1,h2,h3,h4{
    font-family:var(--font-sans);
    font-weight:600;
    line-height:1.25;
    color:var(--text);
    letter-spacing:-0.01em;
  }

  /* ---------- Layout ---------- */
  .layout{
    display:flex;
    align-items:flex-start;
    max-width:1600px;
    margin:0 auto;
  }

  .sidebar{
    position:sticky;
    top:0;
    height:100vh;
    width:var(--sidebar-w);
    flex:0 0 var(--sidebar-w);
    overflow-y:auto;
    padding:28px 22px 40px;
    border-right:1px solid var(--border);
    background:var(--surface);
  }

  .brand{
    display:flex;
    align-items:center;
    gap:10px;
    margin-bottom:4px;
  }
  .brand-mark{
    width:30px;height:30px;border-radius:7px;
    background:linear-gradient(155deg,var(--accent-bright),var(--accent));
    display:flex;align-items:center;justify-content:center;
    flex:0 0 auto;
  }
  .brand-mark svg{width:17px;height:17px;}
  .brand-name{font-weight:700;font-size:1.05rem;letter-spacing:-0.01em;}

  .brand-meta{
    font-family:var(--font-mono);
    font-size:0.72rem;
    color:var(--text-muted);
    margin:6px 0 22px;
    display:flex;
    gap:8px;
    flex-wrap:wrap;
  }
  .pill{
    display:inline-block;
    padding:2px 8px;
    border-radius:99px;
    background:var(--surface-2);
    border:1px solid var(--border);
    color:var(--text-muted);
  }

  .nav-group{margin-bottom:4px;}
  .nav-group-label{
    font-size:0.68rem;
    text-transform:uppercase;
    letter-spacing:0.08em;
    color:var(--text-faint);
    margin:20px 0 6px;
    font-weight:600;
  }
  .nav-group:first-of-type .nav-group-label{margin-top:0;}

  .sidebar nav a{
    display:block;
    color:var(--text-muted);
    font-size:0.885rem;
    padding:6px 10px;
    border-radius:5px;
    text-decoration:none;
    border-left:2px solid transparent;
    transition:background 0.12s ease, color 0.12s ease;
  }
  .sidebar nav a:hover{background:var(--surface-2);color:var(--text);}
  .sidebar nav a.active{
    color:var(--accent);
    background:var(--accent-soft);
    border-left-color:var(--accent-bright);
    font-weight:500;
  }

  .main-col{
    flex:1 1 auto;
    min-width:0;
    padding:0 0 120px;
  }

  .content{
    max-width:1200px;
    margin:0 auto;
    padding:0 48px;
  }
  /* Keep flowing prose at a comfortable reading measure, but let wide
     elements (tables, code blocks, diagrams) use the full content width so
     they don't need a horizontal scrollbar on a wide screen. */
  .content > p,
  .content > ul,
  .content > ol,
  .content > h2,
  .content > h3,
  .content > h4,
  .content > blockquote{
    max-width:820px;
  }
  .content > .table-wrap,
  .content > pre,
  .content > .callout{
    max-width:100%;
  }

  /* ---------- Hero ---------- */
  .hero{
    padding:64px 48px 48px;
    max-width:1200px;
    margin:0 auto;
    border-bottom:1px solid var(--border);
  }
  .hero-eyebrow{
    font-family:var(--font-mono);
    font-size:0.78rem;
    color:var(--accent);
    margin-bottom:14px;
  }
  .hero h1{
    font-size:2.6rem;
    margin:0 0 14px;
    letter-spacing:-0.02em;
    color:var(--accent);
  }
  .mermaid{
    /* A mermaid block is a <pre>, so it would otherwise inherit the dark code
       background/border/padding. Render the diagram on the page background. */
    margin:1.5rem 0;
    text-align:center;
    background:transparent;
    color:inherit;
    border:0;
    padding:0;
    overflow-x:auto;
  }
  /* Until mermaid.js has rendered a block (it stamps data-processed on success),
     keep the raw diagram source hidden so it is never shown as a wall of text --
     during the CDN load, or if the runtime is blocked/unavailable. mermaid still
     measures and renders normally while it is hidden; the element reveals itself
     the moment it is processed. */
  figure.diagram{margin:1.5rem 0;text-align:center;}
  .diagram-svg{display:block;}
  .diagram-svg svg{max-width:100%;height:auto;}
  /* keep raw mermaid source hidden until rendered */
  .mermaid:not([data-processed]){display:none;}
  .mermaid[data-processed]{display:block;}
  /* once live mermaid has rendered, hide the embedded SVG fallback */
  .mermaid[data-processed] + .diagram-svg{display:none;}
  .hero p.lede{
    font-size:1.13rem;
    color:var(--text-muted);
    max-width:640px;
    margin:0 0 28px;
    line-height:1.6;
  }
  .hero-stats{
    display:flex;
    gap:36px;
    flex-wrap:wrap;
    margin-top:8px;
  }
  .hero-stat .num{
    font-family:var(--font-mono);
    font-size:1.6rem;
    font-weight:600;
    color:var(--text);
    display:block;
  }
  .hero-stat .label{
    font-size:0.8rem;
    color:var(--text-muted);
  }

  /* ---------- Sections ---------- */
  section{
    padding:56px 0 8px;
    border-bottom:1px solid var(--border);
  }
  section:last-of-type{border-bottom:none;}

  .section-kicker{
    font-family:var(--font-mono);
    font-size:0.75rem;
    color:var(--text-faint);
    margin-bottom:8px;
  }
  h2{
    font-size:1.65rem;
    margin:0 0 18px;
    scroll-margin-top:24px;
  }
  h3{
    font-size:1.18rem;
    margin:34px 0 12px;
    scroll-margin-top:24px;
  }
  h4{
    font-size:0.98rem;
    margin:22px 0 8px;
    color:var(--text);
    scroll-margin-top:24px;
  }
  p{margin:0 0 14px;color:var(--text);}
  section p, section li{color:var(--text);}
  ul,ol{padding-left:1.3em;margin:0 0 16px;}
  li{margin-bottom:6px;}
  .prose-muted{color:var(--text-muted);}

  .file-label{
    font-family:var(--font-mono);
    font-size:0.72rem;
    color:var(--text-faint);
    margin:18px 0 -8px;
    display:block;
  }

  /* ---------- Callouts ---------- */
  .callout{
    border-radius:var(--radius);
    padding:16px 18px;
    margin:18px 0;
    border:1px solid var(--border);
    background:var(--surface);
    font-size:0.93rem;
  }
  .callout-title{
    font-weight:600;
    font-size:0.82rem;
    text-transform:uppercase;
    letter-spacing:0.05em;
    margin-bottom:6px;
    display:flex;
    align-items:center;
    gap:7px;
  }
  .callout.warn{background:var(--danger-soft);border-color:#f0c9bd;}
  .callout.warn .callout-title{color:var(--danger);}
  .callout.note{background:var(--accent-soft);border-color:#bfe4e9;}
  .callout.note .callout-title{color:var(--accent);}
  .callout p:last-child{margin-bottom:0;}

  /* ---------- Tables ---------- */
  .table-wrap{overflow-x:auto;margin:18px 0 26px;border:1px solid var(--border);border-radius:var(--radius);}
  table{
    border-collapse:collapse;
    width:100%;
    font-size:0.87rem;
  }
  caption{
    text-align:left;
    font-size:0.78rem;
    color:var(--text-muted);
    padding:8px 14px;
    background:var(--surface);
    border-bottom:1px solid var(--border);
    caption-side:top;
  }
  th,td{
    text-align:left;
    padding:9px 14px;
    border-bottom:1px solid var(--border);
    vertical-align:top;
  }
  thead th{
    background:var(--surface);
    font-weight:600;
    font-size:0.76rem;
    text-transform:uppercase;
    letter-spacing:0.04em;
    color:var(--text-muted);
    white-space:nowrap;
  }
  tbody tr:last-child td{border-bottom:none;}
  tbody tr:hover{background:var(--surface);}
  td code, th code{white-space:nowrap;}
  .req-yes{color:var(--danger);font-weight:600;font-size:0.82rem;}
  .req-opt{color:var(--text-faint);font-size:0.82rem;}
  .req-dash{color:var(--border);}
  .matrix th, .matrix td{text-align:center;}
  .matrix td:first-child, .matrix th:first-child{text-align:left;}
  .matrix{font-size:0.8rem;}
  .matrix code{white-space:nowrap;}

  /* ---------- Flag reference ---------- */
  .flag-card{
    border:1px solid var(--border);
    border-radius:var(--radius);
    padding:16px 18px;
    margin:14px 0;
    background:var(--bg);
  }
  .flag-card + .flag-card{margin-top:10px;}
  .flag-head{
    display:flex;
    align-items:baseline;
    gap:10px;
    flex-wrap:wrap;
    margin-bottom:8px;
  }
  .flag-tag{
    font-family:var(--font-mono);
    font-weight:600;
    background:var(--code-bg);
    color:var(--code-accent);
    border-radius:4px;
    padding:3px 9px;
    font-size:0.86rem;
  }
  .flag-req{
    font-size:0.72rem;
    font-family:var(--font-mono);
    color:var(--text-faint);
  }
  .flag-card p{margin-bottom:8px;font-size:0.92rem;color:var(--text-muted);}
  .flag-card p:last-child{margin-bottom:0;}
  .exit-list{list-style:none;padding:0;margin:8px 0 0;font-family:var(--font-mono);font-size:0.82rem;}
  .exit-list li{display:flex;gap:10px;margin-bottom:3px;}
  .exit-list .code{color:var(--text);font-weight:600;min-width:1.6em;}

  /* ---------- Footnotes ---------- */
  sup.fnref{font-size:0.68em;line-height:0;vertical-align:super;}
  sup.fnref a{color:var(--accent);text-decoration:none;font-weight:600;padding:0 1px;}
  sup.fnref a:hover{text-decoration:underline;}
  .footnotes{margin-top:1.4rem;padding-top:0.9rem;border-top:1px solid var(--border);
             font-size:0.9rem;color:var(--text-muted);}
  .footnote{margin:0 0 0.55rem 0;padding-left:1.9em;text-indent:-1.9em;line-height:1.5;}
  .footnote:last-child{margin-bottom:0;}
  .footnote .fnnum{display:inline-block;min-width:1.5em;text-indent:0;
                   font-weight:600;color:var(--text);font-family:var(--font-mono);}

  /* ---------- Color swatches (email notif) ---------- */
  .swatches{display:flex;gap:14px;flex-wrap:wrap;margin:18px 0 22px;}
  .swatch{
    display:flex;align-items:center;gap:9px;
    border:1px solid var(--border);border-radius:99px;
    padding:5px 12px 5px 6px;font-size:0.82rem;background:var(--surface);
  }
  .swatch .dot{width:16px;height:16px;border-radius:50%;flex:0 0 auto;border:1px solid rgba(0,0,0,0.12);}

  /* ---------- Toggle tabs (Installation) ---------- */
  .tabs{margin:18px 0;}
  input.tab-input{position:absolute;opacity:0;pointer-events:none;}
  .tab-labels{display:flex;gap:4px;border-bottom:1px solid var(--border);margin-bottom:20px;}
  .tab-labels label{
    font-size:0.88rem;font-weight:500;color:var(--text-muted);
    padding:9px 16px;cursor:pointer;border-bottom:2px solid transparent;
    margin-bottom:-1px;
  }
  .tab-panel{display:none;}
  #tab-unix:checked ~ .tab-labels label[for="tab-unix"],
  #tab-win:checked ~ .tab-labels label[for="tab-win"]{
    color:var(--accent);border-bottom-color:var(--accent-bright);
  }
  #tab-unix:checked ~ .tab-panels #panel-unix,
  #tab-win:checked ~ .tab-panels #panel-win{display:block;}

  /* ---------- Device support grid ---------- */
  .device-grid td:first-child code{font-weight:600;}

  /* ---------- Footer ---------- */
  .page-footer{
    max-width:1200px;margin:0 auto;padding:40px 48px 60px;
    color:var(--text-faint);font-size:0.82rem;
  }
  .page-footer a{color:var(--text-muted);}

  /* ---------- Mobile nav ---------- */
  .nav-toggle{display:none;}
  .mobile-bar{display:none;}

  @media (max-width: 900px){
    .sidebar{
      position:fixed;
      inset:0 auto 0 0;
      z-index:40;
      transform:translateX(-100%);
      transition:transform 0.2s ease;
      box-shadow:2px 0 24px rgba(0,0,0,0.15);
    }
    .nav-toggle:checked ~ .layout .sidebar{transform:translateX(0);}
    .mobile-bar{
      display:flex;align-items:center;justify-content:space-between;
      position:sticky;top:0;z-index:30;
      background:var(--bg);border-bottom:1px solid var(--border);
      padding:14px 20px;
    }
    .mobile-bar .brand{margin:0;}
    .mobile-bar label{
      font-family:var(--font-mono);font-size:0.8rem;
      border:1px solid var(--border);border-radius:6px;padding:6px 10px;cursor:pointer;
    }
    .content{padding:0 22px;}
    .hero{padding:36px 22px 32px;}
    .hero h1{font-size:2rem;}
    .page-footer{padding:32px 22px 48px;}
  }
  @media (min-width:901px){
    .mobile-bar{display:none !important;}
  }

  @media print{
    .sidebar,.mobile-bar{display:none !important;}
    .layout{display:block;}
    a{color:inherit;text-decoration:none;}
    pre{white-space:pre-wrap;}
  }
</style>
"""


readme = _open_utf8(README_IN).read()
style  = STYLE

# --- verbatim license mode -------------------------------------------------
# The GPLv3 LICENSE is a fixed legal document: it must be reproduced EXACTLY,
# not reflowed or reformatted as Markdown prose. When the input is a LICENSE
# file (basename "LICENSE", or any file with no .md/.markdown/.html suffix),
# render it verbatim inside a <pre> block, and also emit a LICENSE.md that wraps
# the same text in a fenced code block. This keeps the legal text byte-exact.
def _looks_like_license(path):
    base = os.path.basename(path)
    if base.upper().startswith('LICENSE') and '.' not in base:
        return True
    low = path.lower()
    return not low.endswith(('.md', '.markdown', '.html', '.htm'))

if _looks_like_license(README_IN):
    _title = 'GNU General Public License, Version 2'
    # LICENSE.md: verbatim text in a fenced block (so Markdown viewers show it
    # unaltered). Derive the .md path from the HTML output path.
    _md_out = re.sub(r'\.html?$', '', HTML_OUT, flags=re.I) + '.md'
    if _md_out == HTML_OUT:
        _md_out = HTML_OUT + '.md'
    with _open_utf8(_md_out, 'w') as _f:
        _f.write('# ' + _title + '\n\n```\n' + readme.rstrip('\n') + '\n```\n')
    # LICENSE.html: the text inside a <pre> in the standard page shell.
    _pre = _html_escape(readme.rstrip('\n'))
    _lic_page = (u"""<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>fetchconfig &mdash; {title}</title>
<link rel="preconnect" href="https://fonts.googleapis.com">
<link rel="preconnect" href="https://fonts.gstatic.com" crossorigin>
<link href="https://fonts.googleapis.com/css2?family=IBM+Plex+Sans:ital,wght@0,400;0,500;0,600;0,700;1,400&family=IBM+Plex+Mono:wght@400;500;600&display=swap" rel="stylesheet">
{style}
<style>
  .license-wrap{{max-width:900px;margin:0 auto;padding:40px 22px 64px;}}
  .license-wrap .hero-eyebrow{{text-transform:uppercase;letter-spacing:.08em;font-size:.8rem;color:var(--accent);font-weight:600;}}
  .license-wrap h1{{font-size:2rem;margin:.2em 0 1rem;color:var(--accent);}}
  pre.license-text{{white-space:pre-wrap;word-wrap:break-word;overflow-wrap:anywhere;
    font-family:'IBM Plex Mono',ui-monospace,Menlo,Consolas,monospace;font-size:.82rem;
    line-height:1.5;background:var(--card,#fff);border:1px solid var(--border,#e2e5ea);
    border-radius:8px;padding:1.2em 1.4em;color:var(--ink,#1a2129);}}
</style>
</head>
<body>
<div class="license-wrap">
  <h1 class="hero-title">fetchconfig &mdash; {title}</h1>
  <pre class="license-text">{body}</pre>
</div>
</body>
</html>
""").format(title=html.escape(_title), style=style, body=_pre)
    with _open_utf8(HTML_OUT, 'w') as _f:
        _f.write(_ascii_entities(_lic_page))
    sys.stderr.write("wrote %s and %s (verbatim GPLv3)\n" % (HTML_OUT, _md_out))
    sys.exit(0)

# --- plain-text (ASCII) renderer -------------------------------------------
# Turn Markdown into clean, wrapped plain text. Used for EVERY document (the
# "always generate an ASCII version" rule): headings get underlines, pipe
# tables become aligned columns, fenced code is indented verbatim, lists wrap
# with a hanging indent, blockquotes/callouts are indented, and inline markup
# and a few HTML entities are stripped/decoded. Written for Python 2.7 and 3.
_ASCII_ENTITIES = (
    ('&mdash;', '--'), ('&ndash;', '-'), ('&hellip;', '...'),
    ('&rarr;', '->'), ('&larr;', '<-'), ('&harr;', '<->'),
    ('&times;', 'x'), ('&nbsp;', ' '), ('&copy;', '(c)'), ('&reg;', '(R)'),
    ('&lt;', '<'), ('&gt;', '>'), ('&quot;', '"'),
    ('&#39;', "'"), ('&apos;', "'"), ('&amp;', '&'),   # &amp; last
)

def _ascii_inline(s):
    s = re.sub(r'`([^`]*)`', r'\1', s)                      # inline code
    s = re.sub(r'!\[([^\]]*)\]\([^)]*\)', r'\1', s)         # image -> alt
    def _lk(m):
        t, u = m.group(1), m.group(2)
        return t if u.startswith('#') else '%s (%s)' % (t, u)
    s = re.sub(r'\[([^\]]+)\]\(([^)]+)\)', _lk, s)          # link -> text (url)
    s = s.replace('***', '')
    s = re.sub(r'\*\*([^*]+)\*\*', r'\1', s)                # bold
    s = re.sub(r'(?<!\*)\*(?!\*)([^*]+)\*(?!\*)', r'\1', s) # italic
    for a, b in _ASCII_ENTITIES:
        s = s.replace(a, b)
    return s

def _is_block_start(s):
    return bool(re.match(r'^(```|#{1,6}\s|\s*[-*]\s|\s*\d+\.\s|>\s)', s)
                or re.match(r'^\s*([-*_])(\s*\1){2,}\s*$', s))

import hashlib as _hashlib
def _mermaid_svg(src):
    """Return a pre-rendered SVG (embedded fallback shown when the Mermaid CDN
    is unavailable), or '' if none is cached. Cache: tools/mermaid-cache/<sha1>.svg,
    keyed by the diagram source. Regenerate with tools/gen-mermaid-svg.py."""
    key=_hashlib.sha1(src.encode('utf-8')).hexdigest()[:16]
    path=os.path.join(os.path.dirname(os.path.abspath(__file__)),'mermaid-cache',key+'.svg')
    try:
        with io.open(path,encoding='utf-8') as f: return f.read()
    except (IOError,OSError):
        return ''


def _preprocess_mermaid(md_text):
    """HTML path: replace each <!--MERMAID ... MERMAID--> comment with a
    ```mermaid fence, and drop an immediately-preceding ```text ... ``` ASCII
    twin (its role is the .md / plain-text fallback only). Mirrors the fetchconfig
    md2html.py convention so the same docs render diagrams here."""
    md_text = re.sub(r"```text\n.*?\n```\n(\s*)<!--MERMAID\n",
                     r"\1<!--MERMAID\n", md_text, flags=re.S)
    md_text = re.sub(r"<!--MERMAID\n(.*?)\nMERMAID-->",
                     lambda m: "```mermaid\n" + m.group(1) + "\n```",
                     md_text, flags=re.S)
    return md_text


def md_to_text(md, width=80):
    md = re.sub(r'<!--MERMAID.*?MERMAID-->', '', md, flags=re.S)
    md = re.sub(r'<!--.*?-->', '', md, flags=re.S)
    src = md.split('\n')
    out = []
    i, n = 0, len(src)

    def wrap(text, first='', rest=None):
        rest = first if rest is None else rest
        text = _ascii_inline(text).strip()
        if text == '':
            return ['']
        return textwrap.wrap(text, width=width, initial_indent=first,
                             subsequent_indent=rest) or [first.rstrip()]

    while i < n:
        ln = src[i]
        # fenced code -> indented verbatim
        m = re.match(r'^(\s*)```(.*)$', ln)
        if m:
            indent = m.group(1); _lang = m.group(2).strip().lower(); i += 1
            # A mermaid fence is diagram markup, unreadable as plain text, so it
            # is dropped from the ASCII rendering -- the ASCII-art ```text block
            # that accompanies each diagram is its plain-text form and is kept.
            if _lang == 'mermaid':
                while i < n and not re.match(r'^\s*```', src[i]):
                    i += 1
                i += 1  # closing fence
                continue
            out.append('')
            while i < n and not re.match(r'^\s*```', src[i]):
                cl = src[i]
                cl = cl[len(indent):] if cl.startswith(indent) else cl.lstrip()
                out.append(('    ' + cl).rstrip()); i += 1
            i += 1  # closing fence
            out.append('')
            continue
        # pipe table -> aligned columns
        if '|' in ln and i+1 < n and re.match(r'^\s*\|?[\s:|-]+\|[\s:|-]+', src[i+1]) and '-' in src[i+1]:
            header = [_ascii_inline(c.strip()) for c in ln.strip().strip('|').split('|')]
            i += 2
            rows = []
            while i < n and '|' in src[i] and src[i].strip():
                rows.append([_ascii_inline(c.strip()) for c in src[i].strip().strip('|').split('|')])
                i += 1
            ncol = len(header)
            rows = [(r + [''] * ncol)[:ncol] for r in rows]
            w = [len(header[c]) for c in range(ncol)]
            for r in rows:
                for c in range(ncol):
                    if len(r[c]) > w[c]:
                        w[c] = len(r[c])
            out.append('')
            if sum(w) + 2 * (ncol - 1) <= width:
                # Fits: aligned columns with a rule under the header.
                def _row(cells):
                    return '  '.join(cells[c].ljust(w[c]) for c in range(ncol)).rstrip()
                out.append(_row(header))
                out.append('  '.join('-' * w[c] for c in range(ncol)))
                for r in rows:
                    out.append(_row(r))
            else:
                # Too wide for the page: one "Header: value" record per row,
                # each value wrapped, so nothing overflows.
                for r in rows:
                    for c in range(ncol):
                        if r[c] == '':
                            continue
                        lab = (header[c] + ': ') if header[c] else ''
                        out += (textwrap.wrap(r[c], width=width,
                                              initial_indent='  ' + lab,
                                              subsequent_indent='  ' + ' ' * len(lab))
                                or ['  ' + lab.rstrip()])
                    out.append('')
            out.append('')
            continue
        # heading
        m = re.match(r'^(#{1,6})\s+(.*)$', ln)
        if m:
            lvl = len(m.group(1)); t = _ascii_inline(m.group(2).strip())
            rule = {1: '=', 2: '=', 3: '-'}.get(lvl, '.')
            out += ['', t, rule * max(1, len(t)), '']
            i += 1
            continue
        # horizontal rule
        if re.match(r'^\s*([-*_])(\s*\1){2,}\s*$', ln):
            out += ['', '-' * width, '']; i += 1
            continue
        # blockquote / callout -> indented block
        if re.match(r'^>\s?', ln):
            inner = []
            while i < n and re.match(r'^>\s?', src[i]):
                inner.append(re.sub(r'^>\s?', '', src[i])); i += 1
            label = None
            am = re.match(r'^\[!(NOTE|TIP|IMPORTANT|WARNING|CAUTION)\]\s*$', inner[0]) if inner else None
            if am:
                label = am.group(1); inner = inner[1:]
            out.append('')
            if label:
                out.append('    [' + label + ']')
            for sl in md_to_text('\n'.join(inner), width=max(20, width - 4)).rstrip('\n').split('\n'):
                out.append(('    ' + sl).rstrip())
            out.append('')
            continue
        # unordered list (absorb continuation lines)
        if re.match(r'^(\s*)[-*]\s+', ln):
            while i < n:
                mm = re.match(r'^(\s*)[-*]\s+(.*)$', src[i])
                if not mm:
                    break
                depth = len(mm.group(1)) // 2
                cur = mm.group(2); i += 1
                while i < n and re.match(r'^\s+\S', src[i]) and not re.match(r'^\s*[-*]\s|^\s*\d+\.\s', src[i]):
                    cur += ' ' + src[i].strip(); i += 1
                pad = '  ' * depth
                out += wrap(cur, pad + '- ', pad + '  ')
            continue
        # ordered list (absorb continuation lines)
        if re.match(r'^\s*\d+\.\s+', ln):
            num = 1
            while i < n:
                mm = re.match(r'^\s*\d+\.\s+(.*)$', src[i])
                if not mm:
                    break
                cur = mm.group(1); i += 1
                while i < n and re.match(r'^\s+\S', src[i]) and not re.match(r'^\s*[-*]\s|^\s*\d+\.\s', src[i]):
                    cur += ' ' + src[i].strip(); i += 1
                prefix = '%d. ' % num; num += 1
                out += wrap(cur, prefix, ' ' * len(prefix))
            continue
        # blank
        if ln.strip() == '':
            out.append(''); i += 1
            continue
        # paragraph
        para = [ln]; i += 1
        while i < n and src[i].strip() and not _is_block_start(src[i]) \
                and not ('|' in src[i] and i+1 < n and '-' in src[i+1]):
            para.append(src[i]); i += 1
        out += wrap(' '.join(para))

    text = re.sub(r'\n{3,}', '\n\n', '\n'.join(out))
    return text.strip('\n') + '\n'

# ---- split README into top-level (##) sections; keep the H1 intro separately
lines = _preprocess_mermaid(readme).split('\n')
# Split into top-level (##) sections. "## Title {#id}" sets an explicit anchor;
# a "<!--nav-group: NAME-->" line before a section assigns it (and following ones)
# to a sidebar nav group. Both markers are consumed here.
def _parse_heading(s):
    # strip optional "{#anchor}" and "{nav:Short label}" suffixes (either order).
    # The nav label is the short text shown in the sidebar; the remaining text is
    # the full heading/title shown in the body. Returns (title, anchor, nav_label).
    anchor = None; nav = None
    while True:
        mn = re.search(r'\s*\{nav:\s*(.+?)\s*\}\s*$', s)
        ma = re.search(r'\s*\{#([\w-]+)\}\s*$', s)
        if mn and (not ma or mn.start() >= ma.start()):
            nav = mn.group(1).strip(); s = s[:mn.start()]
        elif ma:
            anchor = ma.group(1); s = s[:ma.start()]
        else:
            break
    return (s.strip(), anchor, nav)
sections = []   # (title, anchor, group, nav_label, body_lines)
intro = []
cur_title = None; cur_anchor = None; cur_group = None; cur_nav = None; cur_body = []
pending_group = None
for ln in lines:
    gm = re.match(r'^\s*<!--\s*nav-group:\s*(.+?)\s*-->\s*$', ln)
    if gm:
        pending_group = gm.group(1).strip()
        continue
    m = re.match(r'^## (.+)$', ln)
    if m:
        if cur_title is None:
            intro = cur_body[:]
        else:
            sections.append((cur_title, cur_anchor, cur_group, cur_nav, cur_body))
        cur_title, cur_anchor, cur_nav = _parse_heading(m.group(1))
        cur_group = pending_group   # group carries forward until the next marker
        cur_body = []
    else:
        cur_body.append(ln)
if cur_title is not None:
    sections.append((cur_title, cur_anchor, cur_group, cur_nav, cur_body))
else:
    intro = cur_body

def slug(t):
    # GitHub-compatible heading anchors (github-slugger): lowercase, then DROP any
    # character that is not a word char / hyphen / space -- punctuation such as
    # "." is removed, not turned into a hyphen, so "How fetchconfig.pl is invoked"
    # becomes "how-fetchconfigpl-is-invoked" -- and finally spaces -> hyphens.
    # This matches the #anchors authors write against the GitHub-rendered README
    # (the canonical source), so intra- and cross-document links resolve in the
    # generated HTML too. Backticks/asterisks from inline code or emphasis in a
    # heading are punctuation and are likewise dropped, leaving the inner text.
    s = re.sub(r'[^\w\- ]+', '', t.lower(), flags=re.UNICODE)
    s = s.replace(' ', '-')
    return s

# ---- inline markdown: code, bold, italic, links -> HTML (with escaping)
def inline(text):
    # protect inline code first
    parts = []
    idx = 0
    for m in re.finditer(r'`([^`]+)`', text):
        parts.append(('t', text[idx:m.start()]))
        parts.append(('c', m.group(1)))
        idx = m.end()
    parts.append(('t', text[idx:]))
    out = ''
    for kind, seg in parts:
        if kind == 'c':
            out += '<code>' + html.escape(seg) + '</code>'
        else:
            seg = html.escape(seg)
            # restore HTML entities the source intentionally used (e.g. &#10003;
            # for a check mark in the option matrix) -- html.escape turned the
            # leading "&" into "&amp;", which would otherwise show literally.
            seg = re.sub(r'&amp;(#[0-9]+|#x[0-9A-Fa-f]+|[A-Za-z][A-Za-z0-9]+);',
                         r'&\1;', seg)
            # links [text](url). An in-page anchor (#...) is normalised through
            # the same slug() rules as the heading ids, so a hand-written TOC
            # link like "#part-1----before-you-start" matches the generated id
            # "part-1-before-you-start" (GitHub keeps the doubled hyphens; this
            # renderer collapses them, so without this the TOC links are dead).
            def _link(m):
                text, url = m.group(1), m.group(2)
                if url.startswith('#'):
                    url = '#' + slug(url[1:])
                return '<a href="%s">%s</a>' % (html.escape(url), text)
            seg = re.sub(r'\[([^\]]+)\]\(([^)]+)\)', _link, seg)
            out += seg
    # Protect any run of 3+ asterisks and the password-mask literal so the
    # bold/italic passes below don't chew them up (e.g. "?***?").
    out = out.replace('***', '\x00AST3\x00')
    # Bold/italic AFTER code protection so **`code`** works (the ** are outside
    # the <code> span). Non-greedy; do not let a match cross a "**" boundary.
    out = re.sub(r'\*\*([^*]+(?:\*(?!\*)[^*]+)*)\*\*', r'<strong>\1</strong>', out)
    out = re.sub(r'(?<!\*)\*(?!\*)([^*]+)\*(?!\*)', r'<em>\1</em>', out)
    out = out.replace('\x00AST3\x00', '***')
    # footnote references: "[^N]" (numeric only, so regex-like "[^/]" is left
    # alone) -> superscript link to the definition below.
    out = re.sub(r'\[\^(\d+)\]',
                 r'<sup class="fnref"><a href="#fn-\1">\1</a></sup>', out)
    return out

# ---- code-block syntax highlighting -----------------------------------------
# Reproduces the reference rendering's three token classes inside <pre><code>:
#   .c  whole-line comments  (# ... , :: ... , SQL-style "-- ...")
#   .s  double-quoted strings
#   .k  fetchconfig option flags (-g, -devices=, --check-template, ...) and the
#       config directives "default:" / "email:"
# Flags are highlighted only on lines that invoke fetchconfig.pl, so ordinary
# shell flags ("ln -s", "tar -xzf") are left uncoloured, matching the reference.
def _highlight_code(esc):
    out_lines = []
    for cl in esc.split('\n'):
        # whole-line comment ("--" only when NOT the start of a --flag)
        if re.match(r'^\s*(#|::|--(?![A-Za-z]))', cl):
            out_lines.append('<span class="c">%s</span>' % cl)
            continue
        strs = []
        def _stash(m, _s=strs):
            _s.append(m.group(0))
            return '\x00S%d\x00' % (len(_s) - 1)
        s = re.sub(r'"[^"]*"', _stash, cl)
        if 'fetchconfig.pl' in s:
            s = re.sub(r'(?<![\w/.\-])(-{1,2}[A-Za-z][\w\-]*=?)',
                       r'<span class="k">\1</span>', s)
        s = re.sub(r'^(\s*)(default:|email:)', r'\1<span class="k">\2</span>', s)
        s = re.sub(r'\x00S(\d+)\x00',
                   lambda m: '<span class="s">%s</span>' % strs[int(m.group(1))], s)
        out_lines.append(s)
    return '\n'.join(out_lines)

# ---- block renderer for a body (list of lines) -> HTML string
# Set to True by render_body() when a ```mermaid fence is rendered, so the page
# template below pulls in the Mermaid runtime only for documents that use it.
_uses_mermaid = [False]

def render_body(body):
    out = []
    i = 0
    n = len(body)
    while i < n:
        ln = body[i]
        # fenced code block. The opening fence may be indented (e.g. a fence
        # inside a numbered list item is indented to align with the item text);
        # that indent is stripped from the fence and from every code line, so
        # indented blocks render as boxes instead of leaking literal backticks.
        mfence = re.match(r'^(\s*)```(.*)$', ln)
        if mfence:
            indent = mfence.group(1)
            lang = mfence.group(2).strip()
            code = []
            i += 1
            while i < n and not re.match(r'^\s*```', body[i]):
                cl = body[i]
                cl = cl[len(indent):] if cl.startswith(indent) else cl.lstrip()
                code.append(cl); i += 1
            i += 1  # skip closing ```
            # Mermaid fences render as diagrams (DEVELOPER.md). Mermaid reads the
            # element's textContent as diagram source, so the source must be
            # HTML-escaped exactly once: a literal "<br/>" in a node label has to
            # arrive as the characters &lt;br/&gt; (which the browser decodes back
            # to "<br/>" in textContent) -- an unescaped <br/> would be parsed as
            # a real element and the line break would be lost. The page is flagged
            # so the Mermaid runtime is pulled in.
            if lang == 'mermaid':
                _uses_mermaid[0] = True
                _src = '\n'.join(code)
                _svg = _mermaid_svg(_src)
                if _svg:
                    out.append('<figure class="diagram"><pre class="mermaid">%s</pre>'
                               '<div class="diagram-svg">%s</div></figure>'
                               % (html.escape(_src), _svg))
                else:
                    out.append('<pre class="mermaid">%s</pre>' % html.escape(_src))
                # A ```text block immediately following a diagram is its ASCII-art
                # twin, written for the plain-text rendering only. Drop it from the
                # HTML so the page shows the diagram, not the diagram AND its text
                # form (the ASCII output drops the diagram and keeps this block).
                j = i
                while j < n and body[j].strip() == '':
                    j += 1
                tw = re.match(r'^\s*```(.*)$', body[j]) if j < n else None
                if tw and tw.group(1).strip().lower() == 'text':
                    j += 1
                    while j < n and not re.match(r'^\s*```', body[j]):
                        j += 1
                    i = j + 1  # consume the twin incl. its closing fence
                continue
            if lang:
                label = {'sql':'sql','sh':'shell','bash':'shell','perl':'perl','text':'text','apache':'Apache config','conf':'Apache config'}.get(lang, lang)
                out.append('<span class="file-label">%s</span>' % html.escape(label))
            # Syntax highlight the block: comment lines -> .c, double-quoted
            # strings -> .s, and fetchconfig option flags / config directives
            # -> .k. quote=False keeps " and ' literal, as the reference does.
            esc = html.escape('\n'.join(code), quote=False)
            out.append('<pre><code>%s</code></pre>' % _highlight_code(esc))
            continue
        # table (GitHub pipe table): header line + --- line. Split on pipes that
        # are NOT backslash-escaped, then turn "\|" back into a literal "|" in the
        # cell (so a cell may contain a pipe, e.g. the shell-metacharacter list).
        def _cells(row):
            s = row.strip()
            s = re.sub(r'^\|', '', s); s = re.sub(r'(?<!\\)\|\s*$', '', s)
            return [c.strip().replace('\\|', '|') for c in re.split(r'(?<!\\)\|', s)]
        if '|' in ln and i+1 < n and re.match(r'^\s*\|?[\s:|-]+\|[\s:|-]+', body[i+1]) and '-' in body[i+1]:
            header = _cells(ln)
            i += 2
            rows = []
            while i < n and '|' in body[i] and body[i].strip():
                rows.append(_cells(body[i]))
                i += 1
            th = ''.join('<th>%s</th>' % inline(c) for c in header)
            trs = ''
            for r in rows:
                tds = ''.join('<td>%s</td>' % inline(c) for c in r)
                trs += '<tr>%s</tr>' % tds
            out.append('<div class="table-wrap"><table><thead><tr>%s</tr></thead><tbody>%s</tbody></table></div>' % (th, trs))
            continue
        # horizontal rule (---, ***, ___) -> <hr>
        if re.match(r'^\s*([-*_])(\s*\1){2,}\s*$', ln):
            out.append('<hr>'); i += 1
            continue
        # <!--tabs--> <!--tab: Label--> ... <!--/tabs--> : CSS tab group. A
        # two-tab group reuses the shipped tab-unix/tab-win CSS ids.
        if ln.strip() == '<!--tabs-->':
            i += 1
            tabs = []
            while i < n and body[i].strip() != '<!--/tabs-->':
                tm = re.match(r'^\s*<!--tab:\s*(.+?)\s*-->\s*$', body[i])
                if tm:
                    tabs.append((tm.group(1).strip(), []))
                elif tabs:
                    tabs[-1][1].append(body[i])
                i += 1
            if i < n:
                i += 1
            ids = (['unix', 'win'] if len(tabs) == 2 else ['t%d' % k for k in range(len(tabs))])
            inp = ''.join('<input type="radio" name="tabgrp" class="tab-input" id="tab-%s"%s>'
                          % (ids[k], ' checked' if k == 0 else '') for k in range(len(tabs)))
            lab = ''.join('<label for="tab-%s">%s</label>' % (ids[k], inline(t))
                          for k, (t, _b) in enumerate(tabs))
            pan = ''.join('<div class="tab-panel" id="panel-%s">%s</div>' % (ids[k], render_body(b))
                          for k, (_t, b) in enumerate(tabs))
            out.append('<div class="tabs">%s<div class="tab-labels">%s</div>'
                       '<div class="tab-panels">%s</div></div>' % (inp, lab, pan))
            continue
        # "#### Title {.flag-group}" -- an h4 carrying a CSS class (used for the
        # group headers in the flag reference). Must be tried before the generic
        # heading match below, which would otherwise keep "{.flag-group}" as text.
        mfg = re.match(r'^#{3,4} (.+?)\s*\{\.([\w-]+)\}\s*$', ln)
        if mfg:
            lvl = len(re.match(r'^(#{3,4}) ', ln).group(1))
            out.append('<h%d class="%s">%s</h%d>'
                       % (lvl, mfg.group(2), inline(mfg.group(1).strip()), lvl))
            i += 1
            continue
        # <!--flag: TAG | REQ--> ... <!--/flag--> : a flag-card (the CLI flag
        # reference). TAG is the option (e.g. "-g dev_id"); REQ is the short
        # qualifier shown on the right ("mutually exclusive with ...", "optional").
        # The body between the markers is rendered as normal blocks, so a card may
        # hold paragraphs, lists, code and callouts.
        mflag = re.match(r'^\s*<!--flag:\s*(.*?)\s*-->\s*$', ln)
        if mflag:
            spec = mflag.group(1)
            tag, req = (spec.split('|', 1) + [''])[:2]
            i += 1
            inner = []
            while i < n and body[i].strip() != '<!--/flag-->':
                inner.append(body[i]); i += 1
            if i < n:
                i += 1  # skip <!--/flag-->
            req_html = ('<span class="flag-req">%s</span>' % inline(req.strip())) if req.strip() else ''
            head = ('<div class="flag-head"><span class="flag-tag">%s</span>%s</div>'
                    % (inline(tag.strip()), req_html))
            out.append('<div class="flag-card">%s%s</div>' % (head, render_body(inner)))
            continue
        # <!--exit-list--> ... <!--/exit-list--> : the exit-code lists used inside
        # flag-cards. Each line "- CODE | text" becomes one row whose CODE is shown
        # in the monospace "code" column.
        if ln.strip() == '<!--exit-list-->':
            i += 1
            lis = []
            while i < n and body[i].strip() != '<!--/exit-list-->':
                mm = re.match(r'^\s*-\s+(.*)$', body[i])
                if mm:
                    parts = mm.group(1).split('|', 1)
                    code = parts[0].strip()
                    txt = parts[1].strip() if len(parts) > 1 else ''
                    lis.append('<li><span class="code">%s</span> %s</li>'
                               % (inline(code), inline(txt)))
                i += 1
            if i < n:
                i += 1  # skip <!--/exit-list-->
            out.append('<ul class="exit-list">%s</ul>' % ''.join(lis))
            continue
        # heading ### / #### -- give it an id (slug of its text) so the sidebar
        # nav links resolve to it.
        m = re.match(r'^(#{3,4}) (.+)$', ln)
        if m:
            lvl = len(m.group(1))
            htext, hid, _hnav = _parse_heading(m.group(2).strip())
            out.append('<h%d id="%s">%s</h%d>' % (lvl, hid or slug(htext), inline(htext), lvl))
            i += 1
            continue
        # blockquote -> callout note. Strip the "> " prefix and render the
        # inner content as blocks (so nested fenced code, lists and multiple
        # paragraphs inside a blockquote render correctly instead of being
        # flattened into one line).
        # A GitHub alert marker on the first line ("> [!CAUTION]" etc.) picks
        # the callout style: CAUTION/WARNING -> red "warn", anything else ->
        # "note". The marker line itself is not rendered.
        if re.match(r'^> ?', ln):
            inner = []
            while i < n and re.match(r'^> ?', body[i]):
                inner.append(re.sub(r'^> ?', '', body[i])); i += 1
            cls = 'note'; ctitle = ''
            am = re.match(r'^\[!(\w+)\]\s*(.*)$', inner[0]) if inner else None
            if am:
                t = am.group(1).upper()
                if t in ('WARNING', 'CAUTION', 'WARN'):
                    cls = 'warn'
                elif t in ('PLAIN', 'BOX', 'NEUTRAL'):
                    cls = ''          # bare <div class="callout"> (no accent)
                else:
                    cls = 'note'
                ctitle = am.group(2).strip()
                inner = inner[1:]
            title_html = ('<div class="callout-title">%s</div>' % inline(ctitle)) if ctitle else ''
            out.append('<div class="callout%s">%s%s</div>'
                       % ((' ' + cls) if cls else '', title_html, render_body(inner)))
            continue
        # unordered list (absorb indented continuation lines into the item)
        if re.match(r'^\s*[-*] ', ln):
            items = []
            while i < n and re.match(r'^\s*[-*] ', body[i]):
                cur = re.sub(r'^\s*[-*] ','',body[i]); i += 1
                while i < n and re.match(r'^\s+\S', body[i]) and not re.match(r'^\s*[-*] |^\s*\d+\. ', body[i]):
                    cur += ' ' + body[i].strip(); i += 1
                items.append(cur)
            out.append('<ul>%s</ul>' % ''.join('<li>%s</li>' % inline(x) for x in items))
            continue
        # ordered list (absorb indented continuation lines into the item)
        if re.match(r'^\s*\d+\. ', ln):
            items = []
            while i < n and re.match(r'^\s*\d+\. ', body[i]):
                mnum = re.match(r'^\s*(\d+)\. (.*)$', body[i])
                num = mnum.group(1); cur = mnum.group(2); i += 1
                while i < n and re.match(r'^\s+\S', body[i]) and not re.match(r'^\s*[-*] |^\s*\d+\. ', body[i]):
                    cur += ' ' + body[i].strip(); i += 1
                items.append((num, cur))
            out.append('<ol>%s</ol>' % ''.join('<li value="%s">%s</li>' % (num, inline(x)) for num, x in items))
            continue
        # footnote definitions: a run of "[^N]: text" lines -> a footnotes block,
        # each footnote on its own line (standard footnote convention).
        if re.match(r'^\[\^[\w-]+\]:\s', ln):
            notes = []
            while i < n:
                fm = re.match(r'^\[\^([\w-]+)\]:\s*(.*)$', body[i])
                if not fm:
                    break
                notes.append((fm.group(1), fm.group(2))); i += 1
            items = ''.join(
                '<div class="footnote" id="fn-%s"><span class="fnnum">%s.</span> %s</div>'
                % (num, num, inline(txt)) for num, txt in notes)
            out.append('<div class="footnotes">%s</div>' % items)
            continue
        # blank
        if ln.strip() == '':
            i += 1
            continue
        # paragraph (gather until blank / block start)
        para = [ln]
        i += 1
        while i < n and body[i].strip() and not re.match(r'^(```|#{2,4} |\s*[-*] |\s*\d+\. |> )', body[i]) and not ('|' in body[i] and i+1<n and '-' in (body[i+1] if i+1<n else '')):
            para.append(body[i]); i += 1
        out.append('<p>%s</p>' % inline(' '.join(para)))
    return '\n'.join(out)

# ---- intro: strip the H1, keep the rest as the hero lede + first section
intro_text = '\n'.join(intro)

# ---- build sidebar nav directly from the actual document structure.
# Each top-level (##) section becomes a nav group; its ### subsections become
# the links under it. This stays in sync with the README automatically instead
# of a hardcoded title map. A "Part N -- Name" heading is shown as just "Name";
# a ## section with no ### subsections links to itself.
def _aid(title, anchor):
    return anchor or slug(title)

def nav_html():
    # Grouped nav when the document uses <!--nav-group--> markers (each section is
    # a link under its group); otherwise one nav-group per ## section with its ###
    # subsections as links.
    if any(g for (_t, _a, g, _n, _b) in sections):
        groups = []   # [(group, [(nav_text, anchor)])]
        for title, anchor, group, nav, body in sections:
            if title == 'Contents':
                continue
            if not groups or groups[-1][0] != group:
                groups.append((group, []))
            groups[-1][1].append((nav or title, anchor, title))
        out = []
        for group, items in groups:
            links = ''.join('<a href="#%s">%s</a>' % (_aid( title, a), inline(navtext))
                            for navtext, a, title in items)
            if group:
                out.append('<div class="nav-group"><div class="nav-group-label">%s</div>%s</div>'
                           % (html.escape(group), links))
            else:
                out.append('<div class="nav-group">%s</div>' % links)
        return '\n'.join(out)
    parts = []
    for title, anchor, group, nav, body in sections:
        if title == 'Contents':
            continue
        subs = [_parse_heading(mm.group(1)) for mm in
                (re.match(r'^### (.+)$', ln) for ln in body) if mm]
        if subs:
            links = ''.join('<a href="#%s">%s</a>' % (_aid(st, sa), inline(snav or st))
                            for st, sa, snav in subs)
            parts.append('<div class="nav-group"><div class="nav-group-label">%s</div>%s</div>'
                         % (html.escape(nav or title), links))
        else:
            parts.append('<div class="nav-group">'
                         '<a href="#%s">%s</a></div>' % (_aid(title, anchor), inline(nav or title)))
    return '\n'.join(parts)

# ---- sections html with numbered kickers
sec_html = []
for idx,(title, anchor, group, nav, body) in enumerate(sections, start=1):
    sec_html.append(
        '<section id="%s">\n<div class="section-kicker">%02d</div>\n<h2>%s</h2>\n%s\n</section>'
        % (_aid(title, anchor), idx, inline(title), render_body(body))
    )

# Title, eyebrow and hero lede are derived from the INPUT document so the same
# renderer serves README.md ("fetchconfig ... Documentation") and
# INSTALL.md ("fetchconfig -- Installation") correctly:
#   - the H1 "fetchconfig -- <Subtitle>" gives the eyebrow (<Subtitle>);
#     a bare "fetchconfig" H1 falls back to "Documentation";
#   - the lede is the first non-empty intro paragraph after the H1.
_h1 = ''
_lede_lines = []
_box_lines = []
_stats_lines = []
_kk = 0
while _kk < len(intro):
    _ln = intro[_kk]
    if not _h1:
        if _ln.startswith('# '):
            _h1 = _ln[2:].strip()
        _kk += 1
        continue
    if _ln.strip() == '':
        _kk += 1
        continue
    # an ASCII "####..." box right after the title -> red info box in the hero
    if not _box_lines and re.match(r'^#{8,}\s*$', _ln):
        _box_lines.append(_ln); _kk += 1
        while _kk < len(intro) and not re.match(r'^#{8,}\s*$', intro[_kk]):
            _box_lines.append(intro[_kk]); _kk += 1
        if _kk < len(intro):
            _box_lines.append(intro[_kk]); _kk += 1
        continue
    # a <!--stats--> ... <!--/stats--> block -> hero stat tiles
    if not _stats_lines and _ln.strip() == '<!--stats-->':
        _kk += 1
        while _kk < len(intro) and intro[_kk].strip() != '<!--/stats-->':
            if intro[_kk].strip():
                _stats_lines.append(intro[_kk].strip())
            _kk += 1
        if _kk < len(intro):
            _kk += 1
        continue
    if _ln.startswith('#'):
        break
    _lede_lines.append(_ln.strip()); _kk += 1
    while _kk < len(intro) and intro[_kk].strip() != '' and not intro[_kk].startswith('#'):
        _lede_lines.append(intro[_kk].strip()); _kk += 1
    break
# Anything left in the intro after the lede (and before the first "## " section)
# -- e.g. a file listing or extra paragraphs in a utility's README -- is real
# body content; render it just below the hero instead of dropping it.
_intro_body_lines = intro[_kk:]
# An app document (README/INSTALL) has an H1 that starts "fetchconfig"; its
# hero shows the "fetchconfig" brand title plus the app-specific warning
# callouts and stat tiles. Any other document (e.g. a utility's README) is a
# generic doc: its hero title comes from the H1 itself and the app-specific
# warnings/stats are omitted.
is_app_doc = _h1.lower().startswith('fetchconfig')
if is_app_doc:
    hero_title_plain = 'fetchconfig'
    _sm = re.match(r'^fetchconfig(?:\.pl)?\s*(?:--|-|\u2014)\s*(.+)$', _h1)
    eyebrow = _sm.group(1).strip() if _sm else 'Documentation'
else:
    _sm = re.match(r'^(.*?)\s*(?:--|\u2014)\s*(.+)$', _h1)
    hero_title_plain = (_sm.group(1).strip() if _sm else (_h1.strip() or 'Documentation'))
    eyebrow = _sm.group(2).strip() if _sm else 'Documentation'
hero_title = html.escape(hero_title_plain)
page_title = html.escape(hero_title_plain) + ' &mdash; ' + html.escape(eyebrow)
lede = inline(' '.join(_lede_lines)) if _lede_lines else \
    "A single-file Perl CGI front-end for fetchconfig: a browser UI for browsing device backups, viewing and comparing configurations, checking run status, and editing the device table &mdash; backed by a PostgreSQL user database."

# Version strings for the sidebar pill, hero tile and hero warning, read from
# fetchconfig.cgi next to this script. Falls back to '?' with a warning on
# stderr if the file or a constant is missing.
def cgi_constant(name):
    # fetchconfig keeps its version in fetchconfig/Constants.pm (my $version = '...').
    path = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                        '..', 'fetchconfig', 'Constants.pm')
    try:
        with io.open(path, encoding='utf-8', errors='replace') as f:
            txt = f.read()
    except (IOError, OSError) as e:
        sys.stderr.write("render-doc.py: cannot read %s: %s\n" % (path, e))
        return '?'
    m = re.search(r"my\s*\$version\s*=\s*'([^']+)'", txt)
    if not m:
        sys.stderr.write("render-doc.py: version not found in %s\n" % path)
        return '?'
    return m.group(1)

app_version = html.escape(cgi_constant('APP_VERSION_INTERNAL'))
min_fc_version = html.escape(cgi_constant('MIN_FETCHCONFIG_VERSION'))

# Hero extras come from the SOURCE, not hardcoded:
#   <!--stats--> lines -> stat tiles ("value | label"; {version} is substituted
#      from fetchconfig/Constants.pm)
#   an ASCII "####..." box after the title -> a red info callout (README testers box)
if _stats_lines:
    _tiles = []
    for _sl in _stats_lines:
        _num, _lab = (_sl.split('|', 1) + [''])[:2]
        _num = _num.strip().replace('{version}', app_version)
        _tiles.append(u'<div class="hero-stat"><span class="num">%s</span>'
                      u'<span class="label">%s</span></div>'
                      % (html.escape(_num), html.escape(_lab.strip())))
    hero_stats = u'<div class="hero-stats">%s</div>' % ''.join(_tiles)
else:
    hero_stats = u''
if _box_lines:
    _inner = []
    for _bl in _box_lines:
        if re.match(r'^#{8,}\s*$', _bl):
            continue
        _t = re.sub(r'\s*#\s*$', '', re.sub(r'^#\s?', '', _bl)).strip()
        if _t:
            _inner.append(_t)
    hero_warnings = (u'<div class="callout warn" style="margin-top:1.4rem">'
                     + u''.join(u'<p>%s</p>' % html.escape(_t) for _t in _inner)
                     + u'</div>')
else:
    hero_warnings = u''

# Precompute the dynamic pieces so the template below uses only simple named
# placeholders -- str.format() (used for Python 2.7 compatibility) cannot call
# functions or run expressions inside the template.
nav = nav_html()
sections = chr(10).join(sec_html)
intro_body = render_body(_intro_body_lines).strip() if any(l.strip() for l in _intro_body_lines) else ''

# Pull in the Mermaid runtime only when a document actually used a ```mermaid
# fence (DEVELOPER.md). This is the only external asset beyond Google Fonts, and
# only for those documents; everything else stays fully self-contained.
if _uses_mermaid[0]:
    mermaid_script = (
        u'<script type="module">\n'
        u'  import mermaid from "https://cdn.jsdelivr.net/npm/mermaid@11.4.1/dist/mermaid.esm.min.mjs";\n'
        u'  mermaid.initialize({ startOnLoad: true, theme: "neutral" });\n'
        u'</script>'
    )
else:
    mermaid_script = u''

page = (u"""<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>{page_title}</title>
<link rel="preconnect" href="https://fonts.googleapis.com">
<link rel="preconnect" href="https://fonts.gstatic.com" crossorigin>
<link href="https://fonts.googleapis.com/css2?family=IBM+Plex+Sans:ital,wght@0,400;0,500;0,600;0,700;1,400&family=IBM+Plex+Mono:wght@400;500;600&display=swap" rel="stylesheet">
{style}
</head>
<body>

<input type="checkbox" id="nav-toggle" class="nav-toggle">

<div class="mobile-bar">
  <div class="brand">
    <span class="brand-mark"><svg viewBox="0 0 24 24" fill="none"><path d="M4 12h16M4 6h10M4 18h7" stroke="white" stroke-width="2" stroke-linecap="round"/></svg></span>
    <span class="brand-name">fetchconfig</span>
  </div>
  <label for="nav-toggle">Menu</label>
</div>

<div class="layout">

  <aside class="sidebar">
    <div class="brand">
      <span class="brand-mark"><svg viewBox="0 0 24 24" fill="none"><path d="M4 12h16M4 6h10M4 18h7" stroke="white" stroke-width="2" stroke-linecap="round"/></svg></span>
      <span class="brand-name">fetchconfig</span>
    </div>
    <div class="brand-meta">
      <span class="pill">v{app_version}</span>
      <span class="pill">GPL&#8209;2.0+</span>
    </div>

    <nav>
{nav}
    </nav>
  </aside>

  <div class="main-col">

    <div class="hero">
      <div class="hero-eyebrow">{eyebrow}</div>
      <h1 class="hero-title">{hero_title}</h1>
      <p class="lede">{lede}</p>
      {hero_warnings}
      {hero_stats}
    </div>

    <div class="content">

{intro_body}
{sections}

    </div>

    <div class="page-footer">
      Generated from the fetchconfig README &middot; Rainer Tammer &middot; GPL&#8209;2.0-or-later
    </div>

  </div>
</div>

<script>
  // Scroll-spy: highlight the sidebar link matching the section in view.
  (function(){{
    var links = Array.prototype.slice.call(document.querySelectorAll('.sidebar nav a'));
    // Resolve by id, not by CSS selector: section ids can start with a digit
    // (version numbers in CHANGES, numbered sections in DEVELOPER), which is a
    // valid HTML id but an invalid CSS id selector, so passing the href to
    // querySelector would throw. getElementById has no such restriction.
    var sections = links.map(function(a){{ return document.getElementById(a.getAttribute('href').slice(1)); }}).filter(Boolean);
    if (!('IntersectionObserver' in window) || !sections.length) return;
    var current = null;
    function setActive(id){{
      if (id === current) return;
      current = id;
      links.forEach(function(a){{ a.classList.toggle('active', a.getAttribute('href') === '#' + id); }});
    }}
    var observer = new IntersectionObserver(function(entries){{
      var visible = entries.filter(function(e){{ return e.isIntersecting; }});
      if (visible.length){{
        visible.sort(function(a,b){{ return a.boundingClientRect.top - b.boundingClientRect.top; }});
        setActive(visible[0].target.id);
      }}
    }}, {{ rootMargin: '-10% 0px -70% 0px', threshold: 0 }});
    sections.forEach(function(s){{ observer.observe(s); }});
    setActive(sections[0].id);
    var toggle = document.getElementById('nav-toggle');
    links.forEach(function(a){{ a.addEventListener('click', function(){{ if (toggle) toggle.checked = false; }}); }});
  }})();
</script>
{mermaid_script}
</body>
</html>
""").format(style=style, lede=lede, nav=nav, sections=sections,
            intro_body=intro_body,
            page_title=page_title, eyebrow=html.escape(eyebrow),
            hero_title=hero_title, hero_warnings=hero_warnings, hero_stats=hero_stats,
            app_version=app_version, min_fc_version=min_fc_version,
            mermaid_script=mermaid_script)
_open_utf8(HTML_OUT, 'w').write(_ascii_entities(to_text(page)))
# Always also emit the plain-text (ASCII) rendering of the same Markdown.
_open_utf8(TXT_OUT, 'w').write(to_text(md_to_text(readme)))
print("wrote %s (%d bytes, %d sections) and %s" % (HTML_OUT, len(page), len(sec_html), TXT_OUT))

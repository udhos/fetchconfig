#!/usr/bin/env python
# gen-mermaid-svg.py - (re)generate the embedded-SVG fallback cache for the
# Mermaid diagrams used in the documentation.
#
# The styled HTML (tools/render-doc.py) loads Mermaid from a CDN to draw the
# <!--MERMAID ... MERMAID--> diagrams. So the pages also work offline / on an
# AIX host with no outbound network, render-doc.py embeds a pre-rendered SVG of
# each diagram as a fallback (shown until / unless the live Mermaid runs). Those
# SVGs live in tools/mermaid-cache/<sha1>.svg, keyed by the diagram source.
#
# "make doc" does NOT run this - it just embeds whatever SVGs are already in the
# cache, so the normal build stays dependency-free. Run this ONLY after you add
# or change a diagram, then commit the updated cache.
#
# Requires the Mermaid CLI on PATH:   npm install -g @mermaid-js/mermaid-cli
# (which provides "mmdc"). Then:      python tools/gen-mermaid-svg.py [DIR]
#
# Standard library only; the heavy lifting is mmdc's.

import os, re, sys, hashlib, subprocess, tempfile, glob

ROOT = sys.argv[1] if len(sys.argv) > 1 else '.'
CACHE = os.path.join(os.path.dirname(os.path.abspath(__file__)), 'mermaid-cache')

def preprocess(md):
    md = re.sub(r"```text\n.*?\n```\n(\s*)<!--MERMAID\n", r"\1<!--MERMAID\n", md, flags=re.S)
    md = re.sub(r"<!--MERMAID\n(.*?)\nMERMAID-->",
                lambda m: "```mermaid\n" + m.group(1) + "\n```", md, flags=re.S)
    return md

def diagrams(md):
    lines = preprocess(md).replace('\r\n', '\n').split('\n')
    i, out, n = 0, [], len(lines)
    while i < n:
        m = re.match(r'^(\s*)```(.*)$', lines[i])
        if m and m.group(2).strip() == 'mermaid':
            indent = m.group(1); i += 1; code = []
            while i < n and not re.match(r'^\s*```', lines[i]):
                cl = lines[i]
                cl = cl[len(indent):] if cl.startswith(indent) else cl.lstrip()
                code.append(cl); i += 1
            i += 1; out.append('\n'.join(code))
        else:
            i += 1
    return out

def have_mmdc():
    try:
        subprocess.check_output(['mmdc', '--version'], stderr=subprocess.STDOUT)
        return True
    except Exception:
        return False

def main():
    if not have_mmdc():
        sys.stderr.write("gen-mermaid-svg.py: 'mmdc' not found. Install with:\n"
                         "  npm install -g @mermaid-js/mermaid-cli\n")
        return 2
    if not os.path.isdir(CACHE):
        os.makedirs(CACHE)
    srcs = {}
    for dp, _dd, ff in os.walk(ROOT):
        for name in ff:
            if name.endswith('.md') or name.endswith('.markdown'):
                md = open(os.path.join(dp, name), 'r').read()
                for s in diagrams(md):
                    srcs[hashlib.sha1(s.encode('utf-8')).hexdigest()[:16]] = s
    made = 0
    for key, src in srcs.items():
        out = os.path.join(CACHE, key + '.svg')
        tmp = tempfile.NamedTemporaryFile('w', suffix='.mmd', delete=False)
        tmp.write(src); tmp.close()
        try:
            subprocess.check_call(['mmdc', '-i', tmp.name, '-o', out,
                                   '-t', 'neutral', '-b', 'transparent'])
            made += 1
            sys.stderr.write("  wrote %s\n" % out)
        finally:
            os.unlink(tmp.name)
    # prune cache entries no longer referenced by any diagram
    keep = set(k + '.svg' for k in srcs)
    for f in glob.glob(os.path.join(CACHE, '*.svg')):
        if os.path.basename(f) not in keep:
            os.unlink(f); sys.stderr.write("  removed stale %s\n" % f)
    sys.stderr.write("gen-mermaid-svg.py: %d diagram(s) in cache\n" % made)
    return 0

if __name__ == '__main__':
    sys.exit(main())

#!/usr/bin/env python3
#
# gen-syntax-diagrams.py - part of fetchconfig
# Copyright (c) 2026 Rainer Tammer
#
# fetchconfig is free software; you can redistribute it and/or modify it under
# the terms of the GNU General Public License as published by the Free Software
# Foundation; either version 2, or (at your option) any later version. See the
# file COPYING.
#
# Generate the IBM-style railroad (syntax) diagrams used by the documentation.
# Each diagram is written as a self-contained, self-styled SVG into
# tools/syntax-cache/<name>.svg; render-doc.py embeds it wherever a doc has a
#
#     ```railroad
#     <name>
#     optional caption text
#     ```
#
# fence (and md2html.py leaves a text placeholder in the plain-text companion).
# The SVGs are committed, so `make doc` needs no extra dependency; this script is
# only needed to REGENERATE them, and requires the "railroad-diagrams" package:
#
#     pip install railroad-diagrams
#     python3 tools/gen-syntax-diagrams.py
#
import io, os, sys

try:
    import railroad
    from railroad import (Diagram, Terminal, NonTerminal, Optional, Sequence,
                          Choice, OneOrMore)
except ImportError:
    sys.exit("error: the 'railroad-diagrams' package is required "
             "(pip install railroad-diagrams)")

OUTDIR = os.path.join(os.path.dirname(os.path.abspath(__file__)), 'syntax-cache')

# --- small grammar fragments reused across diagrams -------------------------
def match():      # how a profile line selects a device
    return Choice(0, NonTerminal('enterprise number'),
                     NonTerminal('sysObjectID'),
                     NonTerminal('sysObjectID prefix'))

def field():      # the headline field an oid/override line fills
    return Choice(0, Terminal('model'), Terminal('serial'), Terminal('os_version'))

def oid_tok():    # a numeric OID, optionally a ".*" table-column base
    return Sequence(NonTerminal('numeric OID'), Optional(Terminal('.*'), skip=True))

# --- the diagrams -----------------------------------------------------------
DIAGRAMS = {
    # snmp-profiles.conf directives
    'snmp-vendor': Diagram(
        Terminal('vendor'), match(), NonTerminal('canonical name')),
    'snmp-model': Diagram(
        Terminal('model'),
        Choice(0, NonTerminal('sysObjectID'), NonTerminal('sysObjectID prefix')),
        NonTerminal('model name')),
    'snmp-oid': Diagram(
        Terminal('oid'), field(), match(), oid_tok(),
        Optional(NonTerminal('extract regex'), skip=True)),
    'snmp-override': Diagram(
        Terminal('override'), field(), match(),
        Choice(0, Terminal('sysdescr'), Terminal('entdescr'), Terminal('entmodel'),
                  Terminal('entserial'), oid_tok()),
        Optional(NonTerminal('extract regex'), skip=True)),
    'snmp-members': Diagram(
        Terminal('members'), match(),
        Sequence(Terminal('serial='), NonTerminal('column OID')),
        Optional(Sequence(Terminal('model='), NonTerminal('column OID')), skip=True),
        Optional(Sequence(Terminal('name='),  NonTerminal('column OID')), skip=True),
        Optional(Sequence(Terminal('os='),    NonTerminal('column OID')), skip=True)),

    # the device table (-devices= file)
    'devtable-line': Diagram(
        Choice(0,
            Sequence(Terminal('default:'), NonTerminal('model'),
                     Optional(NonTerminal('options'), skip=True)),
            Sequence(NonTerminal('model'), NonTerminal('dev-unique-id'),
                     NonTerminal('device-host'),
                     Optional(NonTerminal('options'), skip=True)),
            NonTerminal('control directive'))),
    'devtable-options': Diagram(
        OneOrMore(
            Sequence(NonTerminal('option'), Terminal('='), NonTerminal('value')),
            repeat=Terminal(','))),
    'devtable-directives': Diagram(
        Choice(0,
            Sequence(Terminal('email:'), NonTerminal('sender / recipients / server')),
            Sequence(Terminal('db:'), NonTerminal('DSN + options')),
            # directory: either <any type> $TAG path, or the two "none" forms
            # (fetch_run none / report none) -- $TAG and path are mandatory
            # otherwise.
            Sequence(Terminal('directory:'),
                     Choice(0,
                         Sequence(Choice(0, Terminal('repository'), Terminal('template'),
                                            Terminal('fetch_run'), Terminal('report'),
                                            Terminal('lock')),
                                  NonTerminal('$TAG'), NonTerminal('path')),
                         Sequence(Choice(0, Terminal('fetch_run'), Terminal('report')),
                                  Terminal('none')))),
            Sequence(Terminal('pw:'),
                     Choice(0, Terminal('user'), Terminal('pass')),
                     NonTerminal('$Alias'), NonTerminal('value')))),
}

def main():
    os.makedirs(OUTDIR, exist_ok=True)
    for name, d in sorted(DIAGRAMS.items()):
        buf = io.StringIO()
        d.writeStandalone(buf.write)      # self-contained SVG with embedded <style>
        svg = buf.getvalue()
        with io.open(os.path.join(OUTDIR, name + '.svg'), 'w', encoding='utf-8') as f:
            f.write(svg)
        print('wrote', os.path.join('tools', 'syntax-cache', name + '.svg'))
    print('%d diagram(s)' % len(DIAGRAMS))

if __name__ == '__main__':
    main()

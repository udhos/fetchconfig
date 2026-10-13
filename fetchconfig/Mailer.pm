# fetchconfig - Retrieving configuration for multiple devices
# Copyright (c) 2026 Rainer Tammer
#
# fetchconfig is free software; you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation; either version 2, or (at your option)
# any later version.
#
# fetchconfig is distributed in the hope that it will be useful, but
# WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
# General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with fetchconfig; see the file COPYING. If not, write to the
# Free Software Foundation, Inc., 51 Franklin St, Fifth Floor, Boston,
# MA 02110-1301 USA.
#
# $Id: Mailer.pm,v 9.27 2026/08/31 12:00:00 tammer Exp $

package fetchconfig::Mailer; # fetchconfig/Mailer.pm

#
# Collects per-device backup results over the course of a run and, at
# the end of it, e-mails a summary: a small statistics table (State:
# success/failed counts; Changes: changed/unchanged/n-a counts)
# followed by the full per-device table ("Device-ID", "Date", "Time",
# "State", "Size", "Changes"):
#
#   - the globally configured recipient (email: to=...) always gets a
#     summary of every device processed in the run;
#   - a device whose recipient was overridden (device-specific option
#     "to=...") is left out of nobody's mail except its own: it is
#     bundled with every other device sharing that same override
#     recipient into a separate mail, sent only to that recipient.
#
# Both tables use the same simple color scheme (inline styles, since
# many mail clients strip <style> blocks): a solid header row, body
# rows alternating between two shades of grey, "failed" always shown
# in red, and "changed" always shown in blue, wherever either word
# appears (State/Changes columns of the device table, and the
# matching rows of the statistics table). The whole e-mail uses
# sans-serif (the browser/OS default, since named fonts like Calibri
# aren't reliably installed across recipients), and ends with a small
# copyright/version footer line.
#
# Entirely opt-in: unless a device_table/-line= "email:" entry is
# present, record_result() calls are cheap (just an array push) and
# send_summaries() does nothing at all -- no SMTP connection is ever
# attempted.
#

use strict;
use warnings;
use Net::SMTP;
use MIME::Base64 qw(encode_base64);
use POSIX qw(strftime);
use Text::ParseWords ();
use fetchconfig::Constants;

my $log;

my $email_seen = 0; # true once at least one "email:" line has been parsed
my %email_config;   # from=, to=, smtp=, user=, password=

my @results; # list of { dev_id, dev_host, ts, success, size, changed, to }
my ($rep_email_diffs, $rep_n_changed, $rep_max_diff, $rep_url, $rep_mask);  # change-report e-mail material
my @report_hide;  # accumulated report_hide=<regex> patterns (custom masking)

my $FONT_FAMILY = 'sans-serif';

# Small logo shown in the e-mail header bar (NOT in the on-disk HTML
# report, which keeps its own report_logo=). Embedded inline so fetchconfig
# needs no separate image asset; emitted as a multipart/related part with
# Content-ID <fcwlogo> and referenced from the HTML as src="cid:fcwlogo".
# This is the same small logo used by fetchconfig-web, so the two mails
# share one look. Base64 of a 50x50 PNG.
my $MAIL_LOGO_B64 = <<'__LOGO__';
iVBORw0KGgoAAAANSUhEUgAAADIAAAAyCAYAAAAeP4ixAAAWfmNhQlgAABZ+anVtYgAAAB5qdW1k
YzJwYQARABCAAACqADibcQNjMnBhAAAAFlhqdW1iAAAAR2p1bWRjMm1hABEAEIAAAKoAOJtxA3Vy
bjpjMnBhOmEyM2EwNWZkLTZlNmQtNDZkOS04NWEzLTYyM2IzZTBkNWQyYwAAAAOTanVtYgAAAClq
dW1kYzJhcwARABCAAACqADibcQNjMnBhLmFzc2VydGlvbnMAAAAAuGp1bWIAAABEanVtZGNib3IA
EQAQgAAAqgA4m3ETYzJwYS5pbmdyZWRpZW50LnYzAAAAABhjMnNoPfCeUnj/N2dyLYCS7FqmIwAA
AGxjYm9yo2lkYzpmb3JtYXRpaW1hZ2UvcG5namluc3RhbmNlSUR4LHhtcDppaWQ6ZTU5ODgxZDkt
YjM5Ny00ZDlmLWE0MTMtNTg4ZTM2YjcwNzU5bHJlbGF0aW9uc2hpcGhwYXJlbnRPZgAAAeJqdW1i
AAAAQWp1bWRjYm9yABEAEIAAAKoAOJtxE2MycGEuYWN0aW9ucy52MgAAAAAYYzJzaJmLDfLOWdbF
hkyao6hO4bgAAAGZY2JvcqJnYWN0aW9uc4KiZmFjdGlvbmtjMnBhLm9wZW5lZGpwYXJhbWV0ZXJz
oWtpbmdyZWRpZW50c4GiY3VybHgtc2VsZiNqdW1iZj1jMnBhLmFzc2VydGlvbnMvYzJwYS5pbmdy
ZWRpZW50LnYzZGhhc2hYIOO10LM5BqsSOrho9KHexbESWAswExA99W2twB0LUUN2pGZhY3Rpb254
HWNvbS5hbnRocm9waWMuY2xhdWRlLnByb3ZpZGVkanBhcmFtZXRlcnOheB9jb20uYW50aHJvcGlj
Lm9yaWdpbi1jb25maWRlbmNlZ3Vua25vd25rZGVzY3JpcHRpb254ZkNsYXVkZSBwcm92aWRlZCB0
aGlzIGZpbGUgYXQgdGhlIHJlcXVlc3Qgb2YgYSB1c2VyIGFuZCBtYXkgaGF2ZSBjcmVhdGVkIG9y
IG1vZGlmaWVkIHRoZSBmaWxlIGNvbnRlbnRzLm1zb2Z0d2FyZUFnZW50oWRuYW1lZkNsYXVkZXJh
bGxBY3Rpb25zSW5jbHVkZWT1AAAAyGp1bWIAAABAanVtZGNib3IAEQAQgAAAqgA4m3ETYzJwYS5o
YXNoLmRhdGEAAAAAGGMyc2jFhrMoMrDidIvmpxRXu7f6AAAAgGNib3KlY2FsZ2ZzaGEyNTZjcGFk
TQAAAAAAAAAAAAAAAABkaGFzaFggx3osK8ArMrzCBF0JoNWYK9GrV5iY99dvldetKswbjkpkbmFt
ZW5qdW1iZiBtYW5pZmVzdGpleGNsdXNpb25zgaJlc3RhcnQYIWZsZW5ndGgZFooAAAI+anVtYgAA
ACdqdW1kYzJjbAARABCAAACqADibcQNjMnBhLmNsYWltLnYyAAAAAg9jYm9ypWNhbGdmc2hhMjU2
aXNpZ25hdHVyZXhNc2VsZiNqdW1iZj0vYzJwYS91cm46YzJwYTphMjNhMDVmZC02ZTZkLTQ2ZDkt
ODVhMy02MjNiM2UwZDVkMmMvYzJwYS5zaWduYXR1cmVqaW5zdGFuY2VJRHgseG1wOmlpZDplNTI4
MzVjYi03MDk4LTQwMWItODQzZi02YWM3MTM3OWQ5ODhyY3JlYXRlZF9hc3NlcnRpb25zg6JjdXJs
eC1zZWxmI2p1bWJmPWMycGEuYXNzZXJ0aW9ucy9jMnBhLmluZ3JlZGllbnQudjNkaGFzaFgg47XQ
szkGqxI6uGj0od7FsRJYCzATED31ba3AHQtRQ3aiY3VybHgqc2VsZiNqdW1iZj1jMnBhLmFzc2Vy
dGlvbnMvYzJwYS5hY3Rpb25zLnYyZGhhc2hYIBs+Nd2lBCLqqfbF5DOowJRU11CKNwWdMKsOQVMW
v1RpomN1cmx4KXNlbGYjanVtYmY9YzJwYS5hc3NlcnRpb25zL2MycGEuaGFzaC5kYXRhZGhhc2hY
IBxERaXDmWzLC3P2osZop87kjKDG5Lh5DwFxd1+4SyNFdGNsYWltX2dlbmVyYXRvcl9pbmZvo2Ru
YW1lb0FudGhyb3BpYyBGaWxlc2d2ZXJzaW9uZTEuMC4wa3NwZWNWZXJzaW9uZTIuNC4wAAAQOGp1
bWIAAAAoanVtZGMyY3MAEQAQgAAAqgA4m3EDYzJwYS5zaWduYXR1cmUAAAAQCGNib3LShFkCEqIB
JhghWQIKMIICBjCCAY2gAwIBAgIUQOWgCu7COdC+uIP6BkIFPWdVEwAwCgYIKoZIzj0EAwMwSTEX
MBUGA1UEChMOQW50aHJvcGljLCBQQkMxLjAsBgNVBAMTJUFudGhyb3BpYyBDb250ZW50IENyZWRl
bnRpYWxzIFJvb3QgQ0EwHhcNMjYwODA3MTg0MzU2WhcNMjgwODA2MTk0MzU2WjBEMRcwFQYDVQQK
Ew5BbnRocm9waWMsIFBCQzEpMCcGA1UEAxMgQW50aHJvcGljIENsYXVkZSBDb250ZW50IFNpZ25p
bmcwWTATBgcqhkjOPQIBBggqhkjOPQMBBwNCAASYegpry1AYBRTVNL1CpTlbROnY3dey+UrsF9C3
phYrATN3ZHf93Mo8RQN0KOUuOn19P4oWNFWe5n2/She9N7eTo1gwVjAOBgNVHQ8BAf8EBAMCB4Aw
FQYDVR0lBA4wDAYKKwYBBAGD6F4CATAMBgNVHRMBAf8EAjAAMB8GA1UdIwQYMBaAFM5R4gSBTmRb
I/jjxM+aPpzB11zCMAoGCCqGSM49BAMDA2cAMGQCMDFzHRSeAXrSy1WOzkbhPZ6Km2wGTmZ/2gK1
8k8BQGXyqz88Rdrz6CTX9flAnYNVxgIwcF9c3fVhqmJKpi+UhasNUMko69cyX6STPfta3Q8EjyzD
jzoyrol46FP6VFHhvUcJoWNwYWRZDZ4AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAD2WEA1a99zbTUBkGxLGnTDoOxFWYOqFdjf
ZssF07Rd4PaguDZ11VBV/yChtVuo9WOqch4KzXz9Zy0PXFUOGDXNU/CHiKT8mwAAFV9JREFUeJx1
mnmUVdWd7z+/vc+591ZdqiiqilkGiXm0UYkoirQiUVA0KGq7ovaQttukVTrPldjP+MwbYkg/Ow4x
bdSspF0xnW67X7JMFA2BOISAAioCJjiCIFBAFVNRRU13Omfv3/vjnDsU3e+udRf33jpnn9/43d/v
byMAPKuWm8TNWKVt3QW3Lj5s5zKCIhgEMIACkr7/fy9t+CzJd5Ne7339t1HXNN7n/5O10n9FAYPn
5AkJt/zz6wuumHfVaysvK3H//YaVK71UnZj1at/Yg4Otv47y9hJeP+DZ32vIWkARq6iAoMnKVYOk
wWIAEVBFUExgASEuVECVoDkDXvHq0aoHAmi6UOOajU5o+kUVAgv7P/R07zRBc/PaxfPn/slLT3y+
zP33J/Ga9Wrf2K5Ky8tubDBfXtrtWPeOJVCw6QNE05AkttYWbjBABIwRxAix8/jhEhSKzPp0GwB7
95yEXBNmTI4gsKh6vPOjElS1XaoBUh39F1UIQnTwqNPigG3OZ9avuH7utY9+femInNOl43Z+5FZH
HfZi+c2emLXbAppCCG1SUvh6SakiIsmTvCbGWwMiRJGDQhmKJSQnLPxMOyuu/TS3XPVpAH7+8h5+
uPpjNn7Qi5YFmnNIU5YwMKgqXkG9r2cWUNWaMyJJxFQVxED/oZjyUJBvCtfdtPySGyT4Vfz7eKo9
V36z2/Hr7ZamECyJE0It3OnSGCMYY/HeE1dS46MymTGW889oY/lFU7n5czM5fdZ4KsCTXYnDX5ku
ZID9e4/z8w37eOGNg2z/ZIB4xEEmB2OaCEKLAbx6vE+NbmgUEUkSgyJi0YGeWMvDQWtT5k3hCVUK
x7y8uM6QDSEwo0rJiGCMQcQkJVMoQbEI6ugYn2Xh2eO54eJpLJs/lY5J4wDYPAw/7fI8f1TpKyUZ
7Mh5bpgg3DrDcMmYxLxj3X2s2XKQVZu72PThCfpPVEBCyDdhmrIEVpJsOZ9morHSFGyAP7jLZ4eP
GZHH1OnBHiPbNkIuA+oQEYwREEMcORgqJMZnPWfNaGHphVO47uIZLJwzGck3MQy82gcv9njWnVAO
FarNKQQmeW7sgTgJztSccnmHcMPUgCs7IQ+4wWE27DjMqs1dvLr9MB8fGobIQFMzjGkizATgPd65
JD9VR/a+S7Z4oijypKoePYJsfj3pC0AjD4MjUC7Q3GpY8Jl2rrt4OtdePIOZZ0wEDDsdrOmB1Ucc
WwehEKWNZMFkhSAP3tUBSFIo9kDsAJdUTD6EC8fCsnFwTQfMDgFi9uw6xq827+fFzV28/XE/pQKQ
aYLWPMYaVB1iM/h975Mp9pVFfqiqPUeQza8hYYhWynTICJd/tpMvXDaLqy6azpjxbUTA7wbh+W7l
t72evUXAS2KdBWtAVPFW0L5+9JmfwEgBbAhqkgbVpMYxKWDgwStIADfdArMm86m4wpIpITdMES5r
hQwweLSPtW918dyGvWx49xh9jIFsDozFd31EptBXFnlKVbuPYF9fjxdLR6bIth8vZ8bUcRwHVh+F
57s9m/o9A1GCUFUwCFKE9Cla4h2mLcA9/AR3txzhuluuoRI5EIsH8hlLS07oH/FUnKLe05QJ+PFP
1/KzN7qIH/gOTJsEJ2OwhtaMcsk44YaphuUTYQLwwa7DXHD7i5SaOzBBgDuwi3C4txxgGmFaCQLD
jElj+MYe5ZGPHc6YJILGYAOPGMGnOOKUeu2kUCkAQ4MsuvlSFi1ZQOPr45Pwz+uKrLyxiUzD71v2
n2T6+Rfw/UceonDvfQQzJuKGHYMY1h6DtUc9d6jn4XMsd01qAWNq2xiSZDtIIlnFb4N6RWPHJ+UQ
J4ZcVogVfGCg2eDiBgsaUMQE4Ac8OA8iDA0M45ynFMf8YP0wx4c8G/eU2LJhkP397bQ3GS45I8sX
zm+hv7efJTdeyxmzJnH7/3iAyspvYiZ3IgWHCQ2hEUpFQ3dF8LFDq1SmGlFjCGoGVTHbewTI2cTZ
2Hvi0MKRbnj6URg+BmLrqTAG4gg38QzM7fcQTG/BGYugWGvI24Dn/1Bgy5Yhpny6ieXXt/PiH4oU
e8rojeP40/ljKUcxvUd6ueK683lkoMg3Hvwu5W/eBy2tOKcYFcRAplo9NUpUD2aAgNiUZ6hH1AEJ
UipJYxofIw+s4NHrjvK5K0/DVYoYkyzovccEAa+u/SX3fuNjSl+5B3oOIcFsAHYcLGGccvbZzWy4
7zQ68pZ3u8tc/p1uRoqeg/0xZ/2X03jumV/xyppW8i15Zsb9fLRxK+YLV6ADMWBprGJ8DQurWUhL
S0BEAY+kmfEpYZPQ4g/1MrG4l7u+3IzJbIc4BpPmNV3z3K/mCUY28drabv7QP0JRlgPwxR8f4b13
Cnx7xRQ68pYThZg5U7Ms+EyOf13Vx5i85Qd/uohlV12Auph8YOkwnvu7ihg0rZ4GnncqOZNkv0to
unrQFNh9XL9J6heLcQwe248fGCEeHMYNjOAGCriBEfxwgdLeA9w5v58XHhvhuksHGBwuA/DAjZ2c
/dlmXt4xRNkpHc0B+/sifr+7yOeXjOWv/7iVkciTH9NMvnUMLa15FIMJQkw25XSNzThKRlRLzGDw
Va8anGm4Tho+20AwgWIsKecSjDUYKwTZLCeOjuC2vUPl2CcYk6xz7Zw87eMCNm8dYP4D+1jx74dZ
8MA+uveNMHtahnkzcpSc4pwjjh0VVSJv8D3HqHx8BHLhKdSknqFaxFVr4Jvar/iUeVpPggrVt3pU
I9A4+UF8ysc8iENxGGuwTQESZpL9xXuK3nLJ7LH85fVTwGb40aqTzJ3Vyk3XTOasaQnpas5ZshlL
LhsSilDOtDHr/Sc57+Hz4SePQE5qIJTYeoq6E0NQMzQNv8ckQug/1KMCrma885LS7ERwxbESOyGu
KD5WjDEYY+jqOs6tZ0e05QJ+9V7ED46PcM8ftzB7gqEQD/HhvuGaNBD1ZHMhH+7p5+s39nPnrcdp
v/7fOHnL18AEBALO+yTY0miZNDqSpCnyisaenB3ttKqm5Mmi3hCMFQhJUMFCAExo8QRjobUZmpoC
Hvn+42zcsAYXtuC8IxcKZ2aFxx+OiZxDRFPpoekOkOjhgYEKT22E2a2OieMD+isesjDGQjnyxGlr
17VKA2olNFkoRZ5yJaYlGF1a6hV1Aj7ABo7Vq4vs6070iQJuRBnelWFcJ7y1axw//d9PY/1BfvLD
JVy9tAxlB8SgEUgJqCQZ9j4BGwRweBdjssKmbRO447Z++kPFGMU7aA1gpBCjsSaAnDqiqg0boiSN
Wy56hosRnQEQacJS46SyXMVADu77B8u2A1/i0ksvwHmPiEWaLNoZcsQZlp4ZcqWPac408fD3d/LR
W7/g7jt7iU/GWFMComRRqar3uoASEeJIueS8JqZPD/lwa0jOKqUIJmSg/2gZYp/2uKaIqwTJTpNw
KWMtcSmmt3+E0yZ0Jg5ESeBUIVBDfNzxmzem8NL67zK5o5kiSVklQ456lUYkOuPq6y9nxZd+z9/d
NoINUmjHADbtt1PfQKj4HsiUQQLBpzZMa4ae48MQOUzyU43fBbVJhZhEf8fQdWSIM2YBLklpldOI
N7iSozUfMDBc4Svf+QXeQ7FQpHN8J0cOn2D69Gn09Byns72TYrHA/7rjalryAnGUMAfx/4nx2hCC
xB5TCqsfU36nzMwJW7oHoGFnqWY0qOlyJEEPG/JhVz+3Lkm4losbnpEiVMV5ugeFD97/AGMD+voH
mTljBh/t3Eel4vjgw0+YNWMmx4730jN0DVEcgRaBZHoiKbCMftnkQcZDIYCKSZxWcBXozMN44N29
fZDJ1AcU6d1B/Vsq9sMM2/ec4G5gag4ORakjIqj32BBGiiWGizH/8k9/T7FYScywAcVyTDYTEscR
1gTkcsL+AzGFkQhsBY0CxKTbmVZHSdV5UvJZUBjOQFilFgJl5cwJBkF5Z08/ZLM4VVTq22BQyyaC
9wrNWbbvHQA889oMhw4lxSgosY+wYwPuuPwA37zrzzjnvAWUKzEiBgRymQ7iOI/zWVAlmw35w5u7
+OqyPZBVTFkR00j/pAY0iRGeuBCipWwiDascq+BZNAHKA0PsPDAETe2oVxq288bSSlBAcll2H+ql
/2g/y6Z18MJekqZHsUEEQyXu+tqn+Nyufex94xUkC0EzvPY2PLz6b1h45gd8/fqTxOUMOM9//0qJ
s5adpHK8TKVSBDxeFU1lr6SbmyoEAeRtC07DlLUmKKMVz/IZsPW9HgqDMUGrxcfxqCAE+LTXU1gO
A0Ol6Hl560GWL+3gTgEXVbWHgjii5vM5Z8EA55zVA9IKbZ5Me4VH9y7kswv2c+0dh2AoB8ZBWOGB
7wVs2HoG4ZgcqgZVQSQAbDqrUowIlaJyZscBHv7SCNaZpKUjmJxxnN8K/+31LgiyGBF8nbanFKUR
MKoCK9vMv6/byy3XnMtF7fDGAcUKSWrCENM0jvjwW1AOidUROmVo0OHiMhr1g+uFchO0ed5cV2LN
O3/Ji798jOZ8Dq9gbKqMqSnkhJSi3PTX/8i/rnmcv7ktC94gJeXmGWDUsWrTQRjbgvc+rcr0ZvUp
RSGdhiA455DWPL/dfpiBvpN8dU4bm9+MEZNwMJongg5jo+NgM6h3WONx3mHH5di0fxq3ryzjXI5s
3rLjrUNcfe0cTpQcj/7sFaZM7GRopEgmkyGKY1QhE1p6+wZZvngOSz73GfavV/CeyIGamLsW5Nm8
tYuugwWC6e1JWdUwyqelVQ1LmiZVCENLqVf40fPvce+XFzI+FzMcJ+NMmtthZDf4SlLUaVRCq7ie
99kx8fPseKuSjFhsFnavZ1FUZuOOQzz0zUeZu3gR73+wk+nTpjEwNIR6T0dHGx/v+IgwXIGMOLK2
DMT0D8ZcuOgcZrVn+K9Pb4WmMemJQAJOkpaRVHukfkQAiEloR/s4vvfz97j7ixfx7YU5vvpPKUSG
BvoOgLfgPBZFh5QrLzL8mseoOAgCwTnItBpe+W2BwwPzWH7OTP723i9zxqzTObFkHmNbx1Iul1Eg
l8tw5Mr5XLbos6x+bjutcRl8jNLKP9x/N7s+6eWl1w9hZ83Exa4OVbUe4RT2m+pf9UrQlOVYl+PR
f3mT+267iIdalLJYWvwwFAZADahLQU9oCpRlS4N6n3mgSThzfMCyb61l3kULmT93LqVShdYpLTjn
keYket4r405vZ/dHx3n5xdU8vjyGYoXmXBOd7eP4xsPr0XwbIpLwZEmGgbUJkNZKi//w8lGEnTSB
B5/5PZeeN4X2lhwuMFDqQ0qVZNjdoNk94IspAqY/eg+nTxGeuPV3PPPTy3DWppWYaGxTDZ4RxAum
YHjwiiGumFeBk4621gzf+9EmXtg6hJk8Hh+70cK9Rq8gwJHq4gSDq6N8VcUEhkFp5c7/sxZxDskI
camAx9eMbdyHquwxJQqYACplWLwIFi8eSfajBkpUP40CjiuUDcRC8YQhk1cqhQrPPfsRwXlz8c4n
nOnUqEvCBhJHXKKDq82TsFLBO0/Q2sr73YO09gyRzypBXwQFAasNa2pdfjaeMlV7b7gavYZ37e8C
ZaAsyQBZlaZMBB5ODFSQyRMQa5Nx/qn0LHVklNStMeoq/5FqiVUIJ01n8OiF3H7vaq4+3TPQq2RC
GJdJLvVV8VW7f3T2vZpEGiM4L8n1DX+3RonUMxBFKNDZkeWdPcKWE2cicyfh4viUbDQ8RBP8ChLR
lPwoqUjR9GSo6rGLIuzZN/F/t7Wx4cAwN3x+DruPlnhldzrJtpJmRNIHpsNu0s8aJBNJbFJvjaG1
mmQkG/G3c5RQlPue3gLZScjcC8GGtaFhLeuiNbSqDuuC6kCkxn7RhK7UTl6rTS1kL1xGpe8YCxcu
4slr/4hnemDFJhhxkMum5zijhcLokm74LCT+l8rwR23wwlKYbWDFt39H9lPjoLODqFJKUm0a2GGN
/sdUeyCO4jionWj50fCVUKA6lVbvibVMb76NW/5uLZu37+fxby1m7pWWP3sl4r2jBsmlhzmamlqT
o/VFRRVrIHJCVFGun+X5+dIsfT0nuODuNWzbWcJOHY+WR0hmzFJru7qEqa8pKKpejTjS8wF/CiCM
Hrkko3yDtYZw9uk88XwXC//il4wd6ufdm7LcO88ianBRgDEBxtqEVJkAbIDYAGstJgiIo4CWUPjh
5QGrlmZZ9/oezv3iKrYdMITTJ6HOJ/dWx0SjDKnDr1QnO96rIfKqWsVNj9Q6URuqJF0spTCuEhPO
mMimTyLOvvkXPPWzd3joAsP7N1uuPM3jyoqL0sMsASuKEXARuIpy4yzP7j+33Dkr4msPrmfZ3b/l
mLQRdLTUGlt9lU0me2/tlKt63l/T30mjGLFGGDmRqBStlkJaZpIuUD2qlpRcGiGuxAQdLQyO6eSO
h97mstt+Qbyvm5evtry03DCvw+OKiqsoriK4kjJ/vGf9DYZfLrbs2LiH2X/yLN9/di928mRs1uKc
S5+j6S4OSj2wqAfv6s3vHRRPqqpayVy/plLZ9VZox7Qp4yYJziVM11pUTEoJpMY8khApVXkmAiYI
iPqHoDTEbVfO5IEVFzDptE7WHIaVbzu8wrfmW66ZDHv3HOWex7ayamMPtI8lbMnhorihAZTqeaOm
zLauzn2CrCgqFv1km9Oj+2xmbPthmTTnnqtO2PbnolKp2bS0e2mbYEQTpFBJYFRPrVGtprRerzaw
OK/44yfJ2YgvXTWL//lX5zJ5+ngAuruOs/LHO/jJS/txEmIntIJ61DVkvrq36OhnidQzIill8Hu2
Oj26z4bNzYfbcuZqAZiy+HtLjvZVVrtyIWtaOlXaxptGjaLS0C3S0D01uK07FASWSuThxAChifnz
JTMAw7+90kWsITK+BWsNPnK1eq9LVqn/bwetEvTGjS8JoN+z3enh3TZozvee1tmyZP8HT+4Qzr89
ZPtTUefFD149UGR1VCxa09rhyDWb6ryrjmDVvaXREanFrxpNEbBBQBR76BtOynBcnjC0uCge3Yek
uj29uZH1VI1X1aS5gxCO7PK+Z0+QGTNmoGNsePnhnU+9A/cHyQqL7g94bWU88ZLvXtM74p91J3ub
GOlLzshFQNLduFZOjQ5J3ZBqWaTMQESwQYCqwblGf08tz2oEGhfx9RqrxVHRYj8Bxd5pUzqW7dvx
j2/DogBei+sWpJkZu/CxGws9h7+tlUHEBqZ6/GuNRWyVfiTT8OS/NGkcRXEk1cwBYpLra9/FIEbU
oqKKK1Vc2UgSAEkHrcbamiOmVqmKtUKpElfi2EUY1KC0VI78ff+BpzfD/QGsjAH+H5qSwuReGvPv
AAAAAElFTkSuQmCC
__LOGO__
$MAIL_LOGO_B64 =~ s/\s+//g;

# Card/header palette, matching the fetchconfig-web mail.
my $MAIL_CANVAS_BG = '#f4f5f7';
my $MAIL_CARD_BG   = '#ffffff';
my $MAIL_CARD_BORDER = '#e1e4e8';
my $MAIL_HEADER_BG = '#1f4e79';
my $MAIL_FOOTER_FG = '#8a929b';

my $HEADER_BG = '#1f4e79';   # match the mail card header
my @ROW_BG    = ('#cfcfcf', '#afafaf');
my $FAILED_FG  = '#ff0000';
my $CHANGED_FG = '#0000ff';

#
# remove heading and trailing blanks (same rule as
# model::Abstract::opt_trim; duplicated here to keep this module
# self-contained, same as e.g. mask_secrets is duplicated between
# Detector.pm and model::Abstract.pm)
#
sub trim {
    my ($str) = @_;
    if ($str =~ /^\s*(\S|\S.*\S)\s*$/) {
	return $1;
    }
    $str;
}

#
# Strips surrounding double quotes from an option value (duplicated
# from model::Abstract::dequote_value to keep this module
# self-contained). A matched pair "..." is unwrapped and \" / \\
# escapes inside it are unescaped; a single stray leading or trailing
# quote (an unbalanced value that Text::ParseWords leaves as-is) is
# also removed, so a mistyped footer="(c) ... doesn't render its
# quote literally in the mail.
#
sub dequote_value {
    my ($val) = @_;

    if ($val =~ /^"(.*)"$/s) {
	(my $inner = $1) =~ s/\\(["\\])/$1/g;
	return $inner;
    }

    $val =~ s/^"//;
    $val =~ s/"$//;

    $val;
}

#
# Returns $line with any password=... value replaced by '***', so a
# raw "email:" line can be logged (e.g. on a parse error) without
# leaking the SMTP credential.
#
sub mask_password {
    my ($line) = @_;

    (my $masked = $line) =~ s/\bpassword=[^,\s]*/password=***/gi;

    $masked;
}

# Percent-encode a string for use in a URL query value. Report filenames
# are "report-YYYYMMDD-HHMMSS.html" (letters, digits, "-", "."), so this is
# belt-and-braces, but correct. Kept dependency-free (no URI::Escape):
# everything except the RFC 3986 unreserved set is percent-encoded.
sub _url_encode {
    my ($s) = @_;
    return '' unless defined $s;
    $s =~ s/([^A-Za-z0-9_.~-])/sprintf('%%%02X', ord($1))/ge;
    return $s;
}

sub escape_html {
    my ($str) = @_;

    return '' unless defined($str);

    $str =~ s/&/&amp;/g;
    $str =~ s/</&lt;/g;
    $str =~ s/>/&gt;/g;

    $str;
}

#
# Wraps the literal text "failed" in red/bold; anything else is
# returned unchanged. Applied to both tables, wherever "failed" shows
# up (State column, and the failed-count row of the statistics
# table).
#
sub red_if_failed {
    my ($text) = @_;

    return $text unless defined($text) && $text eq 'failed';

    "<span style=\"color: $FAILED_FG; font-weight: bold;\">failed</span>";
}

#
# Wraps the literal text "changed" in blue; anything else (including
# "unchanged", which contains "changed" as a substring but must not
# match here) is returned unchanged.
#
# Colour the Changes-column state word: "changed" blue, "initial" teal
# (a first backup, not a real change), anything else unchanged.
sub colour_state {
    my ($text) = @_;
    return $text unless defined($text);
    return '<span style="color: #2451c4; font-weight: bold;">changed</span>' if $text eq 'changed';
    return '<span style="color: #0e7c8c; font-weight: bold;">initial</span>' if $text eq 'initial';
    return $text;
}

sub blue_if_changed {
    my ($text) = @_;

    return $text unless defined($text) && $text eq 'changed';

    "<span style=\"color: $CHANGED_FG; font-weight: bold;\">changed</span>";
}

sub header_row_html {
    my (@cols) = @_;

    my $html = '<tr>';
    foreach my $col (@cols) {
	$html .= '<th style="background-color: ' . $HEADER_BG . '; color: #ffffff; '
	    . 'padding: 4px 8px; border: 1px solid #888888; text-align: left; '
	    . 'font-family: ' . $FONT_FAMILY . '; '
	    . 'line-height: 100%; mso-line-height-rule: exactly;">'
	    . escape_html($col) . '</th>';
    }
    $html .= "</tr>\n";

    $html;
}

#
# @cell_html is pre-formatted cell content (already escaped/colored
# by the caller) - not re-escaped here.
#
sub body_row_html {
    my ($row_index, @cell_html) = @_;

    my $bg = $ROW_BG[$row_index % 2];

    my $html = '<tr style="background-color: ' . $bg . ';">';
    foreach my $cell (@cell_html) {
	$html .= '<td style="padding: 4px 8px; border: 1px solid #888888; font-family: ' . $FONT_FAMILY
	    . '; line-height: 100%; mso-line-height-rule: exactly;">' . $cell . '</td>';
    }
    $html .= "</tr>\n";

    $html;
}

sub init {
    my ($class, $logger) = @_;

    $log = $logger;
}

#
# Parses an "email:" device_table line, e.g.:
#   email: from=config.backup@acme.com,to=admin@acme.com,smtp=FQDN,user=xxx,password=xxx
# "user"/"password" are optional. "footer" is optional too: it sets the
# copyright text in the summary mail's footer (the " - Version <n>" that
# follows it is fixed); it must not contain a comma. May be given more
# than once; later
# values overwrite earlier ones for the same key (same merge rule
# used by "default:").
#
sub parse_email_line {
    my ($class, $file, $line_num, $line, $rest) = @_;

    $email_seen = 1;

    # report_hide= is special: a regex may contain commas (e.g. the quantifier
    # {m,n}) and other characters the comma-aware option parser below would
    # mangle. When the line is a report_hide= option, take EVERYTHING after the
    # first "=" verbatim as the regex - no comma split, no quote stripping, no
    # trimming. One regex per line; comment the line out to stop hiding it.
    if ($rest =~ /^\s*report_hide\s*=(.*)$/s) {
	my $pat = $1;
	push @report_hide, $pat if defined($pat) && length($pat);
	return;
    }


    # Quote-aware split, like the device options in model::Abstract:
    # a comma inside a double-quoted value (e.g. a footer that reads
    # "(c) 2026 ACME, Inc.") is not an option separator, and the
    # surrounding quotes are stripped from the value. $keep=1 leaves a
    # literal backslash in an unquoted value untouched. Quoting stays
    # optional; an unquoted, comma-free value parses exactly as before.
    foreach (Text::ParseWords::parse_line(',', 1, $rest)) {
	next unless defined && /\S/;
	if (/^([^=]+)=(.*)$/s) {
	    my $opt = trim($1);
	    my $val = dequote_value(trim($2));
	    $email_config{$opt} = $val;
	    next;
	}
	$log->error("bad email option '" . mask_password($_) . "' at file=$file line=$line_num: " . mask_password($line));
    }
}

#
# Records the outcome of one device's fetch attempt, to be folded
# into the end-of-run summary e-mail(s). $args{to}, if defined, is
# the device's overridden recipient (device-specific "to=" option).
#
# Also writes the per-device status file <repository>/<dev_id>.status
# (see write_status_file), unconditionally - it is a repository
# artifact, not part of the e-mail feature, so it is produced even
# when no "email:" line is configured.
#
# Parallel fetching (fetchconfig.pl -P): a worker process cannot share
# @results with the parent. While a result sink is set
# (set_result_sink), the row is serialized to that file instead of
# being kept; the parent later calls replay_result_file, which feeds
# each row through this same routine - so @results, the .status file
# and send_summaries all happen in the parent, exactly as at -P 1.
#
my $result_sink;   # path, or undef

sub set_result_sink {
    my ($class, $path) = @_;
    $result_sink = $path;
}

sub record_result {
    my ($class, %args) = @_;

    if (defined($result_sink)) {
	# One row per line: key=value pairs, tab-separated. Values are
	# escaped so tabs/newlines/backslashes survive; undef is kept
	# distinct from '' (as "~") so the replay reproduces it exactly.
	if (open(my $fh, '>>', $result_sink)) {
	    my @kv;
	    foreach my $k (sort keys %args) {
		my $v = $args{$k};
		if (!defined($v)) { push @kv, "$k=~"; next; }
		$v =~ s/\\/\\\\/g; $v =~ s/\t/\\t/g; $v =~ s/\n/\\n/g;
		push @kv, "$k=$v";
	    }
	    print $fh join("\t", @kv), "\n";
	    close $fh;
	}
	else {
	    $log->error("cannot write result sink $result_sink: $!");
	}
	return;
    }

    push @results, { %args };

    $class->write_status_file(\%args);
}

sub replay_result_file {
    my ($class, $path) = @_;

    return unless -f $path;
    open(my $fh, '<', $path) or do { $log->error("cannot read result file $path: $!"); return; };
    while (my $line = <$fh>) {
	chomp $line;
	next unless length $line;
	my %args;
	foreach my $kv (split /\t/, $line) {
	    my ($k, $v) = split /=/, $kv, 2;
	    next unless defined $k;
	    if (defined($v) && $v eq '~') { $args{$k} = undef; next; }
	    $v = '' unless defined $v;
	    $v =~ s/\\n/\n/g; $v =~ s/\\t/\t/g; $v =~ s/\\\\/\\/g;
	    $args{$k} = $v;
	}
	$class->record_result(%args);
    }
    close $fh;
}

#
# Writes <repository>/<dev_id>.status as an INI-style file: a
# [<dev_id>] section header, then key=value lines. Consumed by
# external tools (e.g. fetchconfig-web uses backup_duration_sec for
# its progress spinner). Overwritten on every run. Never fatal: a
# problem here is logged and the run continues.
#
# Fields (from the arguments record_result already receives, plus
# elapsed/dev_opt_tab/changes_only added at the call sites):
#   backup_start_date/time  derived from the end timestamp minus the
#                           duration (epoch subtraction, so leap years,
#                           month lengths and DST are handled by the
#                           time library, not by hand)
#   backup_end_date/time    the end timestamp
#   backup_duration_sec     integer seconds
#   backup_state            success | failed | skipped
#   backup_changed          unchanged | changed | initial | forced | unknown
#
sub write_status_file {
    my ($class, $args) = @_;

    my $dev_id       = $args->{dev_id};

    return unless defined($dev_id);

    # The repository is resolved at the call site (via the model's
    # dev_option, which also consults the default: options) and passed
    # in explicitly; it is where every other per-device artifact lives.
    my $repository = $args->{repository};
    if (!defined($repository) || !length($repository)) {
	$log->error("cannot write status file for $dev_id: no repository");
	return;
    }

    # $args->{ts} is the fetch START time; duration is elapsed seconds.
    # End = start + duration. (Start is a real recorded timestamp here,
    # so no derivation is needed; the subtraction path is kept for the
    # documented contract in case a caller ever passes only the end.)
    my $duration = $args->{elapsed};
    $duration = 0 unless defined($duration) && $duration =~ /^\d+$/;

    my $start_ts = $args->{ts};
    my $end_ts;
    if (defined($start_ts)) {
	$end_ts = $start_ts + $duration;
    }
    else {
	# Only an end time known: derive start by epoch subtraction.
	$end_ts   = time;
	$start_ts = $end_ts - $duration;
    }

    my $state;
    if (defined($args->{state})) {
	$state = $args->{state};                 # explicit, if a caller sets it
    }
    elsif (!defined($args->{success})) {
	$state = 'skipped';
    }
    else {
	$state = $args->{success} ? 'success' : 'failed';
    }

    my $changed;
    if ($state ne 'success') {
	$changed = 'unknown';                    # no meaningful comparison
    }
    elsif ($args->{changed} && $args->{changed} eq 'initial') {
	$changed = 'initial';                    # first-ever backup, no previous
    }
    elsif ($args->{changes_only}) {
	$changed = ($args->{changed} && $args->{changed} eq 'unchanged')
		 ? 'unchanged' : 'changed';
    }
    else {
	$changed = 'forced';                     # changes_only=0: saved regardless
    }

    my $path = "$repository/$dev_id.status";
    # The temp file is a DOTFILE (".<dev_id>.status.tmp.<pid>") so that
    # a concurrent -P worker scanning the repository root skips it by
    # name (scan_dir ignores entries starting with "."). Without the
    # dot, a worker could list it, then find it gone after the rename
    # below - the race that produced "could not open dir ... .status.tmp"
    # errors in a parallel run.
    my $tmp  = "$repository/.$dev_id.status.tmp.$$";

    if (!open(my $fh, '>', $tmp)) {
	$log->error("cannot write status file $path: $!");
	return;
    }
    else {
	# Localize the output separators: Abstract::dump_config sets a
	# global $, = "\n" that is not restored, so a bare multi-arg
	# print here would otherwise get newlines inserted between
	# every argument. Build one string and print it as a single
	# argument, with $, and $\ neutralized for safety.
	local $, = '';
	local $\ = '';
	my $body =
	      "[$dev_id]\n"
	    . "backup_start_date=" . iso_date($start_ts) . "\n"
	    . "backup_start_time=" . iso_time($start_ts) . "\n"
	    . "backup_end_date="   . iso_date($end_ts)   . "\n"
	    . "backup_end_time="   . iso_time($end_ts)   . "\n"
	    . "backup_duration_sec=$duration\n"
	    . "backup_state=$state\n"
	    . "backup_changed=$changed\n";
	print $fh $body;
	close($fh);
    }

    # Atomic replace so a reader (the web spinner) never sees a
    # half-written file.
    if (!rename($tmp, $path)) {
	$log->error("cannot rename status file into place $path: $!");
	unlink($tmp);
    }
}

sub iso_date {
    my ($ts) = @_;

    strftime('%Y-%m-%d', localtime($ts));
}

sub iso_time {
    my ($ts) = @_;

    strftime('%H:%M:%S', localtime($ts));
}

#
# Small "State"/"Changes" counts table, meant to sit above the
# per-device table in the same e-mail, reflecting only the rows in
# $rows_ref (i.e. per-recipient, not global).
#
sub build_stats_table_html {
    my ($class, $rows_ref) = @_;

    my %state_count;
    my %changed_count;

    foreach my $row (@$rows_ref) {
	$state_count{row_state($row)}++;
	$changed_count{defined($row->{changed}) ? $row->{changed} : 'n/a'}++;
    }

    my $html = "<table border=\"0\" cellpadding=\"0\" cellspacing=\"0\" style=\"border-collapse: collapse;\">\n";
    $html .= header_row_html('Statistic', 'Count');

    my $row_index = 0;

    foreach my $key ('success', 'failed', 'skipped') {
	next if ($key eq 'skipped' && !$state_count{$key});   # only show skipped if it occurred
	$html .= body_row_html($row_index++, red_if_failed($key), $state_count{$key} || 0);
    }

    foreach my $key ('initial', 'changed', 'unchanged', 'n/a') {
	next if ($key eq 'n/a' && !$changed_count{$key});       # only show n/a if it occurred
	next if ($key eq 'initial' && !$changed_count{$key});   # only show initial if it occurred
	$html .= body_row_html($row_index++, colour_state(escape_html($key)), $changed_count{$key} || 0);
    }

    $html .= "</table>\n";

    $html;
}

# row_state - the effective State of a result row for the summary mail:
# the explicit backup_state if the caller set one ("skipped"), else derived
# from the success boolean. A lock-skip (or a system-dir/allowlist skip) is
# recorded with state => 'skipped' and must show as Skipped, not failed.
sub row_state {
    my ($row) = @_;
    return $row->{state} if defined($row->{state}) && length($row->{state});
    return $row->{success} ? 'success' : 'failed';
}

sub build_device_table_html {
    my ($class, $rows_ref) = @_;

    my $html = "<table border=\"0\" cellpadding=\"0\" cellspacing=\"0\" style=\"border-collapse: collapse;\">\n";
    $html .= header_row_html('Device-ID', 'Date', 'Time', 'State', 'Size', 'Changes');

    my $row_index = 0;

    foreach my $row (@$rows_ref) {
	my $state = row_state($row);
	my $size  = defined($row->{size}) ? $row->{size} : '-';

	$html .= body_row_html($row_index++,
				escape_html($row->{dev_id}),
				iso_date($row->{ts}),
				iso_time($row->{ts}),
				red_if_failed($state),
				escape_html($size),
				colour_state(escape_html($row->{changed})));
    }

    $html .= "</table>\n";

    $html;
}

#
# Full e-mail body: heading, statistics table, then the per-device
# table, all for the same set of rows.
#
# Test hook: set the change-report lexicals from a test (see t/49). Harmless
# in production - nothing calls it except the test suite.
sub _test_set_rep { ($rep_email_diffs,$rep_n_changed,$rep_max_diff,$rep_url,$rep_mask)=([],0,0,$_[1],0); }

sub build_report_html {
    my ($class, $rows_ref, $heading) = @_;

    my $ver = escape_html(fetchconfig::Constants::version());
    my $ff  = $FONT_FAMILY;

    # Grey canvas -> centered white rounded card with a dark-blue header bar
    # carrying the inline logo (cid:fcwlogo) and "fetchconfig vX.Y". The
    # copyright footer is emitted OUTSIDE/below the card (see the end of this
    # sub). Email-safe: nested tables + inline styles only, no <style> block.
    my $html = '<!DOCTYPE html><html><head>'
	. '<meta http-equiv="Content-Type" content="text/html; charset=utf-8">'
	. '<meta name="viewport" content="width=device-width, initial-scale=1"></head>' . "\n"
	. qq{<body style="margin:0;padding:0;background:$MAIL_CANVAS_BG;font-family:$ff;color:#222;">\n}
	. qq{<table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="background:$MAIL_CANVAS_BG;"><tr><td align="center" style="padding:24px 12px;">\n}
	. qq{<table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="max-width:820px;background:$MAIL_CARD_BG;border:1px solid $MAIL_CARD_BORDER;border-radius:10px;overflow:hidden;">\n}
	. qq{<tr><td style="background:$MAIL_HEADER_BG;padding:16px 24px;">}
	. qq{<table role="presentation" cellpadding="0" cellspacing="0"><tr>}
	. qq{<td style="vertical-align:middle;"><img src="cid:fcwlogo" alt="" width="40" height="40" style="display:block;border-radius:8px;"></td>}
	. qq{<td style="vertical-align:middle;padding-left:14px;color:#ffffff;font-size:20px;font-weight:600;">fetchconfig <span style="opacity:0.8;font-weight:400;">v$ver</span></td>}
	. qq{</tr></table></td></tr>\n}
	. qq{<tr><td style="padding:24px;font-size:14px;line-height:1.5;">\n};

    $html .= '<p style="font-family: ' . $FONT_FAMILY . ';margin:0 0 16px;">' . escape_html($heading) . "</p>\n" if defined($heading);

    $html .= $class->build_stats_table_html($rows_ref);

    # A CSS margin on <table> isn't reliably honored by Outlook's
    # Word-based rendering engine, so the gap between the two tables
    # is an explicit spacer block instead.
    $html .= '<div style="height: 16px; line-height: 16px; font-size: 1px;">&nbsp;</div>' . "\n";

    $html .= $class->build_device_table_html($rows_ref);

    # Change-report section: a link to the full report (if written and a
    # web_report_url is set), then up to email_max_diff device diffs
    # (device-table order), then a truncation/masking note. email_max_diff=0
    # shows no diffs. Uses the material stashed by send_summaries.
    if (defined($rep_email_diffs)) {
	my $ff = $FONT_FAMILY;
	if (defined($rep_url)) {
	    my $u = escape_html($rep_url);
	    # A call-to-action button (same style as the fetchconfig-web
	    # mails), then a plain "copy this link" fallback for clients that
	    # don't render the button.
	    $html .= qq{<p style="margin:20px 0 20px;">}
		   . qq{<a href="$u" style="display:inline-block;background:$MAIL_HEADER_BG;color:#ffffff;text-decoration:none;padding:11px 22px;border-radius:6px;font-weight:600;font-family:$ff;">View the full report</a>}
		   . qq{</p>\n};
	    $html .= qq{<p style="font-family:$ff;margin:0 0 16px;font-size:13px;color:#57606a;">If the button does not work, copy this link into your browser:<br>}
		   . qq{<a href="$u" style="color:$MAIL_HEADER_BG;word-break:break-all;">$u</a></p>\n};
	}
	if ($rep_max_diff > 0 && @$rep_email_diffs) {
	    require fetchconfig::Report;
	    foreach my $d (@$rep_email_diffs) {
		my ($dev_id, $state, $lines) = @$d;
		$html .= qq{<h3 style="font-family: $ff; margin-top: 16px;">} . escape_html($dev_id) . qq{</h3>\n};
		$html .= qq{<pre style="font-family: monospace; font-size: 12px; background: #10171c; color: #dce8ec; padding: 10px; overflow-x: auto;">};
		foreach my $raw (@$lines) {
		    my $line = $rep_mask ? fetchconfig::Report::mask_line($raw) : $raw;
		    my $color = '';
		    $color = qq{ style="color:#ff6b6b"} if $line =~ /^</;
		    $color = qq{ style="color:#51d88a"} if $line =~ /^>/;
		    $html .= qq{<span$color>} . escape_html($line) . qq{</span>\n};
		}
		$html .= qq{</pre>\n};
	    }
	}
	my $shown = ($rep_max_diff > 0) ? scalar(@$rep_email_diffs) : 0;
	if ($rep_max_diff == 0) {
	    $html .= qq{<p style="font-family: $ff; font-size: 11px; color: #888;">Config diffs are not included in this e-mail (email_max_diff=0).}
		   . (defined($rep_url) ? qq{ See the full report above.} : qq{ View changes in the web UI.}) . qq{</p>\n};
	} elsif ($rep_n_changed > $shown) {
	    my $more = $rep_n_changed - $shown;
	    my $msg = qq{Only the first $shown of $rep_n_changed changed device(s) are shown here ($more more).}
		    . (defined($rep_url) ? qq{ See the full report above for all changes.} : qq{ View all changes in the web UI.});
	    $msg .= qq{ Secret values are masked (best effort).} if $rep_mask;
	    $html .= qq{<p style="font-family: $ff; font-size: 11px; color: #888;">} . $msg . qq{</p>\n};
	} elsif ($rep_mask && $shown > 0) {
	    $html .= qq{<p style="font-family: $ff; font-size: 11px; color: #888;">Secret values are masked (best effort).</p>\n};
	}
    }

    # Footer copyright text is configurable via "email: footer=..."; the
    # " - Version <n>" that follows is fixed. Default names the project's
    # authors. (Note: email-line options are comma-split, so a footer
    # value must not contain a comma.)
    my $footer = $email_config{footer};
    $footer = '(c) 2006-2026 Everton da Silva Marques, Rainer Tammer and others'
	unless defined($footer);

    # Close the card body cell and the card table, then put the copyright
    # OUTSIDE/below the card, centered on the grey canvas (muted, small) -
    # the same placement as the fetchconfig-web mail.
    $html .= "</td></tr>\n</table>\n";
    $html .= qq{<table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="max-width:820px;"><tr>}
	. qq{<td style="padding:14px 8px 0;text-align:center;font-family:$ff;font-size:12px;color:$MAIL_FOOTER_FG;">}
	. escape_html($footer) . ' - Version ' . $ver
	. qq{</td></tr></table>\n};
    $html .= "</td></tr></table>\n";

    $html .= "</body></html>\n";

    $html;
}

#
# Sends one e-mail: $to_line may hold one or more ';'-separated
# addresses. Every failure is logged and non-fatal to the caller (a
# mail problem must never abort the backup run itself).
#
sub send_mail {
    my ($class, $to_line, $subject, $html_body, $text_body) = @_;

    my $host = $email_config{smtp};

    # A port given as part of the host ("smtp=mail.acme.com:587") is
    # honoured, but an explicit "port=" option wins; the default is
    # chosen below once the TLS mode is known (25 for off/starttls,
    # 465 for ssl).
    my $port_from_host;
    if ($host =~ /^([^:]+):(\d+)$/) {
	$host = $1;
	$port_from_host = $2;
    }

    my @rcpt_list = grep { length($_) } map { trim($_) } split /;/, $to_line;

    if (@rcpt_list < 1) {
	$log->error("fetchconfig::Mailer: no valid recipient in '" . mask_password($to_line) . "' - skipping mail");
	return;
    }

    # TLS: "email: tls=off|starttls|ssl" (default off = plain SMTP, the
    # historical behaviour). "ssl" opens a TLS connection from the start
    # (typically port 465); "starttls" connects in clear and upgrades
    # with STARTTLS (typically 25/587). Both need IO::Socket::SSL (which
    # needs Net::SSLeay); plain SMTP needs neither. If TLS is requested
    # but the module is missing, or the upgrade fails, the mail is NOT
    # sent - we never fall back to plaintext, since that would silently
    # defeat the point of enabling TLS.
    my $tls = lc(defined($email_config{tls}) ? $email_config{tls} : 'off');
    if ($tls !~ /^(off|starttls|ssl)$/) {
	$log->error("fetchconfig::Mailer: bad tls option '$tls' (use off, starttls or ssl) - skipping mail");
	return;
    }

    # Port: "email: port=N" (explicit) > "smtp=host:N" > TLS-aware default.
    # Works with every tls setting; the default just follows the
    # convention for each mode (25 plain / STARTTLS, 465 implicit TLS),
    # so "tls=ssl" works without also typing port=465.
    my $port = $email_config{port};
    $port = $port_from_host unless defined($port) && length($port);
    if (!defined($port) || !length($port)) {
	$port = ($tls eq 'ssl') ? 465 : 25;
    }
    if ($port !~ /^\d+$/ || $port < 1 || $port > 65535) {
	$log->error("fetchconfig::Mailer: bad port '$port' (must be 1-65535) - skipping mail");
	return;
    }

    my $want_tls = ($tls ne 'off');
    if ($want_tls) {
	if (!eval { require IO::Socket::SSL; 1 }) {
	    $log->error("fetchconfig::Mailer: tls=$tls requested but IO::Socket::SSL is not installed - skipping mail (not falling back to plaintext)");
	    return;
	}
    }

    my $smtp = Net::SMTP->new($host,
			      Port    => $port,
			      Timeout => 30,
			      Hello   => 'fetchconfig',
			      ($tls eq 'ssl' ? (SSL => 1) : ()));

    if (!defined($smtp)) {
	$log->error("fetchconfig::Mailer: could not connect to SMTP server $host:$port" . ($tls eq 'ssl' ? ' (SSL)' : '') . ": $!");
	return;
    }

    if ($tls eq 'starttls') {
	if (!$smtp->starttls()) {
	    $log->error("fetchconfig::Mailer: STARTTLS to $host:$port failed - skipping mail (not falling back to plaintext): " . ($smtp->message || (do { no warnings 'once'; $IO::Socket::SSL::SSL_ERROR }) || ''));
	    $smtp->quit;
	    return;
	}
    }

    my $user     = $email_config{user};
    my $password = $email_config{password};

    if (defined($user) && length($user)) {
	$smtp->command('AUTH', 'LOGIN');
	$smtp->response();
	if ($smtp->code != 334) {
	    $log->error("fetchconfig::Mailer: SMTP server $host:$port did not accept AUTH LOGIN (code=" . $smtp->code . ")");
	    $smtp->quit;
	    return;
	}

	$smtp->command(encode_base64($user, ''));
	$smtp->response();

	$smtp->command(encode_base64(defined($password) ? $password : '', ''));
	$smtp->response();

	if ($smtp->code != 235) {
	    $log->error("fetchconfig::Mailer: SMTP authentication to $host:$port failed (code=" . $smtp->code . ")");
	    $smtp->quit;
	    return;
	}
    }

    my $from = $email_config{from};

    # Header injection guard: a value carrying "\r" or "\n" (the device
    # table is operator-controlled, but fetchconfig-web writes it from
    # user input) could otherwise smuggle extra headers into the message.
    # Strip line breaks from every field that goes into a header. The
    # recipients also go into the SMTP envelope, so clean them too.
    my $hdr_clean = sub { my ($v) = @_; $v = '' unless defined($v); $v =~ s/[\r\n]+/ /g; $v };
    $from      = $hdr_clean->($from);
    $subject   = $hdr_clean->($subject);
    @rcpt_list = map { $hdr_clean->($_) } @rcpt_list;

    if (!$smtp->mail($from)) {
	$log->error("fetchconfig::Mailer: SMTP server $host:$port rejected MAIL FROM=<$from>");
	$smtp->quit;
	return;
    }

    if (!$smtp->to(@rcpt_list)) {
	$log->error("fetchconfig::Mailer: SMTP server $host:$port rejected RCPT TO=<" . join('>,<', @rcpt_list) . ">");
	$smtp->quit;
	return;
    }

    $smtp->data;
    # MIME requires CRLF line endings in headers and at boundaries. Bare
    # "\n" breaks multipart parsing in many clients, which is why an inline
    # cid: image then fails to display. Use "\r\n" throughout, matching the
    # (known-good) fetchconfig-web mailer.
    $smtp->datasend("From: $from\r\n");
    $smtp->datasend("To: " . join(', ', @rcpt_list) . "\r\n");
    $smtp->datasend("Subject: $subject\r\n");
    $smtp->datasend("MIME-Version: 1.0\r\n");

    # The HTML references the header logo as src="cid:fcwlogo". Send
    # multipart/related wrapping a multipart/alternative (a short text/plain
    # fallback + the HTML), plus the logo as a Content-ID image, so the logo
    # renders inline. Same structure as fetchconfig-web. Fall back to a
    # single text/html part only if the logo is somehow empty.
    if (defined($MAIL_LOGO_B64) && length($MAIL_LOGO_B64)) {
	# 12 random bytes -> 24 hex chars, matching the fetchconfig-web mailer.
	my $rand12 = sub {
	    my $b = '';
	    if (open(my $rf, '<:raw', '/dev/urandom')) {
		while (length($b) < 12) { my $g = read($rf, my $c, 12 - length $b); last if !$g; $b .= $c; }
		close $rf;
	    }
	    # fall back to a time/rand mix if /dev/urandom is unavailable
	    $b .= pack('N', int(rand(0xffffffff))) while length($b) < 12;
	    return unpack('H*', substr($b, 0, 12));
	};
	my $rb = 'fcwR-' . $rand12->();
	my $ab = 'fcwA-' . $rand12->();

	# Plain-text alternative. Includes the report link, so a text-only
	# client still gets it.
	# Prefer the caller's plain-text summary (the stats + device tables);
	# fall back to a short notice (e.g. for the report-write-failure mail,
	# which passes no text body). Normalise bare LF to CRLF for the wire.
	my $text;
	if (defined($text_body) && length($text_body)) {
	    ($text = $text_body) =~ s/\r?\n/\r\n/g;
	}
	else {
	    $text = "fetchconfig backup summary.\r\n\r\n"
	          . "Please view this message in an HTML-capable mail client.\r\n";
	    if (defined($rep_url)) {
		$text .= "\r\nFull report:\r\n$rep_url\r\n";
	    }
	}

	# multipart/related wrapping a multipart/alternative (text + HTML)
	# plus the logo as a CID-referenced image. This is copied verbatim
	# (bar variable names) from the fetchconfig-web mailer, which renders
	# the inline image correctly - do not "tidy" the spacing: the exact
	# datasend sequence is what makes clients associate cid:fcwlogo.
	# Fold the "boundary=" onto a continuation line, exactly as the
	# received fetchconfig-web mail does. The multipart Content-Type must
	# fold here: an unfolded long Content-Type with the boundary inline is
	# what made the inline logo fail to associate in the mail client.
	$smtp->datasend(qq{Content-Type: multipart/related;\r\n\tboundary="$rb"\r\n});
	$smtp->datasend("\r\n");
	# 1) the alternative (text + html)
	$smtp->datasend("--$rb\r\n");
	$smtp->datasend(qq{Content-Type: multipart/alternative;\r\n\tboundary="$ab"\r\n\r\n});
	$smtp->datasend("--$ab\r\n");
	$smtp->datasend("Content-Type: text/plain; charset=UTF-8\r\n");
	$smtp->datasend("Content-Transfer-Encoding: 8bit\r\n\r\n");
	$smtp->datasend($text . "\r\n");
	$smtp->datasend("--$ab\r\n");
	$smtp->datasend("Content-Type: text/html; charset=UTF-8\r\n");
	$smtp->datasend("Content-Transfer-Encoding: 8bit\r\n\r\n");
	$smtp->datasend($html_body . "\r\n");
	$smtp->datasend("--$ab--\r\n");
	# 2) the inline logo (base64 PNG, Content-ID matches cid:fcwlogo)
	$smtp->datasend("--$rb\r\n");
	$smtp->datasend("Content-Type: image/png\r\n");
	$smtp->datasend("Content-Transfer-Encoding: base64\r\n");
	$smtp->datasend("Content-ID: <fcwlogo>\r\n");
	$smtp->datasend("Content-Disposition: inline; filename=\"logo.png\"\r\n\r\n");
	(my $b64 = $MAIL_LOGO_B64) =~ s/\s+//g;
	$b64 =~ s/(.{1,76})/$1\r\n/g;
	$smtp->datasend($b64);
	$smtp->datasend("--$rb--\r\n");
    } else {
	$smtp->datasend("Content-Type: text/html; charset=UTF-8\r\n");
	$smtp->datasend("Content-Transfer-Encoding: 8bit\r\n");
	$smtp->datasend("\r\n");
	$smtp->datasend($html_body);
    }

    if (!$smtp->dataend) {
	$log->error("fetchconfig::Mailer: SMTP server $host:$port did not accept mail body for <" . join('>,<', @rcpt_list) . ">");
	$smtp->quit;
	return;
    }

    $smtp->quit;

    $log->info("fetchconfig::Mailer: sent backup summary (" . scalar(@rcpt_list) . " recipient(s)): " . join(', ', @rcpt_list));
}

#
# Builds and sends the end-of-run summary e-mail(s). No-op (no SMTP
# connection at all) unless an "email:" line was parsed and no
# devices were recorded via record_result().
#
# --- change report (HTML + e-mail diffs) --------------------------------
#
# build_report_text - a plain-text version of the summary for the text/plain
# MIME part: the statistics block and the per-device table, in the same row
# order and with the same state/changed values as the HTML. No diffs (the
# report link covers detail). Columns are auto-sized to the data. $rep_url,
# when set, is appended as the full-report link.
sub build_report_text {
    my ($class, $rows_ref, $heading) = @_;

    my $out = "fetchconfig backup summary - " . iso_date(time) . "\r\n";
    $out .= "$heading\r\n" if defined($heading) && length($heading);

    # Statistics: state buckets (success/failed/skipped, skipped only if it
    # occurred) and changed buckets, matching build_stats_table_html.
    my (%state_count, %changed_count);
    for my $row (@$rows_ref) {
	$state_count{row_state($row)}++;
	$changed_count{defined($row->{changed}) ? $row->{changed} : 'n/a'}++;
    }
    $out .= "\r\nStatistics:\r\n";
    for my $k ('success', 'failed', 'skipped') {
	next if $k eq 'skipped' && !$state_count{$k};
	$out .= sprintf("  %-10s %d\r\n", $k, $state_count{$k} || 0);
    }
    for my $k ('changed', 'unchanged', 'initial', 'n/a') {
	next unless $changed_count{$k};
	$out .= sprintf("  %-10s %d\r\n", $k, $changed_count{$k});
    }

    # Per-device table, auto-sized columns.
    my @hdr = ('Device-ID', 'Date', 'Time', 'State', 'Size', 'Changes');
    my @w   = map { length } @hdr;
    my @data;
    for my $row (@$rows_ref) {
	my @d = (
	    $row->{dev_id},
	    iso_date($row->{ts}),
	    iso_time($row->{ts}),
	    row_state($row),
	    defined($row->{size}) ? $row->{size} : '-',
	    defined($row->{changed}) ? $row->{changed} : 'n/a',
	);
	for my $i (0 .. $#d) { $w[$i] = length($d[$i]) if length($d[$i]) > $w[$i]; }
	push @data, \@d;
    }
    my $fmt = join('  ', map { "%-${_}s" } @w) . "\r\n";
    $out .= "\r\nDevices:\r\n";
    $out .= sprintf($fmt, @hdr);
    $out .= sprintf($fmt, @$_) for @data;

    if (defined($rep_url)) {
	$out .= "\r\nFull report:\r\n$rep_url\r\n";
    }
    return $out;
}

# Map a @results row to a report state string.
sub _report_state {
    my ($row) = @_;
    return 'Skipped' if defined($row->{state}) && $row->{state} eq 'skipped';
    return 'Failed' unless $row->{success};
    my $ch = $row->{changed};
    # The run records 'initial' for a first-ever backup (no previous config),
    # else 'changed'/'unchanged'/'n/a'. "initial" is a first backup, not a
    # real change. 'n/a' (changes_only=0) is resolved by the diff itself.
    return 'initial'   if defined($ch) && $ch eq 'initial';
    return 'Changed'   if defined($ch) && $ch eq 'changed';
    return 'Unchanged' if defined($ch) && $ch eq 'unchanged';
    return 'Changed'   if defined($ch) && $ch eq 'n/a';   # changes_only=0: must diff to know
    return 'Unchanged';
}

# Build the report rows (device-table order is @results order) and, for the
# devices whose diff is needed, attach it. $need_diff is a coderef deciding
# per row whether to compute the diff body now (email top-N or full report).
sub _build_report_rows {
    my ($class, $results, $mask, $want_full) = @_;
    require fetchconfig::Report;
    my @rows;
    my $email_diff_budget = $want_full->{email_max_diff};
    my $email_diffs_done = 0;
    my @email_diffs;   # [dev_id, state, diff_lines] for the first N changed
    foreach my $r (@$results) {
        my $state = _report_state($r);
        my $diff;
        my $is_new = 0;
        if ($state eq 'Changed') {
            my ($lines, $ok, $count) = fetchconfig::Report::device_diff($r->{dev_id});
            if (!$ok && $count < 2) {
                # fewer than two backups -> no previous config -> New
                $state = 'initial';
            }
            elsif (!$ok) {
                # two or more backups but the diff could not be produced
                $state = 'diff-unavailable'; $diff = $lines;
            }
            elsif (!@$lines) {
                # changes_only=0 and identical consecutive saves -> Unchanged
                $state = 'Unchanged';
            }
            else {
                $diff = $lines;
                if (defined($email_diff_budget) && $email_diffs_done < $email_diff_budget) {
                    push @email_diffs, [ $r->{dev_id}, $state, $lines ];
                    $email_diffs_done++;
                }
            }
        }
        push @rows, {
            dev_id  => $r->{dev_id},
            host    => $r->{dev_host},
            state   => $state,
            ts      => (defined $r->{ts} ? iso_date($r->{ts}) : ''),
            size    => $r->{size},
            # Count change HUNKS (diff's NcM / NaM / NdM headers) - i.e. the
            # number of places that differ - not the <>/line count, which
            # double-counts a changed line (one "<" old + one ">" new).
            changes => ($diff ? scalar(grep { /^\d+[acd]\d+/ } @$diff) : ''),
            diff    => ($want_full->{full} ? $diff : undef),
        };
    }
    return (\@rows, \@email_diffs, $email_diffs_done);
}

sub report_hide_patterns { return @report_hide; }

# Resolve the report_dir option (may be a directory: $TAG) to a real path,
# or undef if not set / disabled.
sub _resolve_report_dir {
    my $rd = $email_config{report_dir};
    return undef unless defined($rd) && length($rd);
    my ($ok, $resolved) = fetchconfig::model::Detector->resolve_allowed_dir('report', $rd);
    if (!$ok) {
        $log->error("fetchconfig::Mailer: report_dir not allowed: $resolved");
        return undef;
    }
    return $resolved;
}

# Write the standalone HTML report to report_dir, return the path or undef.
sub _write_report_file {
    my ($class, $rows, $mask, $report_dir) = @_;
    return undef unless defined $report_dir;
    if (! -d $report_dir) {
        $log->error("fetchconfig::Mailer: report_dir does not exist: $report_dir");
        return undef;
    }
    require fetchconfig::Report;
    my @t = localtime(time);
    my $stamp = sprintf("%04d%02d%02d-%02d%02d%02d",
                        $t[5]+1900,$t[4]+1,$t[3],$t[2],$t[1],$t[0]);
    my $file = "$report_dir/report-$stamp.html";
    my $logo;
    if (defined($email_config{report_logo}) && $email_config{report_logo} ne ''
            && lc($email_config{report_logo}) ne 'none') {
        $logo = "$report_dir/" . $email_config{report_logo};
    }
    my $html = fetchconfig::Report::build_html($rows,
        title => 'fetchconfig change report - ' . iso_date(time),
        mask  => $mask, logo_path => $logo, generated => scalar localtime);
    if (open(my $fh, '>', $file)) {
        print $fh $html; close $fh;
        $log->info("fetchconfig::Mailer: wrote change report $file");
        return $file;
    }
    $log->error("fetchconfig::Mailer: cannot write change report $file: $!");
    return undef;
}

# Prune reports older than report_days (only if > 1). Exact-name unlink only.
sub _prune_reports {
    my ($class, $report_dir) = @_;
    my $days = $email_config{report_days};
    return unless defined($days) && $days =~ /^\d+$/ && $days > 1;
    return unless defined($report_dir) && -d $report_dir;
    my $cutoff = time - $days * 86400;
    local *D; return unless opendir(D, $report_dir);
    my @files = readdir(D); closedir(D);
    foreach my $f (@files) {
        next unless $f =~ /^report-\d{8}-\d{6}\.html$/;   # our exact naming
        my $path = "$report_dir/$f";
        my @st = stat($path); next unless @st;
        next if $st[9] >= $cutoff;
        if (unlink($path)) { $log->info("fetchconfig::Mailer: pruned old report $path"); }
        else { $log->error("fetchconfig::Mailer: could not prune $path: $!"); }
    }
}

sub send_summaries {
    my ($class, $logger) = @_;

    $log = $logger if defined($logger);

    return unless $email_seen; # no "email:" configured at all - stay silent

    $log->info('-----[email]--------------------------------------------------------------------------------');

    if (@results < 1) {
	$log->debug("fetchconfig::Mailer: no devices processed - skipping backup summary email");
	return;
    }

    # change report (HTML file) + e-mail diffs
    my $mask = !(defined($email_config{mask_secrets})
                 && lc($email_config{mask_secrets}) eq 'off');
    # report_hide custom patterns are governed by the mask_secrets master:
    # when masking is off, no custom patterns are applied either.
    require fetchconfig::Report;
    fetchconfig::Report::set_custom_hide($mask ? @report_hide : ());
    my $write_report = defined($email_config{write_report})
                       && lc($email_config{write_report}) eq 'on';
    my $email_max_diff = $email_config{email_max_diff};
    $email_max_diff = 0 unless defined($email_max_diff) && $email_max_diff =~ /^\d+$/;   # default 0: no diffs unless asked
    my $report_dir = $class->_resolve_report_dir;

    my ($report_rows, $email_diffs, $n_changed) = $class->_build_report_rows(
        \@results, $mask,
        { email_max_diff => $email_max_diff, full => $write_report });

    my $report_file; my $report_write_failed = 0;
    if ($write_report) {
        $report_file = $class->_write_report_file($report_rows, $mask, $report_dir);
        $report_write_failed = 1 if !defined($report_file);
        $class->_prune_reports($report_dir);
    }

    my $from      = $email_config{from};
    my $to        = $email_config{to};
    my $smtp_host = $email_config{smtp};

    if (!defined($from) || !defined($to) || !defined($smtp_host)) {
	if ($write_report) {
	    $log->debug("fetchconfig::Mailer: report-only mode (no from=/to=/smtp=) - report written, no e-mail");
	} else {
	    $log->error("fetchconfig::Mailer: email: configuration incomplete (from=/to=/smtp= are mandatory) - skipping backup summary email");
	}
	return;
    }

    # carry e-mail diff material into build_report_html
    $rep_email_diffs = $email_diffs;
    $rep_n_changed   = $n_changed;
    $rep_max_diff    = $email_max_diff;
    # Build the "Full report" link, but only when a report file was actually
    # written AND web_report_url is set. web_report_url is the BASE URL of
    # fetchconfig-web (e.g. https://host/cgi-bin/fetchconfig-web.cgi); we
    # append the query that points at this specific report
    # (action=view_report&file=<basename>). Any query string already present
    # on the configured value is dropped, so a legacy setting that still
    # carries "?action=report" keeps working.
    if (defined($report_file) && defined($email_config{web_report_url})) {
	require File::Basename;
	(my $base = $email_config{web_report_url}) =~ s/\?.*//;
	my $rf = _url_encode(File::Basename::basename($report_file));
	$rep_url = $base . "?action=view_report&file=" . $rf;
    } else {
	$rep_url = undef;
    }
    $rep_mask = $mask;

    my @global_rows = sort { $a->{dev_id} cmp $b->{dev_id} } @results;

    $class->send_mail($to,
		       'fetchconfig backup summary - ' . iso_date(time),
		       $class->build_report_html(\@global_rows, 'Status of all backups'),
		       $class->build_report_text(\@global_rows, 'Status of all backups'));

    # If the report file was requested but could not be written, tell the
    # user with a separate error e-mail (best effort; also logged above).
    if ($report_write_failed) {
	$class->send_mail($to,
			   'fetchconfig: change report could NOT be written - ' . iso_date(time),
			   '<html><body style="font-family: ' . $FONT_FAMILY . ';"><p>'
			   . 'The backup run completed and this summary was sent, but the HTML '
			   . 'change report could not be written to the configured report_dir. '
			   . 'See the fetchconfig log for the reason.</p></body></html>');
    }

    # Group devices whose recipient was overridden per-device; each
    # distinct override recipient gets its own mail with only its
    # own devices. Skip an override that's identical to the global
    # recipient: that address already received the full report above.
    my %override_groups;

    foreach my $row (@results) {
	my $override_to = $row->{to};

	next unless defined($override_to) && length(trim($override_to));
	next if lc(trim($override_to)) eq lc(trim($to));

	push @{$override_groups{$override_to}}, $row;
    }

    foreach my $override_to (sort keys %override_groups) {
	my @rows = sort { $a->{dev_id} cmp $b->{dev_id} } @{$override_groups{$override_to}};

	$class->send_mail($override_to,
			   'fetchconfig backup summary (your devices) - ' . iso_date(time),
			   $class->build_report_html(\@rows, 'Status of your backups'),
			   $class->build_report_text(\@rows, 'Status of your backups'));
    }
}

1;

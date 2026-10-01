#
# fetchconfig::Report - change-report generation (HTML report + e-mail diffs).
#
# A report is built once, after a run (and after the parallel-fetch join), from
# data the run already produced: each device's state (New / Changed / Unchanged
# / Failed / diff-unavailable / worker-failed) and, for changed devices, the
# unified diff between the two most recent backups (-n 1 -m 2).
#
# Diffs are produced ONLY where they are shown: the first email_max_diff changed
# devices (device-table order) in the e-mail, and every changed device in the
# full HTML report. Detection of "changed" does not require a diff (it comes
# from the run's save decision); the diff is run only to render the body.
#
# Secret masking (best effort): mask_secrets masks a small set of high-value,
# common secret forms AFTER diffing, on both old ("<") and new (">") lines, so
# a rotated secret still shows as a changed line (**** -> ****) without
# revealing either value. This is NOT comprehensive and is vendor-incomplete -
# reports and report e-mails must still be treated as sensitive.
#
package fetchconfig::Report;

use strict;
use warnings;
use MIME::Base64 ();

my $logger;

sub init {
    my ($class, $log) = @_;
    $logger = $log;
}

# --- secret masking (best effort) ---------------------------------------
#
# Applied to a single diff line (already including its leading "< " / "> "
# from diff, or a bare config line). Masks the VALUE, keeping the keyword so
# the change is still visible as "<keyword> ****".
#
# Covered (common forms): Cisco type-5/7/8/9 password & enable secret hashes,
# SNMP community (Cisco bare and ProCurve quoted), key-string / pre-shared-key
# / wpa-psk / wpa-passphrase, a bare "key <hex>", the Hirschmann
# "passwd <user> :vN:<hash>:" form (username kept, hash masked), and the
# generic "password <x>" / "passwd <x>". Deliberately conservative.
# Custom report_hide patterns, set once per run by the Mailer. Each is a
# raw regex string; only the substring it matches is replaced with ****.
# Compiled lazily and eval-guarded so a bad pattern is skipped (warned once),
# never crashing the run.
my @custom_hide;
my %custom_hide_bad;
sub set_custom_hide {
    my (@patterns) = @_;
    @custom_hide = ();
    %custom_hide_bad = ();
    for my $p (@patterns) {
        my $re = eval { qr/$p/ };
        if (defined $re) { push @custom_hide, $re; }
        elsif (!$custom_hide_bad{$p}) {
            $custom_hide_bad{$p} = 1;
            $logger->error("report_hide: ignoring invalid regex: $p") if $logger;
        }
    }
}

sub mask_line {
    my ($line) = @_;
    return $line unless defined $line;

    # enable secret / password with an algorithm tag and a hash
    $line =~ s/((?:enable\s+)?(?:secret|password)\s+\d+\s+)\S+/$1****/ig;
    # Cisco "password 7 <hex>" already covered above; bare "password <x>"
    $line =~ s/(\bpassw(?:or)?d\s+)(?!\d+\s)(?!\S+\s+:v\d+:)\S+/$1****/ig;
    # Hirschmann "users passwd <user> :vN:<hash>:" - the word after passwd is
    # the USERNAME (kept, by the lookahead above); the secret is the hash in
    # the :vN:...: token, masked here.
    $line =~ s/(:v\d+:)[0-9a-fA-F]+(:)/$1****$2/g;
    # SNMP community - Cisco bare and ProCurve quoted
    $line =~ s/(\bsnmp-server\s+community\s+)("[^"]*"|\S+)/$1****/ig;
    $line =~ s/(\bcommunity\s+)("[^"]*"|\S+)/$1****/ig;
    # keys and pre-shared secrets
    $line =~ s/(\b(?:key-string|pre-shared-key|wpa-psk|wpa-passphrase|key\s+\d+)\s+)("[^"]*"|\S+)/$1****/ig;
    # a bare "key <value>" where the value is a long hex string or quoted -
    # anchored to the hash/quoted forms so it does not clobber key-string,
    # key chain, key-id, or a short "key <N>" index (handled just above).
    $line =~ s/(\bkey\s+)([0-9a-fA-F]{16,}|"[^"]*")/$1****/g;
    # Juniper-style "$9$..." secrets
    $line =~ s/(\bsecret\s+)"\$\d\$[^"]*"/$1"****"/ig;

    # custom report_hide patterns (after the built-ins): replace only the
    # substring each regex matches, so the user can keep surrounding keywords
    # by matching just the value.
    for my $re (@custom_hide) {
        $line =~ s/$re/****/g;
    }

    return $line;
}

# --- safe diff (never exits) --------------------------------------------
#
# Return the unified-style diff lines between backup N-1 (older, -m 2) and
# N (newer, -n 1) for a device, as a list. On any problem (missing N-1,
# unreadable, diff failure) return a single sentinel line so the caller can
# render "diff unavailable - check" rather than aborting the run.
#   returns (\@lines, $ok, $count)
#     $count = number of backups on file (0 if none/unknown)
#     $ok    = 1 diff produced, 0 no diff
#   The caller uses $count to tell a NEW device (count < 2, no N-1, not an
#   error) from a real diff failure (count >= 2 but unreadable). We read the
#   backup list once with scan_backups (which does NOT log an error for a
#   device with only one backup), so a new device never produces a spurious
#   "requested backup 2 but only 1 available" error line.
sub device_diff {
    my ($dev_id) = @_;
    my ($files_ref) = fetchconfig::Tools::scan_backups($dev_id);
    my $count = (defined($files_ref)) ? scalar(@$files_ref) : 0;
    if ($count < 2) {
        # no previous backup to diff against - not an error here
        return ([], 0, $count);
    }
    my ($path_n) = fetchconfig::Tools::locate_backup($dev_id, 1);
    my ($path_m) = fetchconfig::Tools::locate_backup($dev_id, 2);
    if (!defined($path_n) || !defined($path_m)) {
        return ([ 'diff unavailable - check' ], 0, $count);
    }
    local *DIFF;
    my $pid = open(DIFF, '-|');
    if (!defined($pid)) {
        $logger->error("dev=$dev_id: could not fork to run diff: $!") if $logger;
        return ([ 'diff unavailable - check' ], 0);
    }
    if ($pid == 0) {
        open(STDERR, '>', '/dev/null');
        exec('diff', $path_m, $path_n);
        exit 127;    # exec failed
    }
    my @lines = <DIFF>;
    close(DIFF);
    chomp @lines;
    return (\@lines, 1, $count);
}

# --- HTML escaping -------------------------------------------------------
sub _esc {
    my ($s) = @_;
    return '' unless defined $s;
    $s =~ s/&/&amp;/g; $s =~ s/</&lt;/g; $s =~ s/>/&gt;/g; $s =~ s/"/&quot;/g;
    return $s;
}

# a dotted device id is fine in data-device; an HTML id must be token-safe
sub _anchor_id {
    my ($dev_id) = @_;
    (my $a = $dev_id) =~ s/[^A-Za-z0-9_-]/_/g;
    return "dev-$a";
}

# --- render one diff as coloured HTML -----------------------------------
#
# $diff_lines: arrayref of raw diff lines. $mask: apply masking.
# Produces <div class="device-diff" data-device="ID" id="dev-ID"> ... with
# red (old "<") / green (new ">") lines. This div/structure is a STABLE,
# ARMORED contract for external post-processing (fetchconfig-web).
sub diff_block_html {
    my ($dev_id, $state, $diff_lines, $mask) = @_;
    my $aid = _anchor_id($dev_id);
    my $out = qq{      <div class="device-diff" data-device="} . _esc($dev_id)
            . qq{" data-state="} . _esc($state) . qq{" id="$aid">\n};
    $out .= qq{        <h3>} . _esc($dev_id) . qq{ <span class="state state-}
          . _esc(lc $state) . qq{">} . _esc($state) . qq{</span></h3>\n};
    if ($state eq 'initial' || $state eq 'New') {
        $out .= qq{        <p class="prose-muted">Initial configuration backup.</p>\n};
    }
    elsif ($diff_lines && @$diff_lines) {
        $out .= qq{        <pre class="diff">};
        for my $raw (@$diff_lines) {
            my $line = $mask ? mask_line($raw) : $raw;
            my $cls = '';
            $cls = 'd-old' if $line =~ /^</;
            $cls = 'd-new' if $line =~ /^>/;
            $cls = 'd-hunk' if $line =~ /^[0-9]/ || $line =~ /^---$/;
            my $e = _esc($line);
            $out .= $cls ? qq{<span class="$cls">$e</span>\n} : "$e\n";
        }
        $out .= qq{</pre>\n};
    }
    $out .= qq{      </div>\n};
    return $out;
}

# --- embed the logo as a data: URI (self-contained) ---------------------
#
# $path is report_dir/report_logo. Returns an <img ...> tag, or '' on any
# problem (missing, unreadable) - a missing logo never aborts the report.
# Recommended logo size is 250x50 px.
sub _logo_img {
    my ($path) = @_;
    return '' unless defined($path) && length($path) && -f $path && -r $path;
    local *L; return '' unless open(L, '<', $path);
    binmode L; local $/; my $data = <L>; close L;
    return '' unless defined($data) && length($data);
    my $mime = 'image/png';
    $mime = 'image/jpeg' if $path =~ /\.jpe?g$/i;
    $mime = 'image/gif'  if $path =~ /\.gif$/i;
    $mime = 'image/svg+xml' if $path =~ /\.svg$/i;
    my $b64 = MIME::Base64::encode_base64($data, '');
    return qq{<img class="report-logo" alt="logo" src="data:$mime;base64,$b64">};
}

# minimal stylesheet matching the help design (tokens copied from the help).
sub _report_css {
    return <<'CSS';
  :root{
    --bg:#fbfbf9; --surface:#f1f4f4; --border:#dde3e3; --text:#141a1f;
    --text-muted:#5b6770; --accent:#0e7c8c; --danger:#c4432b; --success:#1c8a5b;
    --changed:#2451c4; --code-bg:#10171c; --code-text:#dce8ec; --radius:6px;
    --font-sans:'IBM Plex Sans',-apple-system,BlinkMacSystemFont,'Segoe UI',sans-serif;
    --font-mono:'IBM Plex Mono',ui-monospace,SFMono-Regular,Consolas,monospace;
    --sidebar-w:260px;
  }
  @media (prefers-color-scheme: dark){:root:not([data-theme="light"]){
    --bg:#0e1316; --surface:#161d22; --border:#273036; --text:#e7edf0;
    --text-muted:#9aa7ae;
  }}
  *{box-sizing:border-box;} html{scroll-behavior:smooth;}
  body{margin:0;font-family:var(--font-sans);background:var(--bg);color:var(--text);
    display:flex;min-height:100vh;}
  nav.side{width:var(--sidebar-w);flex:0 0 auto;background:var(--surface);
    border-right:1px solid var(--border);padding:1.2rem;position:sticky;top:0;
    height:100vh;overflow:auto;}
  nav.side a{display:block;color:var(--text-muted);text-decoration:none;
    font-family:var(--font-mono);font-size:.82rem;padding:.2rem 0;}
  nav.side a:hover{color:var(--accent);}
  main{flex:1 1 auto;padding:1.5rem 2rem;max-width:100%;overflow:auto;}
  header.report-head{display:flex;justify-content:space-between;align-items:flex-start;
    border-bottom:1px solid var(--border);padding-bottom:1rem;margin-bottom:1.2rem;}
  .report-logo{max-width:250px;max-height:50px;}
  h1{font-size:1.35rem;margin:0 0 .2rem;} h2{font-size:1.05rem;margin:1.6rem 0 .6rem;}
  h3{font-size:.95rem;font-family:var(--font-mono);margin:1.4rem 0 .4rem;}
  table.overview{border-collapse:collapse;width:100%;font-size:.85rem;margin:.5rem 0 1rem;}
  table.overview th,table.overview td{border:1px solid var(--border);padding:.35rem .6rem;text-align:left;}
  table.overview th{background:var(--surface);}
  .state{font-family:var(--font-mono);font-size:.72rem;padding:.1rem .4rem;border-radius:3px;}
  .state-new{color:#fff;background:var(--accent);}
  .state-changed{color:#fff;background:var(--changed);}
  .state-unchanged{color:var(--text-muted);border:1px solid var(--border);}
  .state-failed,.state-diff-unavailable,.state-worker-failed{color:#fff;background:var(--danger);}
  pre.diff{background:var(--code-bg);color:var(--code-text);padding:.9rem 1rem;
    border-radius:var(--radius);overflow-x:auto;font-family:var(--font-mono);
    font-size:.8rem;line-height:1.4;white-space:pre;}
  pre.diff .d-old{color:#ff6b6b;} pre.diff .d-new{color:#51d88a;}
  pre.diff .d-hunk{color:#7f929b;}
  .legend{font-size:.8rem;margin:.3rem 0 1rem;}
  .legend .sw{display:inline-block;width:.8rem;height:.8rem;vertical-align:middle;margin:0 .2rem 0 .8rem;border-radius:2px;}
  .prose-muted{color:var(--text-muted);}
  .note{background:var(--surface);border:1px solid var(--border);border-radius:var(--radius);
    padding:.6rem .9rem;font-size:.82rem;margin:1rem 0;}
CSS
}

# Build the full standalone HTML report.
#   $rows : arrayref of { dev_id, host, state, ts, size, changes, diff (arrayref|undef) }
#   %opt  : title, logo_path, mask, generated (timestamp string)
sub build_html {
    my ($rows, %opt) = @_;
    my $title = _esc($opt{title} || 'fetchconfig change report');
    my $mask  = $opt{mask};
    my $logo  = _logo_img($opt{logo_path});
    my $gen   = _esc($opt{generated} || scalar localtime);

    my $h = '';
    $h .= qq{<!DOCTYPE html>\n<html lang="en"><head>\n};
    $h .= qq{<meta charset="utf-8">\n};
    $h .= qq{<meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">\n};
    $h .= qq{<title>$title</title>\n<style>\n} . _report_css() . qq{</style>\n</head>\n<body>\n};

    # nav: a jump to each device
    $h .= qq{<nav class="side">\n  <strong>Devices</strong>\n};
    for my $r (@$rows) {
        my $aid = _anchor_id($r->{dev_id});
        $h .= qq{  <a href="#$aid">} . _esc($r->{dev_id}) . qq{</a>\n};
    }
    $h .= qq{</nav>\n<main>\n};

    # header + logo
    $h .= qq{<header class="report-head">\n  <div>\n    <h1>$title</h1>\n};
    $h .= qq{    <div class="prose-muted">Generated $gen</div>\n  </div>\n  <div>$logo</div>\n</header>\n};

    $h .= qq{<p class="legend">Diff colours: <span class="sw" style="background:#ff6b6b"></span>old }
        . qq{<span class="sw" style="background:#51d88a"></span>new</p>\n};
    if ($mask) {
        $h .= qq{<div class="note">Secret values are masked (best effort). Masking covers common }
            . qq{forms only and is vendor-incomplete &mdash; treat this report as sensitive.</div>\n};
    }

    # overview table
    $h .= qq{<h2>Overview</h2>\n<table class="overview">\n};
    $h .= qq{<tr><th>Device</th><th>Host</th><th>State</th><th>Time</th><th>Size</th><th>Changes</th><th></th></tr>\n};
    for my $r (@$rows) {
        my $aid = _anchor_id($r->{dev_id});
        my $st = _esc($r->{state});
        $h .= qq{<tr><td>} . _esc($r->{dev_id}) . qq{</td><td>} . _esc($r->{host}||'')
            . qq{</td><td><span class="state state-} . _esc(lc $r->{state}) . qq{">$st</span></td><td>}
            . _esc($r->{ts}||'') . qq{</td><td>} . _esc(defined $r->{size} ? $r->{size} : '')
            . qq{</td><td>} . _esc(defined $r->{changes} ? $r->{changes} : '')
            . qq{</td><td><a href="#$aid">view</a></td></tr>\n};
    }
    $h .= qq{</table>\n};

    # per-device diff blocks
    $h .= qq{<h2>Changes</h2>\n};
    for my $r (@$rows) {
        $h .= diff_block_html($r->{dev_id}, $r->{state}, $r->{diff}, $mask);
    }

    $h .= qq{</main>\n</body>\n</html>\n};
    return $h;
}

1;

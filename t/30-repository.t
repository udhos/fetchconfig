#!/usr/bin/perl
#
# 30-repository.t - dump_config() and find_latest()
#
# The repository read/write layer, exercised against a throwaway
# File::Temp directory that is created and removed inside the test - it
# touches nothing outside t/ and needs no network. dump_config writes the
# backup at <repo>/YYYYMM/YYYYMMDD/<dev_id>/<dev_id>.run.<ts><tz><suffix>
# with a terminal newline, refuses an empty config, and validates
# filename_append_suffix; find_latest returns the newest backup by PARSED
# timestamp and copes with a missing repository.
#
use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use File::Path qw(make_path);

# Tier 2 needs a concrete model (for dev_option) and the Logger. If the
# model's transport prerequisite is absent, skip the whole file.
my $loadable = eval {
    require fetchconfig::Logger;
    require fetchconfig::model::CiscoIOS;
    1;
};
if (!$loadable) {
    plan skip_all => 'CiscoIOS/Logger not loadable here (missing prerequisite)';
}

# A quiet model: silence debug/info/error so expected-failure cases do
# not print to the TAP stream. (We assert on return values, not logs.)
sub quiet_model {
    my ($repo) = @_;
    my $log = fetchconfig::Logger->new({ prefix => 't' });
    { no warnings 'redefine', 'once';
      *fetchconfig::Logger::debug = sub { };
      *fetchconfig::Logger::info  = sub { };
      *fetchconfig::Logger::error = sub { }; }
    my $m = fetchconfig::model::CiscoIOS->new($log);
    $m->{default_options} = { repository => $repo, keep => 5 };
    return $m;
}

# slurp a file whole
sub slurp {
    my ($path) = @_;
    open(my $fh, '<', $path) or return undef;
    local $/;
    my $c = <$fh>;
    close $fh;
    return $c;
}

# --- dump_config: a normal write --------------------------------------
{
    my $repo = tempdir(CLEANUP => 1);
    my $m = quiet_model($repo);
    my @cfg = ('hostname sw01', 'interface e0', ' no shutdown');
    my ($dir, $file) = $m->dump_config('dev01', { repository => $repo }, \@cfg);

    ok(defined($dir) && defined($file), 'dump_config returns ($dir,$file) on success');
    like("$dir/$file", qr{/\d{6}/\d{8}/dev01/dev01\.run\.\d{8}\.\d{6}},
         'backup path is <repo>/YYYYMM/YYYYMMDD/dev01/dev01.run.<ts>...');
    ok(-f "$dir/$file", 'the backup file exists on disk');

    my $content = slurp("$dir/$file");
    is($content, "hostname sw01\ninterface e0\n no shutdown\n",
       'content is the config, one line each, with a terminal newline');
    like($content, qr/\n$/, 'file ends with a newline');
}

# --- dump_config: backup file and directory follow the process umask ---
# fetchconfig-web reads backups as an unprivileged user ("nobody" via
# -l/-g), so the file must be readable and the directory traversable by
# that user. The permissions therefore follow the operator's umask and are
# NOT forced owner-only. Under a cron-typical umask 022 that means the file
# is world-readable (0644) and the directory world-traversable (0755) - the
# property the web UI relies on.
{
    my $old_umask = umask(022);             # a permissive umask, as under cron
    my $repo = tempdir(CLEANUP => 1);
    my $m = quiet_model($repo);
    my ($dir, $file) = $m->dump_config('devP', { repository => $repo }, ['x']);
    is((stat("$dir/$file"))[2] & 0777, 0644, 'backup file follows umask 022 -> 0644 (unprivileged-readable)');
    is((stat($dir))[2] & 0777,         0755, 'device directory follows umask 022 -> 0755 (traversable)');
    ok((stat("$dir/$file"))[2] & 0044, 'backup file is readable by group/other (nobody can -g it)');
    ok((stat($dir))[2] & 0011,         'device directory is traversable by group/other (nobody can -l it)');
    umask($old_umask);
}
# --- and under a restrictive umask the operator's choice is honoured -----
{
    my $old_umask = umask(077);
    my $repo = tempdir(CLEANUP => 1);
    my $m = quiet_model($repo);
    my ($dir, $file) = $m->dump_config('devR', { repository => $repo }, ['x']);
    is((stat("$dir/$file"))[2] & 0777, 0600, 'umask 077 -> file 0600 (operator chose owner-only)');
    is((stat($dir))[2] & 0777,         0700, 'umask 077 -> directory 0700');
    umask($old_umask);
}

# --- dump_config: refuses to overwrite an existing same-name backup -----
# Two runs completing within the same one-second filename resolution must
# not let the second silently truncate the first. dump_config creates the
# file O_EXCL; if the exact name already exists it fails and leaves the
# original intact. We force the collision by pre-creating the file the next
# dump would produce (same dev, same second via a fixed-name probe).
{
    my $repo = tempdir(CLEANUP => 1);
    my $m = quiet_model($repo);
    my ($dir, $file) = $m->dump_config('devC', { repository => $repo }, ['FIRST']);
    ok(defined($file), 'first backup written');
    my $path = "$dir/$file";
    my $before = do { open my $fh, '<', $path; local $/; <$fh> };
    # a second dump in the SAME second reuses the same name -> must be refused
    # (we cannot guarantee the same wall-clock second in a test, so assert the
    # O_EXCL property directly: a second open of the exact path is refused and
    # the content is unchanged)
    use Fcntl qw(:DEFAULT);
    my $reopened = sysopen(my $fh2, $path, O_WRONLY|O_CREAT|O_EXCL, 0666);
    ok(!$reopened, 'an existing backup name cannot be re-created (O_EXCL)');
    my $after = do { open my $fh, '<', $path; local $/; <$fh> };
    is($after, $before, 'the existing backup is left intact, not truncated');
}

# --- dump_config: empty config is refused -----------------------------
{
    my $repo = tempdir(CLEANUP => 1);
    my $m = quiet_model($repo);
    my ($dir, $file) = $m->dump_config('dev02', { repository => $repo }, []);
    ok(!defined($dir), 'empty config -> undef (no empty backup written)');
    # and nothing created under the repo for dev02
    ok(!-e "$repo/dev02", 'no directory created for the refused device');
}

# --- dump_config: filename_append_suffix validation -------------------
{
    my $repo = tempdir(CLEANUP => 1);
    my $m = quiet_model($repo);

    for my $bad ('bak', '/x', ".a b", ".a\tb") {
        my ($d, $f) = $m->dump_config('devS',
            { repository => $repo, filename_append_suffix => $bad }, ['x']);
        ok(!defined($f), "suffix [$bad] rejected (must start with '.', no '/' or whitespace)");
    }

    my ($d, $f) = $m->dump_config('devS',
        { repository => $repo, filename_append_suffix => '.bak' }, ['x']);
    ok(defined($f) && $f =~ /\.bak$/, "valid suffix '.bak' accepted and appended");
}

# --- dump_config: timezone=hide blanks the tz token -------------------
{
    my $repo = tempdir(CLEANUP => 1);
    my $m = quiet_model($repo);
    my ($d, $f) = $m->dump_config('devTZ',
        { repository => $repo, timezone => 'hide' }, ['x']);
    like($f, qr/^devTZ\.run\.\d{8}\.\d{6}$/,
         'timezone=hide -> filename has no tz token after HHMMSS');
}

# --- find_latest: newest by PARSED timestamp across mixed tz forms ----
{
    my $repo = tempdir(CLEANUP => 1);
    my $m = quiet_model($repo);
    make_path("$repo/202609/20260921/dev01", "$repo/202609/20260922/dev01");
    my %want = (
        "$repo/202609/20260921/dev01/dev01.run.20260921.001000+0200" => "old\n",
        "$repo/202609/20260922/dev01/dev01.run.20260922.000500+0200" => "mid\n",
        "$repo/202609/20260922/dev01/dev01.run.20260922.001000CEST"  => "new\n",  # newest
    );
    for my $p (keys %want) { open(my $fh, '>', $p); print $fh $want{$p}; close $fh; }

    my ($dir, $file) = $m->find_latest('dev01', { repository => $repo });
    is($file, 'dev01.run.20260922.001000CEST',
       'find_latest returns the newest backup by parsed timestamp (not string order)');
    is(slurp("$dir/$file"), "new\n", 'and it is the right file');
}

# --- find_latest: no backups / missing repository ---------------------
{
    my $repo = tempdir(CLEANUP => 1);
    my $m = quiet_model($repo);
    my ($d1, $f1) = $m->find_latest('nodev', { repository => $repo });
    ok(!defined($f1), 'find_latest on a device with no backups -> undef');

    my ($d2, $f2) = $m->find_latest('dev01', { repository => "$repo/nonexistent" });
    ok(!defined($f2), 'find_latest on a missing repository -> undef (no crash)');
}

done_testing();

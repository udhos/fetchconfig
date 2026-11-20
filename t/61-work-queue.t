#!/usr/bin/perl
#
# 61-work-queue.t - fetchconfig::Tools work-queue helpers used by -P parallel
# fetching. Several worker processes pull device ids from one shared pipe; a
# plain buffered <$fh> read would let one worker's stdio buffer slurp a chunk
# (starving the others) and split a line across two readers (a mangled id).
# dequeue() reads one whole line UNBUFFERED under an exclusive flock, so:
#   - read_one_line() returns exactly one line and leaves the rest in the pipe;
#   - a shared pipe drained by N worker processes yields every item exactly
#     once, intact (no loss, no duplicate, no split), which is what -P relies on.
#
use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);

require_ok('fetchconfig::Tools');

# --- read_one_line: one line per call, rest left in the pipe ------------------
{
    pipe(my $r, my $w) or die "pipe: $!";
    syswrite($w, "a\nbb\nccc\n");
    close $w;
    is(fetchconfig::Tools::read_one_line($r), 'a',   'first line');
    is(fetchconfig::Tools::read_one_line($r), 'bb',  'second line');
    is(fetchconfig::Tools::read_one_line($r), 'ccc', 'third line');
    is(fetchconfig::Tools::read_one_line($r), undef, 'undef at EOF');
    close $r;
}

# --- N worker processes drain one shared pipe: every item exactly once --------
SKIP: {
    skip "fork not available", 4 if $^O eq 'MSWin32';

    my $dir = tempdir(CLEANUP => 1);
    my $qlock = "$dir/.q.lock";
    { open(my $lf, '>', $qlock) or die "create $qlock: $!"; close $lf; }

    # Enough items that the total (~20 KB) exceeds a worker's stdio read buffer
    # (~8 KB): this is exactly where a buffered shared read would split a line or
    # let one worker hog a chunk. Each id is fixed-shape so a split is detectable.
    my $N = 2000;
    my @items = map { sprintf("dev%05d", $_) } 1 .. $N;

    pipe(my $work_r, my $work_w) or die "pipe: $!";

    my $WORKERS = 4;
    my @pids;
    for my $i (1 .. $WORKERS) {
        my $pid = fork();
        die "fork: $!" unless defined $pid;
        if ($pid == 0) {
            close $work_w;
            # each worker opens the lock itself (independent file description),
            # read-write so flock works where it is fcntl-emulated (AIX).
            open(my $qfh, '+<', $qlock) or die "open $qlock: $!";
            open(my $out, '>', "$dir/got.$i") or die "open got.$i: $!";
            while (defined(my $it = fetchconfig::Tools::dequeue($work_r, $qfh))) {
                print $out "$it\n";
            }
            close $out;
            exit 0;
        }
        push @pids, $pid;
    }
    close $work_r;

    # feed the queue, then close so idle workers see EOF
    print $work_w "$_\n" for @items;
    close $work_w;
    waitpid($_, 0) for @pids;

    # collect what every worker consumed
    my @got;
    for my $i (1 .. $WORKERS) {
        open(my $in, '<', "$dir/got.$i") or next;
        while (my $l = <$in>) { chomp $l; push @got, $l; }
        close $in;
    }

    is(scalar(@got), $N, "every item consumed exactly once (count $N, no loss/dup)");
    my $malformed = grep { !/^dev\d{5}$/ } @got;
    is($malformed, 0, 'no item was split or garbled across workers');

    my %seen; $seen{$_}++ for @got;
    my $dups = grep { $seen{$_} > 1 } keys %seen;
    is($dups, 0, 'no item consumed by more than one worker');
    my $missing = grep { !$seen{$_} } @items;
    is($missing, 0, 'no item missed');
}

done_testing();

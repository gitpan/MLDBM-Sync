#!/usr/local/bin/perl -w

use lib qw(.. . lib ../lib);
eval "use Sync";
print $@;
use Fcntl;
use Time::HiRes qw(time);
use Carp qw(confess);
use strict;
use Getopt::Long;
my $INSERTS = 25;
my $parent = $$;
$SIG{__DIE__} = \&confess;
srand(0);

$MLDBM::UseDB = $MLDBM::UseDB; # supress warning
use vars qw($opt_cache);
&GetOptions('c' => \$opt_cache);

for my $SIZE (50, 500, 5000, 20000, 50000) {
    print "\n=== INSERT OF $SIZE BYTE RECORDS ===\n";
    for my $DB ('SDBM_File', 'MLDBM::Sync::SDBM_File', 'GDBM_File', 'DB_File') {
	eval "use $DB";
	next if $@;
	if($DB eq 'SDBM_File' and $SIZE > 800) { 
	    print " (skipping test for SDBM_File 1024 byte limit)\n";
	    next 
	};
	local $MLDBM::UseDB = $DB;
	my %mldbm;
	my $sync = tie(%mldbm, 'MLDBM::Sync', '/tmp/MLDBM_SYNC_BENCH', O_CREAT|O_RDWR, 0666)
	  || die("can't tie to /tmp/bench_mldbm: $!");
	if($opt_cache) {
	    $sync->SyncCacheSize('1000K');
	}
	%mldbm = ();
	my $time = time;
	if($^O !~ /win32/i) { fork; fork; } # will launch 4 processes
	for(1..$INSERTS) {
	    my $rand;
	    for(1..($SIZE/10)) {
		$rand .= '<td>'.rand().rand();
		last if length($rand) > $SIZE;
	    }
	    $rand = substr($rand, 0, $SIZE);
	    my $key = "$$ $_";
# add lock & unlock to increase performance
#	    $sync->Lock;
	    $mldbm{$key} = $rand;
	    ($mldbm{$key} eq $rand) || warn("can't fetch written value for $key => $mldbm{$key} === $rand");
#	    $sync->UnLock;
	}
	if($^O !~ /win32/i) { while(wait != -1) {} }
	if($$ == $parent) {
	    my $total_time = time() - $time;
	    my $num_keys = scalar(keys %mldbm);
	    ($num_keys % $INSERTS) && warn("error, $num_keys should be a multiple of $INSERTS");
	    printf "  Time for $num_keys writes + $num_keys reads for  %-24s %6.2f seconds  %8d bytes\n", $DB, $total_time, $sync->SyncSize;
	} else {
	    exit;
	}
	%mldbm = ();
    }
}

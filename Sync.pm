
package MLDBM::Sync;
$VERSION = .07;

use MLDBM;
use MLDBM::Sync::SDBM_File;
use Data::Dumper;
use Fcntl qw(:flock);
use Digest::MD5 qw(md5_hex);
use strict;
use Carp qw(confess);
no strict qw(refs);
use vars qw($AUTOLOAD @EXT $CACHE_ERR $LOCK_SH $LOCK_EX $LOCK_UN);

eval "use Tie::Cache;";
if (($@)) {
    $CACHE_ERR = $@;
}

$LOCK_SH = LOCK_SH;
$LOCK_UN = LOCK_UN;
$LOCK_EX = LOCK_EX;

@EXT = ('.pag', '.dir', '');

sub TIEHASH {
    my($class, $file, @args) = @_;

    my $fh = $file.".lock";

    my $self = bless {
		      'file' => $file,
		      'args' => [ $file, @args ],
		      'lock_fh' => $fh,
		      'lock_file' => $fh,
		      'lock_num' => 0,
		      'md5_keys' => 0,
		      'pid' => $$,
		      'keys' => [],
		      'db_type' => $MLDBM::UseDB,	   
		      'serializer' => $MLDBM::Serializer,
		     };

    $self;
}

sub DESTROY { 
    my $self = shift;
    if($self->{lock_num}) {
	$self->{lock_num} = 1;
	$self->UnLock;
    }
}

sub AUTOLOAD {
    my($self, $key, $value) = @_;
    $AUTOLOAD =~ /::([^:]+)$/;
    my $func = $1;
    grep($func eq $_, ('FETCH', 'STORE', 'EXISTS', 'DELETE'))
      || die("$func not handled by object $self");

    ## CHECKSUM KEYS
    if(defined $key && $self->{md5_keys}) {
	$key = $self->SyncChecksum($key);
    }

    # CACHE, short circuit if found in cache on FETCH/EXISTS
    # after checksum, since that's what we store
    my $cache = (defined $key) ? $self->{cache} : undef;
    if($cache && ($func eq 'FETCH' or $func eq 'EXISTS')) {
	my $rv = $cache->$func($key);
	defined($rv) && return($rv);
    }

    my $rv;
    if ($func eq 'FETCH') {
	$self->read_lock;
    } else {
	$self->lock;
    }
    if (defined $value) {
	$rv = $self->{dbm}->$func($key, $value);
    } else {
	$rv = $self->{dbm}->$func($key);
    }
    $self->unlock;

    # do after lock critical section, no point taking 
    # any extra time there
    $cache && $cache->$func($key, $value);

    $rv;
}

sub CLEAR { 
    my $self = shift;
    
    $self->lock;
    $self->{dbm} = undef;
    # delete the files to free disk space
    for (@EXT) {
	my $file = $self->{file}.$_;	
	next unless -e $file;
	unlink($file) || die("can't unlink file $file: $!");
    }
    $self->unlock;

    $self->{cache} && $self->{cache}->CLEAR;

    1;
};

# don't bother with cache for first/next key since it'll kill
# the cache anyway likely
sub FIRSTKEY {
    my $self = shift;

    if($self->{md5_keys}) {
	confess("can't get keys() or each() on MLDBM::Sync database ".
		"with SyncKeysChecksum(1) set");
    }
    
    $self->read_lock;
    my $key = $self->{dbm}->FIRSTKEY();
    my @keys;
    if(defined $key) {
	do {
	    push(@keys, $key);
	} while($key = $self->{dbm}->NEXTKEY($key));
    }
    $self->{'keys'} = \@keys;
    $self->unlock;

    $self->NEXTKEY;
}

sub NEXTKEY {
    my $self = shift;

    if($self->{md5_keys}) {
	confess("can't get keys() or each() on MLDBM::Sync database ".
		"with SyncKeysChecksum(1) set");
    }
    
    my $rv = shift(@{$self->{'keys'}});
}

sub SyncChecksum {
    my($self, $key) = @_;
    if(ref $key) {
	join('g', md5_hex($$key), sprintf("%07d",length($$key)));
    } else {
	join('g', md5_hex($key), sprintf("%07d", length($key)));
    }
}

sub SyncCacheSize {
    my($self, $size) = @_;
    $CACHE_ERR && die("need Tie::Cache installed to use this feature: $@");

    if ($size =~ /^(\d+)(M|K)$/) {
	my($num, $type) = ($1, $2);
	if (($type eq 'M')) {
	    $size = $num * 1024 * 1024;
	} elsif (($type eq 'K')) {
	    $size = $num * 1024;
	} else {
	    die "$type symbol not understood for $size";
	}
    } else {
	($size =~ /^\d+$/) or die("$size must be bytes size for cache");
    }
    
    if ($self->{cache}) {
	$self->{cache}->CLEAR(); # purge old cache, to free up RAM maybe for mem leaks
    }
    
    my %cache;
    my $cache = tie %cache, 'Tie::Cache', { MaxBytes => $size };
    $self->{cache} = $cache; # use non tied interface, faster
}

sub SyncTie {
    my $self = shift;
    my %temp_hash;
    my $args = $self->{args};
    local $MLDBM::UseDB = $self->{db_type};
    local $MLDBM::Serializer = $self->{serializer};
    $self->{dbm} = tie(%temp_hash, 'MLDBM', @$args) || die("can't tie to MLDBM with args: ".join(',', @$args)."; error: $!");
}

#### DOCUMENTED API ################################################################

sub SyncKeysChecksum {
    my($self, $setting) = @_;
    if(defined $setting) {
	$self->{md5_keys} = $setting;
    } else {
	$self->{md5_keys};
    }
}

*read_lock = *ReadLock;
sub ReadLock { shift->Lock(1); }

*lock = *SyncLock = *Lock;
sub Lock {
    my($self, $read_lock) = @_;

    if($self->{lock_num}++ == 0) {
	my $file = $self->{lock_file};
	open($self->{lock_fh}, "+>$file") || die("can't open file $file: $!");
	flock($self->{lock_fh}, ($read_lock ? $LOCK_SH : $LOCK_EX))
	    || die("can't ". ($read_lock ? "read" : "write") ." lock $file: $!");
	$self->{read_lock} = $read_lock;
	$self->SyncTie;
    } else {
	if ($self->{read_lock} and ! $read_lock) {
	    $self->{lock_num}--; # roll back lock count
	    # confess here to help developer track this down
	    confess("can't upgrade lock type from LOCK_SH to LOCK_EX! ".
		    "this could also happen if you tried to write to the MLDBM ".
		    "in a critical section locked by ReadLock()");
	}
    }
}

*unlock = *SyncUnLock = *UnLock;
sub UnLock {
    my $self = shift;

    if($self->{lock_num}-- == 1) {
	undef $self->{dbm};
	flock($self->{'lock_fh'}, $LOCK_UN) || die("can't unlock $self->{'lock_file'}: $!");
	close($self->{'lock_fh'}) || die("can't close $self->{'lock_file'}");
	$self->{read_lock} = undef;
    } else {
	1;
    }
}

sub SyncSize {
    my $self = shift;
    my $size = 0;
    for (@EXT) {
	my $file = $self->{file}.$_;	
	next unless -e $file;
	$size += (stat($file))[7];
    }

    $size;
}

1;

__END__

=head1 NAME

  MLDBM::Sync (BETA) - safe concurrent access to MLDBM databases

=head1 SYNOPSIS

  use MLDBM::Sync;                       # this gets the default, SDBM_File
  use MLDBM qw(DB_File Storable);        # use Storable for serializing
  use MLDBM qw(MLDBM::Sync::SDBM_File);  # use extended SDBM_File, handles values > 1024 bytes

  # NORMAL PROTECTED read/write with implicit locks per i/o request
  my $sync_dbm_obj = tie %cache, 'MLDBM::Sync' [..other DBM args..] or die $!;
  $cache{"AAAA"} = "BBBB";
  my $value = $cache{"AAAA"};

  # SERIALIZED PROTECTED read/write with explicit lock for both i/o requests
  my $sync_dbm_obj = tie %cache, 'MLDBM::Sync', '/tmp/syncdbm', O_CREAT|O_RDWR, 0640;
  $sync_dbm_obj->Lock;
  $cache{"AAAA"} = "BBBB";
  my $value = $cache{"AAAA"};
  $sync_dbm_obj->UnLock;

  # SERIALIZED PROTECTED READ access with explicit read lock for both reads
  $sync_dbm_obj->ReadLock;
  my @keys = keys %cache;
  my $value = $cache{'AAAA'};
  $sync_dbm_obj->UnLock;

  # MEMORY CACHE LAYER with Tie::Cache
  $sync_dbm_obj->SyncCacheSize('100K');

  # KEY CHECKSUMS, for lookups on MD5 checksums on large keys
  my $sync_dbm_obj = tie %cache, 'MLDBM::Sync', '/tmp/syncdbm', O_CREAT|O_RDWR, 0640;
  $sync_dbm_obj->SyncKeysChecksum(1);
  my $large_key = "KEY" x 10000;
  $sync{$large_key} = "LARGE";
  my $value = $sync{$large_key};

=head1 DESCRIPTION

This module wraps around the MLDBM interface, by handling concurrent
access to MLDBM databases with file locking, and flushes i/o explicity
per lock/unlock.  The new [Read]Lock()/UnLock() API can be used to serialize
requests logically and improve performance for bundled reads & writes.

  my $sync_dbm_obj = tie %cache, 'MLDBM::Sync', '/tmp/syncdbm', O_CREAT|O_RDWR, 0640;

  # Write locked critical section
  $sync_dbm_obj->Lock;
    ... all accesses to DBM LOCK_EX protected, and go to same tied file handles
    $cache{'KEY'} = 'VALUE';
  $sync_dbm_obj->UnLock;

  # Read locked critical section
  $sync_dbm_obj->ReadLock;
    ... all read accesses to DBM LOCK_SH protected, and go to same tied files
    ... WARNING, cannot write to DBM in ReadLock() section, will die()
    my $value = $cache{'KEY'};
  $sync_dbm_obj->UnLock;

  # Normal access OK too, without explicity locking
  $cache{'KEY'} = 'VALUE';
  my $value = $cache{'KEY'};

MLDBM continues to serve as the underlying OO layer that
serializes complex data structures to be stored in the databases.
See the MLDBM L<BUGS> section for important limitations.

MLDBM::Sync also provides built in RAM caching with Tie::Cache
md5 key checksum functionality.

=head1 INSTALL

Like any other CPAN module, either use CPAN.pm, or perl -MCPAN C<-e> shell,
or get the file MLDBM-Sync-x.xx.tar.gz, unzip, untar and:

  perl Makefile.PL
  make
  make test
  make install

=head1 LOCKING

The MLDBM::Sync wrapper protects MLDBM databases by locking
and unlocking around read and write requests to the databases.
Also necessary is for each new lock to tie() to the database
internally, untie()ing when unlocking.  This flushes any
i/o for the dbm to the operating system, and allows for
concurrent read/write access to the databases.

Without any extra effort from the developer, an existing 
MLDBM database will benefit from MLDBM::sync.

  my $dbm_obj = tie %dbm, ...;
  $dbm{"key"} = "value";

As a write or STORE operation, the above will automatically
cause the following:

  $dbm_obj->Lock; # also ties
  $dbm{"key"} = "value";
  $dbm_obj->UnLock; # also unties

Just so, a read or FETCH operation like:

  my $value = $dbm{"key"};

will really trigger:

  $dbm_obj->ReadLock; # also ties
  my $value = $dbm{"key"};
  $dbm_obj->Lock; # also unties

However, these lock operations are expensive because of the 
underlying tie()/untie() that occurs for i/o flushing, so 
when bundling reads & writes, a developer may explicitly
use this API for greater performance:

  # tie once to database, write 100 times
  $dbm_obj->Lock;
  for (1..100) {
    $dbm{$_} = $_ * 100;
    ...
  }
  $dbm_obj->UnLock;

  # only tie once to database, and read 100 times
  $dbm_obj->ReadLock;
  for(1..100) {
    my $value = $dbm{$_};  
    ...
  }
  $dbm_obj->UnLock;

=head1 CACHING

I built MLDBM::Sync to serve as a fast and robust caching layer
for use in multi-process environments like mod_perl.  In order
to provide an additional speed boost when caching static data,
I have added an RAM caching layer with Tie::Cache, which 
regulates the size of the memory used with its MaxBytes setting.

To activate this caching, just:

  my $dbm = tie %cache, 'MLDBM::Sync', '/tmp/syncdbm', O_CREAT|O_RDWR, 0640;
  $dbm->SyncCacheSize(100000);  # 100000 bytes max memory used
  $dbm->SyncCacheSize('100K');  # 100 Kbytes max memory used
  $dbm->SyncCacheSize('1M');    # 1 Megabyte max memory used

The ./bench/bench_sync.pl, run like "bench_sync.pl C<-c>" will run 
the tests with caching turned on creating a benchmark with 50%
cache hits.

One run without caching was:

 === INSERT OF 50 BYTE RECORDS ===
  Time for 100 writes + 100 reads for  SDBM_File                  0.16 seconds     12288 bytes
  Time for 100 writes + 100 reads for  MLDBM::Sync::SDBM_File     0.17 seconds     12288 bytes
  Time for 100 writes + 100 reads for  GDBM_File                  3.37 seconds     17980 bytes
  Time for 100 writes + 100 reads for  DB_File                    4.45 seconds     20480 bytes

And with caching, with 50% cache hits:

 === INSERT OF 50 BYTE RECORDS ===
  Time for 100 writes + 100 reads for  SDBM_File                  0.11 seconds     12288 bytes
  Time for 100 writes + 100 reads for  MLDBM::Sync::SDBM_File     0.11 seconds     12288 bytes
  Time for 100 writes + 100 reads for  GDBM_File                  2.49 seconds     17980 bytes
  Time for 100 writes + 100 reads for  DB_File                    2.55 seconds     20480 bytes

Even for SDBM_File, this speedup is near 33%.

=head1 KEYS CHECKSUM

A common operation on database lookups is checksumming
the key, prior to the lookup, because the key could be
very large, and all one really wants is the data it maps
too.  To enable this functionality automatically with 
MLDBM::Sync, just:

  my $sync_dbm_obj = tie %cache, 'MLDBM::Sync', '/tmp/syncdbm', O_CREAT|O_RDWR, 0640;
  $sync_dbm_obj->SyncKeysChecksum(1);

 !! WARNING: keys() & each() do not work on these databases
 !! as of v.03, so the developer will not be fooled into thinking
 !! the stored key values are meaningful to the calling application 
 !! and will die() if called.
 !!
 !! This behavior could be relaxed in the future.
 
An example of this might be to cache a XSLT conversion,
which are typically very expensive.  You have the 
XML data and the XSLT data, so all you do is:

  # $xml_data, $xsl_data are strings
  my $xslt_output;
  unless ($xslt_output = $cache{$xml_data.'&&&&'.$xsl_data}) {
    ... do XSLT conversion here for $xslt_output ...
    $cache{$xml_data.'&&&&'.xsl_data} = $xslt_output;
  }

What you save by doing this is having to create HUGE keys
to lookup on, which no DBM is likely to do efficiently.
This is the same method that File::Cache uses internally to 
hash its file lookups in its directories.

=head1 New MLDBM::Sync::SDBM_File

SDBM_File, the default used for MLDBM and therefore MLDBM::Sync 
has a limit of 1024 bytes for the size of a record.

SDBM_File is also an order of magnitude faster for small records
to use with MLDBM::Sync, than DB_File or GDBM_File, because the
tie()/untie() to the dbm is much faster.  Therefore,
bundled with MLDBM::Sync release is a MLDBM::Sync::SDBM_File
layer which works around this 1024 byte limit.  To use, just:

  use MLDBM qw(MLDBM::Sync::SDBM_File);

It works by breaking up up the STORE() values into small 128 
byte segments, and spreading those segments across many records,
creating a virtual record layer.  It also uses Compress::Zlib
to compress STORED data, reducing the number of these 128 byte 
records. In benchmarks, 128 byte record segments seemed to be a
sweet spot for space/time efficiency, as SDBM_File created
very bloated *.pag files for 128+ byte records.

=head1 BENCHMARKS

In the distribution ./bench directory is a bench_sync.pl script
that can benchmark using the various DBMs with MLDBM::Sync.  

The MLDBM::Sync::SDBM_File DBM is special because is uses 
SDBM_File for fast small inserts, but slows down linearly
with the size of the data being inserted and read, with the 
speed matching that of GDBM_File & DB_File somewhere
around 20,000 bytes.  

So for DBM key/value pairs up to 10000 bytes, you are likely 
better off with MLDBM::Sync::SDBM_File if you can afford the 
extra space it uses.  At 20,000 bytes, time is a wash, and 
disk space is greater, so you might as well use DB_File 
or GDBM_File.

Note that MLDBM::Sync::SDBM_File is ALPHA as of 2/27/2001.

The results for a dual 450 linux 2.2.14, with a ext2 file
system blocksize 4096 mounted async on a SCSI disk were as follows:

 === INSERT OF 50 BYTE RECORDS ===
  Time for 100 writes + 100 reads for  SDBM_File                  0.13 seconds     12288 bytes
  Time for 100 writes + 100 reads for  MLDBM::Sync::SDBM_File     0.15 seconds     12288 bytes
  Time for 100 writes + 100 reads for  GDBM_File                  3.33 seconds     18066 bytes
  Time for 100 writes + 100 reads for  DB_File                    4.26 seconds     20480 bytes

 === INSERT OF 500 BYTE RECORDS ===
  Time for 100 writes + 100 reads for  SDBM_File                  0.17 seconds   1033216 bytes
  Time for 100 writes + 100 reads for  MLDBM::Sync::SDBM_File     0.54 seconds    110592 bytes
  Time for 100 writes + 100 reads for  GDBM_File                  3.47 seconds     63472 bytes
  Time for 100 writes + 100 reads for  DB_File                    4.30 seconds     86016 bytes

 === INSERT OF 5000 BYTE RECORDS ===
 (skipping test for SDBM_File 1024 byte limit)
  Time for 100 writes + 100 reads for  MLDBM::Sync::SDBM_File     1.33 seconds   1915904 bytes
  Time for 100 writes + 100 reads for  GDBM_File                  4.32 seconds    832400 bytes
  Time for 100 writes + 100 reads for  DB_File                    6.16 seconds    839680 bytes

 === INSERT OF 20000 BYTE RECORDS ===
 (skipping test for SDBM_File 1024 byte limit)
  Time for 100 writes + 100 reads for  MLDBM::Sync::SDBM_File     4.40 seconds   8173568 bytes
  Time for 100 writes + 100 reads for  GDBM_File                  4.86 seconds   2063912 bytes
  Time for 100 writes + 100 reads for  DB_File                    6.71 seconds   2068480 bytes

 === INSERT OF 50000 BYTE RECORDS ===
 (skipping test for SDBM_File 1024 byte limit)
  Time for 100 writes + 100 reads for  MLDBM::Sync::SDBM_File    12.87 seconds  27446272 bytes
  Time for 100 writes + 100 reads for  GDBM_File                  5.39 seconds   5337944 bytes
  Time for 100 writes + 100 reads for  DB_File                    7.22 seconds   5345280 bytes

=head1 WARNINGS

MLDBM::Sync is in BETA.  As of 2/27/2001 I have been using 
it in development for months, and been using its techniques for
years in Apache::ASP $Session & $Application data storage.
Future releases of Apache::ASP will use MLDBM::Sync for 
its Apache::ASP::State base implementation instead of MLDBM

MLDBM::Sync::SDBM_File is ALPHA quality.  Databases created 
while using it may not be compatible with future releases
if the segment manager code or support for compression changes.

=head1 TODO

Production testing.

=head1 AUTHORS

Copyright (c) 2001 Joshua Chamas, Chamas Enterprises Inc.  All rights reserved.
Sponsored by development on NodeWorks http://www.nodeworks.com

=head1 SEE ALSO

 MLDBM(3), SDBM_File(3), DB_File(3), GDBM_File(3)


package MLDBM::Sync;
$VERSION = .01;

use MLDBM;
use MLDBM::Sync::SDBM_File;
use Data::Dumper;
use Fcntl qw(:flock);
use Digest::MD5 qw(md5_hex);
use strict;
no strict qw(refs);
use vars qw($AUTOLOAD @EXT);

@EXT = ('.pag', '.dir', '');

sub TIEHASH {
    my($class, $file, @args) = @_;

    my $fh = "$file.lock";
    open($fh, ">>$fh") || die("can't open file $fh: $!");

    my $self = bless {
		      'file' => $file,
		      'args' => [ $file, @args ],
		      'lock' => $fh,
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

    $self->{dbm} = undef; # close / flush before unlock
    if (($self->{'lock'})) {
	close($self->{'lock'})
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
	my $oldkey = $key;
	$key = $self->SyncChecksum($key);
	if($func eq 'STORE') {
	    $value = { 'K' => $oldkey, 'V' => $value };
	}
    }

    $self->SyncLock;
    my $rv;
    if (defined $value) {
	$rv = $self->{dbm}->$func($key, $value);
    } else {
	$rv = $self->{dbm}->$func($key);
    }
    $self->SyncUnLock;

    if(defined $rv && $self->{md5_keys}) {
	$rv = $rv->{'V'};
    }

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

    1;
};

# don't bother with cache for first/next key since it'll kill
# the cache anyway likely
sub FIRSTKEY {
    my $self = shift;

    $self->lock;
    my $key = $self->{dbm}->FIRSTKEY();
    my @keys;
    if(defined $key) {
	do {
	    if($self->{md5_keys}) {
		my $raw_value = $self->{dbm}->FETCH($key);
		push(@keys, $raw_value->{'K'});
	    } else {
		push(@keys, $key);
	    }
	} while($key = $self->{dbm}->NEXTKEY($key));
    }
    $self->{'keys'} = \@keys;
    $self->unlock;

    $self->NEXTKEY;
}

sub NEXTKEY {
    my $self = shift;
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

sub SyncTie {
    my $self = shift;
    my %temp_hash;
    my $args = $self->{args};
    local $MLDBM::UseDB = $self->{db_type};
    local $MLDBM::Serializer = $self->{serializer};
    $self->{dbm} = tie(%temp_hash, 'MLDBM', @$args) || die("can't tie to MLDBM with args: ".join(',', @$args)."; error: $!");
}

#### DOCUMENTED API ################################################################

# sub Lock {}, see above for alias to SyncLock
# sub UnLock {}, see above for alias to SynUnLock

sub SyncKeysChecksum {
    my($self, $setting) = @_;
    if(defined $setting) {
	$self->{md5_keys} = $setting;
    } else {
	$self->{md5_keys};
    }
}

*lock = *Lock = *SyncLock;
sub SyncLock {
    my $self = shift;

    # FORK PROOF... we reinit the lock after a fork automatically this 
    # way since a shared file handle will not produce correct results
    # in a load test with forks involved otherwise.
    if ($self->{pid} ne $$) {
	my $fh = $self->{'lock'};
	close $fh;
	open($fh, ">>$fh") || die("can't open file $fh: $!");
	$self->{pid} = $$;
	$self->{lock_num} = 0;
    }

    if($self->{lock_num}++ == 0) {
	flock($self->{'lock'}, LOCK_EX) || die("can't write lock $self->{'lock'}: $!");
	$self->SyncTie;
    } else {
	1;
    }
}

*unlock = *UnLock = *SyncUnLock;
sub SyncUnLock {
    my $self = shift;

    if($self->{lock_num}-- == 1) {
	undef $self->{dbm};
	flock($self->{'lock'}, LOCK_UN) || die("can't unlock $self->{'lock'}: $!");
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
  tie %cache, 'MLDBM::Sync' [..other DBM args..] or die $!;
  $cache{"AAAA"} = "BBBB";
  my $value = $cache{"AAAA"};

  # SERIALIZED PROTECTED read/write with explicity lock for both i/o requests
  my $sync_dbm_obj = tie %cache, 'MLDBM::Sync', '/tmp/syncdbm', O_CREAT|O_RDWR, 0640;
  $sync_dbm_obj->Lock;
  $cache{"AAAA"} = "BBBB";
  my $value = $cache{"AAAA"};
  $sync_dbm_obj->UnLock;

=head1 DESCRIPTION

This module wraps around the MLDBM interface, by handling concurrent
access to MLDBM databases with file locking, and flushes i/o explicity
per lock/unlock.  The new Lock()/UnLock() API can be used to serialize
requests logically and improve performance for bundled reads & writes.

  my $sync_dbm_obj = tie %cache, 'MLDBM::Sync', '/tmp/syncdbm', O_CREAT|O_RDWR, 0640;
  $sync_dbm_obj->Lock;
    ... all accesses to DBM LOCK_EX protected, and go to same file handles ...
  $sync_dbm_obj->UnLock;

MLDBM continues to serve as the underlying OO layer that
serializes complex data structures to be stored in the databases.
See the MLDBM L<BUGS> section for important limitations.

=head1 INSTALL

Like any other CPAN module, either use CPAN.pm, or perl -MCPAN C<-e> shell,
or get the file MLDBM-Sync-x.xx.tar.gz, unzip, untar and:

  perl Makefile.PL
  make
  make test
  make install

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
sweet spot for space/time effienciency, as SDBM_File created
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
  Time for 100 write/read's for  SDBM_File                   0.12 seconds      12288 bytes
  Time for 100 write/read's for  MLDBM::Sync::SDBM_File      0.14 seconds      12288 bytes
  Time for 100 write/read's for  GDBM_File                   2.07 seconds      18066 bytes
  Time for 100 write/read's for  DB_File                     2.48 seconds      20480 bytes

 === INSERT OF 500 BYTE RECORDS ===
  Time for 100 write/read's for  SDBM_File                   0.21 seconds     658432 bytes
  Time for 100 write/read's for  MLDBM::Sync::SDBM_File      0.51 seconds     135168 bytes
  Time for 100 write/read's for  GDBM_File                   2.29 seconds      63472 bytes
  Time for 100 write/read's for  DB_File                     2.44 seconds     114688 bytes

 === INSERT OF 5000 BYTE RECORDS ===
 (skipping test for SDBM_File 1024 byte limit)
  Time for 100 write/read's for  MLDBM::Sync::SDBM_File      1.30 seconds    2101248 bytes
  Time for 100 write/read's for  GDBM_File                   2.55 seconds     832400 bytes
  Time for 100 write/read's for  DB_File                     3.27 seconds     839680 bytes

 === INSERT OF 20000 BYTE RECORDS ===
 (skipping test for SDBM_File 1024 byte limit)
  Time for 100 write/read's for  MLDBM::Sync::SDBM_File      4.54 seconds   13162496 bytes
  Time for 100 write/read's for  GDBM_File                   5.39 seconds    2063912 bytes
  Time for 100 write/read's for  DB_File                     4.79 seconds    2068480 bytes

 === INSERT OF 50000 BYTE RECORDS ===
 (skipping test for SDBM_File 1024 byte limit)
  Time for 100 write/read's for  MLDBM::Sync::SDBM_File     12.29 seconds   16717824 bytes
  Time for 100 write/read's for  GDBM_File                   9.10 seconds    5337944 bytes
  Time for 100 write/read's for  DB_File                    11.97 seconds    5345280 bytes

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

#!/usr/local/bin/perl

use ExtUtils::MakeMaker;

# where flock() is unimplemented, use LockFile::Simple
my %prereq = ();
eval { flock(0,0) };
if($@) {
    $prereq{'LockFile::Simple'} = 0;
}

&WriteMakefile( 
		NAME => "MLDBM::Sync", 
		VERSION_FROM => 'Sync.pm', 
		PREREQ_PM => \%prereq 
		);

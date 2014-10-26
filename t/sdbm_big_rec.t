
use lib qw(. t);
use strict;
use MLDBM::Sync;
use MLDBM qw(MLDBM::Sync::SDBM_File);
use Fcntl;
use T;
use Carp;
$SIG{__DIE__}  = \&Carp::confess;
$SIG{__WARN__} = \&Carp::cluck;

my $t = T->new();

my %db;
my $sync = tie %db, 'MLDBM::Sync', 'test_dbm', O_RDWR|O_CREAT, 0640;
$t->eok($sync, "can't tie to MLDBM::Sync");
for(1..10) {
    my $key = $_;
    my $value = rand() x 200;
    $db{$key} = $value;
    $t->eok($db{$key} eq $value, "can't fetch key $key value $value from db");
}
$t->eok(scalar(keys %db) == 10, "key count not successful");

$db{"DEL"} = "DEL";
$t->eok($db{"DEL"}, "failed to add key to delete");
delete $db{"DEL"};
$t->eok(! $db{"DEL"}, "failed to delete key");
$t->eok(scalar(keys %db) == 10, "key count not successful");

%db = ();
$t->eok(scalar(keys %db) == 0, "CLEAR not successful");
$t->done;

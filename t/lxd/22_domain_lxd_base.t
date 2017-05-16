use warnings;
use strict;

use Data::Dumper;
use IPC::Run3;
use POSIX ":sys_wait_h";
use Test::More;
use Test::SQL::Data;
use XML::LibXML;

my $BACKEND = 'LXD';
my @CMD_INFO = ('lxc','info');

use_ok('Ravada');
use_ok("Ravada::Domain::$BACKEND");

my $test = Test::SQL::Data->new( config => 't/etc/ravada.conf');
my $RAVADA;

eval { $RAVADA = Ravada->new( connector => $test->connector) };

my ($DOMAIN_NAME) = $0 =~ m{.*/(.*)\.};
$DOMAIN_NAME =~ s/[^a-z]+//;
$DOMAIN_NAME =~ tr/_/-/;
my $DOMAIN_NAME_SON=$DOMAIN_NAME."-son";
$DOMAIN_NAME_SON =~ s/base-//;

sub test_remove_domain {
    my $name = shift;

    my $domain;
    $domain = $RAVADA->search_domain($name,1);

    if ($domain) {
        diag("Removing domain $name");
        eval { $domain->remove() };
        ok(!$@ , "Error removing domain $name : $@") ;

        if ( $domain->file_base_img ) {
            ok(! -e $domain->file_base_img ,"Image file was not removed "
                                        .$domain->file_base_img )
        }

    }
    $domain = $RAVADA->search_domain($name,1);
    ok(!$domain, "I can't remove old domain $name") or exit;


}

sub test_new_domain_from_image {
    my $name = $DOMAIN_NAME;

    test_remove_domain($name);

    diag("Creating domain $name from image");
    my $domain;
    eval { $domain = $RAVADA->create_domain(
                 name => $name
             ,backend => $BACKEND,
            ,id_image => 1) 
    };
    ok(!$@,"Domain $name not created: $@");

    ok($domain,"Domain not created") or return;
    my $exp_ref= "Ravada::Domain::$BACKEND";
    ok(ref $domain eq $exp_ref, "Expecting $exp_ref , got ".ref($domain))
        if $domain;

    my @cmd = (@CMD_INFO,$name);
    my ($in,$out,$err);
    run3(\@cmd,\$in,\$out,\$err);
    ok(!$?,"@cmd \$?=$? , it should be 0 $err $out");

    my $sth = $test->dbh->prepare("SELECT * FROM domains WHERE name=? ");
    $sth->execute($domain->name);
    my $row =  $sth->fetchrow_hashref;
    ok($row->{name} && $row->{name} eq $domain->name,"I can't find the domain at the db");
    $sth->finish;

    return $domain;
}

sub test_prepare_base {
    my $domain = shift;

    my @list = $RAVADA->list_bases();
    my $name = $domain->name;

    ok(!grep(/^$name$/,map { $_->name } @list),"$name shouldn't be a base ".Dumper(\@list));

    $domain->prepare_base();

    my $sth = $test->dbh->prepare("SELECT * FROM domains WHERE name=? AND is_base='y'");
    $sth->execute($domain->name);
    my $row =  $sth->fetchrow_hashref;
    ok($row->{name} && $row->{name} eq $domain->name);
    $sth->finish;

    my @list2 = $RAVADA->list_bases();
    ok(scalar @list2 == scalar @list + 1 ,"Expecting ".(scalar(@list)+1)." bases"
            ." , got ".scalar(@list2));

    ok(grep(/^$name$/, map { $_->name } @list2),"$name should be a base ".Dumper(\@list2));

}

sub test_new_domain_from_base {
    my $base = shift;

    my $name = $DOMAIN_NAME_SON;
    test_remove_domain($name);

    diag("Creating domain $name from ".$base->name);
    my $domain = $RAVADA->create_domain(
                 name => $name
             ,id_base => $base->id
             ,backend => $BACKEND
    );
    ok($domain,"Domain not created");
    my $exp_ref= "Ravada::Domain::$BACKEND";
    ok(ref $domain eq $exp_ref, "Expecting $exp_ref , got ".ref($domain))
        if $domain;

    my @cmd = (@CMD_INFO,$name);
    my ($in,$out,$err);
    run3(\@cmd,\$in,\$out,\$err);
    ok(!$?,"@cmd \$?=$? , it should be 0 $err $out");

    my $sth = $test->dbh->prepare("SELECT * FROM domains WHERE name=? ");
    $sth->execute($domain->name);
    my $row =  $sth->fetchrow_hashref;
    ok($row->{name} && $row->{name} eq $domain->name,"I can't find the domain at the db");
    $sth->finish;

    return $domain;

}

sub test_spawn_viewer {
    my $domain = shift;

    my $pid = fork();
    die "Cannot fork"   if !defined $pid;

    if ($pid == 0) {

        my $uri = $domain->display;

        my @cmd = ('remote-viewer',$uri);
        my ($in,$out,$err);
        run3(\@cmd,\$in,\$out,\$err);
        ok(!$?,"Error $? running @cmd");
    } else {
        sleep 5;
        $domain->domain->shutdown;
        sleep 5;
        $domain->domain->destroy;
        exit;
    }
    waitpid(-1, WNOHANG);
}

sub remove_old_volumes {

    my $name = "$DOMAIN_NAME_SON.qcow2";
    my $file = "/var/lib/libvirt/images/$name";
    remove_volume($file);

    remove_volume("/var/lib/libvirt/images/$DOMAIN_NAME.img");
}

sub remove_volume {
    my $file = shift;

    return if !-e $file;
    diag("removing old $file");
    $RAVADA->remove_volume($file);
    ok(! -e $file,"file $file not removed" );
}

sub test_dont_allow_remove_base_before_sons {
    #TODO
    # create a base
    # create a son
    # try to remove the base and be denied
    # remove the son
    # try to remove the base and succeed
    # profit !
}

################################################################
my $vm;

eval { 
    $vm = $RAVADA->search_vm($BACKEND) ;
    $vm = $RAVADA->_create_vm_lxd()     if !$vm;
} if $RAVADA;

SKIP: {
    my $msg = "SKIPPED test: No $BACKEND backend found ".($@ or '');
    diag($msg)      if !$vm;
    skip $msg,10    if !$vm;

test_remove_domain($DOMAIN_NAME);
test_remove_domain($DOMAIN_NAME_SON);
remove_old_volumes();
my $domain = test_new_domain_from_image();


if (ok($domain,"test domain not created")) {
    test_prepare_base($domain);

    my $domain_son = test_new_domain_from_base($domain);
    test_remove_domain($domain_son->name);
    test_remove_domain($domain->name);

    test_dont_allow_remove_base_before_sons();
}

};

done_testing();
#!/usr/bin/env perl

use strict;
use warnings;

my $verbose = 0;
my $dirname = `dirname $0`;
chomp $dirname;

my @skipfs = ();
my $ignorelist = undef;
my $cfgfile = undef;

&usage() if (scalar(@ARGV)<2);
@ARGV = &try_opt_arg(@ARGV);
&usage() if (scalar(@ARGV)!=2);

my ($pool, $hostname) = @ARGV;
&read_ignore_list($ignorelist) if (defined $ignorelist);

# Get list of ZFS filesystems
my @out = `/sbin/zfs list -H -o name -r "$pool"`;

# or override auto-detection and back just one dataset
#@out = ("pool/var/log");

my $pidfile = "/var/run/backup-zfs-all.lock";

my $cfgparam = "";
if (defined $cfgfile) {
	$cfgparam = " -c \"$cfgfile\"";
	_log("Using backup configuration: $cfgfile\n");
}

foreach (sort @out) {
        my $fs = $_;
        chomp $fs;

        if (&is_ignored($fs)) {
                _log(sprintf "[%s] Skipped (on ignore list).\n", $fs);
                next;
        }

	_log(sprintf "[%s] Backuping ...\n", $fs);

	my $fs_flat = $fs;
	$fs_flat =~ s/\//-/g;

	system("/usr/bin/lockf -s -t 0 $pidfile /usr/sbin/idprio 16 \"$dirname/backup-zfs-fast.pl\"$cfgparam $fs $hostname-$fs_flat");
}

exit(0);

sub _log {
        my ($msg) = @_;

        printf $msg if ($verbose);
}

sub is_ignored {
	my ($fs) = @_;

	my $match = 0;
	foreach (@skipfs) {
		if ($fs =~ m/$_/) {
			$match = 1;
			last;
		}
	}

	return $match;
}

sub read_ignore_list {
	my ($ignorefile) = @_;
	my $FILE;

	open(FILE, $ignorefile) || die "Ignore-file not found: $ignorefile\n";
	@skipfs = <FILE>;
	close(FILE);

	for (@skipfs) { chomp; s/\$pool/$pool/; s/^/^/; s/$/\$/ }
}

sub usage {
        die "Usage: backup-zfs-all.pl [ -i ignorelist ] [ -c backup-configuration ] poolname hostname\n";
}

sub try_opt_arg {

	while (1) {
		my $cnt = scalar(@_);
		my ($sw, $file) = @_;

		if ($sw eq "-i") {
			$ignorelist = $file;
			shift; shift;
		}

		if ($sw eq "-c") {
			$cfgfile = $file;
			shift; shift;
		}

		last if (scalar(@_) == $cnt);
	}

	return @_;
}

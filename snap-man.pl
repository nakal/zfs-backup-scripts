#!/usr/bin/env perl

use strict;
use warnings;

my $verbose = 0;

&usage() if (scalar(@ARGV) != 1);

my %snapfs = &read_configuration($ARGV[0]);

# do not change this
# the snapshot format is compliant with samba shadow copies
my $snap_regex = "[0-9]{4}-[0-9]{2}-[0-9]{2}_[0-9]{2}:[0-9]{2}:[0-9]{2}";

foreach (keys %snapfs) {

	my $fs = $_;
	my $keep = $snapfs{$fs};

	_log(sprintf("[%s] Snapshotting ...\n", $fs));
	my $snapname = `/bin/date +%Y-%m-%d_%H:%M:%S`;
	chomp($snapname);

	if ($snapname =~ m/$snap_regex/) {
		_log(sprintf("\t -> %s@%s\n", $fs, $snapname));
		system("/sbin/zfs snapshot $fs" . "@" . "$snapname");

		my @snapshots = &list_snapshots($fs);
		my $snapnum = scalar @snapshots;

		_log(sprintf("[%s] Have %u snapshot(s) ...\n", $fs, $snapnum));

		if ($snapnum>$keep) {
			_log(sprintf("[%s] Tidying up old snapshots (keeping %u) ...\n", $fs, $keep));
			my @snaps_to_delete = (reverse @snapshots)[$keep..$#snapshots];

			foreach (@snaps_to_delete) {
				my $dsnap = $_;

				_log(sprintf("[%s] Deleting snapshot %s ...\n", $fs, $dsnap));
				system("/sbin/zfs destroy $fs" . "@" . "$dsnap");
			}
		}

	} else {
		die("Auto-created snapshot name $snapname does not match regexp!");
	}
}

exit 0;

sub list_snapshots {

	my ($fs) = @_;

	#printf("Listing snapshots under %s...\n", $fs);

	my @out = `/sbin/zfs list -H -t snapshot -r $fs`;
	my @ret = ();
	foreach (@out) {

		my $ln = $_;

		if ($ln =~ m/^$fs@($snap_regex)\t/) {
			my $snapname = $1;
			#printf("Snapname: %s\n", $snapname);
			push @ret, $snapname;
		}
	}

	return sort @ret;
}

sub read_configuration {
	my ($conf) = @_;
	my $FILE;

	open(FILE, $conf) || die "Snapshot configuration not found: $conf\n";
	my @lines = <FILE>;
	close(FILE);

	my $lnr = 1;
	my %snaps;
	for (@lines) {
		chomp;
		if (m/^\s*([^ \t]*)[ \t][ \t]*([0-9][0-9]*)$/) {
			$snaps{$1} = $2 if ($2 > 0);
		} else {
			die "Snapshot configuration error in line $lnr\n";
		}
		$lnr++;
	}

	return %snaps;
}

sub _log {
	my ($msg) = @_;

	print $msg if ($verbose);
}

sub usage {
	die "Syntax: snap-man.pl snapshot-configuration\n";
}

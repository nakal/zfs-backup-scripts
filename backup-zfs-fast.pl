#!/usr/bin/env perl

use warnings;
use strict;
use Config::Simple;
use Time::Piece;

# configure this (for your system distribution)
my $gpg_path = "/usr/local/bin/gpg";
my $pigz_path = "/usr/local/bin/pigz";
my $gzip_path = "/usr/bin/gzip";
my $zstd_path = "/usr/bin/zstd";
my $openssl_path = "/usr/bin/openssl";
my $config_path = undef;

# configuration defaults
my $use_ssh = 0;
my $ssh_backup_user = "backup";
my $ssh_backup_host = "backuphost.example.org";
my $ssh_remotedir = "/backups";
my $ssh_ping_backup_host = 0; # ping backup host before going on
my $localdir = "/mnt/backups"; # if NOT using ssh, specify
my $use_gpg = 0;
my $use_aes = 0;
my $gpgdir = "~/.gnupg";
my $gpgkey = "backup\@example.org";
my $aes_passfile = undef;
my $use_pigz = 0;
my $use_gzip = 0;
my $use_zstd = 0;
my $compress_cpu_num = 3; # number of CPUs to use
my $compress_level = 99; # compression level
my $keep_backups_per_level = 3;

# for debugging; makes commands non-destructive
my $test_mode = 0;

&show_usage() if (scalar(@ARGV)<3);

if ($ARGV[0] eq "-c") {
	$config_path = $ARGV[1];
	shift; shift;
}
&show_usage() if (scalar(@ARGV) != 2);

my ($zfs, $backupprefix) = @ARGV;

&read_configuration($config_path) if (defined ($config_path));

my $file_extension = "";
my $compression_pipe = "";
if ($use_zstd) {
	$file_extension .= ".zstd";
	$compress_level = 3 if ($compress_level == 99);
	$compression_pipe = "| $zstd_path -c -T$compress_cpu_num -$compress_level ";
}
if ($use_pigz) {
	$file_extension .= ".gz";
	$compress_level = 6 if ($compress_level == 99);
	$compression_pipe = "| $pigz_path -c -p $compress_cpu_num -$compress_level ";
}
if ($use_gzip) {
	$file_extension .= ".gz";
	$compress_level = 6 if ($compress_level == 99);
	$compression_pipe = "| $gzip_path -c -$compress_level ";
}

my $verbose = 0;
if ($verbose) {
	if ($use_ssh) {
		print "Connecting over ssh to $ssh_backup_user\@$ssh_backup_host\n";
		print "and storing backup in directory $ssh_remotedir\n";
		print "\twill ping\n" if ($ssh_ping_backup_host);
	} else {
		print "Creating backup in directory $localdir\n";
	}

	print "\twill compress " if ($use_pigz || $use_gzip || $use_zstd);
	print "(gzip; level=$compress_level)\n" if ($use_gzip);
	print "(pigz; parallel $compress_cpu_num; level=$compress_level)\n" if ($use_pigz);
	print "(zstd; parallel $compress_cpu_num; level=$compress_level)\n" if ($use_zstd);
	print "\twill encrypt (key $gpgkey from directory $gpgdir)\n" if ($use_gpg);
	print "\twill encrypt (password from file $aes_passfile)\n" if ($use_aes);
}

if ($use_gzip + $use_pigz + $use_zstd > 1) {
	print "*** FATAL: Configuration error, cannot use multiple compressions together.\n";
	exit 1;
}

if ($use_gpg && $use_aes) {
	print "*** FATAL: Configuration error, cannot use GPG and AES together.\n";
	exit 1;
}

if ($use_aes) {
	if (!defined($aes_passfile) || !-r $aes_passfile) {
		print "*** FATAL: Configuration error, AES needs aes_passfile.\n";
		exit 1;
	}
}
my $encrypt_pipe = "";
if ($use_gpg) {
	$file_extension .= ".gpg";
	$encrypt_pipe = "| $gpg_path --homedir $gpgdir --recipient $gpgkey -e ";
}
if ($use_aes) {
	$file_extension .= ".aes";
	$encrypt_pipe = "| $openssl_path enc -aes128 -kfile $aes_passfile -pbkdf2";
}

if ($use_ssh && $ssh_ping_backup_host) {
	my $ping = &execute("/sbin/ping -q -c 1 -t 1 $ssh_backup_host > /dev/null");
	if ($ping != 0) {
		print "*** ABORTED: Backup destination host $ssh_backup_host not online.\n";
		exit(1);
	}
}

my @dumphistory = ();
my @dumphistory_other = ();

my @loctim = localtime;
my $timenow = sprintf ("%04d-%02d-%02d", $loctim[5]+1900, $loctim[4]+1,
	$loctim[3]);

printf ("[%s:%s] Backup started on %s.\n", $backupprefix, $zfs, &time_now());

# read backup history
my @zfs_history = `zfs list -t snapshot -Hr -o name $zfs`;
if ($? != 0) {
	print "*** FATAL: Failed to list snapshots for $zfs\n";
	exit(1);
}

my %snap_level_backups = ();
foreach (@zfs_history) {
	if (m/^$zfs\@([0-9]{4}-[0-9]{2}-[0-9]{2})-L([0-9])$/) {
		my ($l, $d) = ($2, $1);
		push @{$snap_level_backups{$l}}, $d;
	}
	if (m/^$zfs\@([0-9]{4}-[0-9]{2}-[0-9]{2})-L([0-9])-tmp$/) {
		my ($l, $d) = ($2, $1);
		my $ret = &execute("/sbin/zfs", "destroy", "$zfs\@$d-L$l-tmp");
		if ($ret != 0) {
			printf("*** ERROR: Could not delete stale snapshot %s-L%d\n", $d, $l);
		} else {
			printf("*** WARNING: Deleted stale snapshot %s-L%d\n", $d, $l);
		}
	}
}

# Find oldest L0 backup
my $oldest_l0 = "2000-01-01";

# Tidy up snapshots on the local side
foreach (sort keys(%snap_level_backups)) {

	my $lev = $_;

	# sort snapshots for level
	my @local_backups = sort(@{$snap_level_backups{$lev}});

	# sort out snapshots that are older than oldest L0
	my @expired_backups = grep { $_ lt $oldest_l0 } @local_backups if ($lev > 0);
	@local_backups = grep { $_ ge $oldest_l0 } @local_backups if ($lev > 0);

	my @valid = ();

	# Pop n snapshots that should remain and not deleted
	for (my $i = 0;
		$i < scalar(@local_backups) && $i < $keep_backups_per_level - 1;
		$i++) {
		push @valid, pop @local_backups;
	}

	$oldest_l0 = pop @valid if ($lev == 0 && scalar(@valid) > 0);
	push @local_backups, @expired_backups if ($lev > 0);

	# destroy the remaining snapshots
	my %removed = ();
	foreach (@local_backups) {
		my $d = $_;
		my $ret = &execute("/sbin/zfs", "destroy", "$zfs\@$d-L$lev");
		if ($ret != 0) {
			printf("\t*** WARNING: Could not delete old snapshot %s-L%d\n",
					$d, $lev);
		} else {
			$removed{$d} = 1;
		}
	}

	# Delete removed snapshots for later computations
	@{$snap_level_backups{$lev}} =
		grep { !$removed{$_} } @{$snap_level_backups{$lev}};
}

# print "Oldest level 0 backup: $oldest_l0\n" if ($test_mode);
&dump_hash("LOCAL BACKUPS", %snap_level_backups) if ($test_mode);

# remote backup mask to extract backups
my $backupmask = sprintf("%s-????-??-??.L?D?%s*", $backupprefix, $file_extension);

# Get a list of backups on the remote side for the current level
my @output = ();
if ($use_ssh) {
	@output = `ssh -o Compression=no $ssh_backup_user\@$ssh_backup_host /bin/ls -1 $ssh_remotedir/$backupmask`;
} else {
	@output = `/bin/ls -1 $localdir/$backupmask`;
}

# Tidy up backups on the remote side (incomplete backups)
my %remote_level_backups = ();
foreach (@output) {
	chomp;
	# extract date
	if (m/$backupprefix-([0-9-]*)\.L([0-9])D[0-9F]$file_extension$/) {
		my ($l, $d) = ($2, $1);
		push @{$remote_level_backups{$l}}, $d;
	} elsif (m/$backupprefix-([0-9-]*\.L[0-9]D[0-9F])$file_extension\.tmp$/) {
		my $fn = $_;
		my $d = $1;
		# remove stale (unfinished) backups directly
		my $ret;
		if ($use_ssh) {
			$ret = &execute("ssh",
				"-o", "Compression=no", "$ssh_backup_user\@$ssh_backup_host",
				"/bin/rm", "$fn");
		} else {
			$ret = &execute("sh", "-c", "/bin/rm $fn");
		}
		printf($ret == 0 ? "\t*** WARNING: Deleting stale backup %s\n" :
				"\t*** WARNING: FAILED TO DELETE stale backup %s\n", $d);
	}
}

# Tidy up backups on the remote side (old backups)
for my $lev (keys(%remote_level_backups)) {

	my @remote_backups = sort @{$remote_level_backups{$lev}};

	# delete backups NOT to be deleted
	@{$remote_level_backups{$lev}} = ();
	for (my $i = 0; $i < $keep_backups_per_level - 1; $i++) {
		my $d = pop @remote_backups;
		if (defined $d) {
			push @{$remote_level_backups{$lev}}, $d;
		}
	}
	# make space for new backup by keeping <keep_backups_per_level - 1> latest ones for the current level
	for my $n (@remote_backups) {
		my $ret;
		if ($use_ssh) {
			$ret = &execute("ssh", "-o",
				"Compression=no", "$ssh_backup_user\@$ssh_backup_host",
				"/bin/rm", "$ssh_remotedir/$backupprefix-$n.L${lev}D?$file_extension");
		} else {
			$ret = &execute("sh", "-c", "/bin/rm $localdir/$backupprefix-$n.L${lev}D?$file_extension");
		}
		if ($ret != 0) {
			printf("\t*** WARNING: Could not delete old backup %s-%s%s\n",
				$backupprefix, $n, $file_extension);
		}
	}
}

&dump_hash("REMOTE BACKUPS", %remote_level_backups) if ($test_mode);

# Calculate backup state by combining remote backups and local snapshots
my %level_backups = ();
foreach (keys %remote_level_backups) {
	my $lev = $_;
	my @isect = map(
		{
			my $e = $_;
			grep { $e eq $_ } @{$snap_level_backups{$lev}}
		}
		@{$remote_level_backups{$lev}}
	);
	if (scalar(@isect)) {
		@{$level_backups{$lev}} = @isect;
	} else {
		delete $level_backups{$lev};
	}
}

my $snap_date_last = "2000-01-01";
my $snap_lev_last = 0;
while (my ($lev, $dates) = each %level_backups) {
	foreach my $date (@{$dates}) {
		($snap_lev_last, $snap_date_last) = ($lev, $date)
			if ($snap_date_last lt $date);
	}
}

printf("Last backup: %s-L%u\n", $snap_date_last, $snap_lev_last)
	if ($test_mode);

while (my ($l, $ds) = each(%level_backups)) {
	@{$ds} = sort {$b cmp $a} @{$ds};
}

&dump_hash("BACKUPS", %level_backups) if ($test_mode);

my $diff_msg = "";
my $lev = 0;
my $diff_level = 0;
my $diff_date = "2000-01-01";
if (scalar(keys %level_backups) < 1) {
	$diff_msg = "not found, forcing level 0 backup";
} else {
	$diff_msg = "level " . $snap_lev_last . " on " . $snap_date_last;

	my %next_lev_map = (
		0, 4,
		4, 3,
		3, 2,
		2, 7,
		7, 6,
		6, 5,
		5, 1,
		1, 4
	);
	if (defined($next_lev_map{$snap_lev_last})) {
		$lev = $next_lev_map{$snap_lev_last};
	}
}

# Check the date of the last level 0 backup
if ($lev != 0) {
	if (defined($level_backups{0})) {
		my ($date_lev0) = @{$level_backups{0}};
		my $ts_last = Time::Piece->strptime($timenow, '%Y-%m-%d') -
		 Time::Piece->strptime($date_lev0, '%Y-%m-%d');
		if ($ts_last >= 2400000) {
			$lev = 0;
		} else {
			while (my ($l, $ds) = each(%level_backups)) {
				foreach (@{$ds}) {
					my $d = $_;
					($diff_level, $diff_date) = ($l, $d) if (($l < $lev) and ($diff_date lt $d));
				}
			}
		}
	} else {
		$lev = 0;
	}
}

printf ("\tthis: level %s on %s\n", $lev, $timenow);
print "\tlast: " . $diff_msg . "\n";

if ($lev > 0) {
	print "\tdiff: level " . $diff_level . " on " . $diff_date . "\n";
} else {
	print "\tinfo: forcing full backup\n";
}

# remote file name for current backup
my $backupname = $lev == 0 ?
	sprintf("%s-%s.L%1dDF%s", $backupprefix, $timenow, $lev, $file_extension) :
	sprintf("%s-%s.L%1dD%1d%s", $backupprefix, $timenow, $lev, $diff_level, $file_extension);

# Construct command for ZFS send
my $snapname = sprintf("%s-L%1d", $timenow, $lev);
my $sendcmd1 = "/sbin/zfs snapshot " . $zfs . "@" . $snapname . "-tmp";
my $sendcmd2;
if ($lev == 0) {
	$sendcmd2 = "/sbin/zfs send " . $zfs . "@" . $snapname . "-tmp";
} else {
	my $diffsnap = sprintf("%s-L%1d", $diff_date, $diff_level);
	$sendcmd2 = "/sbin/zfs send -i $diffsnap " . $zfs . "@" . $snapname . "-tmp";
}

print "\tmaking snapshot...\n";
my $ret = &execute("sh", "-c", $sendcmd1);
if ($ret != 0) {
	printf("\t*** FATAL: Failed to make snapshot $snapname-tmp\n");
	exit(1);
}

if ($use_ssh) {
	print "\tsending to: $ssh_backup_host\n";
	my $ret = &execute("sh", "-c",
		"$sendcmd2 $compression_pipe $encrypt_pipe | ssh -o Compression=no " . $ssh_backup_user . "\@" . $ssh_backup_host . " 'cat - > $ssh_remotedir/$backupname.tmp'");
	if ($ret == 0) {
		$ret = &execute("ssh", "-o", "Compression=no", "$ssh_backup_user\@$ssh_backup_host",
				"/bin/mv", "$ssh_remotedir/$backupname.tmp", "$ssh_remotedir/$backupname");
		printf($ret == 0 ? "\tOK success\n" : "\t*** FATAL: Failed to rename backup (mv)\n");
		exit(1) if ($ret != 0);
	} else {
		printf("\t*** FATAL: Backup transfer failed\n");
		exit(1);
	}
} else {
	print "\tsaving in: $localdir\n";
	my $ret = &execute("sh", "-c",
		"$sendcmd2 $compression_pipe $encrypt_pipe > $localdir/$backupname.tmp");
	if ($ret == 0) {
		$ret = &execute("/bin/mv",
			"$localdir/$backupname.tmp", "$localdir/$backupname");
		printf($ret == 0 ? "\tOK success\n" : "\t*** FATAL: Failed to rename backup (mv)\n");
		exit(1) if ($ret != 0);
	} else {
		printf("\t*** FATAL: Failed to store backup\n");
		exit(1);
	}
}
if (&execute("/sbin/zfs", "rename", "$zfs\@$snapname-tmp", "$zfs\@$snapname") != 0) {
	printf("\t*** FATAL: Failed to rename snapshot (remove -tmp suffix)\n");
	exit(1);
}

exit 0;

sub execute {
	my @params = @_;
	unshift @params, ("echo") if ($test_mode);
	return system(@params);
}

sub read_configuration {
	my ($conf) = @_;

	my %cfg = ();
	Config::Simple->import_from($conf, \%cfg) || die "*** FATAL: Cannot read configuration $conf\n";

	foreach my $k (keys %cfg) {
		if ($k eq "use_ssh") {
			$use_ssh = &get_bool($cfg{$k});
			next;
		}
		if ($k eq "ssh_backup_user") {
			$ssh_backup_user = $cfg{$k};
			next;
		}
		if ($k eq "ssh_backup_host") {
			$ssh_backup_host = $cfg{$k};
			next;
		}
		if ($k eq "ssh_remotedir") {
			$ssh_remotedir = $cfg{$k};
			next;
		}
		if ($k eq "ssh_ping_backup_host") {
			$ssh_ping_backup_host = &get_bool($cfg{$k});
			next;
		}
		if ($k eq "local_dir") {
			$localdir = $cfg{$k};
			next;
		}
		if ($k eq "keep_backups_per_level") {
			$keep_backups_per_level = $cfg{$k};
			next;
		}
		if ($k eq "use_gpg") {
			$use_gpg = &get_bool($cfg{$k});
			next;
		}
		if ($k eq "use_aes") {
			$use_aes = &get_bool($cfg{$k});
			next;
		}
		if ($k eq "aes_passfile") {
			$aes_passfile = $cfg{$k};
			next;
		}
		if ($k eq "gpg_dir") {
			$gpgdir = $cfg{$k};
			next;
		}
		if ($k eq "gpg_key") {
			$gpgkey = $cfg{$k};
			next;
		}
		if ($k eq "use_zstd") {
			$use_zstd = &get_bool($cfg{$k});
			next;
		}
		if ($k eq "use_pigz") {
			$use_pigz = &get_bool($cfg{$k});
			next;
		}
		if ($k eq "use_gzip") {
			$use_gzip = &get_bool($cfg{$k});
			next;
		}
		if ($k eq "compress_cpu_num") {
			$compress_cpu_num = $cfg{$k};
			next;
		}
		if ($k eq "compress_level") {
			$compress_level = $cfg{$k};
			next;
		}

		die "Unknown setting in $conf: $k\n";
	}
}

sub time_now {
	my $tn = localtime();
	return $tn;
}

sub get_bool {
	my ($v) = @_;

	return 1 if ($v eq "1" || $v eq "on" || $v eq "enable" ||
		$v eq "enabled" || $v eq "true" || $v eq "t" ||
		$v eq "set" || $v eq "yes");

	return 0;
}

sub show_usage {
	die "Usage: backup-zfs-fast.pl [ -c configpath ] zfsname prefix\n";
}

sub dump_hash {
	my ($label, %backups) = @_;

	printf("%s\n", $label);
	while (my ($lev, $dates) = each %backups) {
		printf("Level %u: %s\n", $lev, join(",", @{$dates}));
	}
}

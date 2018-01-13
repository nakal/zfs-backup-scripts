#!/usr/bin/env perl

use warnings;
use strict;
use Config::Simple;
use Time::Piece;

# configure this (for your system distribution)
my $gpg_path = "/usr/local/bin/gpg";
my $pigz_path = "/usr/local/bin/pigz";
my $gzip_path = "/usr/bin/gzip";
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
my $pigz_cpu_num = 3; # number of CPUs to use
my $use_gzip = 0;
my $keep_backups_per_level = 3;

&show_usage() if (scalar(@ARGV)<3);

if ($ARGV[0] eq "-c") {
	$config_path = $ARGV[1];
	shift; shift;
}
&show_usage() if (scalar(@ARGV) != 2);

my ($zfs, $backupprefix) = @ARGV;

&read_configuration($config_path) if (defined ($config_path));

my $verbose = 0;
if ($verbose) {
	if ($use_ssh) {
		print "Connecting over ssh to $ssh_backup_user\@$ssh_backup_host\n";
		print "and storing backup in directory $ssh_remotedir\n";
		print "\twill ping\n" if ($ssh_ping_backup_host);
	} else {
		print "Creating backup in directory $localdir\n";
	}

	print "\twill compress " if ($use_pigz || $use_gzip);
	print "(gzip)\n" if ($use_gzip);
	print "(pigz; parallel $pigz_cpu_num)\n" if ($use_pigz);
	print "\twill encrypt (key $gpgkey from directory $gpgdir)\n" if ($use_gpg);
	print "\twill encrypt (password from file $aes_passfile)\n" if ($use_aes);
}

if ($use_gzip && $use_pigz) {
	print "*** FATAL: Configuration error, cannot use gzip and pigz together.\n";
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

if ($use_ssh && $ssh_ping_backup_host) {
	my $ping = system("/sbin/ping -q -c 1 -t 1 $ssh_backup_host > /dev/null");
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

# read backup history
my @zfs_history = `zfs list -t snapshot -Hr -o name $zfs`;
if ($? != 0) {
	print "*** FATAL: Failed to list snapshots for $zfs\n";
	exit(1);
}

my %level_backups = ();
my $date_last = "2000-01-01";
my $lev_last = 0;
foreach (@zfs_history) {
	if (m/^$zfs\@L([0-9])-([0-9-]*)$/) {
		my ($l, $d) = ($1, $2);
		push @{$level_backups{$l}}, $d;
		($lev_last, $date_last) = ($l, $d) if ($date_last lt $d);
	}
	if (m/^$zfs\@L([0-9])-([0-9-]*)-tmp$/) {
		my ($l, $d) = ($1, $2);
		my $ret = system("/sbin/zfs", "destroy", "$zfs\@L$l-$d-tmp");
		if ($ret != 0) {
			printf("*** ERROR: Could not delete stale snapshot L%d-%s\n", $l, $d);
		} else {
			printf("*** WARNING: Deleted stale snapshot L%d-%s\n", $l, $d);
		}
	}
}

while (my ($l, $ds) = each(%level_backups)) {
	@{$ds} = sort {$b cmp $a} @{$ds};
}

my $diff_msg = "";
my $lev = 0;
my $diff_level = 0;
my $diff_date = "2000-01-01";
if (scalar(keys %level_backups) < 1) {
	$diff_msg = "not found, forcing level 0 backup";
} else {
	$diff_msg = "level " . $lev_last . " on " . $date_last;

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
	if (defined($next_lev_map{$lev_last})) {
		$lev = $next_lev_map{$lev_last};
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

printf ("[%s:%s] Backup started on %s.\n", $backupprefix, $zfs, &time_now());
printf ("\tthis: level %s on %s\n", $lev, $timenow);
print "\tlast: " . $diff_msg . "\n";

my $file_extension = "gz";
my $compression_pipe = "";
my $encrypt_pipe = "";
if ($use_pigz) {
	$compression_pipe = "| $pigz_path -c -p $pigz_cpu_num ";
}
if ($use_gzip) {
	$compression_pipe = "| $gzip_path -c ";
}
if ($use_gpg) {
	$file_extension .= ".gpg";
	$encrypt_pipe = "| $gpg_path --homedir $gpgdir --recipient $gpgkey -e ";
}
if ($use_aes) {
	$file_extension .= ".aes";
	$encrypt_pipe = "| $openssl_path aes-128-cbc -e -kfile $aes_passfile";
}
if ($lev > 0) {
	print "\tdiff: level " . $diff_level . " on " . $diff_date . "\n";
} else {
	print "\tinfo: forcing full backup\n";
}

# remote file name for current backup
my $backupname = $lev == 0 ?
	sprintf("%s-L%1dDF-%s.%s", $backupprefix, $lev, $timenow, $file_extension) :
	sprintf("%s-L%1dD%1d-%s.%s", $backupprefix, $lev, $diff_level, $timenow, $file_extension);

# remote backup mask to extract recent backups on current level
my $backupmask = sprintf("%s-L%dD?-*.%s*", $backupprefix, $lev, $file_extension);

# Get a list of backups on the remote side for the current level
my @output = ();
if ($use_ssh) {
	@output = `ssh -o Compression=no $ssh_backup_user\@$ssh_backup_host /bin/ls -1 $ssh_remotedir/$backupmask`;
} else {
	@output = `/bin/ls -1 $localdir/$backupmask`;
}

# Tidy up backups on the remote side
my @remote_backups = ();
foreach (@output) {
	# extract date
	if (m/$backupprefix-L$lev(D[0-9F]-[0-9-]*)\.$file_extension$/) {
		push @remote_backups, $1;
	} elsif (m/$backupprefix-L$lev(D[0-9F]-[0-9-]*)\.$file_extension\.tmp$/) {
		my $d = $1;
		# remove stale (unfinished) backups directly
		my $ret;
		if ($use_ssh) {
			$ret = system("ssh", "-o", "Compression=no", "$ssh_backup_user\@$ssh_backup_host",
					"/bin/rm", "$ssh_remotedir/$backupprefix-L$lev$d.$file_extension.tmp");
		} else {
			$ret = system("/bin/rm", "$localdir/$backupprefix-L$lev$d.$file_extension");
		}
		printf($ret == 0 ? "\t*** WARNING: Deleting stale backup L%d%s\n" :
				"\t*** WARNING: FAILED TO DELETE stale backup L%d%s\n", $lev, $d);
	}
}
if (scalar(@remote_backups) >= $keep_backups_per_level) {
	@remote_backups = sort {
		substr($a, 3) cmp substr($b, 3) || substr($b, 1, 1) cmp substr($a, 1, 1)
	} @remote_backups;

	for (my $i = 0; $i < $keep_backups_per_level - 1; $i++) {
		pop @remote_backups;
	}

	# make space for new backup by keeping <keep_backups_per_level - 1> latest ones for the current level
	foreach (@remote_backups) {
		my $n = $_;
		my $ret;
		if ($use_ssh) {
			$ret = system("ssh", "-o", "Compression=no", "$ssh_backup_user\@$ssh_backup_host",
					"/bin/rm", "$ssh_remotedir/$backupprefix-L$lev$n.$file_extension");
		} else {
			$ret = system("/bin/rm", "$localdir/$backupprefix-L$lev$n.$file_extension");
		}
		if ($ret != 0) {
			printf("\t*** WARNING: Could not delete old backup %s-L%d%s.%s\n",
				$backupprefix, $lev, $n, $file_extension);
		}
	}
}

# Tidy up snapshots on the local side
if (defined($level_backups{$lev})) {
	my @local_backups = sort(@{$level_backups{$lev}});
	for (my $i = 0; $i < $keep_backups_per_level - 1; $i++) {
		pop @local_backups;
	}
	foreach (@local_backups) {
		my $d = $_;
		my $ret = system("/sbin/zfs", "destroy", "$zfs\@L$lev-$d");
		if ($ret != 0) {
			printf("\t*** WARNING: Could not delete old snapshot L%d-%s\n",
					$lev, $d);
		}
	}
}

# Construct command for ZFS send
my $snapname = sprintf("L%1d-%s", $lev, $timenow);
my $sendcmd1 = "/sbin/zfs snapshot " . $zfs . "@" . $snapname . "-tmp";
my $sendcmd2;
if ($lev == 0) {
	$sendcmd2 = "/sbin/zfs send " . $zfs . "@" . $snapname . "-tmp";
} else {
	my $diffsnap = sprintf("L%1d-%s", $diff_level, $diff_date);
	$sendcmd2 = "/sbin/zfs send -i $diffsnap " . $zfs . "@" . $snapname . "-tmp";
}

print "\tmaking snapshot...\n";
my $ret = system("sh", "-c", $sendcmd1);
if ($ret != 0) {
	printf("\t*** FATAL: Failed to make snapshot $snapname-tmp\n");
	exit(1);
}

if ($use_ssh) {
	print "\tsending to: $ssh_backup_host\n";
	my $ret = system("sh", "-c", "$sendcmd2 $compression_pipe $encrypt_pipe | ssh -o Compression=no " . $ssh_backup_user . "\@" . $ssh_backup_host . " 'cat - > $ssh_remotedir/$backupname.tmp'");
	if ($ret == 0) {
		$ret = system("ssh", "-o", "Compression=no", "$ssh_backup_user\@$ssh_backup_host",
				"/bin/mv", "$ssh_remotedir/$backupname.tmp", "$ssh_remotedir/$backupname");
		printf($ret == 0 ? "\tOK success\n" : "\t*** FATAL: Failed to rename backup (mv)\n");
		exit(1) if ($ret != 0);
	} else {
		printf("\t*** FATAL: Backup transfer failed\n");
		exit(1);
	}
} else {
	print "\tsaving in: $localdir\n";
	my $ret = system("sh", "-c", "$sendcmd2 $compression_pipe $encrypt_pipe > $localdir/$backupname.tmp");
	if ($ret == 0) {
		$ret = system("/bin/mv", "$localdir/$backupname.tmp", "$localdir/$backupname");
		printf($ret == 0 ? "\tOK success\n" : "\t*** FATAL: Failed to rename backup (mv)\n");
		exit(1) if ($ret != 0);
	} else {
		printf("\t*** FATAL: Failed to store backup\n");
		exit(1);
	}
}
if (system("/sbin/zfs", "rename", "$zfs\@$snapname-tmp", "$zfs\@$snapname") != 0) {
	printf("\t*** FATAL: Failed to rename snapshot (remove -tmp suffix)\n");
	exit(1);
}

exit 0;

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
		if ($k eq "use_pigz") {
			$use_pigz = &get_bool($cfg{$k});
			next;
		}
		if ($k eq "pigz_cpu_num") {
			$pigz_cpu_num = $cfg{$k};
			next;
		}
		if ($k eq "use_gzip") {
			$use_gzip = &get_bool($cfg{$k});
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
	die "Usage: backup-zfs-fast.pl [ -c configpath ] zfsname prefix backuplevel\n";
}

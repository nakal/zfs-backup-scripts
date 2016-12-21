#!/usr/bin/env perl

use warnings;
use strict;
use Config::Simple;

# configure this (for your system distribution)
my $backup_history = "/var/db/backup-zfs-history";
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

&show_usage() if (scalar(@ARGV)<3);

if ($ARGV[0] eq "-c") {
	$config_path = $ARGV[1];
	shift; shift;
}
&show_usage() if (scalar(@ARGV)!=3);

my ($zfs, $backupprefix, $lev) = @ARGV;

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

# read backup history DB
my $FILE;
if (open(FILE, $backup_history)) {
	while (<FILE>) {
		if (m/^([^ ]*) ([^ ]*) ([^ ]*) ([^ \n\r]*)$/) {
			my %hash = (
				'zfs' => $1,
				'snap' => $2,
				'lev' => $3,
				'date' => $4,
				);
			# print $hash{'zfs'} . "\n";
			# print $hash{'snap'} . "\n";
			if ($hash{'zfs'} eq $zfs) {
				push @dumphistory, {%hash};
			} else {
				push @dumphistory_other, {%hash};
			}
		}
	}
	close(FILE);
} else {
	print STDERR "WARNING: $backup_history does not exist.\n";
}

my $firstbackup = 0;
my $diff_msg = "";
if (scalar(@dumphistory)<1) {
	$diff_msg = "not found, forcing level 0 backup";
	$lev = 0;
	$firstbackup = 1;
} else {
	my %l = %{$dumphistory[scalar(@dumphistory)-1]};
	$diff_msg = "level " . $l{'lev'} . " on " . $l{'date'}
}

printf ("[%s] Backup started at %s.\n", $zfs, &time_now());
printf ("\tthis: level %s %s\n", $lev, $timenow);
print "\tlast: " . $diff_msg . "\n";

my $file_extension = "$lev";
my $compression_pipe = "";
my $encrypt_pipe = "";
if ($use_pigz) {
	$file_extension .= ".gz";
	$compression_pipe = "| $pigz_path -c -p $pigz_cpu_num ";
}
if ($use_gzip) {
	$file_extension .= ".gz";
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

my $snapname = sprintf ("L%1d-%s", $lev, $timenow);

# calculate diff level

my $difflevel = 10;
my $diffsnap = "";
if ($lev > 0) {
	my $d;
	my $diffdate;
	for ($d = $#dumphistory; $d>=0; $d--) {
		if ($dumphistory[$d]{'lev'}<$lev) {
			$difflevel = $dumphistory[$d]{'lev'};
			$diffsnap = $dumphistory[$d]{'snap'};
			$diffdate = $dumphistory[$d]{'date'};
			last;
		}
	}

	if ($difflevel == 10) {
		print STDERR "*** FATAL: No previous diff dump found in table.\n";
		exit 1;
	}

	print "\tdiff dump: level " . $difflevel . " on " . $diffdate . "\n";
}

# start dump
my $sendcmd1 = "/sbin/zfs snapshot " . $zfs . "@" . $snapname;
my $sendcmd2;
if ($lev == 0) {
	$sendcmd2 = "/sbin/zfs send " . $zfs . "@" . $snapname;
} else {
	$sendcmd2 = "/sbin/zfs send -i $diffsnap " . $zfs . "@" . $snapname;
}

if ($use_ssh) {
	system("ssh", "-o", "Compression=no", $ssh_backup_user . "\@" . $ssh_backup_host, "mv $ssh_remotedir/$backupprefix.$file_extension $ssh_remotedir/$backupprefix.$file_extension.old");
} else {
	system("mv $localdir/$backupprefix.$file_extension $localdir/$backupprefix.$file_extension.old");
}
print "\tmaking snapshot...\n";
system("sh", "-c", $sendcmd1);
if ($use_ssh) {
	print "\tsending to: $ssh_backup_host\n";
	system("sh", "-c", "$sendcmd2 $compression_pipe $encrypt_pipe | ssh -o Compression=no " . $ssh_backup_user . "\@" . $ssh_backup_host . " 'cat - > $ssh_remotedir/$backupprefix.$file_extension'");
} else {
	print "\tsaving in: $localdir\n";
	system("sh", "-c", "$sendcmd2 $compression_pipe $encrypt_pipe > $localdir/$backupprefix.$file_extension");
}

# tidy up old dumps and write out backup history DB
if (open(FILE, ">$backup_history")) {

	my $d;
	for ($d=0; $d<scalar(@dumphistory); $d++) {
		if ($dumphistory[$d]{'lev'}!=$lev) {
			printf FILE "%s %s %s %s\n",
				$dumphistory[$d]{'zfs'},
				$dumphistory[$d]{'snap'},
				$dumphistory[$d]{'lev'},
				$dumphistory[$d]{'date'};
		} else {
			my $dest_snap=$dumphistory[$d]{'snap'};
			if (length($dest_snap)>0) {
				if ($dest_snap eq $snapname) {
					print "\tskipping deleting $dest_snap (this is the latest backup).";
					next;
				}
				print "\tdeleting backup: $dest_snap\n";
				my $destroycmd = "/sbin/zfs destroy -f " . $zfs .
					"@" . $dest_snap;
				system($destroycmd);
			}
		}
	}
	printf FILE "%s %s %s %s\n", $zfs, $snapname, $lev, $timenow;

	for ($d=0; $d<scalar(@dumphistory_other); $d++) {
		printf FILE "%s %s %s %s\n",
			$dumphistory_other[$d]{'zfs'},
			$dumphistory_other[$d]{'snap'},
			$dumphistory_other[$d]{'lev'},
			$dumphistory_other[$d]{'date'};
	}
	close(FILE);
	printf("\tfinished at: %s\n", &time_now());

} else {
	print STDERR "*** FATAL: Could not write $backup_history.\n";
	exit 1;
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

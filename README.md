# ZFS Backup Scripts

This is a collection of backup scripts for ZFS (as found
on [FreeBSD][]).

*Disclaimer:* Please take a look at the scripts before running them.
Be aware that they might erase something, because they are programmed
to tidy up after themselves. In case of errors, I cannot be held
responsible in any manner in case when something has been lost.
Don't run the scripts, if you are unsure.

If you want to take a deeper look what happens, you can set
the variable `$verbose` to `1`. The scripts will dump more
information on what they are doing.

## backup-zfs-fast.pl

This script backups exactly one ZFS dataset. It supports incremental
backups. The backup levels are calculated automatically. A level 0
backup is performed every 4 weeks.

### Prerequisites

The script needs the Perl module
[Config::Simple](http://search.cpan.org/~sherzodr/Config-Simple-4.59/Simple.pm).

Please make sure, you adapt the absolute paths of the required
utilities in the script. The settings are prepared for
[FreeBSD][] operating system.

If you want to use `pigz` or `gnupg`, please install the relevant packages.

### Command line syntax

```
backup-zfs-fast.pl [ -c configpath ] zfsname prefix
```

`zfsname` is the dataset to backup. `prefix` is the filename prefix for the
backup file. Call the command with `nice` to avoid spikes in load.

### Configuration<a name="backupconf"></a>

The configuration is optional is specified by `-c configpath`.
If not specified (or empty) a backup will be stored locally in directory
`/mnt/backups`.

The following parameters can be configured.

#### For SSH piped backups

```
use_ssh 1
ssh_backup_user username
ssh_backup_host remotehost.example.org
ssh_remotedir /path/to/backup/directory
ssh_ping_backup_host 0
```

If `use_ssh` is set to 1, the backup won't be stored locally, but
piped through the ssh command that logs in into a remote server
given by `ssh_backup_host` and user login `ssh_backup_user`.
The backup will be stored in the directory `ssh_remotedir`. Please
make sure that the SSH user has got write access there.

If `ssh_ping_backup_host` is set, the script will try to ping
the remote server specified by `ssh_backup_host` prior to login.
If the ping fails (only 1 try), the backup procedure will be aborted.

#### Backup to locally mounted directory

If not using SSH, the backup will be stored in a local directory.
Note that it might be also an NFS mountpoint.

```
local_dir /path/to/backup/directory
```

#### Compression options

It is possible to compress the backup on-the-fly using `pigz` or
`gzip`. Make sure `pigz` is installed. It is not allowed to specify
both methods at once. When choosing `pigz`, it is further possible
to specify the number of cores to use with the `pigz_cpu_num` parameter.

```
use_pigz 1
pigz_cpu_num 6
use_gzip 0
```

Compression makes backups slower.

#### Encryption options

Furthermore, it is possible to encrypt the backup (after the optional
compression).

With AES-128-CBC (quite fast):

```
use_aes 1
aes_passfile ~/.aes_passphrase
```

`aes_passfile` contains the password in the first line of the text file

or with GPG (makes backups a lot slower!):

```
use_gpg 1
gpg_dir ~/.gnupg
gpg_key backupadmin@example.org
```

`gpg_dir` gives the location where your `gpg` keyring is stored.
`gpg_key` is the key to use for encryption.

## backup-zfs-all.pl

A wrapper for `backup-zfs-fast.pl` that examines the
ZFS datasets in use and backups them all in a non-conflicting
manner.

### Prerequisites

There are some paths in the script which you need to adapt, if
you are not using [FreeBSD][].

### Command line syntax

```
backup-zfs-all.pl [ -i ignorelist ] [ -c backup-configuration ] poolname hostname
```

`poolname` is the pool which is to be handled. `hostname` will be used for
building the backup name prefix.

The `backup-configuration` is optional, but almost always needed and will
be passed to `backup-zfs-fast.pl` as parameter. The format is explained
<a href="#backupconf">here</a>.

#### Ignore list

The option `-i` specifies the ignore list file. This file consists of lines
all specifying a regex pattern of ZFS datasets to ignore.

Examples:

```
$pool/var/crash
pool/tmp
$pool.*usr.*
```

`$pool` will be replaced by the `poolname` specified on the command line.
Please make sure there are no useless lines. Every single line should be
filled with a pattern to match (`^`pattern`$` is implied).

## snap-man.pl

A simple snapshot manager that generates Samba compliant
snapshot names to include them directly into the shadow copy
mechanism to have a "Recent versions" tab for Windows users.

### Command line syntax

```
snap-man.pl snapshot-configuration
```

The script needs exactly one parameter which is the snap-man
configuration.

### Configuration

The configuration has one entry per line. No unused lines
will be tolerated.

Example:

```
pool/usr/home 10
pool/var 5
```

First part of the line is the ZFS dataset. The second part is
the number of snapshots to keep. Please be aware that the script
has a special snapshot naming schema and only matching snapshot
names will be counted, so you can safely make your own snapshot
without being afraid that they will be destroyed at some time.

## diff-man.sh

This script takes a snapshot of its last run and compares the
changes on the given ZFS dataset. It writes the changes to
an output file.

If you have multiple datasets and/or multiple users, you can
send a choice of the outputs individually. You need a script
to do this, of course.

### Command line syntax

```
diff-man.sh zfs-dataset outputfile
```

* `zfs-dataset` is the ZFS dataset name to watch
* `outputfile` is the file that contains the `zfs diff` output which may be empty

When the diff is empty, the headers are also removed, so the calling
script can detect 0-sized diffs more easily.

[FreeBSD]: http://www.freebsd.org/ "FreeBSD operating system"

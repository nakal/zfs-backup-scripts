#!/bin/sh

if [ $# -ne 2 ]; then
	echo "Syntax:"
	echo "	$0 zfs-dataset outputfile"
	echo ""
	echo "This script writes changes on zfs-dataset since last run"
	echo "to file outputfile. The output files from multiple datasets"
	echo "are meant to be concatenated individually and sent to multiple"
	echo "users. You can save runtime, disk space and excessive emails"
	echo "in this way."
	exit 1
fi

ZFSDATASET="$1"
OUTPUT="$2"

if [ "$USER" != "root" ]; then
	echo "This script needs to be run as root." >&2
	exit 1
fi

PATH=/sbin:/bin:/usr/sbin:/usr/bin

DIFFMANSNAP="$ZFSDATASET@diffman"
if zfs list -H -o name "$DIFFMANSNAP" >/dev/null 2>&1; then
	DIFFDATE=`zfs get -H -o value creation $DIFFMANSNAP`
	zfs diff -H "$DIFFMANSNAP" | grep -v '/<xattrdir>' > "$OUTPUT.diffman"
	cat /dev/null > "$OUTPUT"
	if [ -s "$OUTPUT.diffman" ]; then
		echo "=== [$ZFSDATASET] changed since $DIFFDATE ===" >> "$OUTPUT"
		echo "" >> "$OUTPUT"
		cat "$OUTPUT.diffman" >> "$OUTPUT"
		echo "" >> "$OUTPUT"
	fi
	rm -f "$OUTPUT.diffman"
	zfs destroy "$DIFFMANSNAP"
else
	if ! zfs list -H -o name "$ZFSDATASET" >/dev/null 2>&1; then
		echo "No such ZFS dataset: $ZFSDATASET" >&2
		exit 1
	fi
fi
zfs snapshot "$DIFFMANSNAP"

exit 0

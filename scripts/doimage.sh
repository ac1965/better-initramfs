#!/bin/bash

workdir="$(readlink -f $(dirname $0))"
arch=$1
kernelver=$2
cpiof="initramfs-better-$arch-$kernelver"

. $workdir/core.sh || exit 1

$sudo cp -ar /etc/ld.so.conf* "$initramfs_root"/etc
$sudo ldconfig -r "$initramfs_root"

( cd $initramfs_root && find . | $sudo cpio --quiet -H newc -o | gzip -9 > ../$cpiof)

if [[ -f $initramfs_root/../$cpiof ]]; then
	einfo "$cpiof is ready."
else
	die "There is no $cpiof, something goes wrong."
fi

#!/bin/bash

set -e

workdir="$(readlink -f $(dirname $0))"
. $workdir/core.sh || exit 1

ver="$(cat $workdir/../VERSION)"
arch="x86"
kernelver="`uname -r`"

einfo "better-initramfs v${ver} - home page: http://slashbeast.github.com/better-initramfs/"
ewarn "Remember to check ChangeLog file after every update.\n"

bin() {
[ -d ${initramfs_root}/bin ] && \
	(ewarn "cleanup binary files"; $sudo rm -fr ${initramfs_root}/bin; mkdir -p ${initramfs_root}/bin) || mkdir -p ${initramfs_root}/bin 
[ -d ${initramfs_root}/lib ] && \
	(ewarn "cleanup library files"; $sudo rm -fr ${initramfs_root}/lib; mkdir -p ${initramfs_root}/lib) || mkdir -p ${initramfs_root}/lib 

einfo 'Preparing binary files...'
$sudo $workdir/dobin /bin/busybox && \
	( cd $initramfs_root/bin && if [ ! -h sh ]; then $sudo ln -s busybox sh; fi && if [ ! -h bb ]; then $sudo ln -s busybox bb; fi)
$sudo $workdir/dobin /sbin/cryptsetup
$sudo $workdir/dobin /sbin/lvm.static lvm
$sudo $workdir/dobin /usr/sbin/dropbear
$sudo $workdir/dobin /usr/bin/dropbearkey
$sudo $workdir/dobin /usr/bin/dbclient
$sudo $workdir/dobin /usr/bin/dbscp
$sudo $workdir/dobin /sbin/ldconfig
$sudo $workdir/dobin /usr/bin/ldd
$sudo $workdir/dobin /usr/bin/strace
$sudo $workdir/dobin /sbin/blkid
$sudo $workdir/dobin /usr/bin/screen
}

etc() {
[ -d ${initramfs_root}/etc ] && \
	(ewarn "cleanup etc files"; $sudo rm -fr ${initramfs_root}/etc; mkdir -p ${initramfs_root}/etc) || mkdir -p ${initramfs_root}/etc 

einfo 'Preparing etc files...'
$sudo cp -p /etc/hosts ${initramfs_root}/etc
$sudo cp -p /etc/host.conf ${initramfs_root}/etc
$sudo cp -p /etc/localtime ${initramfs_root}/etc
$sudo cp -p /etc/nsswitch.conf ${initramfs_root}/etc
$sudo cp -p /etc/gai.conf ${initramfs_root}/etc
$sudo cp -pr /etc/pam.d ${initramfs_root}/etc
$sudo grep -e "^root" /etc/group > ${initramfs_root}/etc/group
$sudo grep -e "^root" /etc/passwd | sed s/\\/bash/\\/sh/ > ${initramfs_root}/etc/passwd
$sudo grep -e "^root" /etc/shadow > ${initramfs_root}/etc/shadow
$sudo sed -i 's/compat/files/' ${initramfs_root}/etc/nsswitch.conf
$sudo chown root:root ${initramfs_root}/etc/group
$sudo chown root:root ${initramfs_root}/etc/passwd
$sudo chown root:root ${initramfs_root}/etc/shadow
$sudo chmod 0600 ${initramfs_root}/etc/shadow
test -f $workdir/defaults/terminfo.tar.gz && $sudo tar xf $workdir/defaults/terminfo.tar.gz -C $initramfs_root
test -d ${initramfs_root}/etc/modules || mkdir -p ${initramfs_root}/etc/modules
source $workdir/defaults/arch/$arch/modules.conf
for group_modules in ${!MODULES_*}; do
    group="$(echo $group_modules | cut -d_ -f2 | tr "[:upper:]" "[:lower:]")"
    echo "${!group_modules}" > ${initramfs_root}/etc/modules/$group
done
}

lib() {
einfo 'Preparing library files...'
#for l in `ls /lib/libnss_* /lib/libpam.* /lib/libpam_*`; do
for l in `ls /lib/libnss_*`; do
    $sudo $workdir/dolib $l
done
test -d $initramfs_root/lib/keymaps || mkdir -p $initramfs_root/lib/keymaps
test -f $workdir/defaults/keymaps.tar.gz && $sudo tar xf $workdir/defaults/keymaps.tar.gz -C $initramfs_root/lib/keymaps
}

modules() {
    req_modules=$1
    [ -d ${initramfs_root}/lib/modules ] || $sudo mkdir -p ${initramfs_root}/lib/modules
    if [ -z $req_modules ]; then
        [ -f /usr/src/linux/include/config/kernel.release ] && modules=$(cat /usr/src/linux/include/config/kernel.release)
    else
        modules=$req_modules
    fi
    if [ -n $modules ]; then
        einfo "Install modules($modules) into initram."
        [ -d /lib/modules/$modules ] && $sudo cp -a /lib/modules/$modules $initramfs_root/lib/modules
    fi
}

image() {
	einfo 'Building image...'
	$workdir/doimage.sh $arch $kernelver
}

clean() {
	einfo 'Cleanup image...'
	$sudo rm -fr ${initramfs_root}/bin ${initramfs_root}/lib ${initramfs_root}/etc initramfs.cpio.gz
}

case $1 in
	bin|etc|image|clean|modules)
		$1
	;;
	all)
		bin && etc && lib && modules && image
	;;
esac

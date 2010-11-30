#!/bin/sh
# -*- mode: shell-script; coding: utf-8-emacs-unix; sh-basic-offset: 8; indent-tabs-mode: t -*-
# This code is under Simplified BSD License, see LICENSE for more info
# Copyright (c) 2010, Piotr Karbowski
# All rights reserved.

einfo() { echo -ne "\033[1;30m>\033[0;36m>\033[1;36m> \033[0m${@}\n" ;}
ewarn() { echo -ne "\033[1;30m>\033[0;33m>\033[1;33m> \033[0m${@}\n" ;}
eerror() { echo -ne "\033[1;30m>\033[0;31m>\033[1;31m> ${@}\033[0m\n" ;}

droptoshell() {
	if [ ! -e /dev/pty0 ]; then # CONFIG_LEGACY_PTYS=n
		einfo "Initiating /dev/pts (devtpts)."
		[ -d /dev/pts ] || mkdir -p /dev/pts
		if ! mount -t devpts /dev/pts /dev/pts 2>/dev/null; then # CONFIG_UNIX98_PTYS=n
			rm -fr /dev/pts
		fi
	fi

	initkeymap
	if [ $rescueshell = 'false' ]; then
		ewarn "Dropping to rescueshell because of above error."
	else
		use dodropbear && initdropbear
	fi
	ewarn "Rescue Shell (busybox's /bin/sh)"
	ewarn "To reboot, press 'control-alt-delete'."
	ewarn "If you wish continue booting process, just exit from this shell."
	/bin/sh

	[ -e /var/run/dropbear.pid ] && kill "$(cat /var/run/dropbear.pid)"

	if [ -d /dev/pts ]; then
		einfo "Unmount /dev/pts"
		umount /dev/pts
	fi
	pkill screen
}

run() { "$@" || ( eerror $@ 'failed.' ; droptoshell ) ;}

get_opt() {
	echo "$@" | cut -d "=" -f 2,3
}

resolve_device() {
	device=$(eval echo \$$1)

	case $device in
		LABEL\=*|UUID\=*)
			eval $1=$(findfs $device)
		;;
	esac
	
	if [ -z "$(eval echo \$$1)" ]; then
		eerror "Wrong UUID/LABEL."
		droptoshell
	fi
}

use() {
	name="$(eval echo \$$1)"
	if [ -n "$name" ] && [ "$name" = 'true' ]; then
		return 0
	else
		return 1
	fi
}

dodir() {
	for dir in $*; do
		mkdir -p $dir
	done
}

initluks() {
	if [ ! -f /bin/cryptsetup ]; then
		eerror "There is no cryptsetup binary into initramfs image."
		droptoshell
	fi

	if [ -z $enc_root ]; then
		eerror "You have enabled luks but your \$enc_root variable is empty."
		droptoshell
	fi
	
	einfo "Opening encrypted partition and mapping to /dev/mapper/enc_root."
	resolve_device enc_root
	if [ -z $enc_root ]; then
        	eerror "\$enc_root variable is empty. Wrong UUID/LABEL?"
	        droptoshell
	fi

	# Hack for cryptsetup which trying to run /sbin/udevadm.
	run echo -e "#!/bin/sh\nexit 0" > /sbin/udevadm
	run chmod 755 /sbin/udevadm

	cryptsetup_options=""
	mntkey="/mnt/key"
	if [ -n "$enc_root_keydev" ] && [ -n "$enc_root_keyfile" ]; then
		resolve_device enc_root_keydev
		if [ -b $enc_root_keydev ]; then
			einfo "Using key device=$enc_root_keydev"
		else
                	count=30 # wait 30sec
                	ewarn "Please insert removable device ${enc_root_keydev} during the ${count} seconds."
                	while [ ${count} -gt 0 ]; do
                    		count=$((count-1))
				sleep 1
                    		if [ -b $enc_root_keydev ]; then
                        		einfo "device (${enc_root_keydev}) detected."
					break
                    		fi
                	done
			if [ $count -eq 0 ]; then
				eerror "device (${enc_root_keydev}) not found."
				droptoshell
			fi
		fi
		[ -d $mntkey ] || mkdir -p $mntkey
                if mount -n -t auto -o ro $enc_root_keydev $mntkey >/dev/null 2>&1; then
                    	if [ -e "${mntkey}${enc_root_keyfile}" ]; then
                        	cryptsetup_options="-d ${mntkey}${enc_root_keyfile}"
                    	else
                        	ewarn "keyfile (${enc_root_keyfile}) not found, umount ${mntkey}"
                        	umount -n $mntkey
                    	fi
                fi
	fi

	run cryptsetup $cryptsetup_options luksOpen $enc_root enc_root
	if [ -n "$cryptsetup_options" ]; then
		einfo "Unmounting $mntkey"
        	umount -n $mntkey
	fi
}


initlvm() {
	einfo "Scaning all disks for volume groups."
	run lvm vgscan
	run lvm vgchange -a y
}

initmdadm() {
	einfo "Scaning for software raid arrays."
	mdadm --assemble --scan
	mdadm --auto-detect
}

dotuxonice() {
	if [ ! -z $resume ]; then
		if [ ! -f /sys/power/tuxonice/do_resume ]; then
			ewarn "Your kernel do not support TuxOnIce.";
		else
			einfo "Sending do_resume signal to TuxOnIce."
			run echo 1 > /sys/power/tuxonice/do_resume
		fi
	else
		ewarn "resume= variable is empty, not cool, skipping tuxonice."
	fi
}

mountdev() {
	einfo "Initiating /dev (devtmpfs)."
	if ! mount -t devtmpfs devtmpfs /dev 2>/dev/null; then
	ewarn "Unable to mount devtmpfs, missing CONFIG_DEVTMPFS? Switching to busybox's mdev."
	mdev_fallback="true"
	einfo "Initiating /dev (mdev)."
	run touch /etc/mdev.conf # Do we really need this empty file?
	run echo /sbin/mdev > /proc/sys/kernel/hotplug
	run mdev -s
	fi
}

mountroot() {
	mountparams="-o ro"
	if [ -n "$rootfstype" ]; then mountparams="$mountparams -t $rootfstype"; fi
	einfo "Mounting rootfs to /newroot."
	resolve_device root
	run mount $mountparams "${root}" /newroot
}

bootstrap_setups() {
	cat > /etc/ld.so.conf <<EOF
/lib
/lib64
/usr/lib
/usr/lib64
EOF
	ldconfig
	touch /var/log/lastlog
	touch /var/run/utmp
	chmod 600 /etc/shadow
	touch /etc/resolv.conf
}

initdropbear() {
	if [ -n "$dropbearip" ]; then
       		einfo "Try getting IPaddress (${dropbearip})."
        	run ifconfig eth0 $dropbearip up >/dev/null 2>&1
	else
		einfo "Bring up DHCP..."
		run udhcpc
	fi
	getip=$(ip a | grep eth0 | grep inet | sed 's/  //g' | cut -d' ' -f 2)
	if [ -n ${getip} ]; then
		einfo "NIC get IPaddress (${getip})."
            	if [ -x /bin/dropbear ]; then
			for f in /bin/dbclient /bin/dbscp; do
				test -x $f && ln -sf $f /usr/bin
			done
                	run hostname mybox
			
			 # make banner
                	[ ! -e /etc/dropbear/ ] && mkdir -p /etc/dropbear
			cat > /etc/dropbear/banner <<EOF

------------------------------------------------------------
	better-iinitramfs v${ver}
	kernel ${kernelver}

------------------------------------------------------------

EOF
			 # make hostkey
			[ ! -e /etc/dropbear/dropbear_dss_host_key ] && (
				einfo "Generating DSS-Hostkey..."
				dropbearkey -t dss -f /etc/dropbear/dropbear_dss_host_key >/dev/null 2>&1
			)
			[ ! -e /etc/dropbear/dropbear_rsa_host_key ] && (
                    		einfo "Generating RSA-Hostkey..."
                    		dropbearkey -t rsa -f /etc/dropbear/dropbear_rsa_host_key >/dev/null 2>&1
                	)
			
                	einfo "Starting dropbear"
                	dropbear -b /etc/dropbear/banner -F 2>&1 | tee /var/run/dropbear.log > /dev/tty10 &
            	fi # -x /bin/dropbear
	fi
}

initkeymap() {
	if [ -e /lib/keymaps/${keymap}.map ]; then
		einfo "Loading the ''${keymap}'' keymap"
		loadkmap < /lib/keymaps/${keymap}.map
	elif [ -z $keymap ]; then
		ewarn "default keymap use."
	else
		ewarn "invalid keymap ''${keymap}''"
		cat /lib/keymaps/keymapList
		read -t 10 -p '<< Load keymap (Enter for default): ' keymap
		case ${keymap} in
			1|azerty) keymap=azerty ;;
			2|be) keymap=be ;;
			3|bg) keymap=bg ;;
			4|br-a) keymap=br-a ;;
			5|br-l) keymap=br-l ;;
			6|by) keymap=by ;;
			7|cf) keymap=cf ;;
			8|croat) keymap=croat ;;
			9|cz) keymap=cz ;;
			10|de) keymap=de ;;
			11|dk) keymap=dk ;;
			12|dvorak) keymap=dvorak ;;
			13|es) keymap=es ;;
			14|et) keymap=et ;;
			15|fi) keymap=fi ;;
			16|fr) keymap=fr ;;
			17|gr) keymap=gr ;;
			18|hu) keymap=hu ;;
			19|il) keymap=il ;;
			20|is) keymap=is ;;
			21|it) keymap=it ;;
			22|jp) keymap=jp ;;
			23|la) keymap=la ;;
			24|lt) keymap=lt ;;
			25|mk) keymap=mk ;;
			26|nl) keymap=nl ;;
			27|no) keymap=no ;;
			28|pl) keymap=pl ;;
			29|pt) keymap=pt ;;
			30|ro) keymap=ro ;;
			31|ru) keymap=ru ;;
			32|se) keymap=se ;;
			33|sg) keymap=sg ;;
			34|sk-y) keymap=sk-y ;;
			35|sk-z) keymap=sk-z ;;
			36|slovene) keymap=slovene ;;
			37|trf) keymap=trf ;;
			38|trq) keymap=trq ;;
			39|ua) keymap=ua ;;
			40|uk) keymap=uk ;;
			41|us) keymap=us ;;
			42|wangbe) keymap=wangbe ;;
		esac
		loadkmap < /lib/keymaps/${keymap}.map
	fi
}

#!/bin/sh
#
# god - minirc with better CRUX support and sinit
# onodera, https://github.com/onodera-punpun


## CONFIGURATION

# Fallback Configuration Values, to be able to run even with a broken, deleted or outdated minirc.conf
DAEMONS="iptables alsa crond dbus wpa_supplicant dhcpcd acpid"
ENABLED="@dhcpcd"
NETWORK_INTERFACE="eth0"
WIFI_INTERFACE="wlan0"

# User-definable start/stop/restart/poll functions which fall back to defaults
custom_restart() { default_restart "$@"; }
custom_start()   { default_start   "$@"; }
custom_stop()    { default_stop    "$@"; }
custom_poll()    { default_poll    "$@"; }

# Source config
. /etc/god.conf


## FUNCTIONS

# This function defines all the stuff that happens on boot
on_boot() {
	echo -e "\nDear God, dear God, tinkle tinkle hoy!\n"

	echo Mounting API filesystem.
	mountpoint -q /proc  || mount -t proc proc /proc -o nosuid,noexec,nodev
	mountpoint -q /sys   || mount -t sysfs sys /sys -o nosuid,noexec,nodev
	mountpoint -q /run   || mount -t tmpfs run /run -o mode=0755,nosuid,nodev
	mountpoint -q /dev   || mount -t devtmpfs dev /dev -o mode=0755,nosuid
	mkdir -p /dev/pts /dev/shm
	mountpoint -q /dev/pts || mount -t devpts devpts /dev/pts -o mode=0620,gid=5,nosuid,noexec
	mountpoint -q /dev/shm || mount -t tmpfs shm /dev/shm -o mode=1777,nosuid,nodev

	echo Creating tmpfs.
	mount -t tmpfs tmpfs /tmp -o mode=1777,nosuid,nodev

	echo Setting up loopback device.
	/sbin/ip link set up dev lo

	echo Initializing eudev.
	/sbin/udevd --daemon
	/sbin/udevadm trigger --action=add --type=subsystems
	/sbin/udevadm trigger --action=add --type=devices

	echo Setting hostname.
	echo $HOSTNAME >| /proc/sys/kernel/hostname

	echo Setting system clock.
	/sbin/hwclock --hctosys

	echo Mounting fstab.
	mount -a
	mount -o remount,rw /

	echo Starting daemons.
	for dmn in $ENABLED; do
		if [ $(echo $dmn | awk '{ s=substr($0, 1, 1); print s; }') = '@' ]; then
			custom_start $(echo $dmn | awk '{ s=substr($0, 2); print s; }') &
		else
			custom_start "$dmn"
		fi
	done

	/sbin/agetty --noclear --login-pause -8 -s 38400 tty1 linux &
	/sbin/agetty -8 -s 38400 tty2 linux &
	/sbin/agetty -8 -s 38400 tty3 linux &
}

# This function defines all the stuff that happens on shutdown
on_shutdown() {
	echo Stopping daemons.
	custom_stop all

	echo Shutting down eudev.
	killall udevd

	 echo Sending all processes the TERM signal.
	/sbin/busybox killall5 -TERM
	sleep 3

	echo Sending all processes the KILL signal.
	/sbin/busybox killall5 -KILL

	echo Unmounting API filesystem.
	umount -r /run

	echo Unmounting fstab.
	umount -a -r

	echo Remounting root read-only.
	mount -o remount,ro /
}

# This function starts daemons
default_start() {
	echo Starting "$1".

	case "$1" in
		all)
			for dmn in $DAEMONS $ENABLED; do
				custom_poll "${dmn##@}" || custom_start "${dmn##@}"
			done
			;;
		alsa)
			alsactl restore
			;;
		bitlbee)
			su -s /bin/sh -c 'bitlbee -F' bitlbee
			;;
		# TODO: Fix for CRUX
		dbus)
			mkdir -p /run/dbus
			bus-uuidgen --ensure 
			dbus-daemon --system
			;;
		iptables)
			iptables-restore < /etc/iptables/iptables.rules
			;;
		sshd)
			/usr/bin/sshd
			;;
		# TODO: Use sdhcp
		dhcpcd)
			if ip link | grep -Fq $NETWORK_INTERFACE; then :; else
				echo "Waiting for $NETWORK_INTERFACE to settle."
				for i in $(seq 100); do
					ip link | grep -Fq $NETWORK_INTERFACE
					break

					sleep 1
				done
			fi

			dhcpcd -nqb
			;;
		ntpd)
			ntpd -g -u ntp
			;;
		wpa_supplicant)
			wpa_supplicant -Dwext -B -i"$WIFI_INTERFACE" -c/etc/wpa_supplicant.conf
			;;
		*)
			# Fallback: start the command
			"$1"
			;;
	esac
}

# This function stops daemons
default_stop() {
	echo Stopping "$1".

	case "$1" in
		all)
			for dmn in $DAEMONS $ENABLED; do
				custom_poll "${dmn##@}"
				custom_stop "${dmn##@}"
			done
			;;
		alsa)
			alsactl store
			;;
		# TODO: Fix for CRUX
		dbus)
			killall dbus-launch
			killall dbus-daemon
			# TODO: Check out why the /run doesn't work
			rm /var/run/dbus/dbus.pid
			rm /run/dbus/pid
			;;
		iptables)
			for table in $(cat /proc/net/ip_tables_names); do
				iptables-restore < /var/lib/iptables/empty-$table.rules
			done
			;;
		*)
			# Fallback: kill all processes with the name of the command
			killall "$1"
			;;
	esac
}

# This function restarts daemons
default_restart() {
	case "$1" in
		*)
			custom_stop "$@"
			custom_start "$@"
			;;
	esac
}

# This function checks daemon status
default_poll() {
	case "$1" in
		alsa)
			# Doesn't make much sense for this service
			return 0
			;;
		iptables)
			iptables -L -n | grep -m 1 -q '^ACCEPT\|^REJECT'
			;;
		# TODO: Fix for CRUX
		dbus)
			#test -e /run/dbus/pid;;
			test -e /var/run/dbus/dbus.pid
			;;
		*)
			# Fallback: check if any processes of that name are running
			pgrep "(^|/)$1\$" >/dev/null 2>&1
			;;
	esac
}

# This fucntion echoes stuff in color
echo_color() {
	color="$1"
	shift
	text="$@"
	printf "\033[1;3${color}m$text\033[00m\n"
}


## EXECUTE

case "$1" in
	-h|--help)
		self=$(basename "$0")
		echo -e "Usage: god [options]\n"
		echo "options:"
		echo "  -l,   --list            list daemons"
		echo "        --start           starts daemons"
		echo "        --stop            stops daemons"
		echo "        --restart         restars daemons"
		echo "        --init            boots system, don't use this"
		echo "        --shutdown        shutdown system"
		echo "        --reboot          reboots system"
		echo "  -v,   --version         print version and exit"
		echo "  -h,   --help            print help and exit"
		;;
	-v|--version)
		echo god 0.1
		;;
	-l|--list)
		for dmn in $DAEMONS; do
			if custom_poll "$dmn" >/dev/null 2>&1; then
				echo_color 2 [X] $dmn
			else
				echo_color 0 [ ] $dmn
			fi
		done
		;;
	--start|--stop|--restart)
		cmd="$1"

		shift
		for dmn in ${@:-$DAEMONS}; do
			custom_${cmd} "$dmn"
		done
		;;
	--init)
		on_boot
		;;
	--shutdown)
		on_shutdown
		/sbin/busybox poweroff -f
		;;
	--reboot)
		on_shutdown
		/sbin/busybox reboot -f
		;;
	--suspend)
		echo mem > /sys/power/state
		;;
	*)
		echo Invalid option, use -h for help.
		exit 1
		;;
esac

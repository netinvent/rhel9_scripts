#!/usr/bin/env bash

## Readonly setup script 2024013001 for RHEL9

# Requirements:
# RHEL9 installed

script_dir=$(pwd)
result=0

target="${1:-false}"

if [ "${target}" != "ztl" ] && [ "${target}" != "hv" ]; then
    echo "Target needs to be ztl or hv"
    exit 1
 fi

dnf install -y readonly-root

echo "#### Setting up readonly root ####"

# We can add "noreadonly" as kernel argument to bypass readonly root

# Disable unused systemd service that will fail
systemctl disable man-db-restart-cache-update.service

# Enable readonly root
sed -i 's/READONLY=no/READONLY=yes/g' /etc/sysconfig/readonly-root

# Change default label of stateful partition to something less than 15 chars so XFS can hold that label
# Thos should already be set by the VMv4 kickstart file
sed -i 's/STATE_LABEL=stateless-state/STATE_LABEL=STATEFULRW/g' /etc/sysconfig/readonly-root

rm -f /etc/statetab.d/{snmp,nm,qemu,cockpit,log,ztl}
rm -f /etc/rwtab.d/{tuned,issue,rsyslog,node_exporter,cockpit,ztl,haproxy}
# statetab will be persistent volumes stored on a partition which label must match the
# STATE_LABEL= directive in /etc/sysconfig/readonly-root (defaults to stateless-state)
# Those dirs are stateful accross reboots
# Keep in mind we need to label a partition with
# xfs_admnin -L STATEFULRW /dev/disk/by-uuid/{some_uuid}
# find uuid with lsblk -f
echo "/etc/snmp" >> /etc/statetab.d/snmp
echo "/etc/NetworkManager/system-connections" >> /etc/statetab.d/nm
echo "/etc/prometheus" >> /etc/statetab.d/prometheus
echo "/var/lib/prometheus" >> /etc/statetab.d/prometheus
if [ "${target}" == "hv" ]; then
    echo "Configuring specific HV Stateless"
    echo "/var/lib/libvirt" >> /etc/statetab.d/qemu
    echo "/etc/libvirt" >> /etc/statetab.d/qemu
    # For DNF to work we'd need /var/cache/dnf but obviously we won't
    echo "/etc/pcp" >> /etc/statetab.d/cockpit   # cockpit
fi

# Keep logs persistent too
echo "/var/log" > /etc/statetab.d/log
sed -i 's:dirs\(.*\)/var/log:#/dirs\1/var/log # Configured in /etc/statetab to be persistent:g' /etc/rwtab

# Those dirs are stateful until reboot
# Size is 1/2 of system RAM
echo "dirs /var/log/tuned" >> /etc/rwtab.d/tuned
echo "files /etc/issue" >> /etc/rwtab.d/issue
echo "dirs /var/lib/rsyslog" >> /etc/rwtab.d/rsyslog
echo "dirs /var/lib/node_exporter/textfile_collector"  > /etc/rwtab.d/node_exporter
echo "dirs /var/lib/pcp" >> /etc/rwtab.d/cockpit        # cockpit
echo "dirs /var/lib/dnf" >> /etc/rwtab.d/cockpit        # cockpit packagekit (dnf cache)
echo "dirs /var/cache" >> /etc/rwtab.d/cockpit          # cockpit packagekit (dnf cache)

if [ "${target}" == "ztl" ]; then
    echo "Configuring specific ZTL stateless"
    echo "dirs /etc/wireguard" >> /etc/rwtab.d/ztl
    echo "dirs /var/lib/haproxy" >> /etc/rwtab.d/haproxy
    echo "/etc/firewalld/zones" >> /etc/statetab.d/ztl
    echo "/var/ztl" >> /etc/statetab.d/ztl
    echo "/etc/systemd/system" >> /etc/statetab.d/ztl

    echo "dirs /var/ztl_upgrade" >> /etc/rwtab.d/ztl
    echo "dirs /etc/wireguard" >> /etc/rwtab.d/ztl
    echo "files /etc/issue" >> /etc/rwtab.d/ztl
    echo "dirs /var/lib/haproxy" >> /etc/rwtab.d/haproxy
fi

# Optional for xauth support
#echo "files /root" >> /etc/rwtab.d/xauth                # X11 forwarding (xauth)
# NPF-MOD-USER: Change the username to whatever fits !!!
#echo "files /home/npfmonitor" >> /etc/rwtab.d/xauth     # X11 forwarding (xauth) user


# Update grub to add ro and remove rw
grubby --update-kernel=ALL --args="ro"
grubby --update-kernel=ALL --remove-args="rw"
grub2-mkconfig -o /boot/grub2/grub.cfg

# Make sure we mount any xfs filesystems as ro (/boot and /)
# This won't affect the stateful label mounted devices

# Don't touch swap or fat FS. Change mount options for any mountpoint containing images, Change all other mountpoints to ro and add noexec,nosuid,nodev
 awk -i inplace '{
    if ($1 ~ "^#" || $1 == "") { print $0; next };                                  # Skip commented / empty lines
    if ($3 ~ "swap") { print $0; next };                                            # Skip swap FS
    if ($3 ~ "fat") { next };                                                       # Skip fat (vfat) FS (efi)
    if ($2 ~ "images") { $4="defaults,rw,noexec,nosuid,nodev"; print $0; next };    # Change defaults to /*/images mountpoints
    if ($2 != "/" && $4 !~ "noexec") { $4=$4",noexec" };                            # Add noexec to all except /
    if ($2 != "/" && $4 !~ "nosuid") { $4=$4",nosuid" };                            # Add nosuid to all except /
    if ($2 != "/" && $4 !~ "nodev") { $4=$4",nodev" };                              # Add nodev to all except /
    if ($4 !~ "ro|rw") { $4=$4",ro" };                                              # Update any rw instance to ro
    sub("rw","ro"); print $0
}' /etc/fstab
#sed -i 's/xfs\(\s*\)defaults/xfs\1defaults,ro/g' /etc/fstab
# Also remount all vfat systems (/boot/efi) if exist as ro
#sed -i 's/vfat\(\s*\)/vfat\1ro,/g' /etc/fstab


# Fix for statetab file not supporting space in dir nam
# See our PR at https://github.com/fedora-sysv/initscripts/pull/471
# Patch created via  diff -auw /usr/libexec/readonly-root /tmp/readonly-root > /tmp/readonly-root.npf.patch
dnf install -y patch
cat << 'EOF' > /tmp/readonly-root.npf.patch
--- /usr/libexec/readonly-root  2022-08-24 10:42:13.000000000 +0200
+++ /tmp/readonly-root  2024-01-23 13:20:36.167603560 +0100
@@ -1,4 +1,4 @@
-#!/usr/bin/bash
+#!/bin/bash
 #
 # Set up readonly-root support.
 #
@@ -184,17 +184,17 @@
                                mount -n --bind $bindmountopts "$STATE_MOUNT/$file" "$file"
                        fi

-                       for path in $(grep -v "^#" "$file" 2>/dev/null); do
+                       while read path ; do
                                mount_state "$path"
                                selinux_fixup "$path"
-                       done
+                       done < <(grep -v "^#" "$file" 2>/dev/null)
                done

                if [ -f "$STATE_MOUNT/files" ] ; then
-                       for path in $(grep -v "^#" "$STATE_MOUNT/files" 2>/dev/null); do
+                       while read path ; do
                                mount_state "$path"
                                selinux_fixup "$path"
-                       done
+                       done < <(grep -v "^#" "$STATE_MOUNT/files" 2>/dev/null)
                fi
        fi

EOF
patch -l /usr/libexec/readonly-root < /tmp/readonly-root.npf.patch



## Post install
# Remove /etc/resolv.conf file since we don't want it in our image
# See man NetworkManager.conf rc-manager for more info about this
[ -f /etc/resolv.conf ] && rm -f /etc/resolv.conf
ln -s /run/NetworkManager/resolv.conf /etc/resolv.conf

echo "System is now readonly"
echo ""
echo "On modifications, please use 'mount -o remount,rw /'"
echo ""
echo "Once finished, please seal system with command"
echo ""
echo "rm -f ~/.bash_history; history -c; reboot"

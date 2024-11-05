#!/usr/bin/env bash

## Readonly setup script 2024110501 for RHEL9

# Requirements:
# RHEL9 installed

LOG_FILE=/root/.npf-readonly.log
SCRIPT_GOOD=true

function log {
    local log_line="${1}"
    local level="${2}"

    if [ "${level}" != "" ]; then
        log_line="${level}: ${log_line}"
    fi
    echo "${log_line}" >> "${LOG_FILE}"
    echo "${log_line}"

    if [ "${level}" == "ERROR" ]; then
        SCRIPT_GOOD=false
    fi
}

function log_quit {
    log "${1}" "${2}"
    exit 1
}

target="${1:-false}"

if [ "${target}" != "ztl" ] && [ "${target}" != "hv" ]; then
    log_quit "Target needs to be ztl or hv"
 fi

dnf install -y readonly-root 2>> "${LOG_FILE}" || log_quit "Cannot install readonly_root"

echo "#### Setting up readonly root ####"

# We can add "noreadonly" as kernel argument to bypass readonly root

# Disable unused systemd service that will fail
systemctl disable man-db-restart-cache-update.service 2>> "${LOG_FILE}" || log "Cannot disable man-db-restart-cache-update.service" "ERROR"

# Enable readonly root
sed -i 's/READONLY=no/READONLY=yes/g' /etc/sysconfig/readonly-root  2>> "${LOG_FILE}" || log "Cannot enable readonly-root" "ERROR"

# Change default label of stateful partition to something less than 15 chars so XFS can hold that label
# Thos should already be set by the VMv4 kickstart file
sed -i 's/STATE_LABEL=stateless-state/STATE_LABEL=STATEFULRW/g' /etc/sysconfig/readonly-root  2>> "${LOG_FILE}" || log "Cannot change stateful label" "ERROR"

rm -f /etc/statetab.d/{snmp,nm,qemu,cockpit,rsyslog,prometheus,node_exporter,ztl} > /dev/null 2>&1
rm -f /etc/rwtab.d/{tuned,issue,ztl,haproxy,ztl} > /dev/null 2>&1
# statetab will be persistent volumes stored on a partition which label must match the
# STATE_LABEL= directive in /etc/sysconfig/readonly-root (defaults to stateless-state)
# Those dirs are stateful accross reboots
# Keep in mind we need to label a partition with
# xfs_admnin -L STATEFULRW /dev/disk/by-uuid/{some_uuid}
# find uuid with lsblk -f
echo "/etc/snmp" >> /etc/statetab.d/snmp || log "Cannot create /etc/statetab.d/snmp" "ERROR"
echo "/etc/NetworkManager/system-connections" >> /etc/statetab.d/nm || log "Cannot create /etc/statetab.d/nm" "ERROR"
echo "/etc/prometheus" >> /etc/statetab.d/prometheus || log "Cannot create /etc/statetab.d/prometheus" "ERROR"
echo "/var/lib/prometheus" >> /etc/statetab.d/prometheus || log "Cannot create /etc/statetab.d/prometheus" "ERROR"
echo "/var/lib/node_exporter"  >> /etc/statetab.d/node_exporter || log "Cannot create /etc/statetab.d/node_exporter" "ERROR"
echo "/var/lib/rsyslog" >> /etc/statetab.d/rsyslog || log "Cannot create /etc/statetab.d/rsyslog" "ERROR"
# cockpit
echo "/var/lib/pcp" >> /etc/statetab.d/cockpit || log "Cannot create /etc/statetab.d/cockpit" "ERROR"
echo "/etc/pcp" >> /etc/statetab.d/cockpit || log "Cannot create /etc/statetab.d/cockpit" "ERROR"
# dnf cache
echo "/var/lib/dnf" >> /etc/statetab.d/dnf || log "Cannot create /etc/statetab.d/dnf" "ERROR"
echo "/var/cache" >> /etc/statetab.d/dnf || log "Cannot create /etc/statetab.d/dnf" "ERROR"

if [ "${target}" == "hv" ]; then
    log "Configuring specific HV stateless settings"
    echo "Configuring specific HV Stateless" || log "Cannot configure HV stateless" "ERROR"
    echo "/var/lib/libvirt" >> /etc/statetab.d/qemu || log "Cannot create /etc/statetab.d/qemu" "ERROR"
    echo "/etc/libvirt" >> /etc/statetab.d/qemu || log "Cannot create /etc/statetab.d/qemu" "ERROR"
    # For DNF to work we'd need /var/cache/dnf but obviously we won't
    
    
fi

# Keep logs persistent too
echo "/var/log" > /etc/statetab.d/log || log "Cannot create /etc/statetab.d/log" "ERROR"
sed -i 's:dirs\(.*\)/var/log:#/dirs\1/var/log # Configured in /etc/statetab to be persistent:g' /etc/rwtab 2>> "${LOG_FILE}" || log "Cannot comment out /var/log in /etc/rwtab" "ERROR"

# Those dirs are stateful until reboot
# Size is 1/2 of system RAM
echo "dirs /var/log/tuned" >> /etc/rwtab.d/tuned || log "Cannot create /etc/rwtab.d/tuned" "ERROR"
echo "files /etc/issue" >> /etc/rwtab.d/issue || log "Cannot create /etc/rwtab.d/issue" "ERROR"

if [ "${target}" == "ztl" ]; then
    log "Configuring specific ZTL stateless settings"
    echo "dirs /etc/wireguard" >> /etc/rwtab.d/ztl || log "Cannot create /etc/rwtab.d/ztl" "ERROR"
    echo "dirs /var/lib/haproxy" >> /etc/rwtab.d/haproxy || log "Cannot create /etc/rwtab.d/haproxy" "ERROR"
    echo "/etc/firewalld/zones" >> /etc/statetab.d/ztl || log "Cannot create /etc/statetab.d/ztl" "ERROR"
    echo "/var/ztl" >> /etc/statetab.d/ztl || log "Cannot create /etc/statetab.d/ztl" "ERROR"
    echo "/etc/systemd/system" >> /etc/statetab.d/ztl || log "Cannot create /etc/statetab.d/ztl" "ERROR"
    echo "dirs /var/ztl_upgrade" >> /etc/rwtab.d/ztl || log "Cannot create /etc/rwtab.d/ztl" "ERROR"
fi

# Optional for xauth support
#echo "files /root" >> /etc/rwtab.d/xauth                # X11 forwarding (xauth)
# NPF-MOD-USER: Change the username to whatever fits !!!
#echo "files /home/npfmonitor" >> /etc/rwtab.d/xauth     # X11 forwarding (xauth) user


# Update grub to add ro and remove rw
grubby --update-kernel=ALL --args="ro" || log "Cannot update kernel to ro" "ERROR"
grubby --update-kernel=ALL --remove-args="rw" || log "Cannot remove rw from kernel" "ERROR"
grub2-mkconfig -o /boot/grub2/grub.cfg || log "Cannot update grub.cfg" "ERROR"

# Make sure we mount any xfs filesystems as ro (/boot and /)
# This won't affect the stateful label mounted devices

# Change mount options for any mountpoint containing images, Change all other mountpoints to ro and add noexec,nosuid,nodev
# Don't touch swap or fat FS. 
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
}' /etc/fstab || log "Cannot update /etc/fstab" "ERROR"
#sed -i 's/xfs\(\s*\)defaults/xfs\1defaults,ro/g' /etc/fstab
# Also remount all vfat systems (/boot/efi) if exist as ro
#sed -i 's/vfat\(\s*\)/vfat\1ro,/g' /etc/fstab


# The following patch is only necessary for readonly-root < 10.11.6 that comes with RHEL < 9.4
# Let's not execute it anymore
patch_readonly_root() {
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
}


## Post install
# Remove /etc/resolv.conf file since we don't want it in our image
# See man NetworkManager.conf rc-manager for more info about this
[ -f /etc/resolv.conf ] && rm -f /etc/resolv.conf || log "Cannot remove /etc/resolv.conf" "ERROR"
ln -s /run/NetworkManager/resolv.conf /etc/resolv.conf || log "Cannot link /run/NetworkManager/resolv.conf to /etc/resolv.conf" "ERROR"


if [ $SCRIPT_GOOD == false ]; then
    echo "#### WARNING Installation FAILED ####"
    exit 1
else
    echo "System is now readonly"
    echo ""
    echo "On modifications, please use 'mount -o remount,rw /'"
    echo ""
    echo "Once finished, please seal system with command"
    echo ""
    echo "rm -f ~/.bash_history; history -c; reboot"
    exit 0
fi
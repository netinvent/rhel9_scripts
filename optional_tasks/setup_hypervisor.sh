#!/usr/bin/env bash

## Hypervisor Installer 2024111401 for RHEL9

# Requirements:
# RHEL9 installed with NPF VMv4 profile incl. node exporter
# XFS System partition 50G for system

# optional, setup_hypervisor.conf file with variable overrides
[ -f ./setup_hypervisor.conf ] && source ./setup_hypervisor.conf

# COCKPIT ALLOWED USER
[ -z "${ADMIN_USER}" ] && ADMIN_USER=myuser

# HARDWARE ID for NetPerfect hardware
# or UNKNOWN for other hardware
[ -z "${HARDWARE_ID}" ] && HARDWARE_ID="UNKNOWN"


# Autosigned certificate information
[ -z "${COMMON_NAME}" ] && COMMON_NAME=hyper.local
[ -z "${EMAIL}" ] && EMAIL=contact@local.tld
[ -z "${CITY}" ] && CITY=DetroitRockCity
[ -z "${STATE}" ] && STATE=Kiss

CERT_DIR=/etc/pki/tls
TARGET_DIR=/etc/ssl/certs
CRT_SUBJECT="/C=FR/O=Oranization/CN=${COMMON_NAME}/OU=RD/L=${CITY}/ST=${STATE}/emailAddress=${EMAIL}"


LOG_FILE=/root/.npf-hypervisor.log
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

echo "#### Installing prerequisites ####"

dnf install -y epel-release || log "Failed to install epel release" "ERROR"
dnf install -y policycoreutils-python-utils || log "Failed to install selinux tools" "ERROR"
dnf install -y virt-what net-snmp tar bzip2 || log "Failed to install system tools" "ERROR"
dnf install -y qemu-kvm libvirt virt-install bridge-utils libguestfs-tools guestfs-tools cockpit cockpit-machines cockpit-pcp || log "Failed to install KVM" "ERROR"

# Optional virt-manager + X11 support (does not work in readonly mode)
dnf install -y virt-manager xorg-x11-xauth || log "Failed to install virt-manager and X11 auth support" "ERROR"

echo "#### System tuning ####"
# Don't log martian packets, obviously we'll get plenty
# These are RHEL specific with ANSSI BP028 high profile
sysctl -w net.ipv4.conf.all.log_martians=0 || log "Cannot set net.ipv4.conf.all.log_martians=0 live" "ERROR"
# THis is a link
#sed -i 's/net.ipv4.conf.all.log_martians = 1/net.ipv4.conf.all.log_martians = 0/g' /etc/sysctl.d/99-sysctl.conf
sed -i 's/net.ipv4.conf.all.log_martians = 1/net.ipv4.conf.all.log_martians = 0/g' /etc/sysctl.conf || log "Cannot update /etc/sysctl.conf" "ERROR"

echo "#### Setting up system certificate ####"

[ ! -d "${TARGET_DIR}" ] && mkdir "${TARGET_DIR}"

openssl req -nodes -new -x509 -days 7300 -newkey rsa:4096 -keyout "${CERT_DIR}/private/${COMMON_NAME// /_}.key" -subj "${CRT_SUBJECT}" -out "${CERT_DIR}/certs/${COMMON_NAME// /_}.crt"  || log "Failed to generate local cert" "ERROR"
cat "${CERT_DIR}/private/${COMMON_NAME// /_}.key" "${CERT_DIR}/certs/${COMMON_NAME// /_}.crt" > "${TARGET_DIR}/${COMMON_NAME// /_}.pem" || log "Failed to concat local cert" "ERROR"

echo "#### Setup SNMP ####"

cat << 'EOF' > /tmp/snmpd_part.conf
# View all tree in default systemview
view    systemview    included   .1
# System data
view    systemview    included   .1.3.6.1.2.1.1
view    systemview    included   .1.3.6.1.2.1.25.1.1
# Exclude USM and VACM MIBs
view systemview excluded .1.3.6.1.6.3.15
view systemview excluded .1.3.6.1.6.3.16
# Disks
view   systemview    included   .1.3.6.1.4.1.2021.9
# CPU
view    systemview    included   .1.3.6.1.4.1.2021.10
EOF
[ $? -eq 0 ] || log "Failed to create /tmp/snmpdçpart.conf"

sed -i '/^view    systemview    included   .1.3.6.1.2.1.25.1.1$/ r /tmp/snmpd_part.conf' /etc/snmp/snmpd.conf 2>> "${LOG_FILE}" || log "Configuring SNMP failed" "ERROR"

echo "#### Setting up cockpit & performance logging ####"
systemctl enable pmcd || log "Failed to enable pmcd" "ERROR"
systemctl start pmcd || log "Failed to start pmcd" "ERROR"
systemctl enable pmlogger || log "Failed enable pmlogger" "ERROR"
systemctl start pmlogger || log "Failed start pmlogger" "ERROR"
systemctl enable cockpit.socket || log "Failed to enable cockpit" "ERROR"
systemctl start cockpit.socket || log "Failed to start cockpit" "ERROR"


# Actually, we won't allow sudo since ANSSI BP-028 prohibits it (using Defaults noexec in /etc/sudoers)
# Cockpit sudo must work for admin user
#usermod -aG wheel ${ADMIN_USER} || result=1
#echo 'Defaults:'${ADMIN_USER}' !requiretty' >> /etc/sudoers

#Let's allow cockpit user root (which is okay since we have pam faillock set)
sed -i 's/^root/#root/g' /etc/cockpit/disallowed-users 2>> "${LOG_FILE}" || log "Allowing root user for cockpit failed" "ERROR"


echo "#### Setup first ethernet interface as bridged to new bridge kvmbr0 ####"
# ip -br l == ip print brief list of network interfaces
iface=$(ip -br l | awk '$1 !~ "lo|vir|wl" { print $1; exit }')
if [ -z "${iface}" ]; then
    log_quit "Failed to get first ethernet interface" "ERROR"
fi

# Disable spanning tree so we don't interrupt existing STP infrastructure
nmcli c add type bridge ifname kvmbr0 con-name kvmbr0 autoconnect yes bridge.stp no 2>> "${LOG_FILE}" || log "Creating bridge failed" "ERROR"
nmcli c modify kvmbr0 ipv4.method auto 2>> "${LOG_FILE}" || log "Setting bridge ipv4 DHCP failed" "ERROR"
nmcli c add type bridge-slave ifname "${iface}" master kvmbr0 autoconnect yes 2>> "${LOG_FILE}" || log "Adding bridge slave failed" "ERROR"
nmcli c up kvmbr0  2>> "${LOG_FILE}" || log "Enabling bridge failed" "ERROR"
nmcli c del "${iface}"  2>> "${LOG_FILE}" || log "Deleting interface ${iface} config failed" "ERROR"

echo "#### Setting up virualization ####"
cat << 'EOF' > /etc/sysconfig/libvirt-guests
ON_BOOT=start
ON_SHUTDOWN=shutdown
PARALLEL_SHUTDOWN=2
SHUTDOWN_TIMEOUT=360
SYNC_TIME=1
EOF
[ $? -eq 0 ] || log "Failed to create /etc/sysconfig/libvirt-guests" "ERROR"

systemctl enable libvirtd || log "Failed to enable libvirtd" "ERROR"
systemctl start libvirtd || log "Failed to enable libvirtd" "ERROR"
systemctl enable libvirt-guests || log "Failed to enable libvirt-guests" "ERROR"
systemctl start libvirt-guests || log "Failed to start libvirt-guests" "ERROR"


echo "#### Setup PCI Passthrough ####"
grubby --update-kernel=ALL --args="intel_iommu=on" || log "Failed to add iommu kernel argument" "ERROR"
grub2-mkconfig -o /boot/grub2/grub.cfg || log "Failed to generate grub.cfg" "ERROR"


echo "#### Identifying system ####"

host=$(virt-what)

case "$host" in
        *"redhat"*)
        NPFSYSTEM="VMv4r-rhhv"
        ;;
        *"hyperv"*)
        NPFSYSTEM="VMv4r-mshv"
        ;;
        *"vmware"*)
        NPFSYSTEM="VMv4r-vmhv"
        ;;
        *"kvm"*)
        NPFSYSTEM="VMv4r-kvhv"
        ;;
        *)
        echo "Change etc/netperfect-release if we are one an original NetPerfect hardware"
        NPFSYSTEM="${HARDWARE_ID}"
        ;;
esac

echo "NPF-${NPFSYSTEM}" > /etc/netperfect-release || log "Failed to create /etc/netperfect-release" "ERROR"

## Disable sssd
systemctl disable sssd || log "Cannot disable sssd" "ERROR"


echo "#### Cleanup system files ####"
## Clean system so readonly will be clean
# Need to be done before installing the appliance so we can keep logs

# Clean up log files, caches and temp
# Clear caches, files, and logs
/bin/rm -rf /root/* /tmp/* /tmp/.[a-zA-Z]* /var/tmp/*
/bin/rm -rf /etc/*- /etc/*.bak /etc/*~ /etc/sysconfig/*~
/bin/rm -rf /var/cache/dnf/* /var/cache/yum/* /var/log/rhsm/*
/bin/rm -rf /var/lib/dnf/* /var/lib/yum/repos/* /var/lib/yum/yumdb/*
/bin/rm -rf /var/lib/NetworkManager/* /var/lib/unbound/*.key
/bin/rm -rf /var/log/*debug /var/log/dmesg*
/bin/rm -rf /var/lib/cloud/* /var/log/cloud-init*.log
/bin/rm -rf /var/lib/authselect/backups/*
#/bin/rm -rf /var/log/anaconda

if [ "${SCRIPT_GOOD}" == false ]; then
    echo "#### WARNING Installation FAILED ####"
    exit 1
else
    echo "#### Installation done (check logs) ####"
    echo "Don't forget to remove this file if it was on disk"
    echo "Then reboot this machine"
    exit 0
fi
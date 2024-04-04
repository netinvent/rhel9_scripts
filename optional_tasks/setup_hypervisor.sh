#!/usr/bin/env bash

## Hypervisor Installer 2024012801 for RHEL9

# Requirements:
# RHEL9 installed with NPF VMv4 profile incl. node exporter
# XFS System partition 50G for system


CRT_SUBJECT="/C=FR/O=Oranization/CN=${COMMON_NAME}/OU=RD/L=City/ST=State/emailAddress=contact@example.tld"


script_dir=$(pwd)
result=0

echo "#### Installing prerequisites ####"

dnf install -y epel-release
dnf install -y policycoreutils-python-utils
dnf install -y virt-what smartmontools tuned net-snmp tar bzip2 lm_sensors
dnf install -y qemu-kvm libvirt virt-install bridge-utils libguestfs-tools guestfs-tools cockpit cockpit-machines

# Optional virt-manager + X11 support (does not work in readonly mode)
dnf install -y virt-manager xorg-x11-xauth

echo "#### System tuning ####"
# Don't log martian packets, obviously we'll get plenty
# These are RHEL specific with ANSSI BP028 high profile
sysctl -w net.ipv4.conf.all.log_martians=0
sed -i 's/net.ipv4.conf.all.log_martians = 1/net.ipv4.conf.all.log_martians = 0/g' /etc/sysctl.d/99-sysctl.conf
sed -i 's/net.ipv4.conf.all.log_martians = 1/net.ipv4.conf.all.log_martians = 0/g' /etc/sysctl.conf

echo "#### Setting up tuned profiles ####"

mkdir /etc/tuned/{npf-eco,npf-perf}

cat << 'EOF' > /etc/tuned/npf-eco/tuned.conf
[main]
summary=NetPerfect Powersaver
include=powersave

# SETTINGS_VER 2023110301

[cpu]
# Use governor conservative whenever we can, if not, use powersave
governor=conserative
# The way we scale (set via cpupower set --perf-bias 0-15, 15 being most power efficient)
energy_perf_bias=15
# This will set the minimal frequency available (used with intel_pstate, which replaces cpufreq values
min_perf_pct=1
max_perf_pct=75

[sysctl]
# Never put 0, because of potentiel OOMs
vm.swappiness=1
# Keep watchguard active so our machine does not lay there for months without operating
# nmi_watchdog is enabled while we do not operate the tunnel so the machine does not stay dead
kernel.nmi_watchdog = 1

##### Prevent blocking system on high IO

#Percentage of system memory which when dirty then system can start writing data to the disks.
vm.dirty_background_ratio = 1

#Percentage of system memory which when dirty, the process doing writes would block and write out dirty pages to the disks.
vm.dirty_ratio = 2

# delay for disk commit
vm.dirty_writeback_centisecs = 100

[script]
# ON RHEL8, we need to keep profile dir
# ON RHEL9, relative path is enough
#script=\${i:PROFILE_DIR}/script.sh
script=script.sh
EOF

cat << 'EOF' > /etc/tuned/npf-perf/tuned.conf
[main]
summary=NetPerfect Performance
include=network-latency

# SETTINGS_VER 2023110301

[cpu]
# Use governor ondemand whenever we can, if not, use performance which will disable all frequency changes
governor=ondemand
# The way we scale (set via cpupower set --perf-bias 0-15, 15 being most powersave)
energy_perf_bias=performance
# This will set the minimal frequency available (used with intel_pstate, which replaces cpufreq values
min_perf_pct=40
max_perf_pct=100

[sysctl]
# Never put 0, because of potentiel OOMs
vm.swappiness=1
# Keep watchguard active so our machine does not lay there for months without operating
# let's keep the nmi_watchdog disabled while we operate the tunnel so we get no interruptions
kernel.nmi_watchdog = 0

##### Prevent blocking system on high IO

#Percentage of system memory which when dirty then system can start writing data to the disks.
vm.dirty_background_ratio = 1

#Percentage of system memory which when dirty, the process doing writes would block and write out dirty pages to the disks.
vm.dirty_ratio = 2

# delay for disk commit
vm.dirty_writeback_centisecs = 100

[script]
# ON RHEL8, we need to keep profile dir
# ON RHEL9, relative path is enough
#script=\${i:PROFILE_DIR}/script.sh
script=script.sh
EOF

cat << 'EOF' > /etc/tuned/npf-eco/script.sh
#!/usr/bin/env bash

SCRIPT_VER=2024011401

# Powersave will keep low frequency no matter what. If available, use conservative. If not use powersave
if cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_available_governors | grep conservative > /dev/null; then
	governor=conservative
else
	governor=powersave
fi

min_freq=$(cpupower frequency-info | grep limits | awk '{print $3}')
min_freq_unit=$(cpupower frequency-info | grep limits | awk '{print $4}')
max_freq=$(cpupower frequency-info | grep limits | awk '{print $6}')
max_freq_unit=$(cpupower frequency-info | grep limits | awk '{print $7}')

# Calc max freq in eco mode, don't use bc anymore since it's probably not installed
#max_freq_eco=$(bc <<< "scale=2; $max_freq/1.5")
max_freq_eco=$(echo "print(round(${max_freq}/1.5, 2))" | python3)

# Set governor, min and max freq
cpupower frequency-set -g $governor -d ${min_freq}${min_freq_unit} -u ${max_freq_eco}${max_freq_unit}

# Set perf bias to max eco
cpupower set --perf-bias 15

# Enable all idle states
cpupower idle-set -E
EOF

cat << 'EOF' > /etc/tuned/npf-perf/script.sh
#!/usr/bin/env bash

SCRIPT_VER=2023110301

# Performance will keep CPU freq at max all the time. Prefer ondemand if available
if cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_available_governors | grep ondemand > /dev/null; then
	governor=ondemand
else
	governor=performance
fi

min_freq=$(cpupower frequency-info | grep limits | awk '{print $3}')
min_freq_unit=$(cpupower frequency-info | grep limits | awk '{print $4}')
max_freq=$(cpupower frequency-info | grep limits | awk '{print $6}')
max_freq_unit=$(cpupower frequency-info | grep limits | awk '{print $7}')

# Set governor, min and max freq
cpupower frequency-set -g $governor -d ${min_freq}${min_freq_unit} -u ${max_freq}${max_freq_unit}

# Set perf bias to max perf
cpupower set --perf-bias 0

# Optional disable idle states depending on latency (> 100ms)
cpupower idle-set -D 100
EOF

chmod +x /etc/tuned/{npf-eco,npf-perf}/script.sh

systemctl enable --now tuned
tuned-adm profile npf-eco

echo "#### Setting up system certificate ####"

CERT_DIR=/etc/pki/tls
COMMON_NAME=hyper.netinvent.local
TARGET_DIR=/etc/ssl/certs

[ ! -d "${TARGET_DIR}" ] && mkdir "${TARGET_DIR}"

openssl req -nodes -new -x509 -days 7300 -newkey rsa:4096 -keyout ${CERT_DIR}/private/${COMMON_NAME// /_}.key -subj "${CRT_SUBJECT}" -out ${CERT_DIR}/certs/${COMMON_NAME// /_}.crt
cat ${CERT_DIR}/private/${COMMON_NAME// /_}.key ${CERT_DIR}/certs/${COMMON_NAME// /_}.crt > ${TARGET_DIR}/${COMMON_NAME// /_}.pem

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
sed -i '/^view    systemview    included   .1.3.6.1.2.1.25.1.1$/ r /tmp/snmpd_part.conf' /etc/snmp/snmpd.conf

echo "#### Setting up cockpit & performance logging ####"
dnf install -y cockpit cockpit-machines cockpit-pcp
systemctl enable pmcd
systemctl start pmcd
systemctl enable pmlogger
systemctl start pmlogger
systemctl enable --now cockpit.socket
# NPF-MOD-USER: On ztl, the user would be zerotouch !!!
# Cockpit sudo must work for npfmonitor
usermod -aG wheel npfmonitor
echo 'Defaults:npfmonitor !requiretty' >> /etc/sudoers

echo "#### Setup first ethernet interface as bridged to new bridge kvmbr0 ####"
# ip -br l == ip print brief list of network interfaces
iface=$(ip -br l | awk '$1 !~ "lo|vir|wl" { print $1; exit }')
if [ -z ${iface} ]; then
    echo "Failed to get first ethernet interface"
    result=1
fi

# Disable spanning tree so we don't interrupt existing STP infrastructure
nmcli c add type bridge ifname kvmbr0 con-name kvmbr0 autoconnect yes bridge.stp no
nmcli c modify kvmbr0 ipv4.method dhcp
nmcli c add type bridge-slave ifname ${iface} master kvmbr0 autoconnect yes
nmcli c up kvmbr0
nmcli c del ${iface}

echo "#### Setting up virualization ####"
cat << 'EOF' > /etc/sysconfig/libvirt-guests
ON_BOOT=start
ON_SHUTDOWN=shutdown
PARALLEL_SHUTDOWN=2
SHUTDOWN_TIMEOUT=360
SYNC_TIME=1
EOF
systemctl enable --now libvirtd
systemctl enable --now libvirt-guests

echo "#### Setup PCI Passthrough ####"
grubby --update-kernel=ALL --args="intel_iommu=on"
grub2-mkconfig -o /boot/grub2/grub.cfg

echo "#### Checking for node exporter ####"
if [ -f /usr/local/bin/node_exporter ]; then
    echo "Node exporter already installed. Skipping"
else
    echo "Installing node exporter"

    cd /opt && mkdir -p /var/lib/node_exporter/textfile_collector && curl -sSfL https://raw.githubusercontent.com/carlocorradini/node_exporter_installer/main/install.sh | INSTALL_NODE_EXPORTER_SKIP_FIREWALL=true INSTALL_NODE_EXPORTER_EXEC="--collector.logind --collector.interrupts --collector.systemd --collector.processes --collector.textfile.directory=/var/lib/node_exporter/textfile_collector" sh -s - 
    if [ $? -ne 0 ]; then
        echo "Failed to install node exporter"
        result=1
    fi
    # Go back to script_dir
    cd ${script_dir}
fi

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
        echo "Change etc/netperfect-release to NPF-06 if we are one an original NetPerfect hardware"
        NPFSYSTEM="NPF06A"
        ;;
esac

echo "NPF-${NPFSYSTEM}" > /etc/netperfect-release


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

if [ $result -ne 0 ]; then
    echo "#### WARING Installation FAILED ####"
else
    echo "#### Installation done (check logs) ####"
    echo "Don't forget to remove this file if it was on disk"
    echo "Then reboot this machine"
fi
exit $result
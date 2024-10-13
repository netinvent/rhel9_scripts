#!/usr/bin/env bash

# SCRIPT BUILD 2024101304

LOG_FILE=/root/.npf-postinstall.log

function log {
    local log_line="${1}"
    echo "${log_line}" >> "${LOG_FILE}"
    echo "${log_line}"
}

log "Starting NPF post install at $(date)"

# We need a dns hostname in order to validate that we got internet before using internet related functions
# Also, we need to make sure 
function check_internet {
    fqdn_host="one.one.one.one kernel.org github.com"
    ip_hosts="2606:4700:4700::1001 8.8.8.8 9.9.9.9"
    for host in ${fqdn_host[@]}; do
        ping -6 -c2 "${host}" > /dev/null 2>&1
        if [ $? -eq 0 ]; then
            log "FQDN IPv6 echo request to ${host} works."
            return 0
        else
            log "FQDN IPv6 echo request to ${host} failed."
        fi
        ping -4 -c2 "${host}" > /dev/null 2>&1
        if [ $? -eq 0 ]; then
            log "FQDN IPv4 echo request to ${host} works."
            return 0
        else:
            log "FQDN IPv4 echo request to ${host} failed."
        fi
    done
    log "Looks like we cannot access internet via hostnames. Let's try IPs"
    for host in ${ip_hosts[@]}; do
        ping -c2 "${host}" > /dev/null 2>&1
        if [ $? -eq 0 ]; then
            log "IP check to ${host} works."
            return 1
        fi
    done
    ip_result=$(ip a)
    route_result=$(ip route)
    resolv=$(cat /etc/resolv.conf)
    log "Internet check failed. Please find output of diag commands:"
    log "ip a:\n${ip_result}\n\n"
    log "ip route:\n${route_result}\n\n"
    log "resolv.conf content:\n${resolv}\n\n"

    return 1
}

function is_virtual {
# This is a duplicate from the Python script, but since we don't inherit pre settings, we need to redeclare it
# Physical machine can return
# VME (Virtual mode extension)
# Enhanced Virtualization

# Hence we need to detect specific products
    dmidecode | grep -i "kvm\|qemu\|vmware\|hyper-v\|virtualbox\|innotek\|netperfect_vm" > /dev/null 2>&1
}

# Create issue file

# NPF-MOD
is_virtual
if [ $? -eq 0 ]; then
    NPF_NAME=VMv4.4
else
    NPF_NAME=PMv4.4
fi
cat << EOF > /etc/issue
NetPerfect $NPF_NAME

IPv4 \4
IPv6 \6

EOF

# Disable --fetch-remote-resources on machines without internet
[ ! -d /root/openscap_report ] && mkdir /root/openscap_report

check_internet
if [ $? -eq 0 ]; then
        # Let's reinstall openscap in case we're running this script on a non prepared machine
        dnf install -y openscap scap-security-guide
        log "Setting up scap profile with internet"
        oscap xccdf eval --profile anssi_bp28_high --fetch-remote-resources --remediate /usr/share/xml/scap/ssg/content/ssg-almalinux9-ds.xml > /root/openscap_report/actions.log 2>&1
        [ $? -ne 0 ] && log "OpenSCAP failed. See /root/openscap_report/actions.log"
else
        log "Setting up scap profile without internet"
        oscap xccdf eval --profile anssi_bp28_high --remediate /usr/share/xml/scap/ssg/content/ssg-almalinux9-ds.xml > /root/openscap_report/actions.log 2>&1
        [ $? -ne 0 ] && log "OpenSCAP failed. See /root/openscap_report/actions.log"
fi

log "Generating scap results"
oscap xccdf generate guide --profile anssi_bp28_high /usr/share/xml/scap/ssg/content/ssg-almalinux9-ds.xml > "/root/openscap_report/oscap_anssi_bp028_high_$(date '+%Y-%m-%d').html" 2> "${LOG_FILE}"
[ $? -ne 0 ] && log "OpenSCAP results failed. See log file"

# Fix firewall cannot load after anssi_bp28_high
setsebool -P secure_mode_insmod=off

# NPF don't fetch dnf epel packages since it's not sure we get internet
# Setup EPEL and packages
check_internet
if [ $? -eq 0 ]; then
    log "Install available with internet. setting up additional packages."
    dnf install -4 -y epel-release
    dnf install -4 -y htop atop nmon iftop iptraf
else
    log "No epel available without internet. Didn't install additional packages."
fi

is_virtual
if [ $? -ne 0 ]; then
    log "Setting up disk SMART tooling"
    echo  "DEVICESCAN -H -l error -f -C 197+ -U 198+ -t -l selftest -I 194 -n sleep,7,q -s (S/../.././10|L/../../[5]/13)" >> /etc/smartmontools/smartd.conf
    systemctl enable --now smartd

    log "Setting up smart script for prometheus"
    cat << 'EOF' > /usr/local/bin/smartmon.sh
#!/usr/bin/env bash
#
# Script informed by the collectd monitoring script for smartmontools (using smartctl)
# by Samuel B. <samuel_._behan_(at)_dob_._sk> (c) 2012
# source at: http://devel.dob.sk/collectd-scripts/

# TODO: This probably needs to be a little more complex.  The raw numbers can have more
#       data in them than you'd think.
#       http://arstechnica.com/civis/viewtopic.php?p=22062211

# Formatting done via shfmt -i 2
# https://github.com/mvdan/sh

# Ensure predictable numeric / date formats, etc.
export LC_ALL=C

parse_smartctl_attributes_awk="$(
  cat <<'SMARTCTLAWK'
$1 ~ /^ *[0-9]+$/ && $2 ~ /^[a-zA-Z0-9_-]+$/ {
  gsub(/-/, "_");
  printf "%s_value{%s,smart_id=\"%s\"} %d\n", $2, labels, $1, $4
  printf "%s_worst{%s,smart_id=\"%s\"} %d\n", $2, labels, $1, $5
  printf "%s_threshold{%s,smart_id=\"%s\"} %d\n", $2, labels, $1, $6
  printf "%s_raw_value{%s,smart_id=\"%s\"} %e\n", $2, labels, $1, $10
}
SMARTCTLAWK
)"

smartmon_attrs="$(
  cat <<'SMARTMONATTRS'
airflow_temperature_cel
command_timeout
current_pending_sector
end_to_end_error
erase_fail_count
g_sense_error_rate
hardware_ecc_recovered
host_reads_32mib
host_reads_mib
host_writes_32mib
host_writes_mib
load_cycle_count
media_wearout_indicator
nand_writes_1gib
offline_uncorrectable
power_cycle_count
power_on_hours
program_fail_cnt_total
program_fail_count
raw_read_error_rate
reallocated_event_count
reallocated_sector_ct
reported_uncorrect
runtime_bad_block
sata_downshift_count
seek_error_rate
spin_retry_count
spin_up_time
start_stop_count
temperature_case
temperature_celsius
temperature_internal
total_lbas_read
total_lbas_written
udma_crc_error_count
unsafe_shutdown_count
unused_rsvd_blk_cnt_tot
wear_leveling_count
workld_host_reads_perc
workld_media_wear_indic
workload_minutes
SMARTMONATTRS
)"
smartmon_attrs="$(echo "${smartmon_attrs}" | xargs | tr ' ' '|')"

parse_smartctl_attributes() {
  local disk="$1"
  local disk_type="$2"
  local labels="disk=\"${disk}\",type=\"${disk_type}\""
  sed 's/^ \+//g' |
    awk -v labels="${labels}" "${parse_smartctl_attributes_awk}" 2>/dev/null |
    tr '[:upper:]' '[:lower:]' |
    grep -E "(${smartmon_attrs})"
}

parse_smartctl_scsi_attributes() {
  local disk="$1"
  local disk_type="$2"
  local labels="disk=\"${disk}\",type=\"${disk_type}\""
  while read -r line; do
    attr_type="$(echo "${line}" | tr '=' ':' | cut -f1 -d: | sed 's/^ \+//g' | tr ' ' '_')"
    attr_value="$(echo "${line}" | tr '=' ':' | cut -f2 -d: | sed 's/^ \+//g')"
    case "${attr_type}" in
    number_of_hours_powered_up_) power_on="$(echo "${attr_value}" | awk '{ printf "%e\n", $1 }')" ;;
    Current_Drive_Temperature) temp_cel="$(echo "${attr_value}" | cut -f1 -d' ' | awk '{ printf "%e\n", $1 }')" ;;
    Blocks_sent_to_initiator_) lbas_read="$(echo "${attr_value}" | awk '{ printf "%e\n", $1 }')" ;;
    Blocks_received_from_initiator_) lbas_written="$(echo "${attr_value}" | awk '{ printf "%e\n", $1 }')" ;;
    Accumulated_start-stop_cycles) power_cycle="$(echo "${attr_value}" | awk '{ printf "%e\n", $1 }')" ;;
    Elements_in_grown_defect_list) grown_defects="$(echo "${attr_value}" | awk '{ printf "%e\n", $1 }')" ;;
    esac
  done
  [ -n "$power_on" ] && echo "power_on_hours_raw_value{${labels},smart_id=\"9\"} ${power_on}"
  [ -n "$temp_cel" ] && echo "temperature_celsius_raw_value{${labels},smart_id=\"194\"} ${temp_cel}"
  [ -n "$lbas_read" ] && echo "total_lbas_read_raw_value{${labels},smart_id=\"242\"} ${lbas_read}"
  [ -n "$lbas_written" ] && echo "total_lbas_written_raw_value{${labels},smart_id=\"241\"} ${lbas_written}"
  [ -n "$power_cycle" ] && echo "power_cycle_count_raw_value{${labels},smart_id=\"12\"} ${power_cycle}"
  [ -n "$grown_defects" ] && echo "grown_defects_count_raw_value{${labels},smart_id=\"-1\"} ${grown_defects}"
}

parse_smartctl_info() {
  local -i smart_available=0 smart_enabled=0 smart_healthy=
  local disk="$1" disk_type="$2"
  local model_family='' device_model='' serial_number='' fw_version='' vendor='' product='' revision='' lun_id=''
  while read -r line; do
    info_type="$(echo "${line}" | cut -f1 -d: | tr ' ' '_')"
    info_value="$(echo "${line}" | cut -f2- -d: | sed 's/^ \+//g' | sed 's/"/\\"/')"
    case "${info_type}" in
    Model_Family) model_family="${info_value}" ;;
    Device_Model) device_model="${info_value}" ;;
    Serial_Number|Serial_number) serial_number="${info_value}" ;;
    Firmware_Version) fw_version="${info_value}" ;;
    Vendor) vendor="${info_value}" ;;
    Product) product="${info_value}" ;;
    Revision) revision="${info_value}" ;;
    Logical_Unit_id) lun_id="${info_value}" ;;
    esac
    if [[ "${info_type}" == 'SMART_support_is' ]]; then
      case "${info_value:0:7}" in
      Enabled) smart_available=1; smart_enabled=1 ;;
      Availab) smart_available=1; smart_enabled=0 ;;
      Unavail) smart_available=0; smart_enabled=0 ;;
      esac
    fi
    if [[ "${info_type}" == 'SMART_overall-health_self-assessment_test_result' ]]; then
      case "${info_value:0:6}" in
      PASSED) smart_healthy=1 ;;
      *) smart_healthy=0 ;;
      esac
    elif [[ "${info_type}" == 'SMART_Health_Status' ]]; then
      case "${info_value:0:2}" in
      OK) smart_healthy=1 ;;
      *) smart_healthy=0 ;;
      esac
    fi
  done
  echo "device_info{disk=\"${disk}\",type=\"${disk_type}\",vendor=\"${vendor}\",product=\"${product}\",revision=\"${revision}\",lun_id=\"${lun_id}\",model_family=\"${model_family}\",device_model=\"${device_model}\",serial_number=\"${serial_number}\",firmware_version=\"${fw_version}\"} 1"
  echo "device_smart_available{disk=\"${disk}\",type=\"${disk_type}\"} ${smart_available}"
  echo "device_smart_enabled{disk=\"${disk}\",type=\"${disk_type}\"} ${smart_enabled}"
  [[ "${smart_healthy}" != "" ]] && echo "device_smart_healthy{disk=\"${disk}\",type=\"${disk_type}\"} ${smart_healthy}"
}

output_format_awk="$(
  cat <<'OUTPUTAWK'
BEGIN { v = "" }
v != $1 {
  print "# HELP smartmon_" $1 " SMART metric " $1;
  print "# TYPE smartmon_" $1 " gauge";
  v = $1
}
{print "smartmon_" $0}
OUTPUTAWK
)"

format_output() {
  sort |
    awk -F'{' "${output_format_awk}"
}

smartctl_version="$(/usr/sbin/smartctl -V | head -n1 | awk '$1 == "smartctl" {print $2}')"

echo "smartctl_version{version=\"${smartctl_version}\"} 1" | format_output

if [[ "$(expr "${smartctl_version}" : '\([0-9]*\)\..*')" -lt 6 ]]; then
  exit
fi

device_list="$(/usr/sbin/smartctl --scan-open | awk '/^\/dev/{print $1 "|" $3}')"

for device in ${device_list}; do
  disk="$(echo "${device}" | cut -f1 -d'|')"
  type="$(echo "${device}" | cut -f2 -d'|')"
  active=1
  echo "smartctl_run{disk=\"${disk}\",type=\"${type}\"}" "$(TZ=UTC date '+%s')"
  # Check if the device is in a low-power mode
  /usr/sbin/smartctl -n standby -d "${type}" "${disk}" > /dev/null || active=0
  echo "device_active{disk=\"${disk}\",type=\"${type}\"}" "${active}"
  # Skip further metrics to prevent the disk from spinning up
  test ${active} -eq 0 && continue
  # Get the SMART information and health
  /usr/sbin/smartctl -i -H -d "${type}" "${disk}" | parse_smartctl_info "${disk}" "${type}"
  # Get the SMART attributes
  case ${type} in
  sat) /usr/sbin/smartctl -A -d "${type}" "${disk}" | parse_smartctl_attributes "${disk}" "${type}" ;;
  sat+megaraid*) /usr/sbin/smartctl -A -d "${type}" "${disk}" | parse_smartctl_attributes "${disk}" "${type}" ;;
  scsi) /usr/sbin/smartctl -A -d "${type}" "${disk}" | parse_smartctl_scsi_attributes "${disk}" "${type}" ;;
  megaraid*) /usr/sbin/smartctl -A -d "${type}" "${disk}" | parse_smartctl_scsi_attributes "${disk}" "${type}" ;;
  nvme*) /usr/sbin/smartctl -A -d "${type}" "${disk}" | parse_smartctl_scsi_attributes "${disk}" "${type}" ;;
  usbprolific) /usr/sbin/smartctl -A -d "${type}" "${disk}" | parse_smartctl_attributes "${disk}" "${type}" ;;
  *)
      (>&2 echo "disk type is not sat, scsi, nvme or megaraid but ${type}")
    exit
    ;;
  esac
done | format_output
EOF
    chmod +x /usr/local/bin/smartmon.sh
    echo "Setting up smart script for prometheus task" >> "${LOG_FILE}"
    [ ! -d /var/lib/node_exporter/textfile_collector ] && mkdir -p /var/lib/node_exporter/textfile_collector
    echo "*/5 * * * * root /usr/local/bin/smartmon.sh > /var/lib/node_exporter/textfile_collector/smart_metrics.prom" >> /etc/crontab

    log "Setting up iTCO_wdt watchdog"
    echo "iTCO_wdt" > /etc/modules-load.d/10-watchdog.conf

    sensors-detect --auto | grep "no driver for ITE IT8613E" > /dev/null 2>&1
    if [ $? -eq 0 ]; then
        log "Setting up TCO Watchdog support and partial ITE 8613E support"
        echo "it87" > /etc/modules-load.d/20-it87.conf
        echo "options it87 force_id=0x8620" > /etc/modprobe.d/it87.conf
    fi

    log "Setting up tuned profiles"

    [ ! -d /etc/tuned/npf-eco ] && mkdir /etc/tuned/npf-eco
    [ ! -d /etc/tuned/npf-perf ]&& mkdir /etc/tuned/npf-perf

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

SCRIPT_VER=2024040701

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
max_freq_eco=$(echo "print(round(${max_freq}/1.8, 2))" | python3)

# Set governor, min and max freq
cpupower frequency-set -g $governor -d ${min_freq}${min_freq_unit} -u ${max_freq_eco}${max_freq_unit}

# Set perf bias to max eco
cpupower set --perf-bias 15

# Using idle states with a lacency > 10 will greatly affect bandwidth on KVM virtual machines
# Enable all idle states
cpupower idle-set -E
# Disable any higher than 50ns latency idle states
cpupower idle-set -D 50
EOF

  cat << 'EOF' > /etc/tuned/npf-perf/script.sh
#!/usr/bin/env bash

SCRIPT_VER=2024040701

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

# Using idle states with a lacency > 10 will greatly affect bandwidth on KVM virtual machines
# Enable all idle states
cpupower idle-set -E
# Disable any higher than 50ns latency idle states
cpupower idle-set -D 50
EOF

    chmod +x /etc/tuned/{npf-eco,npf-perf}/script.sh
else
    log "This is a virtual machine. We will not setup hardware tooling"
fi

# Configure serial console
log "Setting up serial console"
systemctl enable serial-getty@ttyS0.service
sed -i 's/^GRUB_TERMINAL_OUTPUT="console"/GRUB_TERMINAL="serial console"\nGRUB_SERIAL_COMMAND="serial --unit=0 --word=8 --parity=no --speed 115200 --stop=1"/g' /etc/default/grub
# Update grub to add console
grubby --update-kernel=ALL --args="console=ttyS0,115200,n8 console=tty0"
grub2-mkconfig -o /boot/grub2/grub.cfg


# Setup automagic terminal resize
# singequotes on EOF prevents variable expansion
cat << 'EOF' >> /etc/profile.d/term_resize.sh
# Based on solution https://unix.stackexchange.com/a/283206/135459 that replaces xterm-resize package


resize_term() {

  old=$(stty -g)
  stty raw -echo min 0 time 5

  printf '\0337\033[r\033[999;999H\033[6n\0338' > /dev/tty
  IFS='[;R' read -r _ rows cols _ < /dev/tty

  stty "$old"

  # echo "cols:$cols"
  # echo "rows:$rows"
  stty cols "$cols" rows "$rows"
}

resize_term2() {

  old=$(stty -g)
  stty raw -echo min 0 time 5

  printf '\033[18t' > /dev/tty
  IFS=';t' read -r _ rows cols _ < /dev/tty

  stty "$old"

  # echo "cols:$cols"
  # echo "rows:$rows"
  stty cols "$cols" rows "$rows"
}

# Run only if we're in a serial terminal
[ $(tty) == /dev/ttyS0 ] && resize_term2
EOF

# Configure persistent journal
log "Setting up persistent boot journal"
[ ! -d /var/log/journal ] && mkdir /var/log/journal
systemd-tmpfiles --create --prefix /var/log/journal >> "${LOG_FILE}"
sed -i 's/.*Storage=.*/Storage=persistent/g' /etc/systemd/journald.conf
killall -USR1 systemd-journald
# Configure max journal size
journalctl --vacuum-size=2G

log "Setup DNF automatic except for updates that require reboot"
systemctl disable dnf-makecache.timer
sed -i 's/^upgrade_type[[:space:]]*=[[:space:]].*/upgrade_type = security/g' /etc/dnf/automatic.conf
sed -i 's/^download_updates[[:space:]]*=[[:space:]].*/download_updates = yes/g' /etc/dnf/automatic.conf
sed -i 's/^apply_updates[[:space:]]*=[[:space:]].*/apply_updates = yes/g' /etc/dnf/automatic.conf
sed -i 's/^emit_via[[:space:]]*=[[:space:]].*/emit_via = stdio,motd/g' /etc/dnf/automatic.conf
systemctl enable --now dnf-automatic.timer

# Setup tuned profile
is_virtual
if [ $? -ne 0 ]; then
    log "Setting up hardware tuned profile"
    systemctl enable tuned
    tuned-adm profile npf-eco
else
    log "Setting up virtual tuned profile"
    systemctl enable tuned
    tuned-adm profile virtual-guest
fi

# Enable guest agent on KVM
is_virtual
if [ $? -eq 0 ]; then
    log "Setting up Qemu guest agent"
    setsebool -P virt_qemu_ga_read_nonsecurity_files 1
	  systemctl enable --now qemu-guest-agent
fi

# Prometheus support
check_internet
if [ $? -eq 0 ]; then
    log "Installing Prometheus"
    cd /opt
    [ ! -d /var/lib/node_exporter/textfile_collector ] && mkdir -p /var/lib/node_exporter/textfile_collector
    curl -sSfL https://raw.githubusercontent.com/carlocorradini/node_exporter_installer/main/install.sh | INSTALL_NODE_EXPORTER_SKIP_FIREWALL=true INSTALL_NODE_EXPORTER_EXEC="--collector.logind --collector.interrupts --collector.systemd --collector.processes --collector.textfile.directory=/var/lib/node_exporter/textfile_collector" sh -s -
else
    log "No prometheus installed"
fi

# Setting up watchdog in systemd
log "Setting up systemd watchdog"
sed -i -e 's,^#RuntimeWatchdogSec=.*,RuntimeWatchdogSec=60s,' /etc/systemd/system.conf


# Setting up banner
cat << 'EOF' > /etc/motd
############################################################
# <<Un grand pouvoir implique de grandes responsabilités>> #
#                                                          #
#               !! Systeme en production !!                #
#               Toute modification doit être               #
#                inscrite dans le cahier de                #
#                 gestion des changements.                 #
#                                                          #
#       Toute connexion à ce système est journalisée       #
#                                                          #
############################################################
EOF

# Cleanup kickstart file replaced with inst.nosave=all_ks
[ -f /root/anaconda-ks.cfg ] && /bin/shred -uz /root/anaconda-ks.cfg
[ -f /root/original-ks.cfg ] && /bin/shred -uz /root/original-ks.cfg

# Clean up log files, caches and temp
# Clear caches, files, and logs
/bin/rm -rf /tmp/* /tmp/.[a-zA-Z]* /var/tmp/*
/bin/rm -rf /etc/*- /etc/*.bak /etc/*~ /etc/sysconfig/*~
/bin/rm -rf /var/cache/dnf/* /var/cache/yum/* /var/log/rhsm/*
/bin/rm -rf /var/lib/dnf/* /var/lib/yum/repos/* /var/lib/yum/yumdb/*
/bin/rm -rf /var/lib/NetworkManager/* /var/lib/unbound/*.key
/bin/rm -rf /var/log/*debug /var/log/dmesg*
/bin/rm -rf /var/lib/cloud/* /var/log/cloud-init*.log
/bin/rm -rf /var/lib/authselect/backups/*
#/bin/rm -rf /var/log/anaconda

# Make sure we write everything to disk
sync; echo 3 > /proc/sys/vm/drop_caches

log "Finished at $(date)"
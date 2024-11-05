#!/usr/bin/env bash

## OPNSense Installer 2024110501 for RHEL9 with PCI passthrough preconfigured

# Requirements:
# RHEL9 installed with NPF hypervisor script

IMAGE_DIR=/var/lib/libvirt/images

# VM Configuration
VCPUS=6
RAM=10240
DISK_SIZE=120G
OS_VARIANT=freebsd14.0  # osinfo-query os | grep freebsd

LOG_FILE=/root/.npf-opnsense.log
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

function usage {
    echo "$0 <tenant> <opnsense_version> <pci_devs>"
    echo "<pci_devs> is a comma separated list of PCI devices to passthrough"
    echo "found via virsh nodedev-list --tree or lspci -nn"
    echo "Example: $0 tenant 24.7 pci_0000_05_00_0,pci_0000_06_00_0"
    exit 1
}


if [ "$1" == "" ]; then
    echo "Requires tenant name"
    usage
fi

if [ "$2" == "" ]; then
    echo "Requires OPNSense version"
    usage
fi

if [ "$3" == "" ]; then
    echo "Requires PCI devices to passthrough"
    usage
fi

dnf install -y bzip2 aria2

#if ! type bzip2 > /dev/null 2>&1; then
#    echo "No bzip2 installed"
#    exit 1
#fi

# Download latest opnsense
if [ ! -d "${IMAGE_DIR}" ]; then
    log_quit "Image dir ${IMAGE_DIR} does not exist. Are we on a KVM machine ?"
fi

cd "${IMAGE_DIR}" || log_quit "Cannot cd to ${IMAGE_DIR}"
log "Downloading OPNsense image"
aria2c "https://mirror.ams1.nl.leaseweb.net/opnsense/releases/$2/OPNsense-$2-dvd-amd64.iso.bz2"
if [ $? -ne 0 ]; then
    log_quit "Failed to download OPNSense v$2"
fi

curl -OL "https://mirror.ams1.nl.leaseweb.net/opnsense/releases/$2/OPNsense-$2-checksums-amd64.sha256"
if [ $? -ne 0 ]; then
    log_quit "Failed to download OPNSense v$2 checksums"
fi

log "Checking SHA256 SUM"
OPNSENSE_ISO="${IMAGE_DIR}/OPNsense-$2-dvd-amd64.iso.bz2"
CHECKSUM_FILE="${IMAGE_DIR}/OPNsense-$2-checksums-amd64.sha256"
if [ ! -f "${OPNSENSE_ISO}" ]; then
    log_quit "ISO File not existent"
fi
if [ ! -f "${CHECKSUM_FILE}" ]; then
    log_quit "Checksum File not existent"
fi
checksum=$(sha256sum "${OPNSENSE_ISO}" | awk '{ print $1 }')
if ! grep "${checksum}" "${CHECKSUM_FILE}"; then
    log_quit "Downloaded OPNsense checksum is invalid"
fi
log "Decompressing image"
bzip2 -d "${OPNSENSE_ISO}"
if [ $? -ne 0 ]; then
    log_quit "Failed to decompress image"
fi
# Removing .bz2 extension
OPNSENSE_ISO="${OPNSENSE_ISO%.*}"

PRODUCT=vmv4kvhv
TENANT=${1}
VM="opnsense01p.${TENANT}.local"
DISKPATH="${IMAGE_DIR}"
FULL_DISKPATH="${DISKPATH}/${VM}-disk0.qcow2"
IO_MODE=,io="native,driver.iothread=${VCPUS},driver.queues=${VCPUS} --iothreads ${VCPUS}"
ISO="${OPNSENSE_ISO}"

PCI_PASSTHROUGH="--network none"
IFS=',' read -r -a host_devices <<< "${3}"
for host_device in "${host_devices[@]}"; do
    echo "Passthrough device ${host_device}"
    PCI_PASSTHROUGH="${PCI_PASSTHROUGH} --host-device ${host_device}"
done

qemu-img create -f qcow2 -o extended_l2=on -o preallocation=metadata "${FULL_DISKPATH}" "${DISK_SIZE}" || log_quit "Failed to create disk"
chown qemu:qemu "${FULL_DISKPATH}" || log "Failed to change disk owner" "ERROR"
virt-install --name "${VM}" --ram "${RAM}" --vcpus "${VCPUS}" --cpu host --os-variant "${OS_VARIANT}" --disk path="${FULL_DISKPATH/${VM}-disk0.qcow2,bus=virtio,cache=none${IO_MODE}" --channel unix,mode=bind,target_type=virtio,name=org.qemu.guest_agent.0 --watchdog i6300esb,action=reset --sound none --boot hd --autostart --sysinfo smbios,bios.vendor=npf --sysinfo smbios,system.manufacturer=NetPerfect --sysinfo smbios,system.product="${PRODUCT}" --cdrom "${ISO}" --graphics vnc,listen=127.0.0.1,keymap=fr --autoconsole text "${PCI_PASSTHROUGH}"

if [ $? -ne 0 ]; then
    echo "#### WARING Installation FAILED ####"
else
    echo "#### Setup done (check logs) ####"
    echo "Now go to cockpit at https://{IP}:9090 to setup the firewall"
    echo "Don't forget to remove this file if it was on disk"
fi
exit
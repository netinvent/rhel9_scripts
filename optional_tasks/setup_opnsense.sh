#!/usr/bin/env bash

## OPNSense Installer 2024100101 for RHEL9 with PCI passthrough preconfigured

# Requirements:
# RHEL9 installed with NPF hypervisor script

IMAGE_DIR=/var/lib/libvirt/images

# VM Configuration
VCPUS=6
RAM=10240
DISK=120G
OS_VARIANT=freebsd14.0  # osinfo-query os | grep freebsd

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
    echo "Image dir ${IMAGE_DIR} does not exist. Are we on a KVM machine ?"
    exit 1
fi

cd "${IMAGE_DIR}"
echo "Downloading OPNsense image"
aria2c "https://mirror.ams1.nl.leaseweb.net/opnsense/releases/$2/OPNsense-$2-dvd-amd64.iso.bz2"
if [ $? -ne 0 ]; then
    echo "Failed to download OPNSense v$2"
    exit 1
fi

curl -OL "https://mirror.ams1.nl.leaseweb.net/opnsense/releases/$2/OPNsense-$2-checksums-amd64.sha256"
if [ $? -ne 0 ]; then
    echo "Failed to download OPNSense v$2 checksums"
    exit 1
fi

echo "Checking SHA256 SUM"
OPNSENSE_ISO="${IMAGE_DIR}/OPNsense-$2-dvd-amd64.iso.bz2"
CHECKSUM_FILE="${IMAGE_DIR}/OPNsense-$2-checksums-amd64.sha256"
if [ ! -f "${OPNSENSE_ISO}" ]; then
    echo "ISO File not existent"
    exit 1
fi
if [ ! -f "${CHECKSUM_FILE}" ]; then
    echo "Checksum File not existent"
    exit 1
fi
checksum=$(sha256sum "${OPNSENSE_ISO}" | awk '{ print $1 }')
if ! grep "${checksum}" "${CHECKSUM_FILE}"; then
    echo "Downloaded OPNsense checksum is invalid"
    exit 1
fi
echo "Decompressing image"
bzip2 -d "${OPNSENSE_ISO}"
if [ $? -ne 0 ]; then
    echo "Failed to decompress image"
    exit 1
fi
# Removing .bz2 extension
OPNSENSE_ISO="${OPNSENSE_ISO%.*}"

PRODUCT=vmv4kvhv
TENANT=${1}
VM=opnsense01p.${TENANT}.local
DISKPATH=${IMAGE_DIR}
IO_MODE=,io="native,driver.iothread=${VCPUS},driver.queues=${VCPUS} --iothreads ${VCPUS}"
ISO=${OPNSENSE_ISO}

PCI_PASSTHROUGH="--network none"
IFS=',' read -r -a host_devices <<< "${3}"
for host_device in "${host_devices[@]}"; do
    echo "Passthrough device ${host_device}"
    PCI_PASSTHROUGH="${PCI_PASSTHROUGH} --host-device ${host_device}"
done

qemu-img create -f qcow2 -o extended_l2=on -o preallocation=metadata "${DISKPATH}/${VM}-disk0.qcow2" ${DISK}
chown qemu:qemu "${DISKPATH}/${VM}-disk0.qcow2"
virt-install --name ${VM} --ram ${RAM} --vcpus ${VCPUS} --cpu host --os-variant ${OS_VARIANT} --disk path=${DISKPATH}/${VM}-disk0.qcow2,bus=virtio,cache=none${IO_MODE} --channel unix,mode=bind,target_type=virtio,name=org.qemu.guest_agent.0 --watchdog i6300esb,action=reset --sound none --boot hd --autostart --sysinfo smbios,bios.vendor=npf --sysinfo smbios,system.manufacturer=NetPerfect --sysinfo smbios,system.product=${PRODUCT} --cdrom ${ISO} --graphics vnc,listen=127.0.0.1,keymap=fr --autoconsole text ${PCI_PASSTHROUGH}

if [ $? -ne 0 ]; then
    echo "#### WARING Installation FAILED ####"
else
    echo "#### Setup done (check logs) ####"
    echo "Now go to cockpit at https://{IP}:9090 to setup the firewall"
    echo "Don't forget to remove this file if it was on disk"
fi
exit
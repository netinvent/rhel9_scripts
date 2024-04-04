#! /usr/bin/env python3
#  -*- coding: utf-8 -*-


__intname__ = "kickstart.partition_script.RHEL9"
__author__ = "Orsiris de Jong"
__copyright__ = "Copyright (C) 2022-2024 Orsiris de Jong - NetInvent SASU"
__licence__ = "BSD 3-Clause"
__build__ = "2024030501"

### This is a pre-script for kickstart files in RHEL 9
### Allows specific partition schemes with one or more data partitions
# Generic partition schema is
# | (efi) | boot | root | data 1 | data part n | swap


## Possible partitionning targets
# hv: Standard KVM hypervisor
# hv-stateless: Stateless KVM hypervisor
# generic: One big root partition
# anssi: ANSSI-BP028 high profile compatible partitioning scheme
TARGET = "anssi"

## Password management
# If ARE_PASSWORDS_CRYPTED, root and user passwords need to be generated using openssl passwd -6 (or -5)
# Else, you can use plain text passwords
ARE_PASSWORDS_CRYPTED = True
# The following password is the output of openssl passwd -6 MySuperSecretPWD123!
DEFAULT_ROOT_PASSWORD = r"$6$tbqw2foUFoYWayGy$6g13/1NgjNlPvXH7nwRyfg3ROfr6d01MUUbt0I2OubtY/zGHjhn2BveYoo8L.BgGXHNq7jKrTtS5lR8ugirom0"
DEFAULT_USER_NAME = "myuser"
# The following password is the output of openssl passwd -6 MySecretPWD123!
DEFAULT_USER_PASSWORD = r"$6$n4c4LJmfmwTgF80z$bPWqMYIVcMN9cK..MTAIXj.Rp2Q/AzhRd8dK4GXUY7GsVerQD8oP0nds.We.WrYOCX5bw8Yaonef0g6dBZxat."


## Hostname
# Hostname used depending on virtual or physical machine
PHYSICAL_HOSTNAME="pmv43.npf.local"
VIRTUAL_HOSTNAME="vmv43.npf.local"

## Package management
# Add lm-sensros and smartmontools on physical machines
ADD_PHYSICAL_PACKAGES=True
# Remove firmware packages, plymouth and pipewire on virtual machines
REMOVE_VIRTUAL_PACKAGES=True


import sys
import os
import subprocess
import logging
from time import sleep


### Set Partition schema here
# boot and swap partitions are automatically created
# Sizes can be
# - <nn>: Size in MB
# - <nn%>: Percentage of remaining size after fixed size has been allocated
# - True: Fill up remaining space after fixed and percentage size has been allocated
#         If multiple True values exist, we'll divide by percentages of remaining space

# Partition schema for standard KVM Hypervisor
PARTS_HV = [
    {"size": 30720, "fs": "xfs", "mountpoint": "/"},
    {"size": True, "fs": "xfs", "mountpoint": "/var/lib/libvirt/images"},
]

# Partition schema for stateless KVM Hypervisor
PARTS_HV_STATELESS = [
    {"size": 30720, "fs": "xfs", "mountpoint": "/"},
    {"size": True, "fs": "xfs", "mountpoint": "/var/lib/libvirt/images"},
    {"size": 30720, "fs": "xfs", "mountpoint": None, "label": "STATEFULRW"},
]

# Partition schema for stateless machines
PARTS_STATELSSS = [
    {"size": True, "fs": 'xfs', "mountpoint": '/'},
    {"size": True,  "fs": 'xfs',  "mountpoint": None, "label": "STATEFULRW"}
]

# Parttiion schema for generic machines with only one big root partition
PARTS_GENERIC = [
    {"size": True, "fs": "xfs", "mountpoint": "/"}
]

# Example partition schema for ANSSI-BP028 high profile
PARTS_ANSSI = [
    {"size": 30720, "fs": "xfs", "mountpoint": "/"},
    {"size": 40960, "fs": "xfs", "mountpoint": "/home"},
    #{"size": 40960 , "fs": "xfs", "mountpoint": "/srv"},                # When FTP/SFTP server is used
    {"size": 10240, "fs": "xfs", "mountpoint": "/tmp"},
    {"size": True, "fs": "xfs", "mountpoint": "/var"},
    {"size": 30720, "fs": "xfs", "mountpoint": "/var/log"},
    {"size": 10240, "fs": "xfs", "mountpoint": "/var/log/audit"},
    {"size": 10240, "fs": "xfs", "mountpoint": "/var/tmp"},
]


def dirty_cmd_runner(cmd: str) -> [int, str]:
    """
    QaD command runner
    """
    try:
        result = subprocess.check_output(cmd, shell=True, stderr=subprocess.STDOUT)
        return True, result.decode("utf-8")
    except subprocess.CalledProcessError as exc:
        result = exc.output
        return False, result


def is_gpt_system() -> bool:
    is_gpt = os.path.exists("/sys/firmware/efi")
    if is_gpt:
        logger.info("We're running on a UEFI machine")
    else:
        logger.info("We're running on a MBR machine")
    return is_gpt


def get_mem_size() -> int:
    """
    Returns memory size in MB
    Balantly copied from https://stackoverflow.com/a/28161352/2635443
    """
    mem_bytes = os.sysconf("SC_PAGE_SIZE") * os.sysconf(
        "SC_PHYS_PAGES"
    )  # e.g. 4015976448
    mem_mib = int(mem_bytes / (1024.0**2))  # e.g. 16384
    logger.info(f"Current system has {mem_mib} MB of memory")
    return mem_mib


def get_first_disk_path() -> list:
    """
    Return list of disks

    First, let's get the all the available disk names (ex hda,sda,vda)
    We might have a /dev/zram0 device which is considered as disk, so we need to filter vdX,sdX,hdX
    """
    cmd = r"lsblk -nd --output NAME,TYPE | grep -i disk | grep -e '^v\|^s\|^h' | cut -f1 -d' '"
    result, output = dirty_cmd_runner(cmd)
    if result:
        disk_path = "/dev/" + output.split("\n")[0]
        logger.info(f"First usable disk is {disk_path}")
        return disk_path

    logger.error(f"Cannot find usable disk: {output}")
    return False


def zero_disk(disk_path: str) -> bool:
    """
    Zero first disk bytes
    """
    cmd = f"dd if=/dev/zero of={disk_path} bs=512 count=1 conv=notrunc && blockdev --rereadpt {disk_path}"
    logger.info(f"Zeroing disk {disk_path}")
    if DRY_RUN:
        return True
    result, output = dirty_cmd_runner(cmd)
    if not result:
        logger.error(f"Could not zero disk {disk_path}: {output}")
    return result


def init_disk(disk_path: str) -> bool:
    """
    Create disk label
    """
    if IS_GPT:
        label = "gpt"
    else:
        label = "msdos"
    cmd = f"parted -s {disk_path} mklabel {label}"
    logger.info(f"Making {disk_path} label")
    if DRY_RUN:
        return True
    result, output = dirty_cmd_runner(cmd)
    if not result:
        logger.error(f"Could not make {disk_path} label: {output}")
    return result


def get_disk_size_mb(disk_path: str) -> int:
    """
    Get disk size in megabytes
    Use parted so we don't rely on other libs
    """
    cmd = f"parted -s {disk_path} unit mb print | grep {disk_path} | awk '{{ print $3 }}' | cut -d'M' -f1"
    logger.info(f"Getting {disk_path} size")
    result, output = dirty_cmd_runner(cmd)
    if result:
        try:
            disk_size = int(output)
            logger.info(f"Disk {disk_path} size is {disk_size} MB")
            return disk_size
        except Exception as exc:
            logger.error(f"Cannot get {disk_path} size: {exc}. Result was {output}")
            return False
    else:
        logger.error(f"Cannot get {disk_path} size. Result was {output}")
        return False


def get_allocated_space(partitions_schema: dict) -> int:
    # Let's fill ROOT part with anything we can
    allocated_space = 0
    for partition in partitions_schema:
        allocated_space += partitions_schema[partition]["size"]
    return allocated_space


def get_partition_schema():
    global PARTS

    mem_size = get_mem_size()
    if mem_size > 16384:
        swap_size = mem_size
    else:
        swap_size = int(mem_size / 2)

    def create_partition_schema():
        if IS_GPT:
            partitions_schema = {
                0: {"size": 600, "fs": "fat32", "mountpoint": "/boot/efi"},
                1: {"size": 1024, "fs": "xfs", "mountpoint": "/boot"},
            }
        else:
            partitions_schema = {0: {"size": 1024, "fs": "xfs", "mountpoint": "/boot"}}

        partitions_schema[99] = {"size": swap_size, "fs": "linux-swap", "mountpoint": "swap"}
        return partitions_schema

    def add_fixed_size_partitions(partitions_schema):
        for index, partition in enumerate(PARTS):
            # Shift index so we don't overwrite boot partition indexes
            index = index + 10
            if not isinstance(partition["size"], bool) and isinstance(
                partition["size"], int
            ):
                partitions_schema[index] = {"size": partition["size"]}
        return partitions_schema

    def add_percent_size_partitions(partitions_schema):
        total_percentage = 0
        free_space = USABLE_DISK_SPACE - get_allocated_space(partitions_schema)
        for index, partition in enumerate(PARTS):
            index = index + 10
            if isinstance(partition["size"], str) and partition["size"][-1] == "%":
                percentage = int(partition["size"][:-1])
                total_percentage += percentage
                size = int(free_space * percentage / 100)
                partitions_schema[index] = {"size": size}
        if total_percentage > 100:
            msg = f"Percentages add up to more than 100%: {total_percentage}"
            logger.error(msg)
            return False
        return partitions_schema

    def get_number_of_filler_parts():
        filler_parts = 0
        for index, partition in enumerate(PARTS):
            index = index + 10
            if isinstance(partition["size"], bool):
                filler_parts += 1
        return filler_parts

    def populate_partition_schema_with_other_data(partitions_schema):
        # Now let's properly populate partition schema with other data
        for index, partition in enumerate(PARTS):
            index = index + 10
            for key, value in partition.items():
                if key == "size":
                    continue
                try:
                    partitions_schema[index][key] = value
                except KeyError:
                    pass
        return partitions_schema

    ## FN ENTRY POINT
    if len(PARTS) >= 3 and not IS_GPT:
        logger.error(
            "We cannot create a two data parts in MBR mode... Didn't bother to code that path for prehistoric systems"
        )
        sys.exit(1)

    # Create a basic partition schema
    partitions_schema = create_partition_schema()
    # Add fixed size partitions to partition schema
    partitions_schema = add_fixed_size_partitions(partitions_schema)
    # Add percentage size partitions to partition schema
    partitions_schema = add_percent_size_partitions(partitions_schema)

    filler_parts = get_number_of_filler_parts()
    # Depending on how many partitions fill the remaining space, convert filler partitions to percentages
    if filler_parts > 1:
        for index, partition in enumerate(PARTS):
            # If we already have percentage partitions, we need to drop them now
            if isinstance(partition["size"], str) and partition["size"][-1] == "%":
                PARTS[index]["size"] = "already calculated"
            if isinstance(partition["size"], bool):
                PARTS[index]["size"] = str(int(100 / filler_parts)) + "%"
        # Now we have to do the percentage calculations again
        partitions_schema = add_percent_size_partitions(partitions_schema)
    else:
        # Else just fill remaining partition with all space
        free_space = USABLE_DISK_SPACE - get_allocated_space(partitions_schema)
        for index, partition in enumerate(PARTS):
            index = index + 10
            if isinstance(partition["size"], bool):
                partitions_schema[index] = {"size": free_space}
    partitions_schema = populate_partition_schema_with_other_data(partitions_schema)

    # Sort partition schema
    partitions_schema = dict(sorted(partitions_schema.items()))
    return partitions_schema


def validate_partition_schema(partitions: dict):
    total_size = 0
    for partition in partitions.keys():
        for key, value in partitions[partition].items():
            if key == "size":
                total_size += value
        msg = f"PART {partition}: {partitions[partition]}"
        logger.info(msg)

    if total_size > USABLE_DISK_SPACE:
        msg = f"Total required partition space {total_size} exceeds disk space {USABLE_DISK_SPACE}"
        logger.error(msg)
        return False
    logger.info(f"Total allocated disk size: {total_size} / {USABLE_DISK_SPACE}")
    return True


def prepare_non_kickstart_partitions(partitions_schema: dict):
    """
    When partitions don't have a mountpoint, we'll have to create the FS ourselves
    If partition has a xfs label, let's create it
    """
    part_number = 1
    for part_properties in partitions_schema.values():
        if part_properties["mountpoint"] is None:
            logger.info(
                f"Partition {DISK_PATH}{part_number} has no mountpoint and won't be handled by kickstart. Going to create it FS {part_properties['fs']}"
            )
            cmd = f'mkfs.{part_properties["fs"]} -f {DISK_PATH}{part_number}'
            if DRY_RUN:
                result = True, "Dry run"
            else:
                result, output = dirty_cmd_runner(cmd)
            if not result:
                logger.error(f"Command {cmd} failed: {output}")
                return False

        if "label" in part_properties.keys():
            if part_properties["fs"] == "xfs":
                cmd = (
                    f'xfs_admin -L {part_properties["label"]} {DISK_PATH}{part_number}'
                )
            elif part_properties["fs"].lower()[:3] == "ext":
                cmd = f'tune2fs -L {part_properties["label"]} {DISK_PATH}{part_number}'
            else:
                logger.error(
                    f'Setting label on FS {part_properties["fs"]} is not implemented'
                )
                return False
            logger.info(
                f'Setting up partition {DISK_PATH}{part_number} FS {part_properties["fs"]} with label {part_properties["label"]}'
            )
            if DRY_RUN:
                result = True, "Dry run"
            else:
                result, output = dirty_cmd_runner(cmd)
            if not result:
                logger.error(f"Command {cmd} failed: {output}")
                return False
            
        part_number += 1
    return True


def write_kickstart_partitions_file(partitions_schema: dict):
    part_number = 1
    kickstart = ""
    for part_properties in partitions_schema.values():
        if part_properties["mountpoint"]:
            # parted wants "linux-swap" whereas kickstart needs "swap" as fstype
            if part_properties["fs"] == "linux-swap":
                part_properties["fs"] = "swap"
            kickstart += f'part {part_properties["mountpoint"]} --fstype {part_properties["fs"]} --onpart={DISK_PATH}{part_number}\n'
        part_number += 1

    try:
        with open("/tmp/partitions", "w", encoding="utf-8") as fp:
            fp.write(kickstart)
    except OSError as exc:
        logger.error(f"Cannot write /tmp/partitions: {exc}")
        return False
    return True


def execute_parted_commands(partitions_schema: dict):
    parted_commands = []
    partition_start = 0
    for part_properties in partitions_schema.values():
        if partition_start == 0:
            partition_start = "1024KiB"
            partition_end = 1 + part_properties["size"]
        else:
            partition_start = partition_end
            partition_end = partition_start + part_properties["size"]
        parted_commands.append(
            f'parted -a optimal -s {DISK_PATH} mkpart primary {part_properties["fs"]} {partition_start} {partition_end}'
        )
    for parted_command in parted_commands:
        if DRY_RUN:
            result = True, "Dry run"
        else:
            result, output = dirty_cmd_runner(parted_command)
        if not result:
            logger.error(f"Cannot run parted command {parted_command}: {output}")
            return False
    # Arbitrary sleep command
    sleep(3)
    return True


def setup_package_lists():
    logger.info("Setting up package ignore lists")
    package_ignore_virt_list = [
        'linux-firmware',
        'a*-firmware',
        'i*-firmware',
        'lib*firmware',
        'n*firmware',
        'plymouth',
        'pipewire'
    ]

    package_add_physical_list = [
        'lm_sensors',
        'smartmontools'
    ]
    try:
        with open("/tmp/packages", "w", encoding="utf-8") as fp:
            if IS_VIRTUAL and REMOVE_VIRTUAL_PACKAGES:
                for package in package_ignore_virt_list:
                    fp.write(f"-{package}\n")
            elif not IS_VIRTUAL and ADD_PHYSICAL_PACKAGES:
                for package in package_add_physical_list:
                    fp.write(f"{package}\n")
            else:
                fp.write("\n")
        return True
    except OSError as exc:
        logger.error(f"Cannot create /tmp/packages file: {exc}")
        return False


def setup_hostname():
    logger.info("Setting up hostname")
    if IS_VIRTUAL:
        hostname=VIRTUAL_HOSTNAME
    else:
        hostname=PHYSICAL_HOSTNAME

    try:
        with open("/tmp/hostname", "w", encoding="utf-8") as fp:
            fp.write(f"network --hostname={hostname}\n")
        return True
    except OSError as exc:
        logger.error(f"Cannot create /tmp/hostname file: {exc}")
        return False
    

def setup_users():
    """
    Root password non encrypted version
    rootpw MyNonEncryptedPassword
    user --name=user --password=MyNonEncryptedUserPassword

    Or password with encryption
    password SHA-512 with openssl passwd -6 (used here)
    password SHA-256 with openssl passwd -5
    password MD5 (don't) with openssl passwd -1
    """
    logger.info("Setting up password file")
    if ARE_PASSWORDS_CRYPTED:
        is_crypted = "--iscrypted "
    else:
        is_crypted = ""
    root = rf"rootpw {is_crypted}{DEFAULT_ROOT_PASSWORD}"
    user = rf"user --name {DEFAULT_USER_NAME} {is_crypted}--password={DEFAULT_USER_PASSWORD}"

    try:
        with open("/tmp/users", "w", encoding="utf-8") as fp:
            fp.write(f"{root}\n{user}\n")
        return True
    except OSError as exc:
        logger.error(f"Cannot create /tmp/users file: {exc}")
        return False


# Script entry point
DRY_RUN = False  # For dev

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(message)s",
    handlers=[logging.FileHandler("/tmp/prescript.log"), logging.StreamHandler()],
)
logger = logging.getLogger()

TARGET = TARGET.lower()
if TARGET == "hw":
    PARTS = PARTS_HV
elif TARGET == "hv-stateless":
    PARTS = PARTS_HV_STATELESS
elif TARGET == "stateless":
    PARTS = PARTS_STATELSSS
elif TARGET == "generic":
    PARTS = PARTS_GENERIC
elif TARGET == "anssi":
    PARTS = PARTS_ANSSI
else:
    logger.error(f"Bad target given: {TARGET}")
    exit(222)


IS_VIRTUAL, _ = dirty_cmd_runner(
    r'dmidecode | grep -i "kvm\|qemu\|vmware\|hyper-v\|virtualbox\|innotek\|netperfect_vm"'
)
IS_GPT = is_gpt_system()
DISK_PATH = get_first_disk_path()
if not DISK_PATH:
    sys.exit(10)
if not zero_disk(DISK_PATH):
    sys.exit(1)
if not init_disk(DISK_PATH):
    sys.exit(2)
disk_space_mb = get_disk_size_mb(DISK_PATH)
if not disk_space_mb:
    sys.exit(3)
USABLE_DISK_SPACE = disk_space_mb - 2  # keep 1KB empty at beginning and 1MB at end
if not IS_VIRTUAL:
    # Let's reserve 5% of disk space on physical machine
    MAX_USABLE = 0.95
    REAL_USABLE_DISK_SPACE = USABLE_DISK_SPACE
    USABLE_DISK_SPACE = int(USABLE_DISK_SPACE * 0.95)
    logger.info(
        f"Reducing usable disk space by {MAX_USABLE * 100} from {REAL_USABLE_DISK_SPACE} to {USABLE_DISK_SPACE}"
    )

partitions_schema = get_partition_schema()
if not partitions_schema:
    sys.exit(4)
if not validate_partition_schema(partitions_schema):
    sys.exit(5)
if not execute_parted_commands(partitions_schema):
    sys.exit(6)
if not prepare_non_kickstart_partitions(partitions_schema):
    sys.exit(7)
if not write_kickstart_partitions_file(partitions_schema):
    sys.exit(8)

logger.info("Partitionning done. Please use '%include /tmp/partitions")

if not setup_package_lists():
    sys.exit(9)

if not setup_hostname():
    sys.exit(10)

if not setup_users():
    sys.exit(11)
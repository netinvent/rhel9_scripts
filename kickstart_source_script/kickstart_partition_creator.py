#! /usr/bin/env python3
#  -*- coding: utf-8 -*-


__intname__ = "kickstart.partition_script.RHEL9"
__author__ = "Orsiris de Jong"
__copyright__ = "Copyright (C) 2022-2024 Orsiris de Jong - NetInvent SASU"
__licence__ = "BSD 3-Clause"
__build__ = "2024041502"

### This is a pre-script for kickstart files in RHEL 9
### Allows specific partition schemes with one or more data partitions
# Standard paritioning scheme is
# | (efi) | boot | root | data 1 | data part n | swap
# LVM partitioning scheme is
# | (efi) | boot | lv [data 1| data part n | swap]

## Possible partitionning targets
# generic: One big root partition
# web: Generic web server setup
# anssi: ANSSI-BP028 high profile compatible partitioning scheme
# hv: Standard KVM hypervisor
# hv-stateless: Stateless KVM hypervisor, /!\: NOT LVM compatible
# stateless: Generic machine with a 50% sized partition for statefulness (readonly-ro), /!\: NOT LVM compatible
TARGET = "anssi"

# Reserve 5% of disk space on physical machines, useful for SSD disks
# Set to 0 to disable
REDUCE_PHYSICAL_DISK_SPACE = 5

# Enable LVM partitioning
LVM_ENABLED = True
# LVM volume group name
VG_NAME = "vg00"
# LVM Physical extent size
PE_SIZE = 4096

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
PHYSICAL_HOSTNAME = "pmv43.npf.local"
VIRTUAL_HOSTNAME = "vmv43.npf.local"

## Package management
# Add lm-sensros and smartmontools on physical machines
ADD_PHYSICAL_PACKAGES = True
# Remove firmware packages, plymouth and pipewire on virtual machines
REMOVE_VIRTUAL_PACKAGES = True


import sys
import os
from typing import Tuple
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
    {
        "size": True,
        "fs": "xfs",
        "mountpoint": "/var/lib/libvirt/images",
        "fsoptions": "nodev,nosuid,noexec",
    },
]

# Partition schema for stateless KVM Hypervisor
PARTS_HV_STATELESS = [
    {"size": 30720, "fs": "xfs", "mountpoint": "/"},
    {
        "size": True,
        "fs": "xfs",
        "mountpoint": "/var/lib/libvirt/images",
        "fsoptions": "nodev,nosuid,noexec",
    },
    {"size": 30720, "fs": "xfs", "mountpoint": None, "label": "STATEFULRW"},
]

# Partition schema for stateless machines
PARTS_STATELSSS = [
    {"size": True, "fs": "xfs", "mountpoint": "/"},
    {"size": True, "fs": "xfs", "mountpoint": None, "label": "STATEFULRW"},
]

# Partition schema for generic machines with only one big root partition
PARTS_GENERIC = [{"size": True, "fs": "xfs", "mountpoint": "/"}]

# Partition schema for generic web servers (sized for minimum 20GB web servers)
PARTS_WEB = [
    {"size": 5120, "fs": "xfs", "mountpoint": "/"},
    {
        "size": True,
        "fs": "xfs",
        "mountpoint": "/var/www",
        "fsoptions": "nodev,nosuid,noexec",
    },
    {
        "size": 4096,
        "fs": "xfs",
        "mountpoint": "/var/log",
        "fsoptions": "nodev,nosuid,noexec",
    },
    {
        "size": 1024,
        "fs": "xfs",
        "mountpoint": "/tmp",
        "fsoptions": "nodev,nosuid,noexec",
    },
    {
        "size": 1024,
        "fs": "xfs",
        "mountpoint": "/var/tmp",
        "fsoptions": "nodev,nosuid,noexec",
    },
]

# Example partition schema for ANSSI-BP028 high profile
# This example requires at least 65GB of disk space
# as it will also require swap space depeding on memory size, /boot and /boot/efi space
PARTS_ANSSI = [
    {"size": 5120, "fs": "xfs", "mountpoint": "/"},
    {"size": 5120, "fs": "xfs", "mountpoint": "/usr", "fsoptions": "nodev"},
    {"size": 1024, "fs": "xfs", "mountpoint": "/opt", "fsoptions": "nodev,nosuid"},
    {"size": 10240, "fs": "xfs", "mountpoint": "/home", "fsoptions": "nodev"},
    # {"size": 40960 , "fs": "xfs", "mountpoint": "/srv", "fsoptions": "nodev,nosuid"},        # When FTP/SFTP server is used
    {
        "size": 5120,
        "fs": "xfs",
        "mountpoint": "/tmp",
        "fsoptions": "nodev,nosuid,noexec",
    },
    {"size": True, "fs": "xfs", "mountpoint": "/var", "fsoptions": "nodev"},
    {
        "size": 5120,
        "fs": "xfs",
        "mountpoint": "/var/tmp",
        "fsoptions": "nodev,nosuid,noexec",
    },
    {
        "size": 10240,
        "fs": "xfs",
        "mountpoint": "/var/log",
        "fsoptions": "nodev,nosuid,noexec",
    },
    {
        "size": 2048,
        "fs": "xfs",
        "mountpoint": "/var/log/audit",
        "fsoptions": "nodev,nosuid,noexec",
    },
]


def dirty_cmd_runner(cmd: str) -> Tuple[int, str]:
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
    if DEV_MOCK:
        return 16384
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
    if DEV_MOCK:
        return "/dev/vdx"
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
    We need this instead of "cleanpart" directive since we're partitionning manually
    in order to have a custom partition schema
    """
    cmd = f"dd if=/dev/zero of={disk_path} bs=512 count=1 conv=notrunc && blockdev --rereadpt {disk_path}"
    logger.info(f"Zeroing disk {disk_path}")
    if DEV_MOCK:
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
    if DEV_MOCK:
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
    if DEV_MOCK:
        return 61140  # 60GB
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
    for key, value in partitions_schema.items():
        if key == "lvm":
            for lvm_value in value.values():
                allocated_space += lvm_value["size"]
            continue
        allocated_space += partitions_schema[key]["size"]
    return allocated_space


def get_partition_schema() -> dict:
    global PARTS

    mem_size = get_mem_size()
    if mem_size > 16384:
        swap_size = mem_size
    else:
        swap_size = int(mem_size / 2)

    def create_partition_schema():
        if IS_GPT:
            partitions_schema = {
                "0": {"size": 600, "fs": "fat32", "mountpoint": "/boot/efi"},
                "1": {"size": 1024, "fs": "xfs", "mountpoint": "/boot"},
            }
        else:
            partitions_schema = {
                "0": {"size": 1024, "fs": "xfs", "mountpoint": "/boot"}
            }

        if LVM_ENABLED:
            partitions_schema["lvm"] = {
                "99": {"size": swap_size, "fs": "linux-swap", "mountpoint": "swap"}
            }
        else:
            partitions_schema["99"] = {
                "size": swap_size,
                "fs": "linux-swap",
                "mountpoint": "swap",
            }
        return partitions_schema

    def add_fixed_size_partitions(partitions_schema):
        """
        Add fixed size partitions to partition schema
        """
        for index, partition in enumerate(PARTS):
            # Shift index so we don't overwrite boot partition indexes
            index = str(int(index) + 10)
            if not isinstance(partition["size"], bool) and isinstance(
                partition["size"], int
            ):
                if LVM_ENABLED:
                    partitions_schema["lvm"][index] = {"size": partition["size"]}
                else:
                    partitions_schema[index] = {"size": partition["size"]}
        return partitions_schema

    def add_percent_size_partitions(partitions_schema):
        """
        Add percentage size partitions to partition schema
        """
        total_percentage = 0
        free_space = USABLE_DISK_SPACE - get_allocated_space(partitions_schema)
        for index, partition in enumerate(PARTS):
            index = str(int(index) + 10)
            if isinstance(partition["size"], str) and partition["size"][-1] == "%":
                percentage = int(partition["size"][:-1])
                total_percentage += percentage
                size = int(free_space * percentage / 100)
                if LVM_ENABLED:
                    partitions_schema["lvm"][index] = {"size": size}
                else:
                    partitions_schema[index] = {"size": size}
        if total_percentage > 100:
            msg = f"Percentages add up to more than 100%: {total_percentage}"
            logger.error(msg)
            return False
        return partitions_schema

    def get_number_of_filler_parts():
        """
        Determine the number of partitions that will fill the remaining space
        """
        filler_parts = 0
        for partition in PARTS:
            if isinstance(partition["size"], bool):
                filler_parts += 1
        return filler_parts

    def populate_partition_schema_with_other_data(partitions_schema):
        """
        Populate partition schema with FS and mountpoints
        """
        for index, partition in enumerate(PARTS):
            index = str(int(index + 10))
            for key, value in partition.items():
                if key == "size":
                    continue
                try:
                    if LVM_ENABLED:
                        partitions_schema["lvm"][index][key] = value
                    else:
                        partitions_schema[index][key] = value
                except KeyError:
                    pass
        return partitions_schema

    ## FN ENTRY POINT
    # When using MBR and more than 3
    if len(PARTS) >= 3 and not IS_GPT and not LVM_ENABLED:
        logger.error(
            "We cannot create more than 4 parts in MBR mode (boot + swap + two other partitions)...Didn't bother to code that path for prehistoric systems. Consider enabling LVM"
        )
        sys.exit(1)

    # Create a basic partition schema
    partitions_schema = create_partition_schema()
    # Add fixed size partitions to partition schema
    partitions_schema = add_fixed_size_partitions(partitions_schema)
    # Add percentage size partitions to partition schema
    partitions_schema = add_percent_size_partitions(partitions_schema)

    filler_parts = get_number_of_filler_parts()
    logger.info(f"Number of filler partitions: {filler_parts}")
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
        if free_space < 0:
            logger.error(
                "Cannot fill remaining space with partitions. Not enough space left. Is your partition schema valid ?"
            )
            logger.error(
                f"Usable disk space: {USABLE_DISK_SPACE}, schema allocated space: {get_allocated_space(partitions_schema)}"
            )
            return
        for index, partition in enumerate(PARTS):
            index = str(int(index + 10))
            if isinstance(partition["size"], bool):
                if LVM_ENABLED:
                    partitions_schema["lvm"][index] = {"size": free_space}
                else:
                    partitions_schema[index] = {"size": free_space}
    partitions_schema = populate_partition_schema_with_other_data(partitions_schema)

    # Sort partition schema
    partitions_schema = dict(sorted(partitions_schema.items()))
    if LVM_ENABLED:
        partitions_schema["lvm"] = dict(sorted(partitions_schema["lvm"].items()))
    return partitions_schema


def validate_partition_schema(partitions: dict) -> bool:
    """
    Check if our partition schema doesn't exceeed disk size
    """
    total_size = 0
    for partition in partitions.keys():
        if partition == "lvm":
            for lvm_partition in partitions["lvm"].keys():
                for key, value in partitions["lvm"][lvm_partition].items():
                    if key == "size":
                        total_size += value
                msg = f"LVMPART {lvm_partition}: {partitions[partition][lvm_partition]}"
                logger.info(msg)
            continue
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


def prepare_non_kickstart_partitions(partitions_schema: dict) -> bool:
    """
    When partitions don't have a mountpoint, we'll have to create the FS ourselves
    If partition has a xfs label, let's create it
    """

    def prepare_non_kickstart_partition(part_properties, part_number):
        if part_properties["mountpoint"] is None:
            logger.info(
                f"Partition {DISK_PATH}{part_number} has no mountpoint and won't be handled by kickstart. Going to create it FS {part_properties['fs']}"
            )
            cmd = f'mkfs.{part_properties["fs"]} -f {DISK_PATH}{part_number}'
            if DEV_MOCK:
                result = True
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
            if DEV_MOCK:
                result = True
            else:
                result, output = dirty_cmd_runner(cmd)
            if not result:
                logger.error(f"Command {cmd} failed: {output}")
                return False

    part_number = 1
    for part_index, part_properties in partitions_schema.items():
        if part_index == "lvm":
            for lvm_part_properties in partitions_schema["lvm"].values():
                prepare_non_kickstart_partition(lvm_part_properties, part_number)
        else:
            prepare_non_kickstart_partition(part_properties, part_number)
        part_number += 1
    return True


def write_kickstart_partitions_file(partitions_schema: dict) -> bool:
    part_number = 1
    kickstart = ""
    for key, part_properties in partitions_schema.items():
        if key == "lvm":
            kickstart += "part PVGroup --grow --size=1\n"
            kickstart += f"volgroup {VG_NAME} --pesize={PE_SIZE} PVGroup\n"
            continue
        if part_properties["mountpoint"]:
            # parted wants "linux-swap" whereas kickstart needs "swap" as fstype
            if part_properties["fs"] == "linux-swap":
                part_properties["fs"] = "swap"
            try:
                fsoptions = f' --fsptions={part_properties["fsoptions"]}'
            except KeyError:
                # Don't bother if partition doesn't have fsoptions
                fsoptions = ""
            kickstart += f'part {part_properties["mountpoint"]} --fstype {part_properties["fs"]} --onpart={DISK_PATH}{part_number}{fsoptions}\n'
        part_number += 1

    if LVM_ENABLED:
        for part_properties in partitions_schema["lvm"].values():
            if part_properties["mountpoint"]:
                # parted wants "linux-swap" whereas kickstart needs "swap" as fstype
                if part_properties["fs"] == "linux-swap":
                    part_properties["fs"] = "swap"
                try:
                    fsoptions = f' --fsptions={part_properties["fsoptions"]}'
                except KeyError:
                    # Don't bother if partition doesn't have fsoptions
                    fsoptions = ""
                if part_properties["mountpoint"] == "/":
                    name = "root"
                else:
                    name = part_properties["mountpoint"].replace("/", "")
                kickstart += f'logvol {part_properties["mountpoint"]} --vgname {VG_NAME} --fstype {part_properties["fs"]} --name={name}{fsoptions} --size={part_properties["size"]}\n'
            part_number += 1
    try:
        with open("/tmp/partitions", "w", encoding="utf-8") as fp:
            fp.write(kickstart)
    except OSError as exc:
        logger.error(f"Cannot write /tmp/partitions: {exc}")
        return False
    return True


def execute_parted_commands(partitions_schema: dict) -> bool:
    """
    We need to manually run partitioning commands since we're not using anaconda to create partitions
    This allows us to have non mounted partitions, eg stateful partitions for readonly-root setups

    Unless specified, parted deals in megabytes
    """
    parted_commands = []
    partition_start = 0
    for part_index, part_properties in partitions_schema.items():
        if partition_start == 0:
            # Properly align first partition to 1MiB for SSD disks
            partition_start = "1024KiB"
            partition_end = 1 + part_properties["size"]
    
        elif part_index == "lvm":
            # Let's assume that partition_end is already calulated since LVM is never the first partition
            partition_start = partition_end
            parted_commands.append(
                f"parted -a optimal -s {DISK_PATH} mkpart primary {partition_start} {USABLE_DISK_SPACE}"
            )
            # Assume we only have one big lvm partition, don't bother with others
            continue

        else:  # Non LVM partitions handling
            partition_start = partition_end
            partition_end = partition_start + part_properties["size"]
        parted_commands.append(
            f'parted -a optimal -s {DISK_PATH} mkpart primary {part_properties["fs"]} {partition_start} {partition_end}'
        )
    for parted_command in parted_commands:
        if DEV_MOCK:
            logger.info(f"Would execute command {parted_command}")
            result = True
        else:
            logger.info(f"Executing command {parted_command}")
            result, output = dirty_cmd_runner(parted_command)
        if not result:
            logger.error(f"Command failed: {output}")
            return False
    # Arbitrary sleep command
    sleep(3)
    return True


def setup_package_lists() -> bool:
    logger.info("Setting up package ignore lists")
    package_ignore_virt_list = [
        "linux-firmware",
        "a*-firmware",
        "i*-firmware",
        "lib*firmware",
        "n*firmware",
        "plymouth",
        "pipewire",
    ]

    package_add_physical_list = ["lm_sensors", "smartmontools"]
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


def setup_hostname() -> bool:
    logger.info("Setting up hostname")
    if IS_VIRTUAL:
        hostname = VIRTUAL_HOSTNAME
    else:
        hostname = PHYSICAL_HOSTNAME

    try:
        with open("/tmp/hostname", "w", encoding="utf-8") as fp:
            fp.write(f"network --hostname={hostname}\n")
        return True
    except OSError as exc:
        logger.error(f"Cannot create /tmp/hostname file: {exc}")
        return False


def setup_users() -> bool:
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
# Set DEV_MOCK to True to avoid executing any command and just create the required files for anaconda
# Of course, we won't be able to get disk size and memory size
DEV_MOCK = False

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(message)s",
    handlers=[logging.FileHandler("/tmp/prescript.log"), logging.StreamHandler()],
)
logger = logging.getLogger()

if DEV_MOCK:
    logger.info(
        "Running in DEV_MOCK mode. Nothing will be executed or actually done here."
    )

TARGET = TARGET.lower()
if TARGET == "hv":
    PARTS = PARTS_HV
elif TARGET == "hv-stateless":
    PARTS = PARTS_HV_STATELESS
elif TARGET == "stateless":
    PARTS = PARTS_STATELSSS
elif TARGET == "generic":
    PARTS = PARTS_GENERIC
elif TARGET == "web":
    PARTS = PARTS_WEB
elif TARGET == "anssi":
    PARTS = PARTS_ANSSI
else:
    logger.error(f"Bad target given: {TARGET}")
    exit(222)
logger.info(f"Running script for target: {TARGET}")


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
if not IS_VIRTUAL and REDUCE_PHYSICAL_DISK_SPACE:
    # Let's reserve 5% of disk space on physical machine
    REAL_USABLE_DISK_SPACE = USABLE_DISK_SPACE
    USABLE_DISK_SPACE = int(
        USABLE_DISK_SPACE * (100 - REDUCE_PHYSICAL_DISK_SPACE) / 100
    )
    logger.info(
        f"Reducing usable disk space by {REDUCE_PHYSICAL_DISK_SPACE}% from {REAL_USABLE_DISK_SPACE} to {USABLE_DISK_SPACE} since we deal with physical disks"
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

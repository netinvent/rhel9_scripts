[![License](https://img.shields.io/badge/License-BSD%203--Clause-blue.svg)](https://opensource.org/licenses/BSD-3-Clause)
[![GitHub Release](https://img.shields.io/github/release/netinvent/rhel9_scripts.svg?label=Latest)](https://github.com/netinvent/rhel9_scripts/releases/latest)
[![Python linter](https://github.com/netinvent/rhel9_scripts/actions/workflows/pylint-windows.yaml/badge.svg)](https://github.com/netinvent/rhel9_scripts/actions/workflows/pylint.yaml)
[![Bash linter](https://github.com/netinvent/rhel9_scripts/actions/workflows/pylint-linux.yaml/badge.svg)](https://github.com/netinvent/rhel9_scripts/actions/workflows/shellcheck.yaml)

## Redhat Enterprise Linux / AlmaLinux / RockyLinux anaconda scipts

### Kickstart file

The kickstart file contains a python script which handles automagic partitioning and other small adjustemnts.  
It will handle MBR, GPT and LVM style partitioning, while being able to autosize partitions.  

The python script is to be executed as `%pre --interpreter=/bin/python3` script and will create the following:

Automatic setup of machines with

- Dynamic partition schema depending on selected target:
  - `hv`: Hypervisor layout with 30GB root partition and `/var/lib/livirt/images` maximum partition size
  - `hv-stateless`: The same as above but with a 30GB size partition with label `STATEFULRW` for stateful storage
  - `stateless`: A 50% size root partition and 50% size partition with label `STATEFULRW` for stateful storage
  - `generic`: A 100% size root partition
  - `web`: A secure web server (subset of ANSSI BP-028-High)
  - `anssi`: ANSSI BP-028-High compatible partition schema

Of course, you can adjust those values or create new partition schemas directly in the python script.

The kickstat file also provides the following:

- Optional packages if physical machine
    - pre-configured smartmontools daemon
    - Optional IT8613 support
    - Intel TCO Watchdog support
    - Tuned config profiles npf-eco and npf-perf
- Optional setups on virtual machines
    - Exclusion of firmware packages
    - Qemu guest agent setup on KVM machines
- Enabling serial console on tty and grub interface
    - Add resize_term() and resize_term2() functions which allows to deal with tty resizing in terminal
- Optional steps if DHCP internet is found
    - Installation of non standard packages
    - ANSSI-BP028-High SCAP Profile configuration with report
    - Prometheus Node exporter installation
- Enable cockpit and allow non root users
- Cleanup of image after setup

### Technical notes about this script

Instead of relying on anaconda for partitioning, the script will handle partitioning via parted to allow usage of non mounted partitions for readonly-root setups with stateful partitions which should not be mounted via fstab.

The script can also optionally reserve 5% disk space at the end of physical disk, in order to have some reserved space left for SSD drives.

If the installation fails for some reason, the logs will be found in `/tmp/prescript.log`

### Restrictions

Using LVM partitioning is incompatible with stateless partitioning since the latter requires partitions without mountpoints.  
As of today, the python script only uses a single disk. Multi disk support can be added on request.

### Troubleshooting

When anaconda install fails, you have to change the terminal (CTRL+ALT+F2) in order to check file `/tmp/prescript.log`.  
Using a serial console, you'll have to use ESC+TAB in order to change terminal.

When installing on an existing disk, the script is not capable to unload LVM partitions, hence it may zero the disk, but the kernel will still think the LVM partitions exist.  
In that case, just reboot and reinstall, since the disk has been emptied, everything will work properly.

## Other scripts

### Setup Hypervisor

Setup KVM environment

### Setup OPNSense

Download and instlal OPNSense firewall and passthrough 2 PCI NICs

### Setup Readonly

Transform a RHEL 9 machine into readonly, especially if hypervisor exists

### Setup simplehelp

Setup simplehelp service, compatible with readonly linux

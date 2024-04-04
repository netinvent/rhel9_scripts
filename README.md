## Redhat Enterprise Linux / AlmaLinux / RockyLinux anaconda scipts

### Kickstart file

The kickstart file contains a python script which handles automagic partitioning and other small adjustemnts.

The python script is to be executed as `%pre --interpreter=/bin/python3` script and will create the following:

Automatic setup of machines with

- Dynamic partition schema depending on selected target:
  - `hv-stateless`: Hypervisor layout with 30GB root partition and `/var/lib/livirt/images` maximum partition size
  - `hv-stateless`: The same as above but with a 30GB Stateful partition with label `STATEFULRW`
  - `stateless`: A 50% size root partition and 50% size stateless partition with label `STATEFULRW`
  - `generic`: A 100% size root partition
  - `anssi`: ANSSI BP-028-High compatible partition schema

Of course, you can adjust those values or create new partition schemas directly in the python script.

- Optional packages if physical machine
    - pre-configured smartmontools daemon
    - Optional IT8613 support
    - Intel TCO Watchguard support
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
- Cleanup of image after setup

### Setup Hypervisor

Setup KVM environment

### Setup OPNSense

Download and instlal OPNSense firewall and passthrough 2 PCI NICs

### Setup Readonly

Transform a RHEL 9 machine into readonly, especially if hypervisor exists

### Setup simplehelp

Setup simplehelp service, compatible with readonly linux
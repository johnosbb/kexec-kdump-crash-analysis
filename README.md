# Using Kexec & Kdump

Kernel Crash Analysis on Arch Linux

## Introduction
Kexec and Kdump are mechanisms available in the Linux kernel to capture and recover the kernel memory snapshot (/proc/vmcore) after a kernel panic. They can do this without requiring a full system reboot and this enables the preservation and retrieval of the system kernel’s memory image. This saved image can later be used for detailed post-mortem analysis to diagnose the cause of the crash.

These tools are uniquely suited to the capture and analysis of certain types of kernel panics. For example:

### Unrecoverable Conditions
When the kernel encounters an unrecoverable condition (e.g. NULL dereference in kernel space), user-space tools cannot respond — only a crash kernel loaded via Kdump can step in and save state (memory dump).

### Crashes in early init code
During kernel initialisation (device driver initialization, memory setup, filesystem mounting) traditional tools may not have yet started so Kdump is the only way to get meaningful data.

### Hardware Exceptions
Certain hardware-triggered exceptions (e.g. NMI, Machine Check Exceptions) in production systems, might not show logs before the system freezes. Kdump can capture the crash state if a crash kernel is preloaded.

### Deadlocks and soft lockups
In cases where the system is non-responsive but not fully halted, Kdump can often be triggered manually to capture state before reset.

## Setting up the Tools on Arch Linux
In this section we are going to look at setting up the tools on an Arch Linux VM hosted on Virtual Box.

```bash
sudo pacman -S crash kexec-tools makedumpfile
```

Checking the Kernel Configuration
We begin by checking the kernel configuration to ensure it supports kexec and kdump, and crucially, includes debug symbols for analysis.

The values shown below should be set.

```bash
CONFIG_KEXEC_CORE=y (Core kexec functionality)
CONFIG_KEXEC_FILE=y (Newer kexec_file_load syscall)
CONFIG_CRASH_DUMP=y (Enables kdump functionality)
CONFIG_PROC_VMCORE=y (Exposes crash dump via /proc/vmcore)
CONFIG_DEBUG_INFO=y (CRUCIAL for debugging symbols, allowing crash to provide meaningful information like function names and line numbers from the core dump.)
```

I have created a simple shell script to check these

```bash
#!/bin/bash
REQUIRED_OPTIONS=(
  "CONFIG_KEXEC_CORE"
  "CONFIG_KEXEC_FILE"
  "CONFIG_CRASH_DUMP"
  "CONFIG_PROC_VMCORE"
  "CONFIG_DEBUG_INFO"
)
CONFIG_FILE="/boot/config-$(uname -r)"
# If /proc/config.gz is available, use it as a fallback
if [ ! -f "$CONFIG_FILE" ] && [ -f /proc/config.gz ]; then
  echo "Extracting kernel config from /proc/config.gz..."
  zcat /proc/config.gz > /tmp/kernel_config_check
  CONFIG_FILE="/tmp/kernel_config_check"
fi

if [ ! -f "$CONFIG_FILE" ]; then
  echo "Could not find a kernel config file."
  exit 1
fi

echo "Checking kernel config in: $CONFIG_FILE"
echo "-------------------------------------------"

missing=0

for opt in "${REQUIRED_OPTIONS[@]}"; do
  if grep -q "^$opt=y" "$CONFIG_FILE"; then
    echo "$opt is enabled"
  else
    echo "$opt is NOT enabled"
    ((missing++))
  fi
done

echo "-------------------------------------------"
if [ "$missing" -eq 0 ]; then
  echo "All required Kexec/Kdump configs are enabled!"
else
  echo "$missing required option(s) are missing."
fi

# Cleanup temporary file if created
[ -f /tmp/kernel_config_check ] && rm /tmp/kernel_config_check
```

If these are not set then you may need to build a kernel version with these enabled. For my Arch Linux VM I built a kernel and configured it as follows.

## Download Kernel Source
for my system I downloaded the 6.9.0 kernel.

```bash
wget https://cdn.kernel.org/pub/linux/kernel/v6.x/linux-6.9.tar.xz
tar -xf linux-6.9.tar.xz
cd linux-6.9

## Configure the Kernel

I used my current config as a starting point:

zcat /proc/config.gz > .config
I then updated with default values for kexec and kdump options should above by using ‘make menuconfig’.
```

Then I ran

```bash
make olddefconfig
```
## Building the Kernel
I then built the kernel with

```bash
make -j$(nproc)
```

## Install Kernel & Initramfs

I installed the kernel as shown below making sure to also copy the vmlinux file to be used for later analysis of the crash.

```bash
sudo make modules_install
sudo cp arch/x86/boot/bzImage /boot/vmlinuz-6.9.0
sudo mkinitcpio -k 6.9.0 -g /boot/initramfs-6.9.0.img
cp vmlinux /boot/vmlinux-6.9.0-debug
```

## Modifying Grub to boot the new Kernel and Reserve Crash Space

I edited the GRUB_DEFAULT and the GRUB_CMDLINE_LINUX_DEFAULT lines in /etc/default/grub.

```bash
GRUB_DEFAULT="Advanced options for Arch Linux>Arch Linux, with Linux 6.9.0"
GRUB_TIMEOUT=10
GRUB_DISTRIBUTOR="Arch"
GRUB_CMDLINE_LINUX_DEFAULT="rootflags=compress-force=zstd crashkernel=512M panic=5 printk.devkmsg=on loglevel=7"
GRUB_DEFAULT now points to my new kernel and I also added the option crashkernel=512M to GRUB_CMDLINE_LINUX_DEFAULT. This latter change will reserve 512MB in system RAM for the crash kernel.
```
After making changes to grub we need to rebuild GRUB config:

```bash
sudo grub-mkconfig -o /boot/grub/grub.cfg
```

You can then reboot the system.

## Verify that the Crash Space has been Reserved
After reboot we can verify that we are now reserving memory for the crash kernel as follows:

```bash
sudo journalctl -b | grep crashkernel

or

sudo dmesg | grep crash
```

We should see

```bash
[    0.000000] Command line: BOOT_IMAGE=/boot/vmlinuz-6.9.0 root=UUID=61ac8f48-ac5c-4f69-823b-bb89fdae68c4 rw net.ifnames=0 rootflags=compress-force=zstd crashkernel=512M panic=5 printk.devkmsg=on loglevel=7
[    0.001136] crashkernel reserved: 0x00000000bf000000 - 0x00000000df000000 (512 MB)
[    0.011667] Kernel command line: BOOT_IMAGE=/boot/vmlinuz-6.9.0 root=UUID=61ac8f48-ac5c-4f69-823b-bb89fdae68c4 rw net.ifnames=0 rootflags=compress-force=zstd crashkernel=512M panic=5 printk.devkmsg=on loglevel=7
```

## Creating the Setup and Collect Services

We now need to setup the kexec and kdump tools so that on panic, the kernel’s kexec utility allows the execution of a “dump-capture” kernel directly from the crashed kernel. I have based this section on simple-kDump, but have made a few modifications which are available in my fork of the project.

We start this section by creating two services. The first of these is: /etc/systemd/system/simple-kdump-collect.service. This service’s role is to capture and store a crash dump after the crash kernel boots. It creates the directory where the crash dump and logs will be saved and uses the makedumpfile utility to extract and compress crash data from /proc/vmcore. It also extracts dmesg logs (vmcore-dmesg.log) for further analysis.

```bash
[Unit]
Description=Collect the vmcore for simple-kdump
DefaultDependencies=no

[Service]
Type=idle
ExecStart=/bin/sh -c 'dumpdir=$$(date "+%%F-%%T") && mkdir -p "/var/crash/$dumpdir" && /usr/bin/makedumpfile -d 31 /proc/vmcore "/var/crash/$dumpdir/vmcore.kdump" && /usr/bin/makedumpfile --dump-dmesg /proc/vmcore "/var/crash/$dumpdir/vmcore-dmesg.log"' #( Note: -d 31 applies bitmask filters to reduce dump size).
ExecStopPost=/usr/bin/systemctl --force reboot # Use systemctl reboot
UMask=0077
```

## kexec and kdump capture process
The second service is /etc/systemd/system/simple-kdump-setup.service

```bash
[Unit]
Description=Setup kexec environment for simple-kdump
After=local-fs.target

[Service]
Type=oneshot
EnvironmentFile=/etc/conf.d/simple-kdump.conf
RemainAfterExit=true
ExecStart=/usr/bin/kexec -p $KERNEL --initrd $INITRAMFS --append "${BOOT_OPTIONS} nr_cpus=1 reset_devices systemd.unit=emergency-kdump.target"
ExecStop=/usr/bin/kexec -p -u

[Install]
WantedBy=multi-user.target
```

This service uses the configuration file (/etc/conf.d/simple-kdump.con) shown below:

```bash
# Kernel and initramfs for the kexec environment.
# Recommended to use the linux or linux-lts kernel with 'default' preset.
KERNEL=/boot/vmlinuz-linux
INITRAMFS=/boot/initramfs-linux.img

# No crashkernel= option for the kexec kernel cmdline.
# Just regular boot options, the extra needed ones will be added by
# simple-kdump-setup service automatically.
BOOT_OPTIONS="root=UUID=61ac8f48-ac5c-4f69-823b-bb89fdae68c4 rw loglevel=5"  ##enter your disk UID here
```
This service sets up the kexec environment early in the boot process. This service is the key to the whole process so let us look at the two main lines:

```bash
ExecStart=/usr/bin/kexec -p $KERNEL --initrd $INITRAMFS --append "${BOOT_OPTIONS} nr_cpus=1 reset_devices systemd.unit=emergency-kdump.target"
ExecStop=/usr/bin/kexec -p -u
kexec -p: Prepares a crash kernel.
— initrd: Specifies the initramfs to load with the kernel.
— append: Sets kernel boot parameters for the crash kernel including the UID of the root disk. Note: Find your root partition’s UUID by using lsblk -f or blkid
Passes various boot options:
-> logging, nr_cpus=1: Limits CPUs used (simplifies crash dump collection).
-> reset_devices: Ensures a clean hardware reset.
-> systemd.unit=emergency-kdump.target: Boot into a minimal target to avoid interference during dump collection.
/usr/bin/kexec -p -u: This unloads the currently registered crash kernel.
```

## Enabling the New Services
We can enable these new services as follows:

```bash
sudo systemctl daemon-reload # Reload systemd units after creating new ones
sudo systemctl enable simple-kdump-setup.service
sudo systemctl start simple-kdump-setup.service
```

## Creating and Analysing a Crash

We can crash the kernel with:

```bash
echo c | sudo tee /proc/sysrq-trigger
```



Following the crash we will boot to the crash kernel as shown above.


vmcore kdump file created
If we look in ```/var/crash``` we should find our vmcore.kdump file (shown above).


## Crash Utility
vmlinux is the uncompressed, ELF-format (Executable and Linkable Format) file containing the entire Linux kernel, including: all compiled kernel code and symbol tables. It is essential when debugging kernel panics or oopses. In this example I have placed a copy of mine in /boot/vmlinuz-6.9.0-debug.

Using the core dump ( /var/crash/2025–06–22–16:05:01/vmcore.kdump) and a copy of the vmlinux file we can use the crash utility to find the source of the crash (as shown above).

From the crash report we can learn quite a lot:

```txt
Tool Used: crash 8.0.6 with GDB 10.2
Kernel Image: /boot/vmlinuz-6.9.0-debug
Dump File: /var/crash/2025–06–22–16:05:01/vmcore.kdump
Dump Type: ✅ Partial dump (not a full memory dump)
Crash Time: Sun Jun 22 16:05:00 UTC 2025
System Uptime Before Crash: 4 hours, 20 minutes, 52 seconds
Number of CPUs Detected: 1 (likely restricted by nr_cpus=1)
Kernel Version: 6.9.0 #2 SMP PREEMPT_DYNAMIC
Hostname: LinuxDebugging
Hardware: x86_64 @ 2.5 GHz with 4 GB RAM
Load Average at Crash: 0.00 (system idle)
Panic Message: Kernel panic — not syncing: sysrq triggered crash.
Crashing Process:PID: 1221
Command: tee
Task state: TASK_RUNNING (PANIC) — Task struct: ffff9fb14368c600
```

This particular message indicates a deliberate crash was triggered (e.g., using echo c > /proc/sysrq-trigger). which is consistent with our demonstration.

## Conclusion
In this article, I have shown how to configure and use Kexec and Kdump on Arch Linux to capture and analyze kernel crash dumps. By building a custom kernel with the necessary configuration options, reserving memory for a crash kernel, and setting up systemd services to handle crash collection, it’s possible to preserve valuable system state after a crash. The captured memory dump (/proc/vmcore) can then be analyzed using the crash utility alongside the uncompressed vmlinux kernel image to diagnose the cause of system failures, including panics, hardware exceptions, and lockups.

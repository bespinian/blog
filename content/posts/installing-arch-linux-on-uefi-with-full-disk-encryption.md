---
title: Installing Arch Linux on UEFI with Full Disk Encryption
author: Lena Fuhrimann
comments: true
date: 2021-03-12
---

This is a step-by-step guide to installing Arch Linux on [UEFI](https://en.wikipedia.org/wiki/Unified_Extensible_Firmware_Interface) with full disk encryption. It deliberately contains no unnecessary words or bling. It is heavily based on the [Arch Linux wiki's installation guide](https://wiki.archlinux.org/index.php/Installation_guide), so if you're ever stuck, just refer to it and the rest of the awesome Arch wiki.

## Download ISO

1. Download the latest ISO from the [Arch Linux website](https://archlinux.org/download/)

## Create Bootable USB Stick

You can skip this step if you just want to run Arch Linux in a VM. In that case, just run the ISO from your favorite VM management tool like [QEMU](https://www.qemu.org/).

1. Insert a USB stick into your computer
1. Run `lsblk` to find the correct disk
1. Run `sudo umount /dev/sdx` or whatever the USB stick is
1. Run `sudo dd bs=4M if=path/to/input.iso of=/dev/sdx oflag=sync status=progress` to write the ISO to the USB stick. Don't forget to replace the two paths with the correct ones.
1. Insert the USB stick into the target computer and boot it from there

As soon as you can see the Arch Linux prompt, you are ready for the next step.

## Check for UEFI support

1. Run `ls /sys/firmware/efi/efivars` to check if that directory exists. If it doesn't, your system does not support UEFI and this guide is not for you, and you should refer to the official [Arch Linux Installation Guide](https://wiki.archlinux.org/index.php/Installation_guide) instead.

## Establish Connectivity

1. Connect the computer via Ethernet (recommended) or run `iwctl` to log into Wi-Fi
1. Check for internet connectivity with `ping archlinux.org`
1. Make sure the clock is synced with `timedatectl set-ntp true`

## Partition

1. Check for different drives and partitions with `lsblk` and then start to partition with `gdisk /dev/nvme0n1` (or whatever the disk is)
1. Delete any existing partitions using `d`
1. Create boot partition with `n` with default number, default first sector, last sector at `+512M` and select `ef00` "EFI System" as the type
1. Create root partition with `n` with default number, default first sector, default last sector and select `8300` "Linux filesystem" as the type
1. Press `w` to write partitions
1. Run `lsblk` again to verify partitioning

## Encrypt Root Partition

1. Run `cryptsetup -y -v luksFormat /dev/nvme0n1p2` and then type `YES` and the new encryption password to encrypt the root partition
1. Run `cryptsetup open /dev/nvme0n1p2 cryptroot` to open the encrypted partition

## Create File Systems

1. Create the boot file system with `mkfs.fat -F32 /dev/nvme0n1p1` (or whatever the partition is called)
1. Create the root file system with `mkfs.ext4 /dev/mapper/cryptroot`

## Mount File Systems

1. Run `mount /dev/mapper/cryptroot /mnt` to mount the root file system
1. Run `mkdir /mnt/boot` to create the boot directory
1. Run `mount /dev/nvme0n1p1 /mnt/boot` to mount your boot file system
1. Run `lsblk` again to verify mounting

## Create Swap File (not needed on VMs)

1. Run `dd if=/dev/zero of=/mnt/swapfile bs=1M count=24576 status=progress` to create the swap file where the count is the number of mebibytes you want the swap file to be (usually around 1.5 times the size of your RAM)
1. Run `chmod 600 /mnt/swapfile` to set the right permissions on it
1. Run `mkswap /mnt/swapfile` to make it an actual swap file
1. Run `swapon /mnt/swapfile` to turn it on

## Install Arch Linux

1. Run `pacstrap /mnt base base-devel linux linux-firmware neovim` to install Arch Linux (`linux-firmware` is not needed on VMs)

## Generate File System Table

1. Run `genfstab -U /mnt >> /mnt/etc/fstab` to generate fstab with UUIDs

## Switch to Your New Linux Installation

1. Run `arch-chroot /mnt` to switch to your new Arch Linux installation

## Set Locales

1. Run `ln -sf /usr/share/zoneinfo/Europe/Zurich /etc/localtime` (or whatever your timezone is) to set your time zone
1. Run `hwclock --systohc`
1. Run `nvim /etc/locale.gen` and uncomment yours (e.g. `en_US.UTF-8 UTF-8`)
1. Run `locale-gen` to generate the locales
1. Run `echo 'LANG=en_US.UTF-8' > /etc/locale.conf`

## Set Hostname

1. Run `echo 'arch' > /etc/hostname` (or whatever your hostname should be)
1. Run `nvim /etc/hosts` and insert the following lines:

```txt
127.0.0.1     localhost
::1           localhost
127.0.1.1     arch.localdomain        arch
```

for the last line: change `arch` to whatever hostname you picked in the last step

## Set Root Password

1. Run `passwd` and set your root password

## Configure Initramfs

1. Run `nvim /etc/mkinitcpio.conf` and, to the `HOOKS` array, add `keyboard` between `autodetect` and `modconf` and add `encrypt` between `block` and `filesystems`
1. Run `mkinitcpio -P`

## Install Boot Loader

1. Run `pacman -S grub efibootmgr intel-ucode` (or `amd-ucode` if you have an AMD processor) to install the GRUB package and CPU microcode
1. Run `blkid -s UUID -o value /dev/nvme0n1p2` to get the UUID of the device
1. Run `nvim /etc/default/grub` and set `GRUB_TIMEOUT=0` to disable GRUB waiting until it chooses your OS (only makes sense if you don't dual boot with another OS), then set `GRUB_CMDLINE_LINUX="cryptdevice=UUID=xxxx:cryptroot"` while replacing "xxxx" with the UUID of the `nvme0n1p2` device to tell GRUB about our encrypted file system
1. Run `grub-install --target=x86_64-efi --efi-directory=/boot --bootloader-id=GRUB` to install GRUB for your system
1. Run `grub-mkconfig -o /boot/grub/grub.cfg` to configure GRUB

## Install Network Manager

1. Run `pacman -S networkmanager` to install NetworkManager
1. Run `systemctl enable NetworkManager` to run NetworkManager at boot

## Reboot

1. Run `exit` to return to the outer shell
1. Run `reboot` to get out of the setup

## Connect to Wi-Fi (only needed if there's no Ethernet connection)

1. Run `nmcli d wifi list` to list the available networks
1. Run `nmcli d wifi connect MY_WIFI password MY_PASSWORD` to connect to one of them

## Add User

1. Run `EDITOR=nvim visudo` and uncomment `%wheel ALL=(ALL) NOPASSWD: ALL` to allow members of the `wheel` group to run privileged commands
1. Run `useradd --create-home --groups wheel lena` (or whatever your user's name should be) to create the user
1. Run `passwd lena` to set your password
1. Run `exit` and log back in with your new user

## Install Window Manager

1. Run `sudo pacman -S sway swayidle swaylock` to install Sway
1. Add the following to `~/.zlogin` or whatever shell you are using:

```bash
# Start window manager
if [ "$(tty)" = "/dev/tty1" ]; then
  exec sway
fi
```

## Set Up Sound

1. Run `sudo pacman -S pipewire pipewire-pulse` to install Pipewire

## Set Up Bluetooth

1. Run `sudo pacman -S bluez bluez-utils` to install the Bluetooth utilities
1. Run `sudo systemctl enable bluetooth.service --now` to start Bluetooth

## Lock Root User (to be extra secure)

1. Run `sudo passwd --lock root` to lock out the root user

## Install a Firewall

1. Run `sudo pacman -S nftables` to install the firewall
1. Run `sudo nvim /etc/nftables.conf` to edit the config to our liking (e.g., according to the [Arch Wiki](https://wiki.archlinux.org/title/nftables#Workstation))
1. Run `sudo systemctl enable nftables.service --now` to enable the firewall

## Enable Time Synchronization

1. Run `sudo systemctl enable systemd-timesyncd.service --now` to enable automated time synchronization

## Improve Power Management (only makes sense on laptops)

1. Run `sudo pacman -S tlp tlp-rdw` to install TLP
1. Run `sudo systemctl enable tlp.service --now` to run power optimizations automatically
1. Run `sudo systemctl enable NetworkManager-dispatcher.service --now` to prevent conflicts
1. Run `sudo tlp-stat` and follow any recommendations there

## Enable Scheduled fstrim (only makes sense for SSDs)

1. Run `sudo systemctl enable fstrim.timer --now` to enable regular housekeeping of your SSD

## Enable Scheduled Mirrorlist Updates

1. Run `sudo pacman -S reflector` to install reflector
2. Run `sudo nvim /etc/xdg/reflector/reflector.conf` and change the file to your liking
3. Run `sudo systemctl enable reflector.timer --now` to enable running reflector regularly

## Reduce Swappiness (only makes sense if you have more than 4 GB of RAM)

1. Run `echo 'vm.swappiness=10' | sudo tee /etc/sysctl.d/99-swappiness.conf` to reduce the swappiness permanently

## Install Dotfiles

1. Run `sudo pacman -S git` to install Git
1. Install [Cloudlena's dotfiles](https://github.com/cloudlena/dotfiles/) or some other ones to customize your installation

#!/usr/bin/env bash

# umount -R /mnt
# swapoff /dev/mapper/cryptswap
# cryptsetup luksClose /dev/mapper/cryptswap
# cryptsetup luksClose /dev/mapper/arch-luks

# Set to true to debug
# From https://gareth.com/index.php/2020/07/16/semi-automated-arch-install/
WAITFORIT="FALSE"

# set -x
set -eu
set -o pipefail

# Non intel users remove intel-ucode from pacstrap and entries/arch.conf

print_message() {
  GREEN='\033[0;32m'
  NC='\033[0m'
  if [ "$WAITFORIT" == "TRUE" ]; then
      read -p "${GREEN}[*]${NC} ${*} [Enter]"        
  else
    echo -e "${GREEN}[*]${NC} ${*}"
  fi
}


HOSTNAME="xps"
ROOT_PASSWORD="foo"
LUKS_PASSWORD="bar"
DEVICE="/dev/nvme0n1"
TIMEZONE="Europe/Rome"
KEYMAP="us"
LOCALE="en_US.UTF-8"
LANGUAGE="en_US:en"

ESP_SIZE=100
SWAP_SIZE=16384
SWAP_END=$(( $ESP_SIZE + $SWAP_SIZE ))MiB

print_message "Creating partitions"
parted --script "${DEVICE}" -- mklabel gpt \
  mkpart ESP fat32 1Mib ${ESP_SIZE}Mib \
  set 1 boot on \
  mkpart primary linux-swap ${ESP_SIZE}Mib "${SWAP_END}" \
  mkpart primary "${SWAP_END}" 100% > /dev/null

BOOT_PART="$(ls ${DEVICE}* | grep -E "^${DEVICE}p?1$")"
SWAP_PART="$(ls ${DEVICE}* | grep -E "^${DEVICE}p?2$")"
LUKS_PART="$(ls ${DEVICE}* | grep -E "^${DEVICE}p?3$")"
BTRFS_VOL="/dev/mapper/arch-luks"
SWAP_PART_ID=$(find -L /dev/disk -samefile ${SWAP_PART} | grep by-id | head -n 1)

# Format and unlock swap drive
print_message "Creating and mounting LUKS swap volume"
cryptsetup open --type plain --key-file /dev/urandom "${SWAP_PART}" cryptswap > /dev/null
mkswap /dev/mapper/cryptswap > /dev/null
swapon /dev/mapper/cryptswap > /dev/null

# Create and unlock root luks drive
# TODO iter-time 5000
print_message "Creating and opening LUKS volume"
echo -n ${LUKS_PASSWORD} | cryptsetup --key-size 512 --hash whirlpool --iter-time 5000 --use-random --cipher aes-xts-plain64 --pbkdf-memory=4194304 --pbkdf=argon2id luksFormat "${LUKS_PART}" - > /dev/null
echo -n ${LUKS_PASSWORD} | cryptsetup luksOpen "${LUKS_PART}" "${BTRFS_VOL##*/}" -d - > /dev/null

# Format and mount root btrfs drive
print_message "Formatting and mounting btrfs volume"
mkfs.btrfs --force "${BTRFS_VOL}" > /dev/null
mount -t btrfs "${BTRFS_VOL}" /mnt

# Create subvolumes
print_message "Creating btrfs subvolumes"
btrfs subvolume create /mnt/root > /dev/null
btrfs subvolume create /mnt/home > /dev/null
btrfs subvolume create /mnt/snapshots > /dev/null

# Mount btrfs subvolumes
print_message "Mounting btrfs subvolumes"
umount -R /mnt
mount -t btrfs -o subvol=root,defaults,x-mount.mkdir,compress=lzo,ssd,discard,noatime "${BTRFS_VOL}" /mnt
mount -t btrfs -o subvol=home,defaults,x-mount.mkdir,compress=lzo,sdd,discard,noatime "${BTRFS_VOL}" /mnt/home
mount -t btrfs -o subvol=snapshots,defaults,x-mount.mkdir,compress=lzo,sdd,discard,noatime "${BTRFS_VOL}" /mnt/.snapshots

# Format and mount boot partition (EFI)
print_message "Formatting and mounting boot partition"
mkfs.vfat -F32 "${BOOT_PART}" > /dev/null
mkdir /mnt/boot
mount "${BOOT_PART}" /mnt/boot

# Install base system
print_message "Installing base system"
pacstrap /mnt base linux btrfs-progs efibootmgr intel-ucode cryptsetup >/dev/null

# Create fstab and update crypttab
print_message "Writing fstab"
genfstab -L -p /mnt >> /mnt/etc/fstab
echo "cryptswap ${SWAP_PART_ID} /dev/urandom swap,offset=2048,cipher=aes-xts-plain64,size=256" >> /mnt/etc/crypttab

print_message "Setting root password"
echo "root:${ROOT_PASSWORD}" | chpasswd --root /mnt

print_message "Setting up locale, timezone and hostname"
sed -i "s/#${LOCALE}/${LOCALE}/g" /mnt/etc/locale.gen
arch-chroot /mnt locale-gen > /dev/null
cat<<EOF>>/mnt/etc/vconsole.conf
KEYMAP=${KEYMAP}
FONT=latarcyrheb-sun32
EOF
echo "LANGUAGE=${LANGUAGE}" > /mnt/etc/locale.conf
arch-chroot /mnt localectl set-locale "LANG=${LOCALE}"
arch-chroot /mnt timedatectl set-ntp 1
arch-chroot /mnt timedatectl set-timezone "${TIMEZONE}"
echo "${HOSTNAME}" >> /mnt/etc/hostname
arch-chroot /mnt hostnamectl set-hostname "${HOSTNAME}"

print_message "Installing boot loader"
arch-chroot /mnt bootctl --path=/boot install > /dev/null
LUKS_UUID=$(blkid -o value -s UUID "${LUKS_PART}")
BTRFS_UUID=$(blkid -o value -s UUID "${BTRFS_VOL}")
mkdir -p /mnt/boot/loader/entries
cat<<EOD>/mnt/boot/loader/entries/arch.conf
title   Arch
linux   /vmlinuz-linux
initrd  /intel-ucode.img
initrd  /initramfs-linux.img
options rd.luks.name=${LUKS_UUID}=${BTRFS_VOL##*/} root=${BTRFS_VOL} rootflags=subvol=root rw
EOD
echo 'default arch' >> /mnt/boot/loader/loader.conf

print_message "Creating initramfs"
sed -i 's/BINARIES=.*/BINARIES=(\/usr\/bin\/btrfs)/g' /mnt/etc/mkinitcpio.conf
sed -i 's/HOOKS=.*/HOOKS=(base systemd autodetect keyboard sd-vconsole modconf block sd-encrypt filesystems btrfs fsck)/g' /mnt/etc/mkinitcpio.conf
arch-chroot /mnt mkinitcpio -p linux > /dev/null 2>&1

curl -Lks bit.do/samirarchconfig > /root/config.sh

print_message "Installation complete. Enjoy your system :)"

# while true; do
#     read -p "Do you want to boot into your system? y/n" ans < /dev/tty
#     case $ans in
#         [Yy]* ) seq -f "pts/%g" 0 9 >> /mnt/etc/securetty; systemd-nspawn -bD /mnt; break;;
#         [Nn]* ) exit;;
#         * ) echo "Please answer yes or no.";;
#     esac
# done

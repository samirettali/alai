#!/usr/bin/env bash

set -eu
set -o pipefail

USERNAME="foo"
PASSWORD="bar"
LUKS_UUID=$(cat /boot/loader/entries/arch.conf | grep rd.luks.name | awk {'print $2'} | cut -d= -f2)

print_message() {
  GREEN='\033[0;32m'
  NC='\033[0m'
  echo -e "${GREEN}[*]${NC} ${1}"
}

# cat<<EOF>/etc/systemd/network/20-wired.network
# [Match]
# Name=en*

# [Network]
# DHCP=yes

# [DHCP]
# RouteMetric=10
# EOF

cat<<EOF>/etc/systemd/network/25-wireless.network
[Match]
Name=wlp*

[Network]
DHCP=yes

[DHCP]
RouteMetric=20
EOF

# Enable network
systemctl enable --now systemd-networkd systemd-resolved

# Install software
print_message "Installing software"
pacman --noconfirm -Syu base-devel zsh xsecurelock xss-lock syncthing wget docker openssh man sudo jq tree git go adobe-source-code-pro-fonts dunst htop tmux fzf feh python rust interception-tools interception-caps2esc xorg-server xorg-xinit wireguard-tools xf86-video-intel nvidia nvidia-prime > /dev/null

systemctl enable --now docker
systemctl enable --now sshd


kbd=$(ls /dev/input/by-path | grep kbd | head -n1)
cat<<EOF>/etc/systemd/system/caps2esc.service
[Unit]
Description=Monitor input devices for launching tasks
Wants=systemd-udev-settle.service
After=systemd-udev-settle.service
Documentation=man:udev(7)

[Service]
ExecStart=/usr/bin/udevmon -c /etc/interception/udevmon.yaml
Nice=-20
Restart=on-failure
OOMScoreAdjust=-1000

CapabilityBoundingSet=~CAP_SETUID CAP_SETGID CAP_SETPCAP CAP_SYS_PTRACE CAP_SYS_ADMIN CAP_NET_ADMIN CAP_SYS_RAWIO CAP_SYS_BOOT
DeviceAllow=char-* rw
DevicePolicy=strict
IPAddressDeny=any
LockPersonality=yes
MemoryDenyWriteExecute=yes
NoNewPrivileges=yes
PrivateMounts=yes
PrivateTmp=yes
ProtectControlGroups=yes
ProtectClock=yes
ProtectHome=yes
ProtectHostname=yes
ProtectKernelLogs=yes
ProtectKernelModules=yes
ProtectKernelTunables=yes
PrivateNetwork=yes
PrivateUsers=yes
ProtectProc=invisible
ProtectSystem=strict
RestrictAddressFamilies=AF_NETLINK
RestrictNamespaces=yes
RestrictRealtime=yes
RestrictSUIDSGID=yes
SystemCallArchitectures=native
SystemCallErrorNumber=EPERM
SystemCallFilter=@system-service
SystemCallFilter=~@privileged @resources
UMask=077
ProcSubset=pid

[Install]
WantedBy=multi-user.target
EOF

mkdir -p /etc/interception
cat<<EOF>/etc/interception/udevmon.yaml
SHELL: [zsh, -c]
---
- JOB:
    - intercept -g \$DEVNODE | caps2esc | uinput -d \$DEVNODE
  DEVICE:
    LINK: /dev/input/by-path/${kbd}
    EVENTS:
      EV_KEY: [KEY_CAPSLOCK, KEY_ESC]
EOF
systemctl enable --now udevmon

print_message "Creating user"
useradd -mU -s /usr/bin/zsh -G wheel,uucp,video,audio,storage,games,input,docker "${USERNAME}"
echo "${USERNAME}:${PASSWORD}" | chpasswd

# Give user sudo permission
print_message "Adding wheel group to sudoers"
echo '%wheel ALL=(ALL) ALL' | sudo EDITOR='tee -a' visudo

# Backup LUKS header
print_message "Backing up LUKS header"
cryptsetup luksHeaderBackup "/dev/disk/by-uuid/${LUKS_UUID}" --header-backup-file "/home/${USERNAME}/arch-luks.img"

# Cron job
# pacman -Syuw --noconfirm

print_message "Installing yay"
cd /tmp
git clone https://aur.archlinux.org/yay.git > /dev/null
chgrp samir yay
chmod g+ws yay
setfacl -m u::rwx,g::rwx yay
setfacl -d --set u::rwx,g::rwx,o::- yay
cd yay
sudo -u samir makepkg -si --noconfirm > /dev/null
cd ..
rm -rf yay

mkdir suckless
cd suckless
git clone https://git.suckless.org/dwm/
cd dwm
make
make install
cd ..
git clone https://git.suckless.org/st/
cd st
make
make install
cd ..
git clone https://git.suckless.org/dmenu/
cd dmenu
make
make install
cd ..
git clone https://git.suckless.org/slstatus/
cd slstatus
make
make install
cd ..
cd ..
mv suckless "/home/${USERNAME}"
chown "${USERNAME}:${USERNAME}" -R "/home/${USERNAME}/suckless"

su samir
curl -Lks bit.do/samirdotfiles | bash > /dev/null
yay -S --noconfirm neovim-nightly-git > /dev/null

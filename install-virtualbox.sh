#!/usr/bin/env bash

DISK='/dev/sda'
FQDN='vagrant-arch.vagrantup.com'
KEYMAP='jp106'
LANGUAGE='en_US.UTF-8'
PASSWORD=$(/usr/bin/openssl passwd -crypt 'vagrant')
TIMEZONE='Asia/Tokyo'

CONFIG_SCRIPT='/usr/local/bin/arch-config.sh'
ROOT_PARTITION="${DISK}3"
TARGET_DIR='/mnt'

echo "==> clearing partition table on ${DISK}"
/usr/bin/sgdisk --zap ${DISK}

echo "==> destroying magic strings and signatures on ${DISK}"
/usr/bin/dd if=/dev/zero of=${DISK} bs=512 count=2048
/usr/bin/wipefs --all ${DISK}

echo "==> creating partitions on ${DISK}"
/usr/bin/sgdisk --new=1:0:+1007K ${DISK}
/usr/bin/sgdisk --typecode=1:EF02 ${DISK}
/usr/bin/sgdisk --new=2:0:+1G ${DISK}
/usr/bin/sgdisk --typecode=2:8200 ${DISK}
/usr/bin/sgdisk --new=3:0:0 ${DISK}

echo "==> setting ${DISK} bootable"
/usr/bin/sgdisk ${DISK} --attributes=1:set:2

echo '==> creating /root filesystem (btrfs)'
/usr/bin/mkfs.btrfs -f -L root ${ROOT_PARTITION}

echo '==> creating swap'
/usr/bin/mkswap ${DISK}2
/usr/bin/swapon ${DISK}2

echo "==> mounting ${ROOT_PARTITION} to ${TARGET_DIR}"
/usr/bin/mount -o defaults,noatime,compress=lzo ${ROOT_PARTITION} ${TARGET_DIR}

echo '==> selecting mirrors'
/usr/bin/pacman -Sy --noconfirm reflector
/usr/bin/reflector -l 50 -p http --sort rate --save /etc/pacman.d/mirrorlist


echo '==> bootstrapping the base installation'
/usr/bin/pacstrap ${TARGET_DIR} base base-devel
/usr/bin/arch-chroot ${TARGET_DIR} pacman -S --noconfirm gptfdisk openssh grub

echo '==> generating the filesystem table'
/usr/bin/genfstab -U -p ${TARGET_DIR} >> "${TARGET_DIR}/etc/fstab"

echo '==> generating the system configuration script'
/usr/bin/install --mode=0755 /dev/null "${TARGET_DIR}${CONFIG_SCRIPT}"

cat <<-EOF > "${TARGET_DIR}${CONFIG_SCRIPT}"
	echo '${FQDN}' > /etc/hostname
	/usr/bin/ln -s /usr/share/zoneinfo/${TIMEZONE} /etc/localtime
	echo 'KEYMAP=${KEYMAP}' > /etc/vconsole.conf
	/usr/bin/sed -i 's/#${LANGUAGE}/${LANGUAGE}/' /etc/locale.gen
	/usr/bin/locale-gen
	/usr/bin/mkinitcpio -p linux
	/usr/bin/usermod --password ${PASSWORD} root

	# Network interfaces
	cat <<-EOF2 > /etc/systemd/network/MyDhcp.network
[Match]
Name=en*

[Network]
DHCP=yes
EOF2
	/usr/bin/systemctl enable systemd-networkd.service

	# SSH
	/usr/bin/sed -i 's/#UseDNS yes/UseDNS no/' /etc/ssh/sshd_config
	/usr/bin/systemctl enable sshd.service

	# GRUB
	grub-install --recheck --debug ${DISK}
	sed -i 's/GRUB_TIMEOUT=5/GRUB_TIMEOUT=0/' /etc/default/grub
	grub-mkconfig -o /boot/grub/grub.cfg

	# Disable CoW on journal directory
	mv /var/log/journal /var/log/journal_old
	mkdir /var/log/journal
	chattr +C /var/log/journal
	cp /var/log/journal_old/* /var/log/journal
	rm -rf /var/log/journal_old

	# VirtualBox Guest Additions
	/usr/bin/pacman -S --noconfirm linux-headers virtualbox-guest-utils virtualbox-guest-dkms
	echo -e 'vboxguest\nvboxsf\nvboxvideo' > /etc/modules-load.d/virtualbox.conf
	guest_version=\$(/usr/bin/pacman -Q virtualbox-guest-dkms | awk '{ print \$2 }' | cut -d'-' -f1)
	kernel_version="\$(/usr/bin/pacman -Q linux | awk '{ print \$2 }')-ARCH"
	/usr/bin/dkms install "vboxguest/\${guest_version}" -k "\${kernel_version}/x86_64"
	/usr/bin/systemctl enable dkms.service
	/usr/bin/systemctl enable vboxservice.service

	# Vagrant-specific configuration
	/usr/bin/groupadd vagrant
	/usr/bin/useradd --password ${PASSWORD} --comment 'Vagrant User' --create-home --gid users --groups vagrant,vboxsf vagrant
	echo 'Defaults env_keep += "SSH_AUTH_SOCK"' > /etc/sudoers.d/10_vagrant
	echo 'vagrant ALL=(ALL) NOPASSWD: ALL' >> /etc/sudoers.d/10_vagrant
	/usr/bin/chmod 0440 /etc/sudoers.d/10_vagrant
	/usr/bin/install --directory --owner=vagrant --group=users --mode=0700 /home/vagrant/.ssh
	/usr/bin/curl --output /home/vagrant/.ssh/authorized_keys --location https://raw.github.com/mitchellh/vagrant/master/keys/vagrant.pub
	/usr/bin/chown vagrant:users /home/vagrant/.ssh/authorized_keys
	/usr/bin/chmod 0600 /home/vagrant/.ssh/authorized_keys

	# Clean up
	/usr/bin/pacman -Rcns --noconfirm gptfdisk
	/usr/bin/pacman -Scc --noconfirm
EOF

echo '==> entering chroot and configuring system'
/usr/bin/arch-chroot ${TARGET_DIR} ${CONFIG_SCRIPT}
rm "${TARGET_DIR}${CONFIG_SCRIPT}"

# http://comments.gmane.org/gmane.linux.arch.general/48739
echo '==> adding workaround for shutdown race condition'
/usr/bin/install --mode=0644 poweroff.timer "${TARGET_DIR}/etc/systemd/system/poweroff.timer"

echo '==> installation complete!'
/usr/bin/sleep 3
/usr/bin/umount ${TARGET_DIR}
/usr/bin/systemctl reboot

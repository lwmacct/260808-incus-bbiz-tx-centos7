#!/usr/bin/env bash

__log() {
  printf '[bbiz-installer] %s\n' "$*"
}

__kernel_arg() {
  _requested_key=$1
  read -r -a _kernel_arguments < /proc/cmdline
  for _argument in "${_kernel_arguments[@]}"; do
    case "${_argument}" in
      "${_requested_key}"=*)
        printf '%s\n' "${_argument#*=}"
        return 0
        ;;
    esac
  done

  return 1
}

__cleanup() {
  set +e

  if declare -p _bind_mounts >/dev/null 2>&1; then
    for ((_index=${#_bind_mounts[@]} - 1; _index >= 0; _index--)); do
      if mountpoint -q "${_bind_mounts[_index]}"; then
        umount -R "${_bind_mounts[_index]}"
      fi
    done
  fi

  if [ -n "${_data_target_mount:-}" ] && mountpoint -q "${_data_target_mount}"; then
    umount "${_data_target_mount}"
  fi
  if [ -n "${_efi_target_mount:-}" ] && mountpoint -q "${_efi_target_mount}"; then
    umount "${_efi_target_mount}"
  fi
  if [ -n "${TARGET_MOUNT:-}" ] && mountpoint -q "${TARGET_MOUNT}"; then
    umount "${TARGET_MOUNT}"
  fi
}

__on_error() {
  _exit_status=$?
  _line_number=$1
  trap - ERR
  set +e
  __log "installation failed at line ${_line_number} with status ${_exit_status}"
  __log "BBIZ_INSTALL_FAILURE line=${_line_number} status=${_exit_status}"
  __cleanup
  trap - EXIT HUP INT TERM

  _automatic_mode=${_automatic:-$(__kernel_arg installer.auto || true)}
  if [ "${_automatic_mode}" = 1 ]; then
    sync
    systemctl poweroff
  fi

  exit "${_exit_status}"
}

__live_disk() {
  _live_source=$(findmnt -n -o SOURCE --target /run/live/medium 2>/dev/null || true)
  [ -n "${_live_source}" ] || return 1
  _live_source=$(readlink -f "${_live_source}")
  _live_parent=$(lsblk -n -o PKNAME "${_live_source}" 2>/dev/null | head -n 1)
  if [ -n "${_live_parent}" ]; then
    printf '/dev/%s\n' "${_live_parent}"
  else
    printf '%s\n' "${_live_source}"
  fi
}

__list_install_disks() {
  _excluded_disk=$(__live_disk || true)
  while read -r _disk; do
    [ -n "${_disk}" ] || continue
    [ "${_disk}" != "${_excluded_disk}" ] || continue
    printf '%s\n' "${_disk}"
  done < <(lsblk -dnpo NAME,TYPE,RO | awk '$2 == "disk" && $3 == "0" {print $1}')
}

__select_target_disk() {
  _configured_target=$(__kernel_arg installer.target || true)
  _automatic=$(__kernel_arg installer.auto || true)

  if [ "${_automatic}" = 1 ]; then
    test -n "${_configured_target}" || {
      __log 'installer.target is required in automatic mode'
      return 1
    }
    _target_disk=$(readlink -f "${_configured_target}")
    return 0
  fi

  mapfile -t _candidate_disks < <(__list_install_disks)
  test "${#_candidate_disks[@]}" -gt 0 || {
    __log 'no writable installation disk found'
    return 1
  }

  printf '\nAvailable installation disks:\n'
  for _index in "${!_candidate_disks[@]}"; do
    _disk=${_candidate_disks[_index]}
    _size=$(lsblk -dn -o SIZE "${_disk}")
    _model=$(lsblk -dn -o MODEL "${_disk}" | sed 's/[[:space:]]*$//')
    printf '  %d. %s  %s  %s\n' "$((_index + 1))" "${_disk}" "${_size}" "${_model}"
  done

  printf 'Select disk number: '
  read -r _selection
  [[ "${_selection}" =~ ^[0-9]+$ ]]
  test "${_selection}" -ge 1
  test "${_selection}" -le "${#_candidate_disks[@]}"
  _target_disk=${_candidate_disks[_selection - 1]}

  printf 'This will erase %s. Type the full device path to continue: ' "${_target_disk}"
  read -r _confirmation
  test "${_confirmation}" = "${_target_disk}"
}

__validate_target_disk() {
  test -b "${_target_disk}"
  test "$(lsblk -dn -o TYPE "${_target_disk}")" = disk
  test "$(lsblk -dn -o RO "${_target_disk}" | tr -d ' ')" = 0

  _live_disk_path=$(__live_disk || true)
  test -z "${_live_disk_path}" || test "${_target_disk}" != "${_live_disk_path}"
  _target_bytes=$(blockdev --getsize64 "${_target_disk}")
  test "${_target_bytes}" -ge "${MINIMUM_DISK_BYTES}" || {
    __log "target disk must be at least ${MINIMUM_DISK_BYTES} bytes"
    return 1
  }

  if lsblk -nrpo MOUNTPOINT "${_target_disk}" | grep -q .; then
    __log 'target disk has mounted filesystems'
    return 1
  fi
}

__partition_device() {
  _partition_number=$1
  lsblk -nrpo NAME,PARTN "${_target_disk}" \
    | awk -v _partition_number="${_partition_number}" \
      '$2 == _partition_number {print $1; exit}'
}

__wait_for_partitions() {
  for _attempt in $(seq 1 50); do
    _bios_partition=$(__partition_device 1)
    _efi_partition=$(__partition_device 2)
    _data_partition=$(__partition_device 3)
    _root_partition=$(__partition_device 4)
    if [ -b "${_bios_partition}" ] \
      && [ -b "${_efi_partition}" ] \
      && [ -b "${_data_partition}" ] \
      && [ -b "${_root_partition}" ]; then
      return 0
    fi
    sleep 0.2
  done

  return 1
}

__create_filesystems() {
  __log "partitioning ${_target_disk}"
  wipefs --all --force "${_target_disk}"
  sgdisk --zap-all "${_target_disk}"
  parted --script --align optimal "${_target_disk}" \
    mklabel gpt \
    mkpart BIOS "${BIOS_START_MIB}MiB" "${BIOS_END_MIB}MiB" \
    set 1 bios_grub on \
    name 1 "${BIOS_PARTITION_LABEL}" \
    mkpart EFI fat32 "${EFI_START_MIB}MiB" "${EFI_END_MIB}MiB" \
    set 2 esp on \
    name 2 EFI_SYSTEM \
    mkpart DATA xfs "${EFI_END_MIB}MiB" "${DATA_END_MIB}MiB" \
    name 3 "${DATA_PARTITION_LABEL}" \
    mkpart ROOT ext4 "${DATA_END_MIB}MiB" 100% \
    name 4 root
  partprobe "${_target_disk}"
  udevadm settle
  __wait_for_partitions

  mkfs.vfat -F 32 -n "${EFI_FILESYSTEM_LABEL}" "${_efi_partition}"
  mkfs.xfs \
    -f \
    -L "${DATA_FILESYSTEM_LABEL}" \
    -m 'crc=1,finobt=1,rmapbt=0,reflink=0,inobtcount=0,bigtime=0' \
    -i 'sparse=0,nrext64=0' \
    "${_data_partition}"
  mkfs.ext4 -F -L "${ROOT_FILESYSTEM_LABEL}" "${_root_partition}"

  test "$(blockdev --getsize64 "${_bios_partition}")" = "${BIOS_PARTITION_BYTES}"
  test "$(blockdev --getsize64 "${_efi_partition}")" = "${EFI_PARTITION_BYTES}"
  test "$(blockdev --getsize64 "${_data_partition}")" = "${DATA_PARTITION_BYTES}"
  test "$(blkid -s PARTLABEL -o value "${_bios_partition}")" = "${BIOS_PARTITION_LABEL}"
  test "$(blkid -s PARTLABEL -o value "${_data_partition}")" = "${DATA_PARTITION_LABEL}"
}

__extract_payload() {
  __log 'verifying and extracting installer payload'
  (
    cd "${PAYLOAD_DIR}"
    sha256sum --check SHA256SUMS
    jq -e \
      --arg _kernel_release "${KERNEL_RELEASE}" \
      '.schema_version == 2
        and .artifact_type == "io.github.lwmacct.centos7-tkernel.installer-rootfs.v2"
        and .image.kernel_release == $_kernel_release
        and .payload.includes_efi_tree == true
        and .boot_capabilities.firmware_modes == ["bios", "uefi"]
        and .boot_capabilities.grub_platforms == ["i386-pc", "x86_64-efi"]
        and .boot_capabilities.secure_boot == false' \
      rootfs-manifest.json
  )

  mkdir -p "${TARGET_MOUNT}"
  mount "${_root_partition}" "${TARGET_MOUNT}"
  _efi_target_mount="${TARGET_MOUNT}/boot/efi"
  mkdir -p "${_efi_target_mount}"
  mount "${_efi_partition}" "${_efi_target_mount}"
  unsquashfs -f -d "${TARGET_MOUNT}" "${PAYLOAD_DIR}/rootfs.squashfs"

  _data_target_mount="${TARGET_MOUNT}${DATA_MOUNT}"
  mkdir -p "${_data_target_mount}"
  mount "${_data_partition}" "${_data_target_mount}"
}

__write_installed_configuration() {
  __log 'writing installed system configuration'
  _root_uuid=$(blkid -s UUID -o value "${_root_partition}")
  _efi_uuid=$(blkid -s UUID -o value "${_efi_partition}")
  cat > "${TARGET_MOUNT}/etc/fstab" <<EOF
UUID=${_root_uuid} / ext4 defaults 0 1
UUID=${_efi_uuid} /boot/efi vfat umask=0077,shortname=winnt 0 2
PARTLABEL=${DATA_PARTITION_LABEL} ${DATA_MOUNT} xfs defaults 0 2
EOF

  install -d -m 0755 "${TARGET_MOUNT}/etc/sysconfig/network-scripts"
  find "${TARGET_MOUNT}/etc/sysconfig/network-scripts" \
    -maxdepth 1 -type f -name 'ifcfg-*' ! -name 'ifcfg-lo' -delete
  cat > "${TARGET_MOUNT}/etc/sysconfig/network-scripts/ifcfg-eth0" <<'EOF'
TYPE=Ethernet
DEVICE=eth0
NAME=eth0
BOOTPROTO=dhcp
ONBOOT=yes
IPV6INIT=no
PEERDNS=yes
EOF
  cat > "${TARGET_MOUNT}/etc/sysconfig/network" <<'EOF'
NETWORKING=yes
HOSTNAME=localhost.localdomain
EOF
  printf '%s\n' localhost.localdomain > "${TARGET_MOUNT}/etc/hostname"

  cat > "${TARGET_MOUNT}/etc/default/grub" <<'EOF'
GRUB_TIMEOUT=5
GRUB_DEFAULT=saved
GRUB_DISABLE_SUBMENU=true
GRUB_DISABLE_RECOVERY=true
GRUB_DISABLE_OS_PROBER=true
GRUB_TERMINAL="serial console"
GRUB_TERMINAL_OUTPUT="console"
GRUB_SERIAL_COMMAND="serial --speed=115200 --unit=0 --word=8 --parity=no --stop=1"
GRUB_CMDLINE_LINUX="console=tty0 console=ttyS0,115200n8 net.ifnames=0 biosdevname=0"
EOF

  printf 'uninitialized\n' > "${TARGET_MOUNT}/etc/machine-id"
  rm -f "${TARGET_MOUNT}/var/lib/dbus/machine-id"
  rm -f "${TARGET_MOUNT}"/etc/ssh/ssh_host_*
  install -d -m 0755 "${TARGET_MOUNT}/etc/dracut.conf.d"
  rm -f "${TARGET_MOUNT}/etc/dracut.conf.d/incus.conf"
  printf '%s\n' 'hostonly="no"' \
    > "${TARGET_MOUNT}/etc/dracut.conf.d/bbiz-installer.conf"

  rm -rf \
    "${TARGET_MOUNT}/etc/systemd/system/incus-agent.service" \
    "${TARGET_MOUNT}/etc/systemd/system/incus-agent.service.d" \
    "${TARGET_MOUNT}/etc/systemd/system/incus-agent-workaround.service" \
    "${TARGET_MOUNT}/usr/lib/systemd/system/incus-agent.service"
  find "${TARGET_MOUNT}/etc/systemd/system" -type l -lname '*incus-agent*' -delete
  find "${TARGET_MOUNT}" -xdev -type f -name incus-agent -delete

  install -d -m 0755 "${TARGET_MOUNT}/etc/bbiz-image"
  install -m 0644 "${PAYLOAD_DIR}/rootfs-manifest.json" \
    "${TARGET_MOUNT}/etc/bbiz-image/rootfs-manifest.json"
}

__configure_root_password() {
  if [ "${_automatic}" = 1 ]; then
    chroot "${TARGET_MOUNT}" passwd --lock root
    return
  fi

  while true; do
    printf 'Set root password: '
    read -r -s _root_password
    printf '\nConfirm root password: '
    read -r -s _root_password_confirmation
    printf '\n'
    if [ -n "${_root_password}" ] \
      && [ "${_root_password}" = "${_root_password_confirmation}" ]; then
      break
    fi
    printf 'Passwords do not match or are empty. Try again.\n'
  done
  printf 'root:%s\n' "${_root_password}" | chroot "${TARGET_MOUNT}" chpasswd
  unset _root_password _root_password_confirmation
}

__bind_chroot_filesystems() {
  _bind_mounts=()
  for _path in dev proc sys run; do
    _destination="${TARGET_MOUNT}/${_path}"
    mkdir -p "${_destination}"
    mount --rbind "/${_path}" "${_destination}"
    mount --make-rslave "${_destination}"
    _bind_mounts+=("${_destination}")
  done
}

__install_bootloader() {
  __log 'building initramfs and installing BIOS and UEFI GRUB'
  chroot "${TARGET_MOUNT}" depmod -a "${KERNEL_RELEASE}"
  chroot "${TARGET_MOUNT}" dracut \
    --force \
    --no-hostonly \
    "/boot/initramfs-${KERNEL_RELEASE}.img" \
    "${KERNEL_RELEASE}"
  chroot "${TARGET_MOUNT}" grub2-install \
    --target=i386-pc \
    --boot-directory=/boot \
    --recheck \
    "${_target_disk}"
  chroot "${TARGET_MOUNT}" grub2-install \
    --target=x86_64-efi \
    --efi-directory=/boot/efi \
    --bootloader-id=centos \
    --removable \
    --no-nvram
  chroot "${TARGET_MOUNT}" grub2-mkconfig -o /boot/grub2/grub.cfg
  install -d -m 0755 "${TARGET_MOUNT}/boot/efi/EFI/centos"
  chroot "${TARGET_MOUNT}" grub2-mkconfig -o /boot/efi/EFI/centos/grub.cfg
  chroot "${TARGET_MOUNT}" grubby --set-default "/boot/vmlinuz-${KERNEL_RELEASE}"
  test -f "${TARGET_MOUNT}/boot/efi/EFI/BOOT/BOOTX64.EFI"
  test -f "${TARGET_MOUNT}/usr/lib/grub/i386-pc/modinfo.sh"
  test -f "${TARGET_MOUNT}/usr/lib/grub/x86_64-efi/modinfo.sh"
}

__install_ci_verifier() {
  _ci_mode=$(__kernel_arg installer.ci || true)
  [ "${_ci_mode}" = 1 ] || return 0

  install -d -m 0755 "${TARGET_MOUNT}/usr/lib/bbiz-installer"
  install -m 0644 /opt/bbiz-installer/install.env \
    "${TARGET_MOUNT}/usr/lib/bbiz-installer/install.env"
  install -m 0755 /opt/bbiz-installer/bbiz-ci-verify.sh \
    "${TARGET_MOUNT}/usr/local/sbin/bbiz-ci-verify"
  cat > "${TARGET_MOUNT}/etc/systemd/system/bbiz-ci-verify.service" <<'EOF'
[Unit]
Description=Verify BBIZ installation in CI
After=network-online.target
Wants=network-online.target
OnFailure=poweroff.target

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/bbiz-ci-verify
StandardOutput=journal+console
StandardError=journal+console

[Install]
WantedBy=multi-user.target
EOF
  install -d -m 0755 "${TARGET_MOUNT}/etc/systemd/system/multi-user.target.wants"
  ln -s ../bbiz-ci-verify.service \
    "${TARGET_MOUNT}/etc/systemd/system/multi-user.target.wants/bbiz-ci-verify.service"
}

__main() {
  set -Eeuo pipefail

  # shellcheck disable=SC1091
  source /opt/bbiz-installer/install.env
  _bind_mounts=()
  _efi_target_mount=
  _data_target_mount=
  trap '__on_error ${LINENO}' ERR
  trap __cleanup EXIT HUP INT TERM

  test "$(id -u)" = 0
  if [ -d /sys/firmware/efi ]; then
    __log 'installer firmware mode: UEFI'
  else
    __log 'installer firmware mode: Legacy BIOS'
  fi
  test -f "${PAYLOAD_DIR}/rootfs.squashfs"
  test -f "${PAYLOAD_DIR}/rootfs-manifest.json"
  test -f "${PAYLOAD_DIR}/SHA256SUMS"

  __select_target_disk
  __validate_target_disk
  __create_filesystems
  __extract_payload
  __write_installed_configuration
  __bind_chroot_filesystems
  __configure_root_password
  __install_bootloader
  __install_ci_verifier
  sync

  __log 'BBIZ_INSTALL_SUCCESS'
  __cleanup
  trap - EXIT HUP INT TERM ERR

  _shutdown_mode=$(__kernel_arg installer.shutdown || true)
  if [ "${_shutdown_mode}" = poweroff ]; then
    systemctl poweroff
  elif [ "${_automatic}" = 1 ]; then
    systemctl reboot
  else
    printf 'Installation complete. Press Enter to reboot.\n'
    read -r
    systemctl reboot
  fi
}

__main "$@"

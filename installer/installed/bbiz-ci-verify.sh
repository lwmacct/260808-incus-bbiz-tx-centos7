#!/usr/bin/env bash

__fail() {
  printf 'BBIZ_BOOT_VERIFY_FAILURE: %s\n' "$*" >&2
  exit 1
}

__partition_number() {
  _device_path=$1
  _device_name=${_device_path##*/}
  cat "/sys/class/block/${_device_name}/partition"
}

__wait_for_network() {
  for _attempt in $(seq 1 60); do
    if ip -4 -o address show scope global | grep -q . \
      && ip -4 route show default | grep -q '^default '; then
      return 0
    fi
    sleep 2
  done

  return 1
}

__main() {
  set -euo pipefail

  # shellcheck disable=SC1091
  source /usr/lib/bbiz-installer/install.env

  test "$(uname -m)" = x86_64 || __fail 'architecture mismatch'
  test "$(uname -r)" = "${KERNEL_RELEASE}" || __fail 'kernel mismatch'
  grep -qx 'ID="centos"' /etc/os-release || __fail 'distribution mismatch'
  grep -qx 'VERSION_ID="7"' /etc/os-release || __fail 'release mismatch'

  _root_source=$(readlink -f "$(findmnt -n -o SOURCE --target /)")
  _data_source=$(readlink -f "$(findmnt -n -o SOURCE --target "${DATA_MOUNT}")")
  _efi_source=$(readlink -f "$(findmnt -n -o SOURCE --target /boot/efi)")
  _parent_name=$(lsblk -n -o PKNAME "${_data_source}" | head -n 1)
  test -n "${_parent_name}" || __fail 'data parent disk is missing'
  test "$(blockdev --getsize64 "/dev/${_parent_name}")" -ge "${MINIMUM_DISK_BYTES}" \
    || __fail 'installed disk is smaller than the install contract'
  test "$(__partition_number "${_efi_source}")" = 1 || __fail 'EFI is not partition 1'
  test "$(__partition_number "${_data_source}")" = 2 || __fail 'data is not partition 2'
  test "$(__partition_number "${_root_source}")" = 3 || __fail 'root is not partition 3'

  test "$(findmnt -n -o FSTYPE --target /)" = ext4 || __fail 'root is not ext4'
  test "$(findmnt -n -o FSTYPE --target "${DATA_MOUNT}")" = xfs || __fail 'data is not XFS'
  test "$(findmnt -n -o FSTYPE --target /boot/efi)" = vfat || __fail 'EFI is not FAT'
  test "$(blkid -s PARTLABEL -o value "${_data_source}")" = "${DATA_PARTITION_LABEL}" \
    || __fail 'data PARTLABEL mismatch'
  test "$(blkid -s LABEL -o value "${_data_source}")" = "${DATA_FILESYSTEM_LABEL}" \
    || __fail 'data filesystem label mismatch'
  test "$(blockdev --getsize64 "${_data_source}")" = "${DATA_PARTITION_BYTES}" \
    || __fail 'data partition size mismatch'
  grep -qF \
    "PARTLABEL=${DATA_PARTITION_LABEL} ${DATA_MOUNT} xfs defaults 0 2" \
    /etc/fstab || __fail 'data fstab entry mismatch'
  grep -qF ' / ext4 ' /etc/fstab || __fail 'root fstab entry is missing'
  grep -qF ' /boot/efi vfat ' /etc/fstab || __fail 'EFI fstab entry is missing'

  _test_file="${DATA_MOUNT}/.bbiz-ci-write-test"
  printf '%s\n' bbiz-ci > "${_test_file}"
  grep -qx bbiz-ci "${_test_file}" || __fail 'data partition is not writable'
  rm -f "${_test_file}"

  test -s /etc/machine-id || __fail 'machine-id is empty'
  ! grep -qx uninitialized /etc/machine-id || __fail 'machine-id was not initialized'
  test -f /boot/efi/EFI/BOOT/BOOTX64.EFI || __fail 'UEFI fallback loader is missing'
  test "$(grubby --default-kernel)" = "/boot/vmlinuz-${KERNEL_RELEASE}" \
    || __fail 'default kernel mismatch'
  ! systemctl is-enabled incus-agent.service >/dev/null 2>&1 \
    || __fail 'Incus agent is enabled'
  ! command -v m-netctl >/dev/null 2>&1 || __fail 'm-netctl must not be installed'
  ! command -v suprce >/dev/null 2>&1 || __fail 'suprce must not be installed'
  ! command -v docker >/dev/null 2>&1 || __fail 'Docker must not be installed'
  systemctl is-enabled NetworkManager.service >/dev/null 2>&1 \
    || __fail 'NetworkManager is not enabled'
  __wait_for_network || __fail 'DHCP network did not become ready'

  printf 'BBIZ_BOOT_VERIFY_SUCCESS\n'
  systemctl disable bbiz-ci-verify.service >/dev/null 2>&1 || true
  systemctl poweroff
}

__main "$@"

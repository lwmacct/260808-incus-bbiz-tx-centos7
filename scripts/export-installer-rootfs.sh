#!/usr/bin/env bash

__cleanup() {
  if [ -n "${_efi_mount:-}" ] && mountpoint -q "${_efi_mount}"; then
    umount "${_efi_mount}"
  fi

  if [ -n "${_root_mount:-}" ] && mountpoint -q "${_root_mount}"; then
    umount "${_root_mount}"
  fi

  if [ "${_nbd_connected:-false}" = true ] && [ -n "${_nbd_device:-}" ]; then
    qemu-nbd --disconnect "${_nbd_device}" >/dev/null
  fi

  if [ -n "${_mount_dir:-}" ] && [ -d "${_mount_dir}" ]; then
    rm -rf -- "${_mount_dir}"
  fi
}

__find_free_nbd() {
  _nbd_device=
  for _candidate in /dev/nbd{0..15}; do
    [ -b "${_candidate}" ] || continue
    _candidate_name=${_candidate##*/}
    [ ! -e "/sys/class/block/${_candidate_name}/pid" ] || continue
    _nbd_device=${_candidate}
    break
  done

  test -n "${_nbd_device}"
}

__wait_for_partitions() {
  for _attempt in $(seq 1 50); do
    if [ -b "${_nbd_device}p1" ] && [ -b "${_nbd_device}p2" ]; then
      return 0
    fi
    sleep 0.2
  done

  return 1
}

__write_manifest() {
  _rootfs_sha256=$(sha256sum "${_output_dir}/rootfs.squashfs" | awk '{print $1}')
  _rootfs_size=$(stat --format=%s "${_output_dir}/rootfs.squashfs")

  jq -n \
    --arg _source_repository "${SOURCE_REPOSITORY}" \
    --arg _source_revision "${SOURCE_REVISION}" \
    --arg _source_serial "${SOURCE_SERIAL}" \
    --arg _architecture "${ARCHITECTURE}" \
    --arg _release "${RELEASE}" \
    --arg _kernel_release "${KERNEL_RELEASE}" \
    --arg _rootfs_sha256 "${_rootfs_sha256}" \
    --argjson _rootfs_size "${_rootfs_size}" \
    '{
      schema_version: 2,
      artifact_type: "io.github.lwmacct.centos7-tkernel.installer-rootfs.v2",
      source: {
        repository: $_source_repository,
        revision: $_source_revision,
        serial: $_source_serial
      },
      image: {
        distribution: "centos",
        release: $_release,
        architecture: $_architecture,
        kernel_release: $_kernel_release
      },
      payload: {
        file: "rootfs.squashfs",
        size: $_rootfs_size,
        sha256: $_rootfs_sha256,
        includes_efi_tree: true
      },
      boot_capabilities: {
        firmware_modes: ["bios", "uefi"],
        grub_platforms: ["i386-pc", "x86_64-efi"],
        uefi_fallback_loader: true,
        secure_boot: false
      }
    }' > "${_output_dir}/rootfs-manifest.json"

  (
    cd "${_output_dir}"
    sha256sum rootfs.squashfs rootfs-manifest.json > SHA256SUMS
    sha256sum --check SHA256SUMS
  )
}

__main() {
  set -euo pipefail

  _disk_path=${1:?Usage: export-installer-rootfs.sh DISK_QCOW2 OUTPUT_DIR}
  _output_dir=${2:?Usage: export-installer-rootfs.sh DISK_QCOW2 OUTPUT_DIR}
  _temporary_dir=${RUNNER_TEMP:-/tmp}
  _nbd_connected=false

  : "${SOURCE_REPOSITORY:?SOURCE_REPOSITORY is required}"
  : "${SOURCE_REVISION:?SOURCE_REVISION is required}"
  : "${SOURCE_SERIAL:?SOURCE_SERIAL is required}"
  : "${ARCHITECTURE:?ARCHITECTURE is required}"
  : "${RELEASE:?RELEASE is required}"
  : "${KERNEL_RELEASE:?KERNEL_RELEASE is required}"

  test "$(id -u)" = 0
  test -f "${_disk_path}"
  mkdir -p "${_output_dir}"
  rm -f \
    "${_output_dir}/rootfs.squashfs" \
    "${_output_dir}/rootfs-manifest.json" \
    "${_output_dir}/SHA256SUMS"

  modprobe nbd max_part=16
  __find_free_nbd
  _mount_dir=$(mktemp -d "${_temporary_dir}/installer-rootfs.XXXXXX")
  _root_mount="${_mount_dir}/root"
  _efi_mount="${_root_mount}/boot/efi"
  mkdir -p "${_root_mount}"
  trap __cleanup EXIT HUP INT TERM

  qemu-nbd --read-only --format=qcow2 \
    --connect="${_nbd_device}" "${_disk_path}"
  _nbd_connected=true
  udevadm settle
  __wait_for_partitions

  test "$(blkid -s TYPE -o value "${_nbd_device}p1")" = vfat
  test "$(blkid -s TYPE -o value "${_nbd_device}p2")" = ext4
  mount -o ro "${_nbd_device}p2" "${_root_mount}"
  test -d "${_efi_mount}"
  mount -o ro "${_nbd_device}p1" "${_efi_mount}"

  grep -qx 'ID="centos"' "${_root_mount}/etc/os-release"
  grep -qx 'VERSION_ID="7"' "${_root_mount}/etc/os-release"
  test -f "${_root_mount}/boot/vmlinuz-${KERNEL_RELEASE}"
  test -f "${_root_mount}/usr/lib/grub/i386-pc/modinfo.sh"
  test -f "${_root_mount}/usr/lib/grub/x86_64-efi/modinfo.sh"
  find "${_efi_mount}/EFI" -maxdepth 3 -type f -print -quit | grep . >/dev/null

  mksquashfs "${_root_mount}" "${_output_dir}/rootfs.squashfs" \
    -comp zstd \
    -Xcompression-level 15 \
    -noappend \
    -no-progress

  unsquashfs -cat "${_output_dir}/rootfs.squashfs" etc/os-release \
    | grep -x 'VERSION_ID="7"' >/dev/null
  unsquashfs -ll "${_output_dir}/rootfs.squashfs" \
    | grep "/boot/vmlinuz-${KERNEL_RELEASE}$" >/dev/null
  unsquashfs -ll "${_output_dir}/rootfs.squashfs" \
    | grep '/usr/lib/grub/i386-pc/modinfo.sh$' >/dev/null
  unsquashfs -ll "${_output_dir}/rootfs.squashfs" \
    | grep '/usr/lib/grub/x86_64-efi/modinfo.sh$' >/dev/null
  unsquashfs -ll "${_output_dir}/rootfs.squashfs" \
    | grep '/boot/efi/EFI/' >/dev/null
  __write_manifest
}

__main "$@"

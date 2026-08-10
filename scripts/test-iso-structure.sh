#!/usr/bin/env bash

__cleanup() {
  if [ -n "${_temporary_dir:-}" ] && [ -d "${_temporary_dir}" ]; then
    rm -rf -- "${_temporary_dir}"
  fi
}

__main() {
  set -euo pipefail

  _iso_path=${1:?Usage: test-iso-structure.sh INSTALLER_ISO [OUTER_MANIFEST]}
  _outer_manifest=${2:-}
  _repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
  _temporary_dir=$(mktemp -d)
  trap __cleanup EXIT HUP INT TERM

  # shellcheck disable=SC1091
  source "${_repo_root}/config/install.env"
  test -f "${_iso_path}"

  _eltorito_report=$(xorriso -indev "${_iso_path}" \
    -report_el_torito plain 2>&1)
  grep -Eq 'BIOS' <<< "${_eltorito_report}"
  grep -Eq 'UEFI|EFI' <<< "${_eltorito_report}"
  _pvd_report=$(xorriso -indev "${_iso_path}" -pvd_info 2>&1)
  grep -Fq 'Volume id' <<< "${_pvd_report}"
  grep -Fq "${ISO_VOLUME_ID}" <<< "${_pvd_report}"

  for _iso_entry in \
    /EFI/efiboot.img \
    /boot/grub/bios.img \
    /live/vmlinuz \
    /live/initrd \
    /live/filesystem.squashfs \
    /payload/rootfs.squashfs \
    /payload/rootfs-manifest.json \
    /payload/SHA256SUMS \
    /iso-manifest.json; do
    xorriso -indev "${_iso_path}" -find "${_iso_entry}" -type f 2>&1 \
      | grep -Fq "${_iso_entry}"
  done

  xorriso -osirrox on -indev "${_iso_path}" \
    -extract /iso-manifest.json "${_temporary_dir}/iso-manifest.json" >/dev/null 2>&1
  jq -e \
    --arg _kernel_release "${KERNEL_RELEASE}" \
    --argjson _minimum_disk_bytes "${MINIMUM_DISK_BYTES}" \
    --argjson _bios_partition_bytes "${BIOS_PARTITION_BYTES}" \
    --arg _bios_partition_label "${BIOS_PARTITION_LABEL}" \
    --argjson _efi_partition_bytes "${EFI_PARTITION_BYTES}" \
    --argjson _data_partition_bytes "${DATA_PARTITION_BYTES}" \
    --arg _data_partition_label "${DATA_PARTITION_LABEL}" \
    --arg _data_filesystem_label "${DATA_FILESYSTEM_LABEL}" \
    --arg _data_mount "${DATA_MOUNT}" \
    '.schema_version == 2
      and .artifact_type == "io.github.lwmacct.centos7-tkernel.installer-iso.v2"
      and .iso.firmware_modes == ["bios", "uefi"]
      and .iso.secure_boot == false
      and (.payload.oci_ref | test("@sha256:[0-9a-f]{64}$"))
      and .payload.kernel_release == $_kernel_release
      and .install_contract.partition_table == "gpt"
      and .install_contract.minimum_disk_bytes == $_minimum_disk_bytes
      and .install_contract.bios_boot_partition_number == 1
      and .install_contract.bios_boot_partition_bytes == $_bios_partition_bytes
      and .install_contract.bios_boot_partition_label == $_bios_partition_label
      and .install_contract.efi_partition_number == 2
      and .install_contract.efi_partition_bytes == $_efi_partition_bytes
      and .install_contract.data_partition_number == 3
      and .install_contract.data_partition_bytes == $_data_partition_bytes
      and .install_contract.data_partition_label == $_data_partition_label
      and .install_contract.data_filesystem == "xfs"
      and .install_contract.data_filesystem_label == $_data_filesystem_label
      and .install_contract.data_mount == $_data_mount
      and .install_contract.root_partition_number == 4
      and .install_contract.root_filesystem == "ext4"
      and .install_contract.grub_platforms == ["i386-pc", "x86_64-efi"]' \
    "${_temporary_dir}/iso-manifest.json"

  if [ -n "${_outer_manifest}" ]; then
    cmp "${_temporary_dir}/iso-manifest.json" "${_outer_manifest}"
  fi
}

__main "$@"

#!/usr/bin/env bash

__cleanup() {
  if [ -n "${_build_dir:-}" ] && [ -d "${_build_dir}" ]; then
    rm -rf -- "${_build_dir}"
  fi
}

__write_iso_manifest() {
  _payload_revision=$(jq -er '.source.revision' \
    "${_payload_dir}/rootfs-manifest.json")
  _payload_sha256=$(sha256sum "${_payload_dir}/rootfs.squashfs" | awk '{print $1}')

  jq -n \
    --arg _iso_repository "${ISO_SOURCE_REPOSITORY}" \
    --arg _iso_revision "${ISO_SOURCE_REVISION}" \
    --arg _iso_version "${ISO_VERSION}" \
    --arg _payload_ref "${PAYLOAD_OCI_REF}" \
    --arg _payload_revision "${_payload_revision}" \
    --arg _payload_sha256 "${_payload_sha256}" \
    --arg _kernel_release "${KERNEL_RELEASE}" \
    --argjson _minimum_disk_bytes "${MINIMUM_DISK_BYTES}" \
    --argjson _data_partition_bytes "${DATA_PARTITION_BYTES}" \
    --arg _data_partition_label "${DATA_PARTITION_LABEL}" \
    --arg _data_filesystem_label "${DATA_FILESYSTEM_LABEL}" \
    --arg _data_mount "${DATA_MOUNT}" \
    '{
      schema_version: 1,
      artifact_type: "io.github.lwmacct.centos7-tkernel.installer-iso.v1",
      iso: {
        repository: $_iso_repository,
        revision: $_iso_revision,
        version: $_iso_version,
        firmware: "uefi",
        secure_boot: false
      },
      payload: {
        oci_ref: $_payload_ref,
        source_revision: $_payload_revision,
        rootfs_sha256: $_payload_sha256,
        kernel_release: $_kernel_release
      },
      install_contract: {
        minimum_disk_bytes: $_minimum_disk_bytes,
        efi_partition_number: 1,
        data_partition_number: 2,
        data_partition_bytes: $_data_partition_bytes,
        data_partition_label: $_data_partition_label,
        data_filesystem: "xfs",
        data_filesystem_label: $_data_filesystem_label,
        data_mount: $_data_mount,
        root_partition_number: 3,
        root_filesystem: "ext4"
      }
    }' > "${_image_dir}/iso-manifest.json"
}

__main() {
  set -euo pipefail

  _payload_dir=${1:?Usage: build-iso.sh PAYLOAD_DIR OUTPUT_DIR}
  _output_dir=${2:?Usage: build-iso.sh PAYLOAD_DIR OUTPUT_DIR}
  _repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
  _temporary_dir=${RUNNER_TEMP:-/tmp}

  : "${PAYLOAD_OCI_REF:?PAYLOAD_OCI_REF is required}"
  : "${ISO_SOURCE_REPOSITORY:?ISO_SOURCE_REPOSITORY is required}"
  : "${ISO_SOURCE_REVISION:?ISO_SOURCE_REVISION is required}"
  : "${ISO_VERSION:?ISO_VERSION is required}"

  # shellcheck disable=SC1091
  source "${_repo_root}/config/install.env"
  test "$(id -u)" = 0
  bash "${_repo_root}/scripts/validate-payload.sh" \
    "${_payload_dir}" "${PAYLOAD_OCI_REF}"

  _build_dir=$(mktemp -d "${_temporary_dir}/bbiz-iso.XXXXXX")
  _rootfs_dir="${_build_dir}/rootfs"
  _image_dir="${_build_dir}/image"
  _scratch_dir="${_build_dir}/scratch"
  trap __cleanup EXIT HUP INT TERM
  mkdir -p \
    "${_image_dir}/EFI" \
    "${_image_dir}/live" \
    "${_image_dir}/payload" \
    "${_scratch_dir}"

  bash "${_repo_root}/scripts/build-live-rootfs.sh" "${_rootfs_dir}"
  install -m 0644 "${_payload_dir}/rootfs.squashfs" \
    "${_image_dir}/payload/rootfs.squashfs"
  install -m 0644 "${_payload_dir}/rootfs-manifest.json" \
    "${_image_dir}/payload/rootfs-manifest.json"
  install -m 0644 "${_payload_dir}/SHA256SUMS" \
    "${_image_dir}/payload/SHA256SUMS"

  _kernel_path=$(find "${_rootfs_dir}/boot" -maxdepth 1 \
    -type f -name 'vmlinuz-*' | sort -V | tail -n 1)
  _kernel_version=${_kernel_path##*/vmlinuz-}
  _initrd_path="${_rootfs_dir}/boot/initrd.img-${_kernel_version}"
  test -f "${_kernel_path}"
  test -f "${_initrd_path}"
  install -m 0644 "${_kernel_path}" "${_image_dir}/live/vmlinuz"
  install -m 0644 "${_initrd_path}" "${_image_dir}/live/initrd"

  mksquashfs "${_rootfs_dir}" "${_image_dir}/live/filesystem.squashfs" \
    -comp zstd \
    -Xcompression-level 15 \
    -noappend \
    -no-progress

  install -m 0644 "${_repo_root}/installer/grub/grub.cfg" \
    "${_scratch_dir}/grub.cfg"
  grub-mkstandalone \
    --format=x86_64-efi \
    --output="${_scratch_dir}/BOOTX64.EFI" \
    --locales='' \
    --fonts='' \
    "boot/grub/grub.cfg=${_scratch_dir}/grub.cfg"

  truncate --size=16M "${_scratch_dir}/efiboot.img"
  mkfs.vfat -n BBIZ_ISO_EFI "${_scratch_dir}/efiboot.img"
  mmd -i "${_scratch_dir}/efiboot.img" ::/EFI ::/EFI/BOOT
  mcopy -i "${_scratch_dir}/efiboot.img" \
    "${_scratch_dir}/BOOTX64.EFI" ::/EFI/BOOT/BOOTX64.EFI
  install -m 0644 "${_scratch_dir}/efiboot.img" \
    "${_image_dir}/EFI/efiboot.img"

  __write_iso_manifest
  mkdir -p "${_output_dir}"
  xorriso \
    -as mkisofs \
    -iso-level 3 \
    -full-iso9660-filenames \
    -volid "${ISO_VOLUME_ID}" \
    -e EFI/efiboot.img \
    -no-emul-boot \
    -append_partition 2 0xef "${_scratch_dir}/efiboot.img" \
    -partition_cyl_align on \
    -partition_offset 16 \
    -appended_part_as_gpt \
    -output "${_output_dir}/installer.iso" \
    "${_image_dir}"

  install -m 0644 "${_image_dir}/iso-manifest.json" \
    "${_output_dir}/iso-manifest.json"
  (
    cd "${_output_dir}"
    sha256sum installer.iso iso-manifest.json > SHA256SUMS
    sha256sum --check SHA256SUMS
  )
}

__main "$@"

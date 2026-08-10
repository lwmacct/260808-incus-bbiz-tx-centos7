#!/usr/bin/env bash

__cleanup() {
  if [ -n "${_listing_path:-}" ]; then
    rm -f "${_listing_path}"
  fi
}

__main() {
  set -euo pipefail

  _payload_dir=${1:?Usage: validate-payload.sh PAYLOAD_DIR [OCI_DIGEST_REF]}
  _payload_ref=${2:-}
  _repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
  _listing_path=$(mktemp)
  trap __cleanup EXIT HUP INT TERM

  # shellcheck disable=SC1091
  source "${_repo_root}/config/install.env"

  test -f "${_payload_dir}/rootfs.squashfs"
  test -f "${_payload_dir}/rootfs-manifest.json"
  test -f "${_payload_dir}/SHA256SUMS"
  if [ -n "${_payload_ref}" ]; then
    [[ "${_payload_ref}" =~ ^ghcr\.io/lwmacct/260808-incus-bbiz-tx-centos7@sha256:[0-9a-f]{64}$ ]]
  fi

  (
    cd "${_payload_dir}"
    sha256sum --check SHA256SUMS
  )

  _rootfs_sha256=$(sha256sum "${_payload_dir}/rootfs.squashfs" | awk '{print $1}')
  _rootfs_size=$(stat --format=%s "${_payload_dir}/rootfs.squashfs")
  jq -e \
    --arg _rootfs_sha256 "${_rootfs_sha256}" \
    --argjson _rootfs_size "${_rootfs_size}" \
    --arg _kernel_release "${KERNEL_RELEASE}" \
    --argjson _minimum_disk_bytes "${MINIMUM_DISK_BYTES}" \
    --argjson _data_partition_bytes "${DATA_PARTITION_BYTES}" \
    --arg _data_partition_label "${DATA_PARTITION_LABEL}" \
    --arg _data_filesystem_label "${DATA_FILESYSTEM_LABEL}" \
    --arg _data_mount "${DATA_MOUNT}" \
    '.schema_version == 1
      and .artifact_type == "io.github.lwmacct.centos7-tkernel.installer-rootfs.v1"
      and (.source.revision | test("^[0-9a-f]{40}$"))
      and .image.distribution == "centos"
      and .image.release == "7.9.2009"
      and .image.architecture == "amd64"
      and .image.kernel_release == $_kernel_release
      and .payload.file == "rootfs.squashfs"
      and .payload.sha256 == $_rootfs_sha256
      and .payload.size == $_rootfs_size
      and .payload.includes_efi_tree == true
      and .install_contract.firmware == "uefi"
      and .install_contract.secure_boot == false
      and .install_contract.minimum_disk_bytes == $_minimum_disk_bytes
      and .install_contract.data_partition_number == 2
      and .install_contract.data_partition_bytes == $_data_partition_bytes
      and .install_contract.data_partition_label == $_data_partition_label
      and .install_contract.data_filesystem == "xfs"
      and .install_contract.data_filesystem_label == $_data_filesystem_label
      and .install_contract.data_mount == $_data_mount
      and .install_contract.root_partition_number == 3
      and .install_contract.root_filesystem == "ext4"' \
    "${_payload_dir}/rootfs-manifest.json"

  unsquashfs -stat "${_payload_dir}/rootfs.squashfs" >/dev/null
  unsquashfs -ll "${_payload_dir}/rootfs.squashfs" > "${_listing_path}"
  grep -q "/boot/vmlinuz-${KERNEL_RELEASE}$" "${_listing_path}"
  grep -q '/usr/lib/grub/x86_64-efi/modinfo.sh$' "${_listing_path}"
  grep -q '/boot/efi/EFI/' "${_listing_path}"
  if grep -Eq '/(m-netctl|suprce)(/|$)|/usr/(bin|sbin)/docker$' "${_listing_path}"; then
    printf 'payload contains excluded external software\n' >&2
    return 1
  fi
}

__main "$@"

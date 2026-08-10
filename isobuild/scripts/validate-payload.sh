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
    '.schema_version == 2
      and .artifact_type == "io.github.lwmacct.centos7-tkernel.installer-rootfs.v2"
      and (.source.revision | test("^[0-9a-f]{40}$"))
      and .image.distribution == "centos"
      and .image.release == "7.9.2009"
      and .image.architecture == "amd64"
      and .image.kernel_release == $_kernel_release
      and .payload.file == "rootfs.squashfs"
      and .payload.sha256 == $_rootfs_sha256
      and .payload.size == $_rootfs_size
      and .payload.includes_efi_tree == true
      and .boot_capabilities.firmware_modes == ["bios", "uefi"]
      and .boot_capabilities.grub_platforms == ["i386-pc", "x86_64-efi"]
      and .boot_capabilities.uefi_fallback_loader == true
      and .boot_capabilities.secure_boot == false' \
    "${_payload_dir}/rootfs-manifest.json"

  unsquashfs -stat "${_payload_dir}/rootfs.squashfs" >/dev/null
  unsquashfs -ll "${_payload_dir}/rootfs.squashfs" > "${_listing_path}"
  grep -q "/boot/vmlinuz-${KERNEL_RELEASE}$" "${_listing_path}"
  grep -q '/usr/lib/grub/i386-pc/modinfo.sh$' "${_listing_path}"
  grep -q '/usr/lib/grub/x86_64-efi/modinfo.sh$' "${_listing_path}"
  grep -q '/boot/efi/EFI/' "${_listing_path}"
  if grep -Eq '/(m-netctl|suprce)(/|$)|/usr/(bin|sbin)/docker$' "${_listing_path}"; then
    printf 'payload contains excluded external software\n' >&2
    return 1
  fi
}

__main "$@"

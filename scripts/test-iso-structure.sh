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
  grep -Eq 'UEFI|EFI' <<< "${_eltorito_report}"
  _pvd_report=$(xorriso -indev "${_iso_path}" -pvd_info 2>&1)
  grep -Fq 'Volume id' <<< "${_pvd_report}"
  grep -Fq "${ISO_VOLUME_ID}" <<< "${_pvd_report}"

  for _iso_entry in \
    /EFI/efiboot.img \
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
    '.schema_version == 1
      and .artifact_type == "io.github.lwmacct.centos7-tkernel.installer-iso.v1"
      and .iso.firmware == "uefi"
      and .iso.secure_boot == false
      and (.payload.oci_ref | test("@sha256:[0-9a-f]{64}$"))
      and .payload.kernel_release == $_kernel_release
      and .install_contract.minimum_disk_bytes == $_minimum_disk_bytes' \
    "${_temporary_dir}/iso-manifest.json"

  if [ -n "${_outer_manifest}" ]; then
    cmp "${_temporary_dir}/iso-manifest.json" "${_outer_manifest}"
  fi
}

__main "$@"

#!/usr/bin/env bash

__main() {
  set -euo pipefail

  _repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
  # shellcheck disable=SC1091
  source "${_repo_root}/config/install.env"

  test "$(((DATA_END_MIB - EFI_END_MIB) * 1024 * 1024))" \
    = "${DATA_PARTITION_BYTES}"
  test "${MINIMUM_DISK_BYTES}" = 107374182400
  test "${EFI_END_MIB}" -gt "${EFI_START_MIB}"
  test "${DATA_END_MIB}" -gt "${EFI_END_MIB}"
  test "${DATA_END_MIB}" -lt "$((MINIMUM_DISK_BYTES / 1024 / 1024))"
  test "${#DATA_PARTITION_LABEL}" -le 36
  test "${#DATA_FILESYSTEM_LABEL}" -le 12
  test "${#ISO_VOLUME_ID}" -le 32
  test "${DATA_MOUNT}" = /pcdn_data/pcdn_index_data
  test "${KERNEL_RELEASE}" = 5.4.119-19-0006
}

__main "$@"

#!/usr/bin/env bash

__cleanup() {
  if [ -n "${_raw_path:-}" ]; then
    rm -f -- "${_raw_path}"
  fi

  if [ -n "${_new_qcow_path:-}" ]; then
    rm -f -- "${_new_qcow_path}"
  fi

  if [ -n "${_filesystem_image_path:-}" ]; then
    rm -f -- "${_filesystem_image_path}"
  fi
}

__main() {
  set -euo pipefail

  _disk_path=${1:?Usage: prepare-vm-data-partition.sh DISK_QCOW2}
  _root_image_bytes=${VM_ROOT_IMAGE_BYTES:-42949672960}
  _disk_total_bytes=${VM_DISK_TOTAL_BYTES:-107374182400}
  _data_label=${VM_DATA_LABEL:-pcdn_index_data}
  _filesystem_label=${VM_DATA_FS_LABEL:-pcdn_data}
  _temporary_dir=${RUNNER_TEMP:-/tmp}
  _raw_path=$(mktemp "${_temporary_dir}/pcdn-vm-disk.XXXXXX")
  _new_qcow_path=$(mktemp "${_temporary_dir}/pcdn-vm-disk.XXXXXX")
  _filesystem_image_path=$(mktemp "${_temporary_dir}/pcdn-vm-filesystem.XXXXXX")
  trap __cleanup EXIT HUP INT TERM

  test -f "${_disk_path}"
  test "${#_data_label}" -le 16
  test "${#_filesystem_label}" -le 12
  test "${_disk_total_bytes}" -gt "${_root_image_bytes}"

  _initial_virtual_size=$(qemu-img info \
    --output=json \
    --force-share \
    "${_disk_path}" | jq -r '."virtual-size"')
  test "${_initial_virtual_size}" = "${_root_image_bytes}"

  qemu-img convert \
    -f qcow2 \
    -O raw \
    -S 4k \
    "${_disk_path}" \
    "${_raw_path}"
  truncate --size "${_disk_total_bytes}" "${_raw_path}"

  sgdisk --move-second-header "${_raw_path}"
  sgdisk \
    --new=3:0:0 \
    --typecode=3:8300 \
    --change-name="3:${_data_label}" \
    "${_raw_path}"
  sgdisk --verify "${_raw_path}"

  _partition_table=$(sfdisk --json "${_raw_path}")
  test "$(jq '.partitiontable.partitions | length' <<< "${_partition_table}")" = 3
  test "$(jq --arg _label "${_data_label}" \
    '[.partitiontable.partitions[] | select(.name == $_label)] | length' \
    <<< "${_partition_table}")" = 1
  _sector_size=$(jq -r '.partitiontable.sectorsize' <<< "${_partition_table}")
  _data_start_sector=$(jq -r --arg _label "${_data_label}" \
    '.partitiontable.partitions[] | select(.name == $_label) | .start' \
    <<< "${_partition_table}")
  _data_sector_count=$(jq -r --arg _label "${_data_label}" \
    '.partitiontable.partitions[] | select(.name == $_label) | .size' \
    <<< "${_partition_table}")
  _data_offset_bytes=$((_data_start_sector * _sector_size))
  _data_partition_bytes=$((_data_sector_count * _sector_size))
  _expected_data_bytes=$((_disk_total_bytes - _root_image_bytes))
  _minimum_data_bytes=$((_expected_data_bytes - 2 * 1024 * 1024))
  test "${_data_partition_bytes}" -ge "${_minimum_data_bytes}"
  test "${_data_partition_bytes}" -le "${_expected_data_bytes}"

  truncate --size "${_data_partition_bytes}" "${_filesystem_image_path}"
  mkfs.xfs \
    -f \
    -L "${_filesystem_label}" \
    -d "file=1,name=${_filesystem_image_path},size=${_data_partition_bytes}"
  dd \
    if="${_filesystem_image_path}" \
    of="${_raw_path}" \
    bs=1M \
    seek="${_data_offset_bytes}" \
    oflag=seek_bytes \
    conv=notrunc,sparse \
    status=none
  test "$(blkid -p -O "${_data_offset_bytes}" -S "${_data_partition_bytes}" \
    -s TYPE -o value "${_raw_path}")" = xfs
  test "$(blkid -p -O "${_data_offset_bytes}" -S "${_data_partition_bytes}" \
    -s LABEL -o value "${_raw_path}")" = "${_filesystem_label}"

  qemu-img convert \
    -c \
    -f raw \
    -O qcow2 \
    -S 4k \
    "${_raw_path}" \
    "${_new_qcow_path}"
  qemu-img check "${_new_qcow_path}"

  _final_virtual_size=$(qemu-img info \
    --output=json \
    --force-share \
    "${_new_qcow_path}" | jq -r '."virtual-size"')
  test "${_final_virtual_size}" = "${_disk_total_bytes}"

  mv -- "${_new_qcow_path}" "${_disk_path}"
  _new_qcow_path=
}

__main "$@"

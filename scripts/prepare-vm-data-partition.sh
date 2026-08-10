#!/usr/bin/env bash

__cleanup() {
  if [ -n "${_root_loop_device:-}" ]; then
    losetup --detach "${_root_loop_device}" 2>/dev/null || true
  fi

  if [ -n "${_data_loop_device:-}" ]; then
    losetup --detach "${_data_loop_device}" 2>/dev/null || true
  fi

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

__validate_root_filesystem() {
  _filesystem_device=$1
  _filesystem_type=$(blkid -s TYPE -o value "${_filesystem_device}")
  test "${_filesystem_type}" = ext4

  _filesystem_features=$(tune2fs -l "${_filesystem_device}" \
    | sed -n 's/^Filesystem features:[[:space:]]*//p')
  test -n "${_filesystem_features}"

  for _unsupported_feature in metadata_csum metadata_csum_seed orphan_file; do
    case " ${_filesystem_features} " in
      *" ${_unsupported_feature} "*)
        echo "Unsupported CentOS 7 ext4 feature: ${_unsupported_feature}" >&2
        return 1
        ;;
    esac
  done
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

  _initial_partition_table=$(sfdisk --json "${_raw_path}")
  test "$(jq '.partitiontable.partitions | length' \
    <<< "${_initial_partition_table}")" = 2
  _sector_size=$(jq -r '.partitiontable.sectorsize' \
    <<< "${_initial_partition_table}")
  _root_start_sector=$(jq -r '.partitiontable.partitions[1].start' \
    <<< "${_initial_partition_table}")
  _root_sector_count=$(jq -r '.partitiontable.partitions[1].size' \
    <<< "${_initial_partition_table}")
  _root_type_code=$(jq -r '.partitiontable.partitions[1].type' \
    <<< "${_initial_partition_table}")
  _root_partition_uuid=$(jq -r '.partitiontable.partitions[1].uuid' \
    <<< "${_initial_partition_table}")
  _root_partition_name=$(jq -r '.partitiontable.partitions[1].name // empty' \
    <<< "${_initial_partition_table}")
  _data_partition_bytes=$((_disk_total_bytes - _root_image_bytes))
  test "$((_data_partition_bytes % _sector_size))" = 0
  _data_sector_count=$((_data_partition_bytes / _sector_size))
  _data_end_sector=$((_root_start_sector + _data_sector_count - 1))
  _root_target_start_sector=$((_data_end_sector + 1))
  _root_target_end_sector=$((_root_target_start_sector + _root_sector_count - 1))
  _root_offset_bytes=$((_root_start_sector * _sector_size))
  _root_target_offset_bytes=$((_root_target_start_sector * _sector_size))
  _root_partition_bytes=$((_root_sector_count * _sector_size))
  test "${_root_target_offset_bytes}" -ge \
    "$((_root_offset_bytes + _root_partition_bytes))"

  _root_loop_device=$(losetup \
    --find \
    --show \
    --read-only \
    --offset "${_root_offset_bytes}" \
    --sizelimit "${_root_partition_bytes}" \
    "${_raw_path}")
  __validate_root_filesystem "${_root_loop_device}"
  losetup --detach "${_root_loop_device}"
  _root_loop_device=

  truncate --size "${_disk_total_bytes}" "${_raw_path}"

  sgdisk --move-second-header "${_raw_path}"
  sgdisk \
    --delete=2 \
    --new="2:${_root_start_sector}:${_data_end_sector}" \
    --typecode=2:8300 \
    --change-name="2:${_data_label}" \
    --new="3:${_root_target_start_sector}:${_root_target_end_sector}" \
    --typecode="3:${_root_type_code}" \
    --partition-guid="3:${_root_partition_uuid}" \
    "${_raw_path}"
  if [ -n "${_root_partition_name}" ]; then
    sgdisk --change-name="3:${_root_partition_name}" "${_raw_path}"
  fi
  sgdisk --verify "${_raw_path}"

  _partition_table=$(sfdisk --json "${_raw_path}")
  test "$(jq '.partitiontable.partitions | length' <<< "${_partition_table}")" = 3
  test "$(jq -r '.partitiontable.partitions[1].name' \
    <<< "${_partition_table}")" = "${_data_label}"
  test "$(jq -r '.partitiontable.partitions[1].start' \
    <<< "${_partition_table}")" = "${_root_start_sector}"
  test "$(jq -r '.partitiontable.partitions[1].size' \
    <<< "${_partition_table}")" = "${_data_sector_count}"
  test "$(jq -r '.partitiontable.partitions[2].start' \
    <<< "${_partition_table}")" = "${_root_target_start_sector}"
  test "$(jq -r '.partitiontable.partitions[2].size' \
    <<< "${_partition_table}")" = "${_root_sector_count}"
  test "$(jq -r '.partitiontable.partitions[2].uuid' \
    <<< "${_partition_table}")" = "${_root_partition_uuid}"

  dd \
    if="${_raw_path}" \
    of="${_raw_path}" \
    bs=4M \
    skip="${_root_offset_bytes}" \
    seek="${_root_target_offset_bytes}" \
    count="${_root_partition_bytes}" \
    iflag=skip_bytes,count_bytes \
    oflag=seek_bytes \
    conv=notrunc,sparse \
    status=none

  truncate --size "${_data_partition_bytes}" "${_filesystem_image_path}"
  # Disable post-5.4 XFS features emitted by current xfsprogs defaults.
  mkfs.xfs \
    -f \
    -L "${_filesystem_label}" \
    -m "crc=1,finobt=1,rmapbt=0,reflink=0,inobtcount=0,bigtime=0" \
    -i "sparse=0,nrext64=0" \
    -d "file=1,name=${_filesystem_image_path},size=${_data_partition_bytes}"
  fallocate \
    --punch-hole \
    --keep-size \
    --offset "${_root_offset_bytes}" \
    --length "${_data_partition_bytes}" \
    "${_raw_path}"
  dd \
    if="${_filesystem_image_path}" \
    of="${_raw_path}" \
    bs=1M \
    seek="${_root_offset_bytes}" \
    oflag=seek_bytes \
    conv=notrunc,sparse \
    status=none
  _data_loop_device=$(losetup \
    --find \
    --show \
    --read-only \
    --offset "${_root_offset_bytes}" \
    --sizelimit "${_data_partition_bytes}" \
    "${_raw_path}")
  xfs_repair -n "${_data_loop_device}"
  losetup --detach "${_data_loop_device}"
  _data_loop_device=
  test "$(blkid -p -O "${_root_offset_bytes}" -S "${_data_partition_bytes}" \
    -s TYPE -o value "${_raw_path}")" = xfs
  test "$(blkid -p -O "${_root_offset_bytes}" -S "${_data_partition_bytes}" \
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

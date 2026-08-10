#!/usr/bin/env bash

__cleanup() {
  if [ -n "${_temporary_dir:-}" ] && [ -d "${_temporary_dir}" ]; then
    rm -rf -- "${_temporary_dir}"
  fi
}

__find_ovmf() {
  for _code_path in \
    /usr/share/OVMF/OVMF_CODE_4M.fd \
    /usr/share/OVMF/OVMF_CODE.fd; do
    [ -f "${_code_path}" ] || continue
    case "${_code_path}" in
      *_4M.fd) _vars_path=/usr/share/OVMF/OVMF_VARS_4M.fd ;;
      *) _vars_path=/usr/share/OVMF/OVMF_VARS.fd ;;
    esac
    [ -f "${_vars_path}" ] || continue
    _ovmf_code=${_code_path}
    _ovmf_vars=${_vars_path}
    return 0
  done

  return 1
}

__run_qemu() {
  _vars_file=$1
  _serial_log=$2
  _timeout_duration=$3
  shift 3

  timeout --foreground "${_timeout_duration}" \
    qemu-system-x86_64 \
      -machine q35,accel=kvm \
      -cpu host \
      -smp 2 \
      -m 4096 \
      -drive "if=pflash,format=raw,unit=0,readonly=on,file=${_ovmf_code}" \
      -drive "if=pflash,format=raw,unit=1,file=${_vars_file}" \
      -drive "if=virtio,format=qcow2,file=${_disk_path}" \
      -netdev user,id=network0 \
      -device virtio-net-pci,netdev=network0 \
      -display none \
      -monitor none \
      -serial "file:${_serial_log}" \
      -no-reboot \
      "$@"
}

__print_failure_log() {
  _log_path=$1
  printf '%s\n' "--- ${_log_path} ---" >&2
  tail -n 240 "${_log_path}" >&2 || true
}

__test_iso_uefi_boot() {
  _iso_vars="${_temporary_dir}/iso-vars.fd"
  _iso_log="${_log_dir}/iso-uefi-serial.log"
  _iso_pid_file="${_temporary_dir}/iso-qemu.pid"
  cp "${_ovmf_vars}" "${_iso_vars}"

  __run_qemu \
    "${_iso_vars}" \
    "${_iso_log}" \
    5m \
    -boot order=d \
    -pidfile "${_iso_pid_file}" \
    -cdrom "${_iso_path}" &
  _qemu_wrapper_pid=$!

  for _attempt in $(seq 1 150); do
    if grep -q 'Available installation disks' "${_iso_log}" 2>/dev/null; then
      if [ -r "${_iso_pid_file}" ]; then
        kill "$(cat "${_iso_pid_file}")" 2>/dev/null || true
      fi
      wait "${_qemu_wrapper_pid}" 2>/dev/null || true
      return 0
    fi
    if ! kill -0 "${_qemu_wrapper_pid}" 2>/dev/null; then
      __print_failure_log "${_iso_log}"
      return 1
    fi
    sleep 2
  done

  if [ -r "${_iso_pid_file}" ]; then
    kill "$(cat "${_iso_pid_file}")" 2>/dev/null || true
  fi
  wait "${_qemu_wrapper_pid}" 2>/dev/null || true
  __print_failure_log "${_iso_log}"
  return 1
}

__main() {
  set -euo pipefail

  _iso_path=${1:?Usage: test-install-qemu.sh INSTALLER_ISO LOG_DIR}
  _log_dir=${2:?Usage: test-install-qemu.sh INSTALLER_ISO LOG_DIR}
  _repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
  _temporary_dir=$(mktemp -d)
  trap __cleanup EXIT HUP INT TERM

  # shellcheck disable=SC1091
  source "${_repo_root}/config/install.env"
  test -r /dev/kvm
  test -w /dev/kvm
  __find_ovmf
  mkdir -p "${_log_dir}"

  _kernel_path="${_temporary_dir}/vmlinuz"
  _initrd_path="${_temporary_dir}/initrd"
  _disk_path="${_temporary_dir}/installed.qcow2"
  _install_vars="${_temporary_dir}/install-vars.fd"
  _boot_vars="${_temporary_dir}/boot-vars.fd"
  _install_log="${_log_dir}/install-serial.log"
  _boot_log="${_log_dir}/installed-boot-serial.log"

  xorriso -osirrox on -indev "${_iso_path}" \
    -extract /live/vmlinuz "${_kernel_path}" >/dev/null 2>&1
  xorriso -osirrox on -indev "${_iso_path}" \
    -extract /live/initrd "${_initrd_path}" >/dev/null 2>&1
  qemu-img create -f qcow2 "${_disk_path}" "${MINIMUM_DISK_BYTES}"
  cp "${_ovmf_vars}" "${_install_vars}"

  __test_iso_uefi_boot

  if ! __run_qemu \
    "${_install_vars}" \
    "${_install_log}" \
    35m \
    -kernel "${_kernel_path}" \
    -initrd "${_initrd_path}" \
    -append "boot=live components live-media-path=/live console=tty0 console=ttyS0,115200n8 installer.auto=1 installer.target=/dev/vda installer.ci=1 installer.shutdown=poweroff" \
    -cdrom "${_iso_path}"; then
    __print_failure_log "${_install_log}"
    return 1
  fi
  grep -q 'BBIZ_INSTALL_SUCCESS' "${_install_log}" || {
    __print_failure_log "${_install_log}"
    return 1
  }
  qemu-img check "${_disk_path}"

  cp "${_ovmf_vars}" "${_boot_vars}"
  if ! __run_qemu "${_boot_vars}" "${_boot_log}" 15m; then
    __print_failure_log "${_boot_log}"
    return 1
  fi
  grep -q 'BBIZ_BOOT_VERIFY_SUCCESS' "${_boot_log}" || {
    __print_failure_log "${_boot_log}"
    return 1
  }
}

__main "$@"

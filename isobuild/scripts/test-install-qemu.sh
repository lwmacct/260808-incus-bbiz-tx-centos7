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
  _firmware_mode=$1
  _vars_file=$2
  _serial_log=$3
  _timeout_duration=$4
  _qemu_disk_path=$5
  shift 5

  _firmware_args=()
  case "${_firmware_mode}" in
    bios)
      test -z "${_vars_file}"
      ;;
    uefi)
      test -f "${_vars_file}"
      _firmware_args+=(
        -drive "if=pflash,format=raw,unit=0,readonly=on,file=${_ovmf_code}"
        -drive "if=pflash,format=raw,unit=1,file=${_vars_file}"
      )
      ;;
    *)
      printf 'unsupported firmware mode: %s\n' "${_firmware_mode}" >&2
      return 1
      ;;
  esac

  timeout --foreground "${_timeout_duration}" \
    qemu-system-x86_64 \
      -machine q35,accel=kvm \
      -cpu host \
      -smp 2 \
      -m 4096 \
      "${_firmware_args[@]}" \
      -drive "if=virtio,format=qcow2,file=${_qemu_disk_path}" \
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

__test_iso_boot() {
  _firmware_mode=$1
  _vars_file=
  _iso_log="${_log_dir}/iso-${_firmware_mode}-serial.log"
  _iso_pid_file="${_temporary_dir}/iso-${_firmware_mode}-qemu.pid"
  if [ "${_firmware_mode}" = uefi ]; then
    _vars_file="${_temporary_dir}/iso-uefi-vars.fd"
    cp "${_ovmf_vars}" "${_vars_file}"
  fi

  __run_qemu \
    "${_firmware_mode}" \
    "${_vars_file}" \
    "${_iso_log}" \
    5m \
    "${_disk_path}" \
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

__test_installed_boot() {
  _firmware_mode=$1
  _vars_file=
  _boot_log="${_log_dir}/installed-${_firmware_mode}-serial.log"
  _boot_overlay="${_temporary_dir}/installed-${_firmware_mode}.qcow2"
  if [ "${_firmware_mode}" = uefi ]; then
    _vars_file="${_temporary_dir}/installed-uefi-vars.fd"
    cp "${_ovmf_vars}" "${_vars_file}"
  fi

  qemu-img create \
    -f qcow2 \
    -F qcow2 \
    -b "${_disk_path}" \
    "${_boot_overlay}"
  if ! __run_qemu \
    "${_firmware_mode}" \
    "${_vars_file}" \
    "${_boot_log}" \
    5m \
    "${_boot_overlay}" \
    -boot order=c; then
    __print_failure_log "${_boot_log}"
    return 1
  fi
  grep -q "INSTALLER_BOOT_VERIFY_SUCCESS firmware=${_firmware_mode}" "${_boot_log}" || {
    __print_failure_log "${_boot_log}"
    return 1
  }
  qemu-img check "${_boot_overlay}"
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
  test -c /dev/kvm
  test -r /dev/kvm
  test -w /dev/kvm
  __find_ovmf
  mkdir -p "${_log_dir}"

  _kernel_path="${_temporary_dir}/vmlinuz"
  _initrd_path="${_temporary_dir}/initrd"
  _disk_path="${_temporary_dir}/installed.qcow2"
  _install_log="${_log_dir}/install-bios-serial.log"

  xorriso -osirrox on -indev "${_iso_path}" \
    -extract /live/vmlinuz "${_kernel_path}" >/dev/null 2>&1
  xorriso -osirrox on -indev "${_iso_path}" \
    -extract /live/initrd "${_initrd_path}" >/dev/null 2>&1
  qemu-img create -f qcow2 "${_disk_path}" "${MINIMUM_DISK_BYTES}"

  __test_iso_boot bios
  __test_iso_boot uefi

  if ! __run_qemu \
    bios \
    '' \
    "${_install_log}" \
    12m \
    "${_disk_path}" \
    -kernel "${_kernel_path}" \
    -initrd "${_initrd_path}" \
    -append "boot=live components live-media-path=/live console=tty0 console=ttyS0,115200n8 installer.auto=1 installer.target=/dev/vda installer.ci=1 installer.shutdown=poweroff" \
    -cdrom "${_iso_path}"; then
    __print_failure_log "${_install_log}"
    return 1
  fi
  grep -q 'installer firmware mode: Legacy BIOS' "${_install_log}" || {
    __print_failure_log "${_install_log}"
    return 1
  }
  grep -q 'INSTALLER_INSTALL_SUCCESS' "${_install_log}" || {
    __print_failure_log "${_install_log}"
    return 1
  }
  qemu-img check "${_disk_path}"

  __test_installed_boot bios
  __test_installed_boot uefi
}

__main "$@"

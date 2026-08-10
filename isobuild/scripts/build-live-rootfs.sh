#!/usr/bin/env bash

__cleanup() {
  set +e
  if declare -p _chroot_mounts >/dev/null 2>&1; then
    for ((_index=${#_chroot_mounts[@]} - 1; _index >= 0; _index--)); do
      if mountpoint -q "${_chroot_mounts[_index]}"; then
        umount -R "${_chroot_mounts[_index]}"
      fi
    done
  fi
}

__mount_chroot_filesystems() {
  _chroot_mounts=()
  for _path in dev proc sys run; do
    _destination="${_rootfs_dir}/${_path}"
    mkdir -p "${_destination}"
    mount --rbind "/${_path}" "${_destination}"
    mount --make-rslave "${_destination}"
    _chroot_mounts+=("${_destination}")
  done
}

__main() {
  set -Eeuo pipefail

  _rootfs_dir=${1:?Usage: build-live-rootfs.sh ROOTFS_DIR}
  _repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
  _ubuntu_mirror=${UBUNTU_MIRROR:-http://archive.ubuntu.com/ubuntu}
  _ubuntu_security_mirror=${UBUNTU_SECURITY_MIRROR:-http://security.ubuntu.com/ubuntu}
  _chroot_mounts=()
  trap __cleanup EXIT HUP INT TERM

  test "$(id -u)" = 0
  test ! -e "${_rootfs_dir}" || test -d "${_rootfs_dir}"
  mkdir -p "${_rootfs_dir}"
  debootstrap \
    --arch=amd64 \
    --variant=minbase \
    noble \
    "${_rootfs_dir}" \
    "${_ubuntu_mirror}"

  cat > "${_rootfs_dir}/etc/apt/sources.list" <<EOF
deb ${_ubuntu_mirror} noble main universe
deb ${_ubuntu_mirror} noble-updates main universe
deb ${_ubuntu_security_mirror} noble-security main universe
EOF
  rm -f "${_rootfs_dir}/etc/resolv.conf"
  cp --dereference /etc/resolv.conf "${_rootfs_dir}/etc/resolv.conf"
  __mount_chroot_filesystems

  chroot "${_rootfs_dir}" /usr/bin/env DEBIAN_FRONTEND=noninteractive \
    apt-get update
  chroot "${_rootfs_dir}" /usr/bin/env DEBIAN_FRONTEND=noninteractive \
    apt-get install --yes --no-install-recommends \
      bash \
      ca-certificates \
      coreutils \
      dosfstools \
      e2fsprogs \
      findutils \
      gawk \
      gdisk \
      grep \
      initramfs-tools \
      jq \
      kmod \
      linux-image-generic \
      live-boot \
      mount \
      parted \
      procps \
      rsync \
      sed \
      squashfs-tools \
      systemd-sysv \
      udev \
      util-linux \
      xfsprogs

  install -d -m 0755 "${_rootfs_dir}/opt/installer"
  install -m 0755 "${_repo_root}/installer/install.sh" \
    "${_rootfs_dir}/opt/installer/install.sh"
  install -m 0755 "${_repo_root}/installer/installed/installer-ci-verify.sh" \
    "${_rootfs_dir}/opt/installer/installer-ci-verify.sh"
  install -m 0644 "${_repo_root}/config/install.env" \
    "${_rootfs_dir}/opt/installer/install.env"
  install -m 0644 "${_repo_root}/installer/live/installer.service" \
    "${_rootfs_dir}/etc/systemd/system/installer.service"
  install -d -m 0755 "${_rootfs_dir}/etc/systemd/system/multi-user.target.wants"
  ln -s ../installer.service \
    "${_rootfs_dir}/etc/systemd/system/multi-user.target.wants/installer.service"
  ln -sf multi-user.target "${_rootfs_dir}/etc/systemd/system/default.target"
  printf '%s\n' installer > "${_rootfs_dir}/etc/hostname"
  : > "${_rootfs_dir}/etc/machine-id"

  chroot "${_rootfs_dir}" update-initramfs -u -k all
  chroot "${_rootfs_dir}" apt-get clean
  rm -rf "${_rootfs_dir}/var/lib/apt/lists"/*
  rm -f "${_rootfs_dir}/var/lib/dbus/machine-id"

  __cleanup
  _chroot_mounts=()
  trap - EXIT HUP INT TERM
}

__main "$@"

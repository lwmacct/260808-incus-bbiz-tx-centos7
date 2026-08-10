#!/usr/bin/env bash

__main() {
  set -euo pipefail

  _repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
  mapfile -t _shell_files < <(
    find \
      "${_repo_root}/installer" \
      "${_repo_root}/scripts" \
      "${_repo_root}/tests" \
      -type f -name '*.sh' -print | sort
  )
  test "${#_shell_files[@]}" -gt 0

  for _shell_file in "${_shell_files[@]}"; do
    bash -n "${_shell_file}"
  done
  bash "${_repo_root}/tests/test-install-config.sh"

  if command -v shellcheck >/dev/null 2>&1; then
    shellcheck -x "${_shell_files[@]}"
  fi
  if command -v actionlint >/dev/null 2>&1; then
    actionlint -color
  fi
}

__main "$@"

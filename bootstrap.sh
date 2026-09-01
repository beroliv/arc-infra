#!/usr/bin/env bash
set -Eeuo pipefail

readonly REPOSITORY_URL="https://github.com/beroliv/arc-infra"
readonly ARCHIVE_URL="${REPOSITORY_URL}/archive/refs/heads/main.tar.gz"

if (( EUID != 0 )); then
  printf 'ERROR: run this bootstrap as root (for example: curl ... | sudo bash)\n' >&2
  exit 1
fi

command -v curl >/dev/null 2>&1 || {
  printf 'ERROR: curl is required.\n' >&2
  exit 1
}
command -v tar >/dev/null 2>&1 || {
  printf 'ERROR: tar is required.\n' >&2
  exit 1
}

work_dir="$(mktemp -d /tmp/arc-infra.XXXXXXXX)"
trap 'rm -rf -- "$work_dir"' EXIT

printf '[arc] Downloading installer...\n'
curl --fail --silent --show-error --location "$ARCHIVE_URL" \
  | tar --extract --gzip --directory "$work_dir" --strip-components=1

[[ -s "$work_dir/install.sh" ]] || {
  printf 'ERROR: downloaded archive does not contain install.sh.\n' >&2
  exit 1
}

bash "$work_dir/install.sh" "$@"

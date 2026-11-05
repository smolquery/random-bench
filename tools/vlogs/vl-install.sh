#!/usr/bin/env bash
set -euo pipefail

version="$1"
dir=/opt/vlogs
mkdir -p /data "$dir"

dev=""
for d in /dev/nvme*n1; do
  if [ -z "$(lsblk -no MOUNTPOINT "$d" | tr -d '[:space:]')" ]; then
    dev="$d"
  fi
done

if ! mountpoint -q /data; then
  [ -n "$dev" ] || { echo "no unmounted data disk" >&2; exit 1; }
  blkid "$dev" >/dev/null || mkfs.ext4 -q -F "$dev"
  mount -o noatime "$dev" /data
fi
basename "$(findmnt -no SOURCE /data)" > "$dir/disk"

cd "$dir"
if [ ! -x vl ]; then
  curl -fsSL -o vl.tgz \
    "https://github.com/VictoriaMetrics/VictoriaLogs/releases/download/$version/victoria-logs-linux-amd64-$version.tar.gz"
  tar xzf vl.tgz
  rm -f vl.tgz
  ln -sf "$dir/$(ls | grep '^victoria-logs' | head -1)" vl
fi
./vl -version
df -h /data

#!/usr/bin/env bash
set -euo pipefail

dir=/opt/vlogs
for u in vlogs vlogs-sampler; do
  systemctl stop "$u" 2>/dev/null || true
  systemctl reset-failed "$u" 2>/dev/null || true
done
rm -rf /data/vl "$dir/samples.txt"
mkdir -p /data/vl
systemd-run -q --unit=vlogs "$dir/vl" -storageDataPath=/data/vl -httpListenAddr=:9428
systemd-run -q --unit=vlogs-sampler /bin/bash "$dir/vl-sampler.sh"
for _ in $(seq 30); do
  curl -fsS localhost:9428/health >/dev/null 2>&1 && break
  sleep 1
done
curl -fsS localhost:9428/health
echo

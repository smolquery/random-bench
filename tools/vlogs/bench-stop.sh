#!/usr/bin/env bash
for u in vlbench-writer vlbench-querier vlbench-sampler; do
  systemctl stop "$u" 2>/dev/null || true
  systemctl reset-failed "$u" 2>/dev/null || true
done

#!/usr/bin/env bash
set -euo pipefail

vl_addr="$1"
sq_addrs="$2"
sq_query_addrs="$3"
shift 3

cd /opt/bench
command -v git >/dev/null || dnf install -y -q git
export PATH=/usr/local/go/bin:$PATH GOPATH=/opt/go GOCACHE=/opt/go/cache GOTOOLCHAIN=auto HOME=/root
tools/vlogs/build.sh /opt/bench/logs-benchmark /opt/bench/vlbench

for u in vlbench-writer vlbench-querier vlbench-sampler; do
  systemctl stop "$u" 2>/dev/null || true
  systemctl reset-failed "$u" 2>/dev/null || true
done
mkdir -p results
rm -f results/vlogs-bench.txt

key="$(aws ssm get-parameter --name /smolquery-bench/api-key --with-decryption \
  --query Parameter.Value --output text --region "${AWS_REGION:-eu-central-1}")"
env_flags=(
  "--setenv=SMOLQUERY_API_KEY=$key"
  "--setenv=SMOLQUERY_DATASET=${SMOLQUERY_DATASET:-bench}"
  "--setenv=SMOLQUERY_TABLE=${SMOLQUERY_TABLE:-vlogs_v1}"
)
names=(-systemName=victorialogs,smolquery -systemType=victorialogs,smolquery)

systemd-run -q --unit=vlbench-querier "${env_flags[@]}" /opt/bench/vlbench -role=querier \
  "${names[@]}" "-systemAddr=$vl_addr,$sq_query_addrs" -queryInterval=0 -queryTimeout=30s -httpListenAddr=:8081
systemd-run -q --unit=vlbench-writer "${env_flags[@]}" /opt/bench/vlbench -role=writer \
  "${names[@]}" "-systemAddr=$vl_addr,$sq_addrs" -httpListenAddr=:8080 "$@"
systemd-run -q --unit=vlbench-sampler /bin/bash /opt/bench/tools/vlogs/bench-sampler.sh
sleep 5
systemctl is-active vlbench-writer vlbench-querier vlbench-sampler

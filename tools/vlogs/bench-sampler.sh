#!/usr/bin/env bash
pattern='^logbench_(target_rate|lines_generated_total|lines_dropped_total|lines_sent_total|bytes_sent_total|send_line_errors_total|send_retries_total|queue_length|stored_rows|stored_rows_errors_total)'
while true; do
  t="$(date +%s.%N | cut -c1-14)"
  m="$({ curl -s -m 5 localhost:8080/metrics; curl -s -m 5 localhost:8081/metrics; } \
    | grep -E "$pattern" \
    | sed -e 's/^logbench_//' -e 's/{system="\([a-z]*\)"}/:\1/' \
    | awk '{printf "%s=%s ", $1, $2}')"
  echo "$t $m"
  sleep 15
done >> /opt/bench/results/vlogs-bench.txt

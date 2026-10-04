#!/usr/bin/env bash
set -euo pipefail

i=$1
dir=logs/$CB_LABEL

bin/duckdb -c "SET threads = $CB_THREADS; SET memory_limit = '$CB_MEMORY';
  COPY (SELECT * REPLACE (
      make_timestamp(EventTime * 1000000) AS EventTime,
      make_timestamp(ClientEventTime * 1000000) AS ClientEventTime,
      make_timestamp(LocalEventTime * 1000000) AS LocalEventTime,
      DATE '1970-01-01' + EventDate::INTEGER AS EventDate)
    FROM read_parquet('data/hits/hits_$i.parquet', binary_as_string = true))
  TO '/dev/stdout' (FORMAT json)" |
  ./upload1brc -format ndjson -row-bytes 2400 -file /dev/stdin \
    -urls "$CB_URLS" -rows "$CB_ROWS" -workers "$CB_WORKERS" \
    -insert-prefix "$CB_PREFIX-f$i" \
    -progress "$dir/f$i.progress.json" -out "$dir/f$i.upload.json" \
    >"$dir/f$i.log" 2>&1

"""Sums the per-file progress of a ClickBench parallel load into one JSON line.

Usage: load-status.py <log dir> <files total>. Each pipeline writes
f<i>.progress.json while it runs and f<i>.upload.json when it ends; the
driver writes started, finished and exit around the whole load.
"""

import glob
import json
import os
import sys
import time

directory, total = sys.argv[1], int(sys.argv[2])
sums = dict.fromkeys(
    ["rows_accepted", "rows_rejected", "rows_failed", "requests", "retries_429", "retries_other", "data_sent_mib"],
    0,
)
p50s = []
p99s = []

for path in glob.glob(os.path.join(directory, "f*.progress.json")):
    try:
        with open(path) as f:
            snap = json.load(f)
    except (OSError, ValueError):
        continue
    for key in sums:
        sums[key] += snap.get(key) or 0
    latency = snap.get("latency_ms") or {}
    if latency.get("med"):
        p50s.append(latency["med"])
    if latency.get("p99"):
        p99s.append(latency["p99"])


def read(name):
    try:
        with open(os.path.join(directory, name)) as f:
            return f.read().strip()
    except OSError:
        return None


started = read("started")
finished = read("finished")
end = float(finished) if finished else None
elapsed = ((end or time.time()) - float(started)) if started else None
done = len(glob.glob(os.path.join(directory, "f*.upload.json")))

out = dict(sums)
out.update(
    files_total=total,
    files_done=done,
    finished=finished is not None,
    exit=read("exit"),
    started_epoch=float(started) if started else None,
    finished_epoch=end,
    duration_s=elapsed,
    rows_per_s=sums["rows_accepted"] / elapsed if elapsed else None,
    mib_per_s=sums["data_sent_mib"] / elapsed if elapsed else None,
    max_file_p50_ms=max(p50s) if p50s else None,
    max_file_p99_ms=max(p99s) if p99s else None,
)
print(json.dumps(out))

# VictoriaLogs' structured-log ingest bench, with a smolquery arm

**With 8 cores for its ingest tiers, tuned smolquery stored 168,760 lines/s.
VictoriaLogs v1.53.0 stored 141,468 lines/s on one 8-vCPU node.** Both ran
the upstream protocol: one writer sent the same lines to both systems,
2,000 lines per request, 32 requests in flight, ramping in 5-minute steps.
smolquery had zero errors, zero retries and zero restarts. Its sealing kept
up for the whole run.

**smolquery as deployed stores only 53,874 lines/s,** and it is not short of
CPU. Each insert waits out the buffer's full 1-second group-commit window,
so 32 requests in flight cannot carry more. A 100 ms window plus a CPU
split that favours storage gave the 3.1x.

**The tuning has a query cost that this bench does not measure.** The
sandbox runs the 1-second window on purpose: a short window makes more hot
files per query (smolquery-deploy README, 2026-09-21). The sandbox is back
on its deployed settings.

| | VictoriaLogs | smolquery, tuned | smolquery, as deployed |
|---|---:|---:|---:|
| ceiling, lines/s | 141,468 | **168,760** | 53,874 |
| cores at the ceiling | 7.63 of 8 | 6.22 of 8 | ~3 (no limit) |
| what stops it | CPU | buffer CPU | ack latency |
| anonymous memory at the ceiling | 2.9 GiB | 16.9 GiB | 10.2 GiB |
| stored bytes per line | 72.7-96.5 (local disk) | 53.3 (S3) | — |

Runs: 2026-11-05, 02:58 to 17:00 UTC. smolquery `main@4a72dc3` (after
v0.29.3), deployed 2026-11-02.

## What upstream does

[VictoriaMetrics/logs-benchmark](https://github.com/VictoriaMetrics/logs-benchmark),
pinned at `d6c59e9` (2026-10-28), benchmark 1, from the
[blog post](https://victoriametrics.com/blog/structured-log-ingestion-benchmark/):

- A Go writer generates JSON log lines of ~930 bytes with 30 to 40 fields,
  over 5,000 streams (125 hosts × 40 apps), seed 1.
- It sends every line to every system. A system that cannot keep up fills
  its queue, and the writer drops its share for that system only.
- The ramp starts at 10k lines/s and adds 10k every 10 minutes, up to 180k.
- The ceiling is the highest stored rate, averaged over one step, before
  the first crash. A querier counts stored rows every 15 s.
- VictoriaLogs ran on an n2d-standard-8 (8 vCPU AMD Milan, 32 GiB) with a
  500 GiB pd-balanced disk. Published ceiling: 120k lines/s.

## What we ran

- **The writer and the querier are upstream's own binary.**
  `tools/vlogs/build.sh` builds `cmd/bench` at the pin, with one added
  adapter (`tools/vlogs/smolquery.go`). The adapter sends upstream's own
  `AppendJSON` bytes as NDJSON to the insert route. It counts a 200 that
  refused any row as an error. It counts stored rows with `SELECT count(*)`.
- **VictoriaLogs:** v1.53.0 at its defaults, on an m6a.2xlarge (8 vCPU AMD
  Milan, 32 GiB) with a 500 GiB gp3 disk at 280 MiB/s and 3,000 IOPS (the
  write cap of upstream's disk).
- **smolquery:** the sandbox cluster. api, buffer and storage have 3 pods
  each, with buffer replication 2 and 3 write partitions. The 8-core budget
  is set with pod CPU limits (below).
- **The writer box:** c7i.4xlarge in the same VPC.
- **Steps are 5 minutes, not 10.** Ten-minute steps cost 3 hours per run.

## The tuned full run

`loadgen-vlogs-20261105T165839Z-full-t3`. smolquery at
`SMOLQUERY_FLUSH_INTERVAL_MS=100`, with CPU limits api 3 × 200m, buffer
3 × 1200m and storage 3 × 1250m (7.95 cores).

| target | VL stored/s | VL cores | VL anon GiB | SQ stored/s | SQ ingest cores | SQ dropped/s |
|---:|---:|---:|---:|---:|---:|---:|
| 10,000 | 9,857 | 0.36 | 0.36 | 9,916 | 2.08 | 0 |
| 20,000 | 19,508 | 0.71 | 0.59 | 19,028 | 2.05 | 0 |
| 40,000 | 39,482 | 1.35 | 0.73 | 39,015 | 2.89 | 0 |
| 60,000 | 59,446 | 2.34 | 0.95 | 58,980 | 3.67 | 0 |
| 80,000 | 79,414 | 3.26 | 1.08 | 78,982 | 4.35 | 0 |
| 100,000 | 99,409 | 4.49 | 1.26 | 98,916 | 4.87 | 0 |
| 120,000 | 119,378 | 5.90 | 1.44 | 118,885 | — | 0 |
| 130,000 | 129,375 | 6.43 | 1.53 | 128,842 | 5.80 | 0 |
| 140,000 | 139,336 | 7.08 | 2.12 | 139,003 | 5.47 | 0 |
| 150,000 | 140,763 | 7.63 | 2.73 | 148,894 | 6.08 | 0 |
| 160,000 | **141,468** | 7.63 | 2.94 | 158,875 | 5.61 | 0 |
| 170,000 | 139,291 | 7.63 | 2.94 | **168,760** | 6.22 | 0 |
| 180,000 | 136,650 | 7.64 | 3.03 | 168,516 | 6.11 | 10,815 |

- Ingest cores are api + buffer + storage. The query pods are outside the
  budget: they serve only the count polls, at 1 to 2 cores.
- The pod sampler missed the 120k step. That is a gap in the data, not idle
  pods.
- smolquery's unsealed entries stayed at 1,122 to 1,606 for the whole run.
  Sealing kept up.

## smolquery as deployed

Run 1, `loadgen-vlogs-20261105T041945Z`, 10k to 150k, no CPU limits:

| target | VL stored/s | VL cores | SQ stored/s | SQ dropped/s |
|---:|---:|---:|---:|---:|
| 50,000 | 49,486 | 1.72 | 49,506 | 0 |
| 60,000 | 59,435 | 2.11 | **53,874** | 4,213 |
| 100,000 | 99,422 | 4.34 | 52,641 | 46,967 |
| 150,000 | **146,794** | 7.64 | 52,529 | 97,164 |

smolquery levels off at about 53k from the 60k step. It sends no 429s and
no 5xx (`send_retries_total` 0), and it uses about 3 cores.

**The limit is ack latency.** 32 requests in flight at 26.3 requests/s
(52.6k lines/s ÷ 2,000) means a mean ack of 1.2 s. At the 80k step every
buffer commit fired on `reason="interval"`, and one commit's phases were:

| phase | per commit |
|---|---:|
| accumulate | 1,000 ms |
| encode | 72 ms |
| replicate | 10 ms |
| manifest | 4 ms |

The deployed `SMOLQUERY_COMMIT_SIBLINGS=0` holds the short window off, so
`flush_interval_ms` (1,000 by default) governs every commit
(`lib/smolquery/buffer_service/runtime.ex:142` at `4a72dc3`). A 200 from the
insert route waits until the rows are durable and replicated
(`lib/smolquery/buffer_service/table_buffer.ex:9`), so each request waits
out the window.

## The tuning points

Short ramps around the ceiling, 3-minute steps, upstream client shape.

| point | change | SQ ceiling | ingest cores | unsealed entries |
|---|---|---:|---:|---|
| T0 | CPU limits api 3×400m, buffer 3×1500m, storage 3×750m | 52,571 | 1.5-3.2 | flat |
| T1 | + `flush_interval_ms=250` | 132,824 | ~4 | flat |
| T2 | + `flush_interval_ms=100` | 179,189 | 5.5, storage at its limit | **grew 1,228 → 4,702** |
| T3 | limits re-split: api 3×200m, buffer 3×1200m, storage 3×1250m | 167,710 | 6.2 | flat |
| off-protocol | T3 + 128 workers | 179,175 | 6.7 | flat, first 429s at 190k |

- **The CPU limits alone cost nothing** (T0), because CPU was not the limit.
- **T2 peaked highest but could not last.** Storage sat at its 2.25-core
  quota, and the unsealed backlog grew. T3 gave storage 1.5 more cores, and
  the backlog held flat at a slightly lower peak.
- **128 workers added only 7% over 32.** At 8 cores the server is now the
  limit, not the client. The buffers ran at 3.1 of their 3.6 cores, and
  the first 429s came at the 190k step.

A CPU limit is not a 2-vCPU node. Under a 1.2-core quota each pod sees one
BEAM scheduler, so the buffer derives `write_pool_size=1` and
`encode_concurrency=1`, against 4 each unlimited
(`lib/smolquery/buffer_service/runtime.ex:81`). The tuned numbers already
carry that cost.

## Memory and disk

**smolquery uses about 5x the memory of VictoriaLogs at the same rate.** At
160k: api 0.66 GiB, buffer 3.78 GiB, storage 10.51 GiB, against 2.94 GiB
for VictoriaLogs. The storage tier's DuckDB merges hold most of it. These
are cgroup `anon` peaks (the page cache is not counted), as upstream counts
memory.

**On disk, smolquery stores fewer bytes per line.**

- smolquery: 91.05 GB of live sealed Parquet in S3 for 1,708,562,000 rows,
  **53.3 bytes/line**. Read it from the plan's file inventory. The S3
  prefixes hold 113.7 GB, because 647 compacted-away objects (22.6 GB) wait
  for GC. A partitioned table also writes under `vlogs_v1__p1/` and
  `vlogs_v1__p2/`, not only `vlogs_v1/`.
- VictoriaLogs: **72.7 bytes/line** after run 1 (28.76 GB, 395.5M lines)
  and 96.5 after the full run (51.9 GB, 537.6M lines). Both were read
  2 minutes after the writer stopped, with merges still running. Upstream
  waited up to an hour.

## VictoriaLogs against upstream's numbers

The setup reproduces upstream closely. Our VictoriaLogs runs somewhat
leaner and faster:

| | upstream | run 1 |
|---|---|---|
| cores at 10k / 40k / 120k | 0.4 / 1.6 / 7.2 | 0.35 / 1.37 / 5.75 |
| memory at 40k / 120k | 0.8 / 2.5 GiB | 0.74 / 1.42 GiB |
| disk writes per line at 10k / 40k / 120k | 323 / 226 / 163 B | 298 / 262 / 200 B |
| ceiling | 120k, failed at 150k | 146,794 at the 150k step |

Likely causes: shorter steps leave less merge debt per step, and gp3
behaves differently from pd-balanced. Across our runs VictoriaLogs levelled
off at 141k to 150k, CPU-bound at 7.6 cores.

## Caveats

1. **5-minute steps, not 10.** A system that degrades slowly looks better
   on shorter steps. This applies to both systems.
2. **smolquery's budget is CPU quota on shared nodes,** not 8 vCPU of
   dedicated hardware. Its pods also have more memory than the 32 GiB of
   the VictoriaLogs node: 16.9 GiB in use, under 51 GiB of limits.
3. **smolquery replicates every commit to a second buffer, and keeps its
   data in S3.** VictoriaLogs writes one local copy. The durability models
   differ.
4. **The cluster's own Vector shippers also insert,** about 20 small
   requests/s. That is a small handicap for smolquery.
5. **The tuning changes query cost, and this bench did not measure it.**
   The 2026-09-21 deploy note measured 120-206 files per query at a ~225 ms
   cadence against 81-92 at 1 s.
6. **One table holds every run** (`vlogs_v1`, 1.71B rows at the end).
   Rates are deltas, so the starting count does not matter.

## Reproduce

```sh
LOADGEN_INSTANCE_TYPE=c7i.4xlarge mise run bench-up
mise run vlogs-up
BASE_URL=https://<sandbox-host>:8443 mise run bench-vlogs
mise run vlogs-down && mise run bench-down
```

The tuning points add `VLOGS_RATE=50000 VLOGS_STEP=20000 VLOGS_MAX=210000
VLOGS_INTERVAL_S=180`. The full tuned run uses `VLOGS_MAX=180000`. The
smolquery knobs and limits went through `push-secrets.exs` and
`overlay/sandbox/patch-resources.yaml` in smolquery-deploy. Both are reverted.

Charted reports: `results/loadgen-20261105T025753Z.html` (run 1) and
`results/loadgen-20261105T151909Z-full-t3.html` (tuned), plus one per
tuning point. The raw `*.vlogs.json` files are in `results/raw-loadgen/`.
`elixir scripts/loadgen.exs vlogs-report <file>` rebuilds any step table.

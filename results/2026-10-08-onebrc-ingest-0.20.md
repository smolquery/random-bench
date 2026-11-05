# 2026-10-08: the billion-row upload on 0.20.0 peaks at 8.82M rows/s, 12% below 0.16.0

**On the cluster as it is set, the peak is 8,821,698 rows/s at 48 workers:
1,000,000,000 rows in 113.4 s.** The curve is flat from 32 to 128 workers,
within 3% of the peak. Every point landed exactly 1,000,000,000 rows, with
zero rejected rows, zero failed requests and zero pod restarts.

**The same sweep on 0.16.0 (2026-08-24) peaked at 10,008,571 rows/s.** Every
point is 7–12% slower now. The `encode` phase of a buffer commit costs 10%
more per row. The cause is open. The two best leads are in the deploy repo,
not the code: `MALLOC_ARENA_MAX=2` on the buffer and storage pods, and new
background writers that share the same cores.

**The 429 reset bug is fixed.** On 0.16.0 every 429 also reset the
keep-alive connection, so the client re-sent the whole body. Today 5,643
refusals produced zero other retries. The fix is `8082428` (T-562): a
refused body is answered on the conn that read it.

## Setup

- Cluster: smolquery **0.20.0** (`main@390f430`, image `sha256:b209cf90`),
  all pods started 2026-10-06, zero restarts before, during or after.
- Shape: 3 api pods on m7i.large (2 vCPU). 3 buffer and 3 storage pods on
  m7i.xlarge (4 vCPU), one buffer and one storage pod on each node. 3 query
  pods on c6a.4xlarge, idle for this test. This is the same api, buffer and
  storage shape as 2026-08-24.
- Limits: api 3 GiB, buffer 8 GiB (4 GiB on 2026-08-24), storage 6 GiB.
- Tuning from `push-secrets.exs`, unchanged since August: 3 write
  partitions, `FLUSH_MAX_BYTES` 94 MB, `MAX_BUFFERED_BYTES` 192 MB,
  `SEAL_MAX_BYTES` 24 MiB, `STORAGE_MEMORY_LIMIT` 3584MiB. The buffer boot
  log: `encode_concurrency=4 write_pool_size=4 claim_valve_factor=1
  max_live_claims=8 backlog_max_entries=279620`. No inline env overrides on
  any StatefulSet.
- Tables: `bench.onebrc_v7_w16` … `_w128`, one per point, `onebrc_v1`
  schema, clustering `[station]`. Each holds exactly 1B rows.
- Data: `measurements.1000000000.txt`, seed 42, generated on a fresh
  c7i.2xlarge in 22 s. Same bytes as every earlier 1BRC run.
- Upload: `tools/upload1brc`, ~200,000 rows (8.9 MB NDJSON) per request,
  round-robin across the three api pod IPs. 600 s deadline per point, never
  reached.
- Command, 17:21–17:50Z:

      mise exec -- sh -c 'BASE_URL=<sandbox-host> BENCHES=onebrc TABLE=onebrc_v7 \
        ONEBRC_QUERIES=false ONEBRC_WORKERS="16 32 48 64 96 128" \
        ONEBRC_UPLOAD_DEADLINE_S=600 LABEL_SUFFIX=-v7-sweep \
        elixir scripts/loadgen.exs sweep'

- Raw data: `results/raw-loadgen/loadgen-onebrc-v7-sweep-w<N>.{upload,onebrc}.json`,
  `loadgen-20261008T172133Z-v7-sweep.metrics.sqlite3`. Report:
  `results/loadgen-20261008T172133Z-v7-sweep.html`.

## The curve

| workers | wall | rows/s | sent MiB/s | requests | 429 | other retries | p50 | p95 | p99 | max | client cores | drain |
|---|---|---|---|---|---|---|---|---|---|---|---|---|
| 16 | 123.1 s | 8,125,230 | 323.9 | 4,928 | 0 | 0 | 352 ms | 704 | 881 | 1,129 | 0.66 | 48 s |
| 32 | 114.6 s | 8,725,650 | 358.4 | 5,078 | 150 | 0 | 549 ms | 1,348 | 1,582 | 2,077 | 0.71 | 36 s |
| **48** | **113.4 s** | **8,821,698** | 397.0 | 5,564 | 636 | 0 | 695 ms | 1,591 | 1,835 | 2,597 | 0.73 | 37 s |
| 64 | 116.7 s | 8,566,842 | 430.9 | 6,219 | 1,291 | 0 | 769 ms | 1,786 | 2,120 | 2,707 | 0.73 | 47 s |
| 96 | 115.6 s | 8,651,295 | 467.2 | 6,676 | 1,748 | 0 | 1,202 ms | 2,444 | 3,194 | 4,001 | 0.74 | 47 s |
| 128 | 116.1 s | 8,611,583 | 469.9 | 6,746 | 1,818 | 0 | 1,534 ms | 3,603 | 4,226 | 4,793 | 0.75 | 37 s |

Latencies are over accepted requests. "Sent MiB/s" counts every body the
client wrote, retries included. The client never passed 0.75 of the box's 8
cores, so no point is client-bound.

Against 0.16.0, point by point:

| workers | 0.16.0 (2026-08-24) | 0.20.0 (today) | change |
|---|---|---|---|
| 16 | 8,896,787 | 8,125,230 | −8.7% |
| 32 | 9,674,025 | 8,725,650 | −9.8% |
| 48 | 9,931,741 | 8,821,698 | −11.2% |
| 64 | 10,008,571 | 8,566,842 | −14.4% |
| 96 | 9,270,057 | 8,651,295 | −6.7% |
| 128 | 9,181,491 | 8,611,583 | −6.2% |

## What limits it

**The buffer's admission meter sends every 429.**
`smolquery_buffer_admission_refused_rows_total` grew by 23.3M rows at 32
workers, 126.6M at 48 and 260.4M at 64, all on the buffer pods. At 48
workers that is 636 × ~200,000 rows. The api tier refused nothing. The gate
is `Load.admit/3` (`buffer_service/load.ex:55`, PL-9). It refuses a batch
when outstanding rows ÷ service rate passes the ack budget. The service rate
is an EMA over commits. `load.ex` has no commits since August, so the rule
did not change. A slower commit lowers the service rate, so the meter
refuses earlier.

**At 16 workers nothing is refused, and the loss is all latency.** The p50
rose from 324 ms to 352 ms (+9%). The rate fell 8.7%. In a closed loop,
rows/s = workers × rows ÷ latency, so these two numbers are one fact.

**CPU per billion rows rose about 12% on the buffer and storage tiers.**
Core-seconds per 1B-row upload, from `bench_pod_cpu_usec_total`, summed
over the three pods of each role:

| workers | api Aug / Oct | buffer Aug / Oct | storage Aug / Oct |
|---|---|---|---|
| 16 | 353 / 337 | 583 / 640 | 431 / 496 |
| 32 | 329 / 373 | 547 / 671 | 398 / 468 |
| 48 | 341 / 399 | 582 / 636 | 432 / 468 |
| 64 | 353 / 502 | 559 / 680 | 412 / 463 |
| 96 | 473 / 504 | 614 / 612 | 435 / 479 |
| 128 | 464 / 558 | 577 / 643 | 425 / 459 |
| mean | 386 / 446 | 577 / 647 | 422 / 471 |

Each window runs a few seconds past the upload, so the storage column
includes some seal work. The window method is the same in both runs.

**Most of this CPU gap is not 1BRC work.** Since August the cluster ingests
its own metrics (vmagent, deploy `8bd99b2`) and logs (vector, `861abb8`),
and HyperDX reads them. With no 1BRC load, after the sweep, `kubectl top`
read 0.34 buffer cores, 0.43 storage cores and 0.09 api cores, summed over
three pods. Over a ~125 s window that is ~42, ~54 and ~11 core-seconds.
It covers the whole storage gap (+49) and about 60% of the buffer gap
(+70). The api gap (+60) is mostly not background.

**The commit's `encode` phase costs 10% more per row.** Commit-phase time
per 1M committed rows at 48 workers, against the 2026-08-26 run on
`main@1a6a543`:

| phase | 2026-08-26 | today | change |
|---|---|---|---|
| `encode` | 1.027 s | 1.134 s | +10.4% |
| `replicate` | 0.112 s | 0.129 s | +15% |
| `manifest` | 0.024 s | 0.027 s | +14% |

`encode` is one DuckDB `COPY` per flush (`table_buffer/committer.ex`). The
cause of the extra 10% is open.

The deploy repo changed three things on the write path between the
2026-08-26 run (`d06db16`) and today:

1. **`MALLOC_ARENA_MAX=2` on buffer** (`f18f7e2`, 2026-09-09) **and storage**
   (`2dd5c92`, 2026-09-13), in `overlay/sandbox/patch-malloc-arena.yaml`.
   The patch freed ~1.3 GiB of glibc arenas. Its own note names the cost:
   "The trade is malloc contention". No one measured that cost on
   throughput. The `encode` `COPY` runs inside the capped process, so this
   is the first lead to test.
2. **New background writers** (vmagent, vector, HyperDX). Their commits,
   seals and compactions share the 4 cores of each buffer + storage node,
   so they can slow a commit without any change to its own cost.
3. **`SMOLQUERY_COMMIT_SIBLINGS` 1 → 0** (`24aa633`, 2026-09-21). A 1BRC
   insert passes `flush_max_rows` on its own and hands off at once, so this
   should not slow 1BRC. It is why the background writer's commits wait
   the full 1,000 ms interval.

The buffer memory limit also rose from 4 GiB to 8 GiB (`050c805`). That
changes no CPU path.

Three other leads were checked and dropped:

- The Polars removal (`c034442`, T-398) did not change this path. The
  August build already defaulted to DuckDB (`runtime.ex:234` at
  `1a6a543`), and the deploy repo never set `SMOLQUERY_FLUSH_WRITER`.
- The new `accumulate` time (1 s in August, 803 s today at 48 workers) is
  not 1BRC work. It comes from 785 commits of 1,000 rows or fewer, each held
  the full 1,000 ms flush interval. They arrive at ~5.8/s in every phase,
  the drain and generate phases too, so they are a background writer on
  another table.
- Neighbor pods on the buffer nodes (hyperdx, mongo, ingress-nginx, vector)
  each used 16 millicores or less during the run.

Code candidates not yet checked: the column-id check per handoff
(`52361ad`, T-439, `table_buffer.ex` `handoff/2`) and the hot tier
projecting by column id (`e8dfe61`, T-437).

## Pods

Averages over each upload window from `bench_pod_cpu_usec_total`; peak from
`bench_pod_memory_bytes`.

| workers | api cores / peak MB | buffer cores / peak MB | storage cores / peak MB |
|---|---|---|---|
| 16 | 0.84–0.89 / 607–651 | 1.54–1.85 / 2,725–2,851 | 1.08–1.44 / 3,604–4,430 |
| 32 | 0.81–0.87 / 766–937 | 1.45–1.66 / 3,706–3,860 | 1.06–1.08 / 3,659–4,479 |
| 48 | 0.96–1.05 / 941–1,054 | 1.49–1.75 / 4,382–4,822 | 1.03–1.33 / 3,688–4,435 |
| 64 | 1.18–1.25 / 1,074–1,162 | 1.51–1.92 / 4,783–5,036 | 1.06–1.27 / 3,583–4,370 |
| 96 | 1.20–1.42 / 1,336–1,903 | 1.40–1.77 / 4,878–5,092 | 1.11–1.29 / 3,662–4,305 |
| 128 | 1.33–1.54 / 1,562–2,256 | 1.54–1.79 / 4,846–5,179 | 1.03–1.40 / 3,604–5,170 |

- **The api tier has headroom.** It never passed 1.54 of 2 cores.
- **The shared 4-vCPU nodes are busy, not pinned.** One buffer plus one
  storage pod averaged 2.6–3.3 cores per node. `kubectl top` spot readings
  during the 32-worker point showed the nodes at 83–101%.
- **Memory is not a limit any more.** The buffer peaked at 5.2 GB against
  its new 8 GiB limit. On 2026-08-24 it sat at its 4 GiB limit from 64
  workers on.

## What to quote

- **8.8M rows/s** for a billion 2-column rows, at 32–48 workers and
  200,000-row requests, on 3 × m7i.large api and 3 × m7i.xlarge
  buffer + storage nodes. It is a 2-minute burst, not a sustained rate.
- Use 32 workers. It gives 99% of the peak at 79% of the p50.
- More workers buy queue time, not rows.

## Next steps

Test the deploy leads before a code bisect. Each test is one 16-worker
point, where nothing is refused, so the rate reads the commit cost directly.

1. Remove `MALLOC_ARENA_MAX` from the buffer pods, roll, run one point.
   Then do the same for storage.
2. Scale vmagent and vector to zero for one point, then restore them.
3. Only if neither closes the gap, bisect `1a6a543..390f430` in code.
4. To raise throughput on this core count, move the storage pods off the
   buffer nodes. Each node now splits 4 cores between commit and seal work.

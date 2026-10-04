# 2026-08-31: the 1BRC read cliff on a small Postgres

**Reads fall over at 5,000,000 rows.** That is where the table passes
`shared_buffers`. The number is a property of the buffer pool, not of the row
count — a bigger instance moves it.

Postgres 17.6, one Supabase instance, `shared_buffers` 224 MB,
`effective_cache_size` 384 MB, `work_mem` 2184 kB,
`max_parallel_workers_per_gather` 1. Measured through the session-mode pooler
in `eu-central-1`, from a laptop. Run
`results/raw-pg/pg-cliff-1m-2026-09-01T061547.919167Z.pgcliff.json`.

## The curve

One insert step of 1,000,000 rows, then three timed runs of each read, then one
`EXPLAIN (ANALYZE, BUFFERS)` per read. The table is `station text` plus
`temperature double precision`, with a B-tree index on `station`. The rows come
from `generate_series` inside the server, over the same 413 stations and means
as `tools/gen1brc`.

| rows | table | index | agg_all p50 | station p50 | count p50 | noop p50 | agg_all blks read |
|---:|---:|---:|---:|---:|---:|---:|---:|
| 1M | 46.1 MB | 6.5 MB | 604ms | 160ms | 232ms | 157ms | 0 |
| 2M | 92.3 MB | 13.0 MB | 957ms | 166ms | 289ms | 158ms | 0 |
| 3M | 138.4 MB | 19.5 MB | 1.54s | 171ms | 361ms | 159ms | 0 |
| 4M | 184.5 MB | 26.0 MB | 3.38s | 172ms | 428ms | 158ms | 0 |
| **5M** | **230.6 MB** | 32.5 MB | **4.75s** | 196ms | 986ms | 159ms | **2,901** |
| 6M | 276.7 MB | 38.9 MB | 3.92s | 179ms | 1.85s | 157ms | 9,255 |
| 7M | 322.8 MB | 45.4 MB | 5.07s | 185ms | 2.60s | 159ms | 15,386 |
| 8M | 369.0 MB | 51.8 MB | 6.67s | 300ms | 3.50s | 160ms | 21,577 |
| 9M | 415.1 MB | 57.7 MB | 9.14s | 229ms | 4.23s | 159ms | 26,925 |
| 10M | 461.2 MB | 63.1 MB | 10.87s | 9.67s | 5.09s | 159ms | 32,215 |

The run stopped itself at 10M rows, when the median `agg_all` passed the 10 s
limit.

## Finding 1: the cliff is `shared_buffers`, not `effective_cache_size`

Up to 4M rows every block is a buffer hit and the scan is linear — about 345 ms
per million rows of engine time. At 5M rows the table reaches 230.6 MB, passes
the 224 MB buffer pool, and `shared_read` leaves zero for the first time.

`effective_cache_size` is 384 MB, which is 8M rows. Nothing happens there. It is
a planner hint, not a cache. **Size the cliff against `shared_buffers`.**

After the cliff the miss rate is steady, near 3,200 blocks per million rows.
This is a step down to a slower plateau, not a runaway.

## Finding 2: `count(*)` falls over harder than the aggregate

`count(*)` looks cheap before the cliff — 232 ms at 1M rows against 604 ms for
the full aggregate. It then rises 12× between 4M and 10M rows, while `agg_all`
rises 3.2×.

Both read the same blocks. `count(*)` has almost no CPU work to hide the wait,
so the disk shows through immediately. **A cheap-looking query is the one that
degrades most visibly when the cache runs out.**

## Finding 3: the index path survives to 10M rows

`station` — one station's min, average and maximum — holds at 160 to 300 ms from
1M to 9M rows. The plan stays `Bitmap Index Scan` on `bench_onebrc_station_idx`
and `shared_read` stays 0. The 63 MB index still fits in the pool.

The 9.67 s reading at 10M rows is **not** a cliff. A repeat probe of the same
10M-row table, minutes later, read 1730 ms cold and then 225 ms and 196 ms, with
the same plan and 0 blocks read. The slow readings came right after three
back-to-back full scans that each faulted in 32,000 blocks. That is contention
from the neighbouring reads, not a limit of the index.

Treat any single slow reading in this bench as suspect until a probe repeats it.

## Finding 4: the network floor is 157 ms, and it hides the early curve

Every read carries one pooler round trip. The `noop` shape (`SELECT 1`) measures
it and never moves: 156 to 160 ms across the whole run.

At 1M rows the `agg_all` wall time is 604 ms, of which 447 ms is work. At 100k
rows it is 201 ms, of which 44 ms is work. **Below about 500k rows this bench
measures the network, not Postgres.** Subtract `noop` from every other column.

## Finding 5: batch size decides the write number

At 50,000 rows per insert the write ran 28,000 rows/s. At 1,000,000 rows per
insert it ran 86,000 rows/s — 3× faster for the same work.

The small batch spent most of its time in the pooler round trip and the
statement overhead. Insert then fell to about 60,000 rows/s once the buffer pool
filled and every write had to evict.

## The head of the curve, at 50k granularity

A first run measured every 50,000 rows to 800,000. It shows the linear region
and the noise floor together.

| rows | table | agg_all p50 | count p50 | noop p50 |
|---:|---:|---:|---:|---:|
| 50k | 2.4 MB | 186ms | 162ms | 157ms |
| 200k | 9.7 MB | 225ms | 173ms | 158ms |
| 400k | 19.4 MB | 287ms | 190ms | 158ms |
| 600k | 29.0 MB | 493ms | 201ms | 158ms |
| 800k | 38.7 MB | 541ms | 213ms | 159ms |

Run `results/raw-pg/pg-cliff-2026-09-01T061203.507212Z.pgcliff.json`. The 600k
and 800k readings sit above the line through their neighbours, which is the
scale at which one noisy sample still moves a median of three.

## What this run does not answer

- **One instance, one shape.** Two columns, 413 groups, no `WHERE` on a range,
  no join, no concurrent reader. A wider row or a second query changes the
  cliff.
- **A shared tenant.** The instance is not isolated. Neighbour load can move any
  single reading.
- **No cold-cache case.** Every read follows an insert into the same table, so
  the cache is always warm from the write. A restarted instance reads worse.
- **The pooler is in the path.** A direct connection removes one hop, but not
  the 157 ms of distance.

## Reproduce it

```sh
cp .env.example .env                 # then set PG_URL
mise run pg-check                    # server settings and the round trip
mise run pg-setup                    # table, 413 stations, the station index
PG_BATCH_ROWS=1000000 PG_MAX_BYTES=2000000000 mise run pg-cliff
elixir scripts/pg-onebrc.exs probe   # retest the table as it stands, no insert
```

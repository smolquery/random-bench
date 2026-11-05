# ClickBench report: loadgen-clickbench-hits_v2-livecheck

- Table `bench.hits_v2`, `count(*)` 99997497, written 2026-10-04T04:22:45.595577Z.
- Cold restart before each pass: false.

## Summary

| system | machine | queries | hot sum (s) | median hot (s) | cold sum (s) | single hot | single cold | scatter hot | scatter cold |
|---|---|---:|---:|---:|---:|---:|---:|---:|---:|
| **smolquery single** | query pod | 3/3 | 0.9 | 0.336 | 1.0 | | | | |
| **smolquery scatter** | query pod | 3/3 | 4.6 | 1.801 | 4.1 | | | | |
| duckdb-datalake | c6a.4xlarge | 3/3 | 1.6 | 0.516 | 2.0 | 0.67x | 0.61x | 2.24x | 1.74x |
| duckdb-datalake | c6a.metal | 3/3 | 1.1 | 0.449 | 6.3 | 0.89x | 0.39x | 2.98x | 1.10x |
| duckdb-datalake-partitioned | c6a.4xlarge | 3/3 | 4.1 | 1.336 | 4.6 | 0.23x | 0.23x | 0.77x | 0.64x |
| duckdb-datalake-partitioned | c6a.metal | 3/3 | 2.7 | 0.851 | 12.3 | 0.33x | 0.11x | 1.10x | 0.32x |
| clickhouse-datalake | c6a.4xlarge | 3/3 | 0.4 | 0.153 | 9.6 | 2.05x | 0.15x | 6.87x | 0.42x |
| clickhouse-datalake | c6a.metal | 3/3 | 0.4 | 0.136 | 2.0 | 1.98x | 0.51x | 6.63x | 1.45x |
| clickhouse-datalake-partitioned | c6a.4xlarge | 3/3 | 0.3 | 0.093 | 3.8 | 2.47x | 0.28x | 8.27x | 0.81x |
| clickhouse-datalake-partitioned | c6a.metal | 3/3 | 0.4 | 0.124 | 2.4 | 2.09x | 0.43x | 7.00x | 1.22x |

A ratio is the geometric mean of `(smolquery + 0.01) / (theirs + 0.01)` over the queries both answered; under 1x means smolquery is faster. Hot is the fastest try after the first, cold is the first try. Sums cover only the queries each system answered.

Published results: `duckdb-datalake/results/20260726`, `duckdb-datalake-partitioned/results/20260726`, `clickhouse-datalake/results/20261004`, `clickhouse-datalake-partitioned/results/20261004`, from `github.com/ClickHouse/ClickBench`.

## Scatter overhead probe

`scripts/clickbench/probe.sql` (ClickBench Q2: scatters, with partials of a few
hundred bytes), median hot wall time:

| single (ms) | scatter (ms) | scatter overhead (ms) |
|---:|---:|---:|
| 330.1 | 1780.1 | 1450.0 |

## Per query (seconds)

| # | single cold | single hot | scatter cold | scatter hot | duckdb-datalake hot | duckdb-datalake-partitioned hot | clickhouse-datalake hot | clickhouse-datalake-partitioned hot |
|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| 1 | 0.18 | 0.17 | 0.19 | 0.18 | 0.14 | 0.72 | 0.15 | 0.09 |
| 2 | 0.41 | 0.34 | 1.79 | 1.80 ⇉ | 0.52 | 1.34 | 0.10 | 0.09 |
| 3 | 0.43 | 0.38 | 2.13 | 2.60 ⇉ | 0.99 | 2.03 | 0.15 | 0.15 |

Published columns are hot times on c6a.4xlarge. ⇉ marks a query that scattered. `fail` means no try of that kind succeeded.

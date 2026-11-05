# ClickBench report: loadgen-clickbench-hits_v2

- Table `bench.hits_v2`, `count(*)` 99997497, written 2026-10-04T02:00:42.404223Z.
- Cold restart before each pass: true.
- Load: 99997497 rows in 680.8 s, 146882 rows/s, 323.0 MiB/s, 0 x 429, 0 failed.

## Summary

| system | machine | queries | hot sum (s) | median hot (s) | cold sum (s) | scatter hot | scatter cold |
|---|---|---:|---:|---:|---:|---:|---:|
| **smolquery scatter** | query pod | 42/43 | 170.4 | 2.302 | 213.5 | | |
| duckdb-datalake | c6a.4xlarge | 43/43 | 80.8 | 1.089 | 89.3 | 1.56x | 1.92x |
| duckdb-datalake | c6a.metal | 43/43 | 64.7 | 0.790 | 95.3 | 1.98x | 1.89x |
| duckdb-datalake-partitioned | c6a.4xlarge | 43/43 | 116.9 | 2.032 | 121.5 | 0.89x | 1.15x |
| duckdb-datalake-partitioned | c6a.metal | 43/43 | 68.0 | 1.119 | 114.2 | 1.46x | 1.30x |
| clickhouse-datalake | c6a.4xlarge | 43/43 | 34.6 | 0.459 | 137.6 | 4.64x | 1.12x |
| clickhouse-datalake | c6a.metal | 43/43 | 15.3 | 0.219 | 57.3 | 7.27x | 2.35x |
| clickhouse-datalake-partitioned | c6a.4xlarge | 43/43 | 41.0 | 0.423 | 109.0 | 4.25x | 1.26x |
| clickhouse-datalake-partitioned | c6a.metal | 43/43 | 13.3 | 0.239 | 61.4 | 7.13x | 2.13x |

A ratio is the geometric mean of `(smolquery + 0.01) / (theirs + 0.01)` over the queries both answered; under 1x means smolquery is faster. Hot is the fastest try after the first, cold is the first try. Sums cover only the queries each system answered.

Published results: `duckdb-datalake/results/20260726`, `duckdb-datalake-partitioned/results/20260726`, `clickhouse-datalake/results/20261004`, `clickhouse-datalake-partitioned/results/20261004`, from `github.com/ClickHouse/ClickBench`.

## Per query (seconds)

| # | scatter cold | scatter hot | duckdb-datalake hot | duckdb-datalake-partitioned hot | clickhouse-datalake hot | clickhouse-datalake-partitioned hot |
|---:|---:|---:|---:|---:|---:|---:|
| 1 | 0.38 | 0.35 | 0.14 | 0.72 | 0.15 | 0.09 |
| 2 | 5.28 | 2.56 ⇉ | 0.52 | 1.34 | 0.10 | 0.09 |
| 3 | 4.42 | 2.64 ⇉ | 0.99 | 2.03 | 0.15 | 0.15 |
| 4 | 3.78 | 2.53 ⇉ | 0.83 | 1.72 | 0.13 | 0.15 |
| 5 | 4.58 | 0.81 | 0.94 | 1.85 | 0.36 | 0.37 |
| 6 | 3.22 | 1.12 | 1.15 | 2.13 | 0.46 | 0.49 |
| 7 | 2.86 | 2.30 ⇉ | 0.59 | 1.51 | 0.10 | 0.11 |
| 8 | 2.44 | 2.30 ⇉ | 0.52 | 1.43 | 0.10 | 0.09 |
| 9 | 1.07 | 0.98 | 1.04 | 2.00 | 0.56 | 0.58 |
| 10 | 2.07 | 1.15 | 1.92 | 3.22 | 0.66 | 0.68 |
| 11 | 0.65 | 0.65 | 1.17 | 2.15 | 0.25 | 0.24 |
| 12 | 0.90 | 0.74 | 1.44 | 2.69 | 0.26 | 0.23 |
| 13 | 3.45 | 3.19 ⇉ | 1.20 | 2.33 | 0.54 | 0.55 |
| 14 | 1.95 | 1.93 | 1.92 | 3.09 | 0.79 | 0.79 |
| 15 | 3.77 | 3.46 ⇉ | 1.61 | 2.67 | 0.66 | 0.67 |
| 16 | 3.54 | 3.10 ⇉ | 1.00 | 1.92 | 0.39 | 0.41 |
| 17 | 6.61 | 5.52 ⇉ | 2.02 | 3.13 | 1.38 | 1.42 |
| 18 | 5.10 | 5.12 ⇉ | 1.86 | 2.80 | 0.56 | 0.61 |
| 19 | 15.30 | 13.64 ⇉ | 3.65 | 4.81 | 2.60 | 2.63 |
| 20 | 9.35 | 1.53 | 0.61 | 1.49 | 0.12 | 0.12 |
| 21 | 4.80 | 2.79 ⇉ | 3.42 | 3.88 | 1.11 | 1.19 |
| 22 | 3.99 | 2.68 ⇉ | 3.70 | 4.61 | 1.28 | 3.48 |
| 23 | 9.21 | 2.84 | 7.00 | 7.40 | 5.51 | 5.52 |
| 24 | 1.38 | 1.08 | 2.22 | 2.81 | 1.35 | 2.63 |
| 25 | 0.76 | 0.78 | 0.54 | 1.12 | 0.47 | 0.42 |
| 26 | 0.85 | 0.85 | 0.95 | 1.78 | 0.30 | 0.32 |
| 27 | 0.76 | 0.70 | 0.64 | 1.24 | 0.46 | 0.43 |
| 28 | 2.67 | 2.76 ⇉ | 3.31 | 4.28 | 1.87 | 2.02 |
| 29 | 18.40 | 14.97 | 10.17 | 10.71 | 2.27 | 2.42 |
| 30 | 2.39 | 2.64 ⇉ | 0.71 | 1.42 | 0.12 | 0.12 |
| 31 | 2.97 | 3.04 ⇉ | 2.71 | 4.22 | 0.56 | 0.53 |
| 32 | 5.78 | 4.88 ⇉ | 3.10 | 4.59 | 0.78 | 3.00 |
| 33 | 47.35 | 47.53 ⇉ | 3.81 | 5.18 | 2.35 | 2.37 |
| 34 | fail | fail | 4.32 | 5.13 | 2.37 | 2.50 |
| 35 | 19.07 | 17.75 | 4.38 | 5.17 | 2.36 | 2.35 |
| 36 | 4.12 | 3.43 ⇉ | 1.09 | 2.03 | 0.31 | 0.34 |
| 37 | 3.75 | 2.24 ⇉ | 0.62 | 0.82 | 0.13 | 0.15 |
| 38 | 2.27 | 2.25 ⇉ | 0.43 | 1.17 | 0.11 | 0.11 |
| 39 | 0.47 | 0.33 | 0.56 | 0.83 | 0.11 | 0.11 |
| 40 | 0.40 | 0.37 | 0.94 | 1.08 | 0.17 | 0.23 |
| 41 | 0.73 | 0.27 | 0.37 | 0.78 | 0.09 | 0.10 |
| 42 | 0.38 | 0.28 | 0.37 | 0.85 | 0.09 | 0.09 |
| 43 | 0.28 | 0.28 | 0.33 | 0.74 | 0.07 | 0.09 |

Published columns are hot times on c6a.4xlarge. ⇉ marks a query that scattered. `fail` means no try of that kind succeeded.

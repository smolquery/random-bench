# ClickBench report: loadgen-clickbench-hits_v2-single

- Table `bench.hits_v2`, `count(*)` 99997497, written 2026-10-04T02:12:39.931129Z.
- Cold restart before each pass: true.

## Summary

| system | machine | queries | hot sum (s) | median hot (s) | cold sum (s) | single hot | single cold |
|---|---|---:|---:|---:|---:|---:|---:|
| **smolquery single** | query pod | 41/43 | 71.3 | 0.675 | 129.3 | | |
| duckdb-datalake | c6a.4xlarge | 43/43 | 80.8 | 1.089 | 89.3 | 0.69x | 1.03x |
| duckdb-datalake | c6a.metal | 43/43 | 64.7 | 0.790 | 95.3 | 0.86x | 1.02x |
| duckdb-datalake-partitioned | c6a.4xlarge | 43/43 | 116.9 | 2.032 | 121.5 | 0.39x | 0.61x |
| duckdb-datalake-partitioned | c6a.metal | 43/43 | 68.0 | 1.119 | 114.2 | 0.65x | 0.68x |
| clickhouse-datalake | c6a.4xlarge | 43/43 | 34.6 | 0.459 | 137.6 | 2.07x | 0.60x |
| clickhouse-datalake | c6a.metal | 43/43 | 15.3 | 0.219 | 57.3 | 3.20x | 1.25x |
| clickhouse-datalake-partitioned | c6a.4xlarge | 43/43 | 41.0 | 0.423 | 109.0 | 1.89x | 0.67x |
| clickhouse-datalake-partitioned | c6a.metal | 43/43 | 13.3 | 0.239 | 61.4 | 3.14x | 1.13x |

A ratio is the geometric mean of `(smolquery + 0.01) / (theirs + 0.01)` over the queries both answered; under 1x means smolquery is faster. Hot is the fastest try after the first, cold is the first try. Sums cover only the queries each system answered.

Published results: `duckdb-datalake/results/20260726`, `duckdb-datalake-partitioned/results/20260726`, `clickhouse-datalake/results/20261004`, `clickhouse-datalake-partitioned/results/20261004`, from `github.com/ClickHouse/ClickBench`.

## Per query (seconds)

| # | single cold | single hot | duckdb-datalake hot | duckdb-datalake-partitioned hot | clickhouse-datalake hot | clickhouse-datalake-partitioned hot |
|---:|---:|---:|---:|---:|---:|---:|
| 1 | 0.18 | 0.22 | 0.14 | 0.72 | 0.15 | 0.09 |
| 2 | 6.66 | 0.34 | 0.52 | 1.34 | 0.10 | 0.09 |
| 3 | 5.96 | 0.38 | 0.99 | 2.03 | 0.15 | 0.15 |
| 4 | 5.04 | 0.40 | 0.83 | 1.72 | 0.13 | 0.15 |
| 5 | 0.65 | 0.62 | 0.94 | 1.85 | 0.36 | 0.37 |
| 6 | 1.36 | 0.93 | 1.15 | 2.13 | 0.46 | 0.49 |
| 7 | 2.92 | 0.32 | 0.59 | 1.51 | 0.10 | 0.11 |
| 8 | 0.33 | 0.31 | 0.52 | 1.43 | 0.10 | 0.09 |
| 9 | 0.79 | 0.82 | 1.04 | 2.00 | 0.56 | 0.58 |
| 10 | 0.99 | 1.05 | 1.92 | 3.22 | 0.66 | 0.68 |
| 11 | 0.54 | 0.49 | 1.17 | 2.15 | 0.25 | 0.24 |
| 12 | 0.59 | 0.60 | 1.44 | 2.69 | 0.26 | 0.23 |
| 13 | 1.16 | 1.09 | 1.20 | 2.33 | 0.54 | 0.55 |
| 14 | 1.87 | 1.84 | 1.92 | 3.09 | 0.79 | 0.79 |
| 15 | 1.25 | 1.24 | 1.61 | 2.67 | 0.66 | 0.67 |
| 16 | 0.82 | 0.68 | 1.00 | 1.92 | 0.39 | 0.41 |
| 17 | 2.81 | 3.26 | 2.02 | 3.13 | 1.38 | 1.42 |
| 18 | 2.70 | 2.47 | 1.86 | 2.80 | 0.56 | 0.61 |
| 19 | 11.07 | 8.23 | 3.65 | 4.81 | 2.60 | 2.63 |
| 20 | 14.20 | 1.07 | 0.61 | 1.49 | 0.12 | 0.12 |
| 21 | 8.85 | 1.53 | 3.42 | 3.88 | 1.11 | 1.19 |
| 22 | 1.64 | 1.55 | 3.70 | 4.61 | 1.28 | 3.48 |
| 23 | 7.07 | 2.67 | 7.00 | 7.40 | 5.51 | 5.52 |
| 24 | 1.42 | 0.74 | 2.22 | 2.81 | 1.35 | 2.63 |
| 25 | 0.42 | 0.41 | 0.54 | 1.12 | 0.47 | 0.42 |
| 26 | 0.58 | 0.58 | 0.95 | 1.78 | 0.30 | 0.32 |
| 27 | 0.39 | 0.36 | 0.64 | 1.24 | 0.46 | 0.43 |
| 28 | 1.53 | 1.42 | 3.31 | 4.28 | 1.87 | 2.02 |
| 29 | 12.65 | 9.11 | 10.17 | 10.71 | 2.27 | 2.42 |
| 30 | 0.33 | 0.33 | 0.71 | 1.42 | 0.12 | 0.12 |
| 31 | 1.10 | 1.10 | 2.71 | 4.22 | 0.56 | 0.53 |
| 32 | 7.93 | 1.58 | 3.10 | 4.59 | 0.78 | 3.00 |
| 33 | 19.98 | 20.60 | 3.81 | 5.18 | 2.35 | 2.37 |
| 34 | fail | fail | 4.32 | 5.13 | 2.37 | 2.50 |
| 35 | fail | fail | 4.38 | 5.17 | 2.36 | 2.35 |
| 36 | 1.05 | 1.09 | 1.09 | 2.03 | 0.31 | 0.34 |
| 37 | 0.55 | 0.31 | 0.62 | 0.82 | 0.13 | 0.15 |
| 38 | 0.29 | 0.26 | 0.43 | 1.17 | 0.11 | 0.11 |
| 39 | 0.32 | 0.29 | 0.56 | 0.83 | 0.11 | 0.11 |
| 40 | 0.43 | 0.35 | 0.94 | 1.08 | 0.17 | 0.23 |
| 41 | 0.39 | 0.22 | 0.37 | 0.78 | 0.09 | 0.10 |
| 42 | 0.26 | 0.22 | 0.37 | 0.85 | 0.09 | 0.09 |
| 43 | 0.23 | 0.23 | 0.33 | 0.74 | 0.07 | 0.09 |

Published columns are hot times on c6a.4xlarge. ⇉ marks a query that scattered. `fail` means no try of that kind succeeded.

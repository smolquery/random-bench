# ClickBench report: loadgen-clickbench-hits_v2-947-scatter

- Table `bench.hits_v2`, `count(*)` 99997497, written 2026-10-04T04:19:47.035689Z.
- Cold restart before each pass: true.

## Summary

| system | machine | queries | hot sum (s) | median hot (s) | cold sum (s) | scatter hot | scatter cold |
|---|---|---:|---:|---:|---:|---:|---:|
| **smolquery scatter** | query pod | 43/43 | 103.4 | 1.778 | 132.7 | | |
| duckdb-datalake | c6a.4xlarge | 43/43 | 80.8 | 1.089 | 89.3 | 1.17x | 1.37x |
| duckdb-datalake | c6a.metal | 43/43 | 64.7 | 0.790 | 95.3 | 1.51x | 1.39x |
| duckdb-datalake-partitioned | c6a.4xlarge | 43/43 | 116.9 | 2.032 | 121.5 | 0.67x | 0.83x |
| duckdb-datalake-partitioned | c6a.metal | 43/43 | 68.0 | 1.119 | 114.2 | 1.11x | 0.95x |
| clickhouse-datalake | c6a.4xlarge | 43/43 | 34.6 | 0.459 | 137.6 | 3.43x | 0.81x |
| clickhouse-datalake | c6a.metal | 43/43 | 15.3 | 0.219 | 57.3 | 5.46x | 1.70x |
| clickhouse-datalake-partitioned | c6a.4xlarge | 43/43 | 41.0 | 0.423 | 109.0 | 3.15x | 0.91x |
| clickhouse-datalake-partitioned | c6a.metal | 43/43 | 13.3 | 0.239 | 61.4 | 5.37x | 1.54x |

A ratio is the geometric mean of `(smolquery + 0.01) / (theirs + 0.01)` over the queries both answered; under 1x means smolquery is faster. Hot is the fastest try after the first, cold is the first try. Sums cover only the queries each system answered.

Published results: `duckdb-datalake/results/20260726`, `duckdb-datalake-partitioned/results/20260726`, `clickhouse-datalake/results/20261004`, `clickhouse-datalake-partitioned/results/20261004`, from `github.com/ClickHouse/ClickBench`.

## Per query (seconds)

| # | scatter cold | scatter hot | duckdb-datalake hot | duckdb-datalake-partitioned hot | clickhouse-datalake hot | clickhouse-datalake-partitioned hot |
|---:|---:|---:|---:|---:|---:|---:|
| 1 | 0.20 | 0.18 | 0.14 | 0.72 | 0.15 | 0.09 |
| 2 | 3.32 | 2.12 ⇉ | 0.52 | 1.34 | 0.10 | 0.09 |
| 3 | 2.52 | 2.04 ⇉ | 0.99 | 2.03 | 0.15 | 0.15 |
| 4 | 2.36 | 1.78 ⇉ | 0.83 | 1.72 | 0.13 | 0.15 |
| 5 | 2.50 | 0.70 | 0.94 | 1.85 | 0.36 | 0.37 |
| 6 | 2.14 | 0.93 | 1.15 | 2.13 | 0.46 | 0.49 |
| 7 | 1.90 | 1.76 ⇉ | 0.59 | 1.51 | 0.10 | 0.11 |
| 8 | 1.69 | 1.75 ⇉ | 0.52 | 1.43 | 0.10 | 0.09 |
| 9 | 0.94 | 0.87 | 1.04 | 2.00 | 0.56 | 0.58 |
| 10 | 1.56 | 1.12 | 1.92 | 3.22 | 0.66 | 0.68 |
| 11 | 0.64 | 0.56 | 1.17 | 2.15 | 0.25 | 0.24 |
| 12 | 0.73 | 0.66 | 1.44 | 2.69 | 0.26 | 0.23 |
| 13 | 2.80 | 2.58 ⇉ | 1.20 | 2.33 | 0.54 | 0.55 |
| 14 | 1.41 | 1.29 | 1.92 | 3.09 | 0.79 | 0.79 |
| 15 | 2.89 | 2.70 ⇉ | 1.61 | 2.67 | 0.66 | 0.67 |
| 16 | 2.72 | 2.44 ⇉ | 1.00 | 1.92 | 0.39 | 0.41 |
| 17 | 3.91 | 3.75 ⇉ | 2.02 | 3.13 | 1.38 | 1.42 |
| 18 | 3.53 | 3.84 ⇉ | 1.86 | 2.80 | 0.56 | 0.61 |
| 19 | 6.50 | 6.03 ⇉ | 3.65 | 4.81 | 2.60 | 2.63 |
| 20 | 12.26 | 0.98 | 0.61 | 1.49 | 0.12 | 0.12 |
| 21 | 3.54 | 2.49 ⇉ | 3.42 | 3.88 | 1.11 | 1.19 |
| 22 | 3.50 | 2.24 ⇉ | 3.70 | 4.61 | 1.28 | 3.48 |
| 23 | 6.46 | 2.68 | 7.00 | 7.40 | 5.51 | 5.52 |
| 24 | 1.18 | 0.90 | 2.22 | 2.81 | 1.35 | 2.63 |
| 25 | 0.85 | 0.61 | 0.54 | 1.12 | 0.47 | 0.42 |
| 26 | 0.65 | 0.55 | 0.95 | 1.78 | 0.30 | 0.32 |
| 27 | 0.42 | 0.39 | 0.64 | 1.24 | 0.46 | 0.43 |
| 28 | 2.01 | 2.32 ⇉ | 3.31 | 4.28 | 1.87 | 2.02 |
| 29 | 7.64 | 5.83 ⇉ | 10.17 | 10.71 | 2.27 | 2.42 |
| 30 | 1.83 | 2.31 ⇉ | 0.71 | 1.42 | 0.12 | 0.12 |
| 31 | 4.63 | 2.57 ⇉ | 2.71 | 4.22 | 0.56 | 0.53 |
| 32 | 4.05 | 2.99 ⇉ | 3.10 | 4.59 | 0.78 | 3.00 |
| 33 | 16.17 | 17.05 ⇉ | 3.81 | 5.18 | 2.35 | 2.37 |
| 34 | 7.90 | 6.85 ⇉ | 4.32 | 5.13 | 2.37 | 2.50 |
| 35 | 6.62 | 6.95 ⇉ | 4.38 | 5.17 | 2.36 | 2.35 |
| 36 | 2.84 | 3.59 ⇉ | 1.09 | 2.03 | 0.31 | 0.34 |
| 37 | 2.19 | 1.93 ⇉ | 0.62 | 0.82 | 0.13 | 0.15 |
| 38 | 1.92 | 1.74 ⇉ | 0.43 | 1.17 | 0.11 | 0.11 |
| 39 | 0.51 | 0.28 | 0.56 | 0.83 | 0.11 | 0.11 |
| 40 | 0.34 | 0.31 | 0.94 | 1.08 | 0.17 | 0.23 |
| 41 | 0.33 | 0.25 | 0.37 | 0.78 | 0.09 | 0.10 |
| 42 | 0.31 | 0.24 | 0.37 | 0.85 | 0.09 | 0.09 |
| 43 | 0.28 | 0.23 | 0.33 | 0.74 | 0.07 | 0.09 |

Published columns are hot times on c6a.4xlarge. ⇉ marks a query that scattered. `fail` means no try of that kind succeeded.

# ClickBench report: loadgen-clickbench-hits_v2-947-single

- Table `bench.hits_v2`, `count(*)` 99997497, written 2026-10-04T04:12:29.607868Z.
- Cold restart before each pass: true.

## Summary

| system | machine | queries | hot sum (s) | median hot (s) | cold sum (s) | single hot | single cold |
|---|---|---:|---:|---:|---:|---:|---:|
| **smolquery single** | query pod | 43/43 | 57.6 | 0.859 | 94.2 | | |
| duckdb-datalake | c6a.4xlarge | 43/43 | 80.8 | 1.089 | 89.3 | 0.67x | 0.87x |
| duckdb-datalake | c6a.metal | 43/43 | 64.7 | 0.790 | 95.3 | 0.86x | 0.88x |
| duckdb-datalake-partitioned | c6a.4xlarge | 43/43 | 116.9 | 2.032 | 121.5 | 0.39x | 0.53x |
| duckdb-datalake-partitioned | c6a.metal | 43/43 | 68.0 | 1.119 | 114.2 | 0.64x | 0.61x |
| clickhouse-datalake | c6a.4xlarge | 43/43 | 34.6 | 0.459 | 137.6 | 1.97x | 0.52x |
| clickhouse-datalake | c6a.metal | 43/43 | 15.3 | 0.219 | 57.3 | 3.13x | 1.08x |
| clickhouse-datalake-partitioned | c6a.4xlarge | 43/43 | 41.0 | 0.423 | 109.0 | 1.80x | 0.58x |
| clickhouse-datalake-partitioned | c6a.metal | 43/43 | 13.3 | 0.239 | 61.4 | 3.08x | 0.98x |

A ratio is the geometric mean of `(smolquery + 0.01) / (theirs + 0.01)` over the queries both answered; under 1x means smolquery is faster. Hot is the fastest try after the first, cold is the first try. Sums cover only the queries each system answered.

Published results: `duckdb-datalake/results/20260726`, `duckdb-datalake-partitioned/results/20260726`, `clickhouse-datalake/results/20261004`, `clickhouse-datalake-partitioned/results/20261004`, from `github.com/ClickHouse/ClickBench`.

## Per query (seconds)

| # | single cold | single hot | duckdb-datalake hot | duckdb-datalake-partitioned hot | clickhouse-datalake hot | clickhouse-datalake-partitioned hot |
|---:|---:|---:|---:|---:|---:|---:|
| 1 | 0.21 | 0.18 | 0.14 | 0.72 | 0.15 | 0.09 |
| 2 | 4.92 | 0.42 | 0.52 | 1.34 | 0.10 | 0.09 |
| 3 | 2.21 | 0.49 | 0.99 | 2.03 | 0.15 | 0.15 |
| 4 | 2.46 | 0.39 | 0.83 | 1.72 | 0.13 | 0.15 |
| 5 | 0.69 | 0.76 | 0.94 | 1.85 | 0.36 | 0.37 |
| 6 | 1.13 | 0.93 | 1.15 | 2.13 | 0.46 | 0.49 |
| 7 | 0.93 | 0.35 | 0.59 | 1.51 | 0.10 | 0.11 |
| 8 | 0.35 | 0.33 | 0.52 | 1.43 | 0.10 | 0.09 |
| 9 | 0.91 | 0.90 | 1.04 | 2.00 | 0.56 | 0.58 |
| 10 | 1.24 | 1.23 | 1.92 | 3.22 | 0.66 | 0.68 |
| 11 | 0.63 | 0.65 | 1.17 | 2.15 | 0.25 | 0.24 |
| 12 | 0.75 | 0.75 | 1.44 | 2.69 | 0.26 | 0.23 |
| 13 | 0.88 | 0.99 | 1.20 | 2.33 | 0.54 | 0.55 |
| 14 | 1.60 | 1.39 | 1.92 | 3.09 | 0.79 | 0.79 |
| 15 | 1.22 | 1.12 | 1.61 | 2.67 | 0.66 | 0.67 |
| 16 | 0.89 | 0.86 | 1.00 | 1.92 | 0.39 | 0.41 |
| 17 | 1.62 | 1.70 | 2.02 | 3.13 | 1.38 | 1.42 |
| 18 | 1.53 | 1.50 | 1.86 | 2.80 | 0.56 | 0.61 |
| 19 | 4.35 | 2.79 | 3.65 | 4.81 | 2.60 | 2.63 |
| 20 | 13.54 | 1.07 | 0.61 | 1.49 | 0.12 | 0.12 |
| 21 | 5.63 | 1.62 | 3.42 | 3.88 | 1.11 | 1.19 |
| 22 | 1.79 | 1.75 | 3.70 | 4.61 | 1.28 | 3.48 |
| 23 | 6.04 | 2.82 | 7.00 | 7.40 | 5.51 | 5.52 |
| 24 | 0.97 | 0.72 | 2.22 | 2.81 | 1.35 | 2.63 |
| 25 | 0.44 | 0.44 | 0.54 | 1.12 | 0.47 | 0.42 |
| 26 | 0.65 | 0.56 | 0.95 | 1.78 | 0.30 | 0.32 |
| 27 | 0.40 | 0.37 | 0.64 | 1.24 | 0.46 | 0.43 |
| 28 | 1.59 | 1.65 | 3.31 | 4.28 | 1.87 | 2.02 |
| 29 | 11.55 | 9.24 | 10.17 | 10.71 | 2.27 | 2.42 |
| 30 | 0.55 | 0.36 | 0.71 | 1.42 | 0.12 | 0.12 |
| 31 | 1.23 | 1.35 | 2.71 | 4.22 | 0.56 | 0.53 |
| 32 | 3.67 | 1.81 | 3.10 | 4.59 | 0.78 | 3.00 |
| 33 | 5.96 | 5.61 | 3.81 | 5.18 | 2.35 | 2.37 |
| 34 | 3.82 | 3.85 | 4.32 | 5.13 | 2.37 | 2.50 |
| 35 | 4.07 | 3.86 | 4.38 | 5.17 | 2.36 | 2.35 |
| 36 | 1.39 | 0.93 | 1.09 | 2.03 | 0.31 | 0.34 |
| 37 | 0.51 | 0.29 | 0.62 | 0.82 | 0.13 | 0.15 |
| 38 | 0.29 | 0.23 | 0.43 | 1.17 | 0.11 | 0.11 |
| 39 | 0.36 | 0.25 | 0.56 | 0.83 | 0.11 | 0.11 |
| 40 | 0.35 | 0.30 | 0.94 | 1.08 | 0.17 | 0.23 |
| 41 | 0.30 | 0.25 | 0.37 | 0.78 | 0.09 | 0.10 |
| 42 | 0.26 | 0.29 | 0.37 | 0.85 | 0.09 | 0.09 |
| 43 | 0.31 | 0.24 | 0.33 | 0.74 | 0.07 | 0.09 |

Published columns are hot times on c6a.4xlarge. ⇉ marks a query that scattered. `fail` means no try of that kind succeeded.

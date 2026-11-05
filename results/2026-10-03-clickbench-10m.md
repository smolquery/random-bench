# ClickBench on the sandbox cluster, 10M rows

**smolquery answers all 43 ClickBench queries on 10M rows of `hits`, with no
failures.** The total hot time is 93.1 s. The median hot query takes 1.82 s.
Only Q33 takes more than 4.5 s (9.2 s hot).

Most queries take 1.2 to 2.5 s. That is close to the fixed per-query floor,
not to the data size. Q1 (`count(*)`, answered from metadata) still takes
0.67 to 0.90 s.

## Setup

- smolquery 0.21.0, image
  `sha256:50d1b1b53db864286f71c540101e2e7dc29ac35d2248108745dbdbcd96a4e348`.
  3 api, 3 buffer, 3 query, 3 storage pods. Zero restarts during the run.
- Table `bench.hits_v1`: 105 columns, integers as `INT64`, text as
  `STRING`. Clustering `[CounterID, EventDate, UserID, EventTime]`.
- Data: `athena_partitioned/hits_0..9.parquet`, the first 10 of 100 files.
  These are **not a random sample**. Each file holds one `EventDate`, so the
  table holds 10 days. Results do not compare with published 100M numbers.
- Queries: ClickBench `duckdb/queries.sql`, with `hits` replaced by
  `bench.hits_v1`. No other change.
- Each query ran 3 times in a row, from a laptop, through `BASE_URL`
  (`<sandbox-host>:8443`). "first" is try 1. "hot" is
  the fastest of tries 2 and 3. Wall times include the laptop's round trip.
  `durationMs` is the server's job time.

## Ingest

| metric | value |
|---|---|
| rows | 10,000,000 accepted, 0 rejected, 0 failed |
| time | 370.4 s |
| rate | 27,001 rows/s, 59.4 MiB/s (NDJSON, ~2.3 KB/row) |
| requests | 2,404 of ~4,000 rows (~9 MB), 8 workers, 3 api pods |
| ack latency | p50 1.24 s, p99 1.54 s, max 1.93 s |
| 429s / retries | 0 / 0 |
| hot-tier drain | 50 s |
| `count(*)` | 10,000,000 (exact) |

This is one 6-minute upload at 8 workers. It is not a sustained rate or a
peak. The uploader used 0.07 cores, so the box did not limit it.

## Queries

| # | first (s) | hot (s) | `durationMs` (3 tries) | query |
|---:|---:|---:|---|---|
| 1 | 0.86 | 0.89 | 696, 897, 674 | `SELECT COUNT(*) FROM hits;` |
| 2 | 1.62 | 1.29 | 1451, 1256, 1126 | `SELECT COUNT(*) FROM hits WHERE AdvEngineID <> 0;` |
| 3 | 1.63 | 1.42 | 1444, 1251, 1326 | `SELECT SUM(AdvEngineID), COUNT(*), AVG(ResolutionWidth) FROM hits;` |
| 4 | 1.63 | 1.46 | 1460, 1342, 1294 | `SELECT AVG(UserID) FROM hits;` |
| 5 | 3.19 | 2.37 | 3021, 2623, 2146 | `SELECT COUNT(DISTINCT UserID) FROM hits;` |
| 6 | 2.98 | 2.42 | 2800, 2328, 2260 | `SELECT COUNT(DISTINCT SearchPhrase) FROM hits;` |
| 7 | 1.59 | 1.39 | 1395, 1231, 1231 | `SELECT MIN(EventDate), MAX(EventDate) FROM hits;` |
| 8 | 1.35 | 1.35 | 1168, 1186, 1248 | `SELECT AdvEngineID, COUNT(*) FROM hits WHERE AdvEngineID <> 0 GROUP BY AdvEngineID ORDE...` |
| 9 | 1.97 | 1.64 | 1703, 1526, 1417 | `SELECT RegionID, COUNT(DISTINCT UserID) AS u FROM hits GROUP BY RegionID ORDER BY u DES...` |
| 10 | 1.95 | 1.76 | 1762, 1579, 1668 | `SELECT RegionID, SUM(AdvEngineID), COUNT(*) AS c, AVG(ResolutionWidth), COUNT(DISTINCT ...` |
| 11 | 1.64 | 1.40 | 1470, 1234, 1294 | `SELECT MobilePhoneModel, COUNT(DISTINCT UserID) AS u FROM hits WHERE MobilePhoneModel <...` |
| 12 | 1.65 | 1.63 | 1476, 1389, 1477 | `SELECT MobilePhone, MobilePhoneModel, COUNT(DISTINCT UserID) AS u FROM hits WHERE Mobil...` |
| 13 | 2.22 | 1.64 | 1981, 1473, 1661 | `SELECT SearchPhrase, COUNT(*) AS c FROM hits WHERE SearchPhrase <> '' GROUP BY SearchPh...` |
| 14 | 2.41 | 1.83 | 2219, 1904, 1666 | `SELECT SearchPhrase, COUNT(DISTINCT UserID) AS u FROM hits WHERE SearchPhrase <> '' GRO...` |
| 15 | 2.06 | 1.78 | 1841, 1700, 1586 | `SELECT SearchEngineID, SearchPhrase, COUNT(*) AS c FROM hits WHERE SearchPhrase <> '' G...` |
| 16 | 1.86 | 1.62 | 1652, 1412, 1484 | `SELECT UserID, COUNT(*) FROM hits GROUP BY UserID ORDER BY COUNT(*) DESC LIMIT 10;` |
| 17 | 2.21 | 1.99 | 2033, 1914, 1827 | `SELECT UserID, SearchPhrase, COUNT(*) FROM hits GROUP BY UserID, SearchPhrase ORDER BY ...` |
| 18 | 2.29 | 2.10 | 2066, 2031, 1820 | `SELECT UserID, SearchPhrase, COUNT(*) FROM hits GROUP BY UserID, SearchPhrase LIMIT 10;` |
| 19 | 3.30 | 3.36 | 3130, 3188, 4098 | `SELECT UserID, extract(minute FROM EventTime) AS m, SearchPhrase, COUNT(*) FROM hits GR...` |
| 20 | 7.80 | 3.93 | 7523, 3906, 3765 | `SELECT UserID FROM hits WHERE UserID = 435090932899640449;` |
| 21 | 1.77 | 1.86 | 1604, 1647, 1634 | `SELECT COUNT(*) FROM hits WHERE URL LIKE '%google%';` |
| 22 | 1.87 | 1.76 | 1707, 1590, 1587 | `SELECT SearchPhrase, MIN(URL), COUNT(*) AS c FROM hits WHERE URL LIKE '%google%' AND Se...` |
| 23 | 2.12 | 2.08 | 1928, 1906, 2055 | `SELECT SearchPhrase, MIN(URL), MIN(Title), COUNT(*) AS c, COUNT(DISTINCT UserID) FROM h...` |
| 24 | 3.23 | 2.70 | 3060, 2530, 2928 | `SELECT * FROM hits WHERE URL LIKE '%google%' ORDER BY EventTime LIMIT 10;` |
| 25 | 1.63 | 1.31 | 1401, 1228, 1147 | `SELECT SearchPhrase FROM hits WHERE SearchPhrase <> '' ORDER BY EventTime LIMIT 10;` |
| 26 | 1.77 | 1.80 | 1603, 1630, 1906 | `SELECT SearchPhrase FROM hits WHERE SearchPhrase <> '' ORDER BY SearchPhrase LIMIT 10;` |
| 27 | 1.51 | 2.04 | 1341, 1794, 3398 | `SELECT SearchPhrase FROM hits WHERE SearchPhrase <> '' ORDER BY EventTime, SearchPhrase...` |
| 28 | 3.18 | 2.89 | 2972, 3041, 2636 | `SELECT CounterID, AVG(STRLEN(URL)) AS l, COUNT(*) AS c FROM hits WHERE URL <> '' GROUP ...` |
| 29 | 5.57 | 4.32 | 5363, 4359, 4150 | `SELECT REGEXP_REPLACE(Referer, '^https?://(?:www\.)?([^/]+)/.*$', '\1') AS k, AVG(STRLE...` |
| 30 | 1.79 | 1.73 | 1618, 1765, 1541 | `SELECT SUM(ResolutionWidth), SUM(ResolutionWidth + 1), SUM(ResolutionWidth + 2), SUM(Re...` |
| 31 | 2.25 | 1.94 | 2023, 2468, 1773 | `SELECT SearchEngineID, ClientIP, COUNT(*) AS c, SUM(IsRefresh), AVG(ResolutionWidth) FR...` |
| 32 | 2.15 | 2.35 | 1984, 2183, 2202 | `SELECT WatchID, ClientIP, COUNT(*) AS c, SUM(IsRefresh), AVG(ResolutionWidth) FROM hits...` |
| 33 | 10.74 | 9.23 | 10571, 13343, 9060 | `SELECT WatchID, ClientIP, COUNT(*) AS c, SUM(IsRefresh), AVG(ResolutionWidth) FROM hits...` |
| 34 | 3.13 | 3.02 | 2929, 2960, 2850 | `SELECT URL, COUNT(*) AS c FROM hits GROUP BY URL ORDER BY c DESC LIMIT 10;` |
| 35 | 3.08 | 3.07 | 2834, 2906, 3080 | `SELECT 1, URL, COUNT(*) AS c FROM hits GROUP BY 1, URL ORDER BY c DESC LIMIT 10;` |
| 36 | 1.87 | 1.82 | 1703, 1652, 1597 | `SELECT ClientIP, ClientIP - 1, ClientIP - 2, ClientIP - 3, COUNT(*) AS c FROM hits GROU...` |
| 37 | 1.86 | 2.06 | 1656, 1894, 1917 | `SELECT URL, COUNT(*) AS PageViews FROM hits WHERE CounterID = 62 AND EventDate >= '2013...` |
| 38 | 1.86 | 1.75 | 1693, 1572, 1630 | `SELECT Title, COUNT(*) AS PageViews FROM hits WHERE CounterID = 62 AND EventDate >= '20...` |
| 39 | 1.37 | 2.20 | 1093, 1945, 2347 | `SELECT URL, COUNT(*) AS PageViews FROM hits WHERE CounterID = 62 AND EventDate >= '2013...` |
| 40 | 2.75 | 2.28 | 2562, 2110, 2298 | `SELECT TraficSourceID, SearchEngineID, AdvEngineID, CASE WHEN (SearchEngineID = 0 AND A...` |
| 41 | 1.27 | 1.21 | 1084, 961, 1011 | `SELECT URLHash, EventDate, COUNT(*) AS PageViews FROM hits WHERE CounterID = 62 AND Eve...` |
| 42 | 1.28 | 1.27 | 1108, 988, 985 | `SELECT WindowClientWidth, WindowClientHeight, COUNT(*) AS PageViews FROM hits WHERE Cou...` |
| 43 | 1.37 | 1.16 | 1203, 1017, 995 | `SELECT DATE_TRUNC('minute', EventTime) AS M, COUNT(*) AS PageViews FROM hits WHERE Coun...` |

## Notes

- **Q33 is the slowest query** (9.2 s hot). It groups all rows by
  `WatchID, ClientIP`, which is nearly unique per row. It did not fail on
  the 1 GB job engine (`config/config.exs:146`). I did not check whether it
  spilled.
- **Q20 is a point lookup** on `UserID` and takes 3.9 s hot, 7.8 s first.
  `UserID` is the third clustering column, so min-max pruning is unlikely
  to help. I did not take its plan.
- Q37 to Q43 filter on `CounterID = 62`, the first clustering column. They
  take 1.0 to 2.3 s, close to the floor.
- "first" is not a ClickBench cold run. Nothing dropped the pods' page cache
  or file cache. The run queried data that sealed 50 s before.
- Q20, Q40 and Q42 return no rows on this subset. Q24's first value is 0.

## Reproduce

    mise run bench-up
    BASE_URL=https://<sandbox-host>:8443 CLICKBENCH_FILES=10 mise run bench-clickbench
    mise run bench-down

Raw data: the per-query JSON was overwritten by the 100M run (same file name, since fixed); the table above is the record. Also
`loadgen-clickbench.upload.json`, `loadgen-20261004T003637Z.metrics.sqlite3`.
Report: `results/loadgen-20261004T003637Z.html`.

DROP TABLE IF EXISTS bench_onebrc;
DROP TABLE IF EXISTS bench_stations;

CREATE TABLE bench_stations (
  id smallint PRIMARY KEY,
  name text NOT NULL,
  mean double precision NOT NULL
);

CREATE TABLE bench_onebrc (
  station text NOT NULL,
  temperature double precision NOT NULL
);

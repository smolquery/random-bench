#!/usr/bin/env elixir
Code.require_file("bench.exs", __DIR__)

defmodule Bench.PgOnebrc do
  @moduledoc """
  The 1BRC read curve on one Postgres instance.

  The run adds rows in fixed steps and times the same reads after every step,
  until a read passes `PG_SLOW_MS` or a limit stops the run. The rows come from
  `generate_series` and the 413-station table inside the server, so no client
  uplink sits in the measurement.

  Three read shapes run at each checkpoint:

    * `agg_all` — the 1BRC query, `GROUP BY station` over the whole table
    * `station` — one station's min/avg/max, the shape an index serves
    * `count` — `count(*)`, the cheap floor
    * `noop` — `SELECT 1`, the network round trip under every other number

  Each shape also gets one `EXPLAIN (ANALYZE, BUFFERS)`, so the shared hit and
  read block counts say whether a slow read left the page cache.

  Credentials come from `PG_URL` in a gitignored `.env` at the repo root. The
  URL is parsed here and passed to `psql` as `PGHOST`, `PGUSER`, `PGPASSWORD`
  and friends, so the password never reaches a command line.
  """

  @shapes ~w(agg_all station count noop)

  def main(["check"]), do: check()
  def main(["probe"]), do: probe()
  def main(["setup"]), do: setup()
  def main(["run"]), do: run()
  def main(["report"]), do: report(latest_result!())
  def main(["report", path]), do: report(path)

  def main(_),
    do:
      Bench.fatal!(
        "usage: pg-onebrc.exs check | probe | setup | run | report [results/raw-pg/<file>.json]"
      )

  # ── configuration ──────────────────────────────────────────────────────────

  defp table, do: Bench.env("PG_TABLE", "bench_onebrc")
  defp batch_rows, do: Bench.env_int("PG_BATCH_ROWS", 50_000)
  defp measure_every, do: Bench.env_int("PG_MEASURE_EVERY", 1)
  defp max_rows, do: Bench.env_int("PG_MAX_ROWS", 1_000_000_000)
  defp max_bytes, do: Bench.env_int("PG_MAX_BYTES", 0)
  defp slow_ms, do: Bench.env_int("PG_SLOW_MS", 10_000)
  defp deadline_s, do: Bench.env_int("PG_DEADLINE_S", 0)
  defp repeats, do: Bench.env_int("PG_QUERY_REPEATS", 3)
  defp query_timeout_ms, do: Bench.env_int("PG_QUERY_TIMEOUT_MS", 600_000)
  defp seed, do: Bench.env_int("PG_SEED", 42)
  defp station, do: Bench.env("PG_STATION", "Abha")
  defp index?, do: Bench.env("PG_INDEX", "true") == "true"
  defp explain?, do: Bench.env("PG_EXPLAIN", "true") == "true"
  defp truncate?, do: Bench.env("PG_TRUNCATE", "true") == "true"
  defp label, do: Bench.env("PG_LABEL", "pg-cliff")
  defp results_dir, do: Bench.env("RESULTS", Path.join(Bench.root(), "results/raw-pg"))
  defp stations_file, do: Path.join(Bench.root(), "schemas/onebrc_stations.sql")

  # ── connection ─────────────────────────────────────────────────────────────

  defp dotenv! do
    path = Bench.env("ENV_FILE", Path.join(Bench.root(), ".env"))

    if File.exists?(path) do
      path
      |> File.read!()
      |> String.split("\n")
      |> Enum.each(&put_env_line/1)
    end
  end

  defp put_env_line(line) do
    line = line |> String.trim() |> String.replace_prefix("export ", "")

    with false <- line == "" or String.starts_with?(line, "#"),
         [name, value] <- String.split(line, "=", parts: 2) do
      name = String.trim(name)
      value = value |> String.trim() |> unquote_value()
      if System.get_env(name) == nil, do: System.put_env(name, value)
    else
      _ -> :ok
    end
  end

  defp unquote_value(<<?", _::binary>> = value), do: String.trim(value, "\"")
  defp unquote_value(<<?', _::binary>> = value), do: String.trim(value, "'")
  defp unquote_value(value), do: value

  defp pg_env do
    case Process.get(:pg_env) do
      nil ->
        env = build_pg_env()
        Process.put(:pg_env, env)
        env

      env ->
        env
    end
  end

  defp build_pg_env do
    dotenv!()

    url =
      System.get_env("PG_URL") || System.get_env("DATABASE_URL") ||
        Bench.fatal!("""
        set PG_URL to the Postgres connection string.

        Put it in a gitignored .env at the repo root:

            PG_URL=postgres://user:password@host:5432/postgres?sslmode=require
        """)

    uri = URI.parse(url)

    uri.scheme in ["postgres", "postgresql"] ||
      Bench.fatal!("PG_URL must start with postgres:// or postgresql://")

    {user, password} = userinfo(uri.userinfo)
    query = URI.decode_query(uri.query || "")
    database = uri.path |> to_string() |> String.trim_leading("/")

    [
      {"PGHOST", uri.host},
      {"PGPORT", uri.port && Integer.to_string(uri.port)},
      {"PGUSER", user},
      {"PGPASSWORD", password},
      {"PGDATABASE", if(database == "", do: nil, else: database)},
      {"PGSSLMODE", query["sslmode"]},
      {"PGOPTIONS", query["options"]},
      {"PGCONNECT_TIMEOUT", Bench.env("PGCONNECT_TIMEOUT", "15")},
      {"PGAPPNAME", "smolquery_bench pg-onebrc"},
      {"LC_ALL", "C"}
    ]
    |> Enum.reject(fn {_name, value} -> value in [nil, ""] end)
  end

  defp userinfo(nil), do: {nil, nil}

  defp userinfo(userinfo) do
    case String.split(userinfo, ":", parts: 2) do
      [user, password] -> {URI.decode(user), URI.decode(password)}
      [user] -> {URI.decode(user), nil}
    end
  end

  defp psql(args) do
    System.cmd("psql", ["-X", "-v", "ON_ERROR_STOP=1", "-A", "-t", "-F", "|"] ++ args,
      env: pg_env(),
      stderr_to_stdout: true
    )
  end

  defp psql!(args, context) do
    case psql(args) do
      {output, 0} -> output
      {output, status} -> Bench.fatal!("#{context} failed (psql exit #{status}):\n#{output}")
    end
  end

  defp sql!(sql, context), do: psql!(["-c", sql], context)

  defp script(sql) do
    path = Path.join(System.tmp_dir!(), "pg-onebrc-#{System.unique_integer([:positive])}.sql")
    File.write!(path, sql)

    try do
      psql(["-f", path])
    after
      File.rm(path)
    end
  end

  defp script!(sql, context) do
    case script(sql) do
      {output, 0} -> output
      {output, status} -> Bench.fatal!("#{context} failed (psql exit #{status}):\n#{output}")
    end
  end

  defp json!(sql, context) do
    sql |> sql!(context) |> String.trim() |> JSON.decode!()
  end

  # ── check ──────────────────────────────────────────────────────────────────

  defp check do
    env = Map.new(pg_env())

    IO.puts(
      "== connecting to #{env["PGUSER"]}@#{env["PGHOST"]}:#{env["PGPORT"] || "5432"}/" <>
        "#{env["PGDATABASE"]} sslmode=#{env["PGSSLMODE"] || "(libpq default)"}"
    )

    info = server_info()
    IO.puts("== connected: #{info["version_full"]}")

    IO.puts(
      "== shared_buffers=#{info["shared_buffers"]} work_mem=#{info["work_mem"]} " <>
        "effective_cache_size=#{info["effective_cache_size"]} " <>
        "maintenance_work_mem=#{info["maintenance_work_mem"]}"
    )

    IO.puts(
      "== max_parallel_workers_per_gather=#{info["max_parallel_workers_per_gather"]} " <>
        "random_page_cost=#{info["random_page_cost"]} jit=#{info["jit"]}"
    )

    IO.puts("== #{JSON.encode!(timing_probe())}")

    existing =
      json!(
        """
        SELECT json_build_object(
          'bench_onebrc', to_regclass('#{table()}') IS NOT NULL,
          'bench_stations', to_regclass('bench_stations') IS NOT NULL,
          'database_bytes', pg_database_size(current_database()),
          'can_create', has_database_privilege(current_database(), 'CREATE')
        )
        """,
        "check state"
      )

    IO.puts("== #{JSON.encode!(existing)}")

    if existing["can_create"] do
      IO.puts("== ready: run `mise run pg-setup`")
    else
      IO.puts("== this user cannot CREATE in the database; pg-setup will fail")
    end
  end

  defp timing_probe do
    started = System.monotonic_time(:microsecond)
    sql!("SELECT 1", "probe")
    round_trip = System.monotonic_time(:microsecond) - started
    %{"connect_plus_query_ms" => Float.round(round_trip / 1000, 1)}
  end

  @doc """
  One checkpoint against the table as it stands, with no insert.

  Use it to retest a row count the run already passed — an erratic read repeats
  differently when the instance throttles than when the table outgrew a cache.
  """
  def probe do
    rows = count_rows()
    sizes = sizes()
    reads = read_checkpoint()
    explains = if explain?(), do: explains(), else: %{}

    checkpoint = %{
      "rows" => rows,
      "insert" => %{"rows_per_s" => nil},
      "sizes" => sizes,
      "reads" => reads,
      "explains" => explains
    }

    IO.puts(header())
    IO.puts(row_line(checkpoint))

    Enum.each(@shapes, fn shape ->
      samples = get_in(reads, [shape, "all_ms"]) |> Enum.map(&round/1)
      explain = explains[shape]

      IO.puts(
        "   #{String.pad_trailing(shape, 8)} samples #{inspect(samples)}  " <>
          "explain #{round(explain["execution_ms"])}ms, " <>
          "#{explain["shared_hit"]} hit, #{explain["shared_read"]} read"
      )
    end)
  end

  # ── setup ──────────────────────────────────────────────────────────────────

  defp setup do
    info = server_info()
    IO.puts("== postgres: #{info["version"]}")

    IO.puts(
      "== settings: shared_buffers=#{info["shared_buffers"]} work_mem=#{info["work_mem"]} " <>
        "effective_cache_size=#{info["effective_cache_size"]} " <>
        "max_parallel_workers_per_gather=#{info["max_parallel_workers_per_gather"]}"
    )

    ddl =
      "postgres"
      |> Bench.schema_path("onebrc_v1")
      |> File.read!()
      |> String.replace("bench_onebrc", table())

    stations = File.read!(stations_file())

    if truncate?() do
      script!(ddl <> "\n" <> stations, "create #{table()}")
      IO.puts("== created #{table()} and bench_stations, 413 stations")
    else
      IO.puts("== PG_TRUNCATE=false: keeping the existing #{table()}")
    end

    if index?() do
      sql!(
        "CREATE INDEX IF NOT EXISTS #{table()}_station_idx ON #{table()} (station)",
        "create index"
      )

      IO.puts("== index #{table()}_station_idx on (station)")
    else
      IO.puts("== PG_INDEX=false: no index on station")
    end
  end

  defp server_info do
    json!(
      """
      SELECT json_build_object(
        'version', current_setting('server_version'),
        'version_full', version(),
        'shared_buffers', current_setting('shared_buffers'),
        'work_mem', current_setting('work_mem'),
        'maintenance_work_mem', current_setting('maintenance_work_mem'),
        'effective_cache_size', current_setting('effective_cache_size'),
        'max_parallel_workers_per_gather', current_setting('max_parallel_workers_per_gather'),
        'max_worker_processes', current_setting('max_worker_processes'),
        'random_page_cost', current_setting('random_page_cost'),
        'jit', current_setting('jit')
      )
      """,
      "server info"
    )
  end

  # ── run ────────────────────────────────────────────────────────────────────

  defp run do
    File.mkdir_p!(results_dir())
    info = server_info()
    started_rows = count_rows()
    started_at = System.monotonic_time(:millisecond)

    out =
      Path.join(
        results_dir(),
        "#{label()}-#{DateTime.utc_now() |> DateTime.to_iso8601() |> String.replace(":", "")}.pgcliff.json"
      )

    IO.puts("== postgres #{info["version"]}, shared_buffers #{info["shared_buffers"]}")

    IO.puts(
      "== #{table()}: #{fmt_int(started_rows)} rows at the start, " <>
        "#{fmt_int(batch_rows())} rows per batch, a checkpoint every " <>
        "#{measure_every()} batch(es), #{repeats()} repeats per read"
    )

    IO.puts("== stop at #{fmt_int(max_rows())} rows or a median agg_all above #{slow_ms()} ms")
    IO.puts("== writing #{Path.relative_to(out, Bench.root())}\n")
    IO.puts(header())

    run = %{
      "label" => label(),
      "table" => table(),
      "started_at" => DateTime.utc_now() |> DateTime.to_iso8601(),
      "server" => info,
      "config" => config(),
      "checkpoints" => []
    }

    loop(run, out, started_rows, 0, started_at)
  end

  defp config do
    %{
      "batch_rows" => batch_rows(),
      "measure_every" => measure_every(),
      "max_rows" => max_rows(),
      "max_bytes" => max_bytes(),
      "slow_ms" => slow_ms(),
      "deadline_s" => deadline_s(),
      "repeats" => repeats(),
      "seed" => seed(),
      "station" => station(),
      "index" => index?(),
      "explain" => explain?()
    }
  end

  defp loop(run, out, rows, batch_index, started_at) do
    {insert, rows, batch_index, error} = insert_batches(rows, batch_index)
    sizes = sizes()
    reads = read_checkpoint()
    explains = if explain?(), do: explains(), else: %{}

    checkpoint = %{
      "rows" => rows,
      "elapsed_s" => div(System.monotonic_time(:millisecond) - started_at, 1000),
      "at" => DateTime.utc_now() |> DateTime.to_iso8601(),
      "insert" => insert,
      "sizes" => sizes,
      "reads" => reads,
      "explains" => explains
    }

    run = Map.update!(run, "checkpoints", &(&1 ++ [checkpoint]))
    IO.puts(row_line(checkpoint))

    case stop_reason(checkpoint, error, started_at) do
      nil ->
        write_run(run, out)
        loop(run, out, rows, batch_index, started_at)

      reason ->
        run =
          run
          |> Map.put("stopped_because", reason)
          |> Map.put("finished_at", DateTime.utc_now() |> DateTime.to_iso8601())

        write_run(run, out)
        IO.puts("\n== stopped: #{reason}")
        IO.puts("== #{Path.relative_to(out, Bench.root())}\n")
        IO.puts(table_markdown(run))
    end
  end

  defp stop_reason(checkpoint, error, started_at) do
    median = get_in(checkpoint, ["reads", "agg_all", "median_ms"])
    elapsed_s = div(System.monotonic_time(:millisecond) - started_at, 1000)

    cond do
      error ->
        "insert failed: #{error}"

      checkpoint["rows"] >= max_rows() ->
        "reached PG_MAX_ROWS (#{fmt_int(max_rows())} rows)"

      median && median >= slow_ms() ->
        "median agg_all #{fmt_ms(median)} passed PG_SLOW_MS"

      max_bytes() > 0 and checkpoint["sizes"]["total_bytes"] >= max_bytes() ->
        "reached PG_MAX_BYTES"

      deadline_s() > 0 and elapsed_s >= deadline_s() ->
        "reached PG_DEADLINE_S"

      true ->
        nil
    end
  end

  defp write_run(run, out), do: File.write!(out, JSON.encode!(run))

  # ── the write step ─────────────────────────────────────────────────────────

  defp insert_batches(rows, batch_index) do
    indexes = Enum.to_list(batch_index..(batch_index + measure_every() - 1))
    sql = indexes |> Enum.map(&insert_sql/1) |> Enum.join("\n")

    started = System.monotonic_time(:millisecond)
    {output, status} = script("\\timing on\n" <> sql)
    wall_ms = System.monotonic_time(:millisecond) - started

    inserted = length(indexes) * batch_rows()
    error = if status == 0, do: nil, else: String.trim(output) |> String.slice(0, 400)
    rows = if status == 0, do: rows + inserted, else: rows

    insert = %{
      "batches" => length(indexes),
      "rows" => if(status == 0, do: inserted, else: 0),
      "wall_ms" => wall_ms,
      "rows_per_s" =>
        if(wall_ms > 0 and status == 0, do: round(inserted * 1000 / wall_ms), else: 0),
      "error" => error
    }

    {insert, rows, batch_index + length(indexes), error}
  end

  defp insert_sql(index) do
    """
    SELECT setseed(#{batch_seed(index)});
    INSERT INTO #{table()} (station, temperature)
    SELECT s.name,
           round((sqrt(-2 * ln(1 - g.u1)) * cos(2 * pi() * g.u2) * 10 + s.mean)::numeric, 1)::double precision
    FROM (
      SELECT 1 + floor(random() * 413)::int AS id, random() AS u1, random() AS u2
      FROM generate_series(1, #{batch_rows()})
      OFFSET 0
    ) AS g
    JOIN bench_stations s ON s.id = g.id;
    """
  end

  defp batch_seed(index) do
    Float.round(rem(seed() * 1_000_003 + index * 7919, 2_000_001) / 1_000_000.0 - 1.0, 6)
  end

  # ── the read step ──────────────────────────────────────────────────────────

  defp query("agg_all") do
    """
    SELECT station, min(temperature), avg(temperature), max(temperature)
    FROM #{table()} GROUP BY station ORDER BY station
    """
  end

  defp query("station") do
    """
    SELECT station, min(temperature), avg(temperature), max(temperature)
    FROM #{table()} WHERE station = '#{String.replace(station(), "'", "''")}' GROUP BY station
    """
  end

  defp query("count"), do: "SELECT count(*) FROM #{table()}"

  defp query("noop"), do: "SELECT 1"

  defp read_checkpoint do
    statements =
      for shape <- @shapes, i <- 1..repeats() do
        "\\echo @@q #{shape}\n" <>
          String.trim_trailing(query(shape)) <> ";\n" <> "\\echo @@r #{i}"
      end

    sql =
      "\\timing on\nSET statement_timeout = #{query_timeout_ms()};\n" <>
        Enum.join(statements, "\n")

    output = script!(sql, "read checkpoint")

    reads =
      output
      |> parse_timings()
      |> Enum.group_by(fn {shape, _ms} -> shape end, fn {_shape, ms} -> ms end)
      |> Map.new(fn {shape, samples} -> {shape, summarize(samples)} end)

    Map.keys(reads) == Enum.sort(@shapes) ||
      Bench.fatal!("psql reported no timing for every read shape:\n#{output}")

    reads
  end

  defp parse_timings(output) do
    output
    |> String.split("\n")
    |> Enum.reduce({nil, []}, fn line, {shape, acc} ->
      line = String.trim(line)

      cond do
        String.starts_with?(line, "@@q ") ->
          {String.trim_leading(line, "@@q "), acc}

        shape && String.starts_with?(line, "Time: ") ->
          {nil, [{shape, parse_ms(line)} | acc]}

        true ->
          {shape, acc}
      end
    end)
    |> elem(1)
    |> Enum.reverse()
  end

  defp parse_ms("Time: " <> rest) do
    rest |> String.split(" ") |> hd() |> String.to_float()
  end

  defp summarize([]), do: %{"samples" => 0}

  defp summarize(samples) do
    sorted = Enum.sort(samples)

    %{
      "samples" => length(sorted),
      "min_ms" => hd(sorted),
      "median_ms" => Enum.at(sorted, div(length(sorted), 2)),
      "max_ms" => List.last(sorted),
      "all_ms" => samples
    }
  end

  defp explains do
    Map.new(@shapes, fn shape ->
      sql = "EXPLAIN (ANALYZE, BUFFERS, FORMAT JSON) " <> String.trim_trailing(query(shape))

      plan =
        ("SET statement_timeout = #{query_timeout_ms()};\n" <> sql <> ";")
        |> script!("explain #{shape}")
        |> decode_plan(shape)
        |> hd()

      node = plan["Plan"]

      {shape,
       %{
         "execution_ms" => plan["Execution Time"],
         "planning_ms" => plan["Planning Time"],
         "node" => node["Node Type"],
         "shared_hit" => node["Shared Hit Blocks"],
         "shared_read" => node["Shared Read Blocks"],
         "rows" => node["Actual Rows"],
         "plan" => plan
       }}
    end)
  end

  defp decode_plan(output, shape) do
    case :binary.match(output, "[") do
      {offset, _length} ->
        output |> binary_part(offset, byte_size(output) - offset) |> JSON.decode!()

      :nomatch ->
        Bench.fatal!("explain #{shape} returned no plan:\n#{output}")
    end
  end

  defp sizes do
    json!(
      """
      SELECT json_build_object(
        'table_bytes', pg_table_size('#{table()}'),
        'index_bytes', pg_indexes_size('#{table()}'),
        'total_bytes', pg_total_relation_size('#{table()}'),
        'database_bytes', pg_database_size(current_database()),
        'reltuples', (SELECT reltuples::bigint FROM pg_class WHERE oid = '#{table()}'::regclass)
      )
      """,
      "sizes"
    )
  end

  defp count_rows do
    "SELECT count(*) FROM #{table()}"
    |> sql!("count rows")
    |> String.trim()
    |> String.to_integer()
  end

  # ── output ─────────────────────────────────────────────────────────────────

  defp header do
    head =
      String.pad_leading("rows", 13) <>
        String.pad_leading("table", 11) <>
        String.pad_leading("index", 10) <>
        String.pad_leading("agg_all", 12) <>
        String.pad_leading("station", 11) <>
        String.pad_leading("count", 11) <>
        String.pad_leading("noop", 10) <>
        String.pad_leading("blks read", 12) <>
        String.pad_leading("insert rows/s", 15)

    head <> "\n" <> String.duplicate("-", String.length(head))
  end

  defp row_line(checkpoint) do
    read = fn shape -> get_in(checkpoint, ["reads", shape, "median_ms"]) end

    String.pad_leading(fmt_int(checkpoint["rows"]), 13) <>
      String.pad_leading(fmt_bytes(checkpoint["sizes"]["table_bytes"]), 11) <>
      String.pad_leading(fmt_bytes(checkpoint["sizes"]["index_bytes"]), 10) <>
      String.pad_leading(fmt_ms(read.("agg_all")), 12) <>
      String.pad_leading(fmt_ms(read.("station")), 11) <>
      String.pad_leading(fmt_ms(read.("count")), 11) <>
      String.pad_leading(fmt_ms(read.("noop")), 10) <>
      String.pad_leading(fmt_int(get_in(checkpoint, ["explains", "agg_all", "shared_read"])), 12) <>
      String.pad_leading(fmt_int(checkpoint["insert"]["rows_per_s"]), 15)
  end

  defp report(path) do
    run = path |> File.read!() |> JSON.decode!()
    IO.puts(table_markdown(run))
  end

  defp table_markdown(run) do
    header = [
      "| rows | table | index | agg_all p50 | station p50 | count p50 | noop p50 | agg_all blks read | insert rows/s |",
      "|---:|---:|---:|---:|---:|---:|---:|---:|---:|"
    ]

    rows =
      Enum.map(run["checkpoints"], fn c ->
        read = fn shape -> fmt_ms(get_in(c, ["reads", shape, "median_ms"])) end

        "| #{fmt_int(c["rows"])} | #{fmt_bytes(c["sizes"]["table_bytes"])} | " <>
          "#{fmt_bytes(c["sizes"]["index_bytes"])} | #{read.("agg_all")} | #{read.("station")} | " <>
          "#{read.("count")} | #{read.("noop")} | " <>
          "#{fmt_int(get_in(c, ["explains", "agg_all", "shared_read"]))} | " <>
          "#{fmt_int(c["insert"]["rows_per_s"])} |"
      end)

    stopped = run["stopped_because"]
    tail = if stopped, do: ["", "Stopped: #{stopped}"], else: []

    Enum.join(header ++ rows ++ tail, "\n")
  end

  defp latest_result! do
    case Path.wildcard(Path.join(results_dir(), "*.pgcliff.json"))
         |> Enum.sort()
         |> List.last() do
      nil -> Bench.fatal!("no result in #{results_dir()}")
      path -> path
    end
  end

  defp fmt_int(nil), do: "-"

  defp fmt_int(n) do
    n
    |> Integer.to_string()
    |> String.reverse()
    |> String.replace(~r/(\d{3})(?=\d)/, "\\1,")
    |> String.reverse()
  end

  defp fmt_ms(nil), do: "-"
  defp fmt_ms(ms) when ms >= 1000, do: "#{Float.round(ms / 1000, 2)}s"
  defp fmt_ms(ms), do: "#{Float.round(ms * 1.0, 1)}ms"

  defp fmt_bytes(nil), do: "-"
  defp fmt_bytes(b) when b >= 1_073_741_824, do: "#{Float.round(b / 1_073_741_824, 2)} GB"
  defp fmt_bytes(b) when b >= 1_048_576, do: "#{Float.round(b / 1_048_576, 1)} MB"
  defp fmt_bytes(b), do: "#{Float.round(b / 1024, 1)} kB"
end

Bench.PgOnebrc.main(System.argv())

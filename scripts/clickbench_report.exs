defmodule Bench.ClickbenchReport do
  @moduledoc """
  Writes the markdown comparison for one ClickBench run: each smolquery pass
  against ClickBench's published results.

  The default comparison set is the object-storage entries, the ones that read
  `hits` Parquet from S3 as smolquery does: `duckdb-datalake`,
  `duckdb-datalake-partitioned`, `clickhouse-datalake` and
  `clickhouse-datalake-partitioned`. The local-disk entries measure a
  different storage model and stay out unless `CLICKBENCH_COMPARE` names them.
  `CLICKBENCH_COMPARE_MACHINES` picks the machines (`c6a.4xlarge,c6a.metal`).

  The latest results date of each entry comes from the GitHub contents API.
  Each published JSON is cached under `results/raw-clickbench-published/`, and
  a failed fetch falls back to the newest cached date.

  Hot is the fastest successful try after the first; cold is the first try.
  Published results are cut to the query numbers the run has, so a
  `CLICKBENCH_ONLY` subset compares like for like.
  A ratio is ClickBench's: the geometric mean of `(ours + 0.01) / (theirs +
  0.01)` over the queries both answered, so under 1 means smolquery is faster.

  Reads both run shapes: `"passes"` keyed by mode (since 2026-10-04), and the
  older single `"queries"` result, whose mode comes from its options.
  """

  @repo "ClickHouse/ClickBench"
  @default_entries ~w(duckdb-datalake duckdb-datalake-partitioned clickhouse-datalake clickhouse-datalake-partitioned)

  def main([path]), do: IO.puts(generate(path))
  def main(_argv), do: Bench.fatal!("usage: clickbench-report.exs <run>.clickbench.json")

  @doc """
  Writes `results/<run>.clickbench.md` for a run JSON and returns its path.
  """
  def generate(path, out \\ nil) do
    run = path |> File.read!() |> JSON.decode!()
    passes = passes(run)
    passes != [] || raise "#{path} holds no query pass"
    numbers = passes |> hd() |> elem(1) |> Enum.map(& &1.n)
    published = Enum.map(published(), &align(&1, numbers))
    name = path |> Path.basename() |> String.replace_suffix(".clickbench.json", "")
    out = out || Path.join([Bench.root(), "results", "#{name}.clickbench.md"])
    File.write!(out, render(name, run, passes, published))
    out
  end

  defp passes(%{"passes" => passes} = run) when is_map(passes) do
    order = run["modes"] || Map.keys(passes)
    for mode <- order, result = passes[mode], do: {mode, vectors(result)}
  end

  defp passes(%{"queries" => %{"queries" => _} = result}) do
    mode = if get_in(result, ["options", "distributed"]) == false, do: "single", else: "scatter"
    [{mode, vectors(result)}]
  end

  defp passes(_run), do: []

  defp vectors(%{"queries" => queries}) do
    queries
    |> Enum.sort_by(& &1["n"])
    |> Enum.map(fn query ->
      [first | rest] = query["tries"]
      ok = fn try -> try["error"] in [nil, ""] end

      %{
        n: query["n"],
        cold: if(ok.(first), do: first["wall_ms"] / 1000),
        hot: rest |> Enum.filter(ok) |> Enum.map(&(&1["wall_ms"] / 1000)) |> min_or_nil(),
        scatter: Enum.any?(query["tries"], &(&1["scatter"] not in [nil, ""])),
        errors: Enum.count(query["tries"], &(not ok.(&1)))
      }
    end)
  end

  defp published do
    entries = Bench.env("CLICKBENCH_COMPARE", Enum.join(@default_entries, ",")) |> csv()
    machines = Bench.env("CLICKBENCH_COMPARE_MACHINES", "c6a.4xlarge,c6a.metal") |> csv()

    for entry <- entries,
        date = latest_date(entry),
        machine <- machines,
        result = fetch_result(entry, date, machine) do
      %{
        entry: entry,
        machine: machine,
        date: date,
        hot:
          Enum.map(result["result"], fn [_ | rest] ->
            rest |> Enum.reject(&is_nil/1) |> min_or_nil()
          end),
        cold: Enum.map(result["result"], &hd/1)
      }
    end
  end

  defp align(entry, numbers) do
    pick = fn values -> Enum.map(numbers, &Enum.at(values, &1 - 1)) end
    %{entry | hot: pick.(entry.hot), cold: pick.(entry.cold)}
  end

  defp csv(value), do: value |> String.split(",", trim: true) |> Enum.map(&String.trim/1)

  defp cache_dir(entry), do: Path.join([Bench.root(), "results/raw-clickbench-published", entry])

  defp latest_date(entry) do
    url = "https://api.github.com/repos/#{@repo}/contents/#{entry}/results"

    case Bench.http(:get, url, [{"user-agent", "smolquery-bench"}]) do
      {:ok, 200, body} ->
        body |> JSON.decode!() |> Enum.map(& &1["name"]) |> Enum.max(fn -> nil end)

      _failure ->
        case entry |> cache_dir() |> Path.join("*") |> Path.wildcard() do
          [] ->
            IO.puts(:stderr, "clickbench-report: no results date for #{entry}, skipped")
            nil

          dirs ->
            dirs |> Enum.map(&Path.basename/1) |> Enum.max()
        end
    end
  end

  defp fetch_result(entry, date, machine) do
    cached = Path.join([cache_dir(entry), date, "#{machine}.json"])

    if File.exists?(cached) do
      cached |> File.read!() |> JSON.decode!()
    else
      url =
        "https://raw.githubusercontent.com/#{@repo}/main/#{entry}/results/#{date}/#{machine}.json"

      case Bench.http(:get, url, [{"user-agent", "smolquery-bench"}]) do
        {:ok, 200, body} ->
          File.mkdir_p!(Path.dirname(cached))
          File.write!(cached, body)
          JSON.decode!(body)

        _missing ->
          nil
      end
    end
  end

  defp render(name, run, passes, published) do
    modes = Enum.map(passes, &elem(&1, 0))

    [
      "# ClickBench report: #{name}\n",
      run_lines(run),
      "## Summary\n",
      summary(passes, published, modes),
      "A ratio is the geometric mean of `(smolquery + 0.01) / (theirs + 0.01)` over " <>
        "the queries both answered; under 1x means smolquery is faster. Hot is the " <>
        "fastest try after the first, cold is the first try. Sums cover only the " <>
        "queries each system answered.\n",
      sources(published),
      probe(run["probe"]),
      "## Per query (seconds)\n",
      per_query(passes, published)
    ]
    |> Enum.reject(&(&1 == ""))
    |> Enum.join("\n")
  end

  defp run_lines(run) do
    load = run["load"]

    lines = [
      "- Table `#{run["table"]}`, `count(*)` #{run["count"]}, written #{run["inserted_at"]}.",
      "- Cold restart before each pass: #{run["cold"] || false}."
    ]

    lines =
      if is_map(load) do
        lines ++
          [
            "- Load: #{load["rows_accepted"]} rows in #{fmt(load["duration_s"], 1)} s, " <>
              "#{round(load["rows_per_s"] || 0)} rows/s, #{fmt(load["mib_per_s"], 1)} MiB/s, " <>
              "#{load["retries_429"]} x 429, #{load["rows_failed"]} failed."
          ]
      else
        lines
      end

    Enum.join(lines, "\n") <> "\n"
  end

  defp summary(passes, published, modes) do
    ratio_headers = Enum.flat_map(modes, &["#{&1} hot", "#{&1} cold"])

    header =
      "| system | machine | queries | hot sum (s) | median hot (s) | cold sum (s) | " <>
        Enum.join(ratio_headers, " | ") <>
        " |\n" <>
        "|---|---|---:|---:|---:|---:|" <>
        String.duplicate("---:|", length(ratio_headers)) <> "\n"

    blanks = String.duplicate(" |", length(ratio_headers))

    ours =
      Enum.map(passes, fn {mode, rows} ->
        hot = Enum.map(rows, & &1.hot)

        "| **smolquery #{mode}** | query pod | #{count_ok(hot)}/#{length(rows)} | " <>
          "#{fmt(sum(hot), 1)} | #{fmt(median(hot), 3)} | #{fmt(sum(Enum.map(rows, & &1.cold)), 1)} |" <>
          blanks
      end)

    theirs =
      Enum.map(published, fn entry ->
        ratios =
          Enum.flat_map(passes, fn {_mode, rows} ->
            [
              ratio(Enum.map(rows, & &1.hot), entry.hot),
              ratio(Enum.map(rows, & &1.cold), entry.cold)
            ]
          end)

        "| #{entry.entry} | #{entry.machine} | #{count_ok(entry.hot)}/#{length(entry.hot)} | " <>
          "#{fmt(sum(entry.hot), 1)} | #{fmt(median(entry.hot), 3)} | #{fmt(sum(entry.cold), 1)} | " <>
          Enum.join(ratios, " | ") <> " |"
      end)

    header <> Enum.join(ours ++ theirs, "\n") <> "\n"
  end

  defp sources([]), do: "No published results could be fetched.\n"

  defp sources(published) do
    dates =
      published
      |> Enum.map(&"`#{&1.entry}/results/#{&1.date}`")
      |> Enum.uniq()
      |> Enum.join(", ")

    "Published results: #{dates}, from `github.com/#{@repo}`.\n"
  end

  defp probe(nil), do: ""

  defp probe(probe) do
    """
    ## Scatter overhead probe

    `scripts/clickbench/probe.sql` (ClickBench Q2: scatters, with partials of a few
    hundred bytes), median hot wall time:

    | single (ms) | scatter (ms) | scatter overhead (ms) |
    |---:|---:|---:|
    | #{fmt(probe["single_ms"], 1)} | #{fmt(probe["scatter_ms"], 1)} | #{fmt(probe["overhead_ms"], 1)} |
    """
  end

  defp per_query(passes, published) do
    machine = published |> Enum.map(& &1.machine) |> List.first()
    columns = Enum.filter(published, &(&1.machine == machine))
    pass_headers = Enum.flat_map(passes, fn {mode, _} -> ["#{mode} cold", "#{mode} hot"] end)
    entry_headers = Enum.map(columns, &"#{&1.entry} hot")
    headers = pass_headers ++ entry_headers

    header =
      "| # | " <>
        Enum.join(headers, " | ") <>
        " |\n" <>
        "|---:|" <> String.duplicate("---:|", length(headers)) <> "\n"

    numbers = passes |> List.first() |> elem(1) |> Enum.map(& &1.n)

    rows =
      numbers
      |> Enum.with_index()
      |> Enum.map(fn {n, index} ->
        ours =
          Enum.flat_map(passes, fn {_mode, rows} ->
            row = Enum.at(rows, index)
            mark = if row.scatter, do: " ⇉", else: ""
            [cell(row.cold), cell(row.hot) <> mark]
          end)

        theirs = Enum.map(columns, &cell(Enum.at(&1.hot, index)))
        "| #{n} | " <> Enum.join(ours ++ theirs, " | ") <> " |"
      end)

    note =
      if machine,
        do:
          "\nPublished columns are hot times on #{machine}. ⇉ marks a query that scattered. " <>
            "`fail` means no try of that kind succeeded.\n",
        else: "\n"

    header <> Enum.join(rows, "\n") <> "\n" <> note
  end

  defp ratio(ours, theirs) do
    pairs = for {a, b} <- Enum.zip(ours, theirs), a != nil and b != nil, do: {a, b}

    case pairs do
      [] ->
        "—"

      _pairs ->
        logs = Enum.map(pairs, fn {a, b} -> :math.log((a + 0.01) / (b + 0.01)) end)
        "#{fmt(:math.exp(Enum.sum(logs) / length(logs)), 2)}x"
    end
  end

  defp cell(nil), do: "fail"
  defp cell(value), do: fmt(value, 2)

  defp count_ok(values), do: Enum.count(values, &(&1 != nil))
  defp sum(values), do: values |> Enum.reject(&is_nil/1) |> Enum.sum()

  defp median(values) do
    case values |> Enum.reject(&is_nil/1) |> Enum.sort() do
      [] ->
        nil

      sorted ->
        middle = div(length(sorted), 2)

        if rem(length(sorted), 2) == 1,
          do: Enum.at(sorted, middle),
          else: (Enum.at(sorted, middle - 1) + Enum.at(sorted, middle)) / 2
    end
  end

  defp min_or_nil([]), do: nil
  defp min_or_nil(values), do: Enum.min(values)

  defp fmt(nil, _digits), do: "—"
  defp fmt(value, digits) when is_integer(value), do: fmt(value / 1, digits)
  defp fmt(value, digits), do: :erlang.float_to_binary(value, decimals: digits)
end

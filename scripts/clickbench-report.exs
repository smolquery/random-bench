#!/usr/bin/env elixir
Code.require_file("bench.exs", __DIR__)
Code.require_file("clickbench_report.exs", __DIR__)
Bench.ClickbenchReport.main(System.argv())

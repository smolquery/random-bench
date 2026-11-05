#!/usr/bin/env elixir
Code.require_file("bench.exs", __DIR__)
Code.require_file("report_html.exs", __DIR__)
Code.require_file("clickbench_report.exs", __DIR__)

defmodule Bench.Loadgen do
  @moduledoc """
  An in-region k6 box, so a sweep measures the cluster instead of the operator's
  uplink.

  The instance lives in the cluster's VPC and carries the EKS cluster security
  group, which permits traffic from itself — so it reaches pod IPs directly, on
  plain HTTP, with no new rule and no Cloudflare, NLB or TLS in the path.

  Everything moves over SSM: no public IP, no SSH key, no inbound rule. Code
  goes up as an inline base64 tarball rather than a `git clone`, so a run always
  ships the working tree instead of whatever landed on `main`. Results come back
  the same way. The api key does not ride in command text — SSM keeps command
  history, and anyone with `ssm:GetCommandInvocation` can read it — so `sweep`
  puts the key in SSM Parameter Store and the box reads it from there.

  `k6` and `genbody` run on the box; `Bench.WatchPods` stays on this machine,
  because pod sampling needs the kubeconfig.
  """

  @tag "smolquery-bench-loadgen"
  @role "smolquery-bench-loadgen"
  @ssm_output_limit 24_000

  def main(argv) do
    case argv do
      ["up"] -> up()
      ["status"] -> status()
      ["sweep"] -> sweep()
      ["fetch"] -> fetch()
      ["down"] -> down()
      ["vlogs-up"] -> vlogs_up()
      ["vlogs-down"] -> vlogs_down()
      ["vlogs-report", path] -> vlogs_report(path)
      ["ssh"] -> session()
      _ -> Bench.fatal!("usage: loadgen.exs <up|status|sweep|fetch|down|ssh|vlogs-up|vlogs-down>")
    end
  end

  # ── configuration ──────────────────────────────────────────────────────────

  defp region, do: Bench.env("AWS_REGION", "eu-central-1")
  defp profile, do: Bench.env("AWS_PROFILE", "sandbox")
  defp cluster, do: Bench.env("CLUSTER_NAME", "smolquery-dev")
  defp instance_type, do: Bench.env("LOADGEN_INSTANCE_TYPE", "c7i.2xlarge")
  defp root_gib, do: Bench.env("LOADGEN_ROOT_GIB", "64")
  defp rows, do: Bench.env("ROWS", "3062")

  defp body_file, do: "bodies/#{Bench.body_name(Bench.shape(), rows())}"

  defp vus_list, do: Bench.env("VUS_LIST", "8 16 32 64 128") |> String.split()
  defp duration_s, do: Bench.env("DURATION_S", "30")
  defp warmup_s, do: Bench.env("WARMUP_S", "10")
  defp pause_s, do: Bench.env_int("PAUSE_S", 8)
  defp results_dir, do: Bench.env("RESULTS", Path.join(Bench.root(), "results/raw-loadgen"))
  defp label_suffix, do: Bench.env("LABEL_SUFFIX", "")
  defp k6_version, do: Bench.env("K6_VERSION", "v2.2.0")
  defp go_version, do: Bench.env("GO_VERSION", "go1.26.4")
  defp remote_dir, do: "/opt/bench"

  # ── aws plumbing ───────────────────────────────────────────────────────────

  defp aws!(args) do
    case System.cmd("aws", args ++ ["--region", region(), "--profile", profile()],
           stderr_to_stdout: true
         ) do
      {out, 0} ->
        String.trim(out)

      {out, _} ->
        if String.contains?(out, "sso") and String.contains?(out, "expired") do
          Bench.fatal!("AWS SSO token expired. Run: aws sso login --profile #{profile()}")
        end

        Bench.fatal!("aws #{Enum.join(args, " ")} failed:\n#{out}")
    end
  end

  defp aws_json!(args) do
    args |> Kernel.++(["--output", "json"]) |> aws!() |> JSON.decode!()
  end

  # ── discovery ──────────────────────────────────────────────────────────────

  defp vpc_config do
    aws_json!([
      "eks",
      "describe-cluster",
      "--name",
      cluster(),
      "--query",
      "cluster.resourcesVpcConfig.{vpc:vpcId,sg:clusterSecurityGroupId,subnets:subnetIds}"
    ])
  end

  @doc """
  The security group the cluster's nodes actually carry.

  Not the EKS cluster security group — that one is attached to the control
  plane's ENIs, and the managed node group uses a separate shared node group
  instead. Only the node group has the self-referencing `tcp 1025-65535` rule
  that lets one member reach a pod port on another, so the load generator has
  to wear this one to reach the api pod on 4000.
  """
  def node_security_group do
    aws!([
      "ec2",
      "describe-instances",
      "--filters",
      "Name=tag:eks:cluster-name,Values=#{cluster()}",
      "Name=instance-state-name,Values=running",
      "--query",
      "Reservations[0].Instances[0].SecurityGroups[0].GroupId",
      "--output",
      "text"
    ])
    |> case do
      id when id in ["", "None"] ->
        Bench.fatal!("could not find the cluster's node security group")

      id ->
        id
    end
  end

  defp instance_id(tag \\ @tag) do
    aws!([
      "ec2",
      "describe-instances",
      "--filters",
      "Name=tag:Name,Values=#{tag}",
      "Name=instance-state-name,Values=pending,running",
      "--query",
      "Reservations[0].Instances[0].InstanceId",
      "--output",
      "text"
    ])
    |> case do
      "" -> nil
      "None" -> nil
      id -> id
    end
  end

  defp instance_id! do
    instance_id() || Bench.fatal!("no running #{@tag} instance. Run: mise run bench-up")
  end

  def api_pod_ip, do: hd(api_pod_ips())

  @doc """
  Every ready api pod's IP, so load spreads across the whole api tier.

  The load generator sits outside the cluster, so it cannot route to the
  `smolquery-api` ClusterIP — kube-proxy only balances from inside. VPC-CNI
  gives each pod a real VPC address instead, and the Service's endpoint list is
  the set of pods that are ready to take traffic. `API_POD` pins the run to one
  pod, which is what every sweep before 2026-08-16 measured by accident.
  """
  def api_pod_ips do
    case Bench.env("API_POD", nil) do
      nil -> endpoint_ips()
      pod -> [pod_ip(pod)]
    end
  end

  @ipv4 ~r/^\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}$/

  defp endpoint_ips(service \\ "smolquery-api") do
    args = [
      "get",
      "endpointslices",
      "-l",
      "kubernetes.io/service-name=#{service}",
      "-o",
      "jsonpath={range .items[*].endpoints[?(@.conditions.ready==true)]}{.addresses[0]}{\" \"}{end}"
    ]

    case Bench.Kube.cmd(args) do
      {output, 0} ->
        ips =
          output
          |> String.split(~r/\s+/, trim: true)
          |> Enum.filter(&Regex.match?(@ipv4, &1))
          |> Enum.uniq()
          |> Enum.sort()

        ips != [] || Bench.fatal!("the smolquery-api service has no ready endpoints")
        ips

      {out, _} ->
        Bench.fatal!("could not resolve the smolquery-api endpoints:\n#{out}")
    end
  end

  defp pod_ip(pod) do
    case Bench.Kube.cmd(["get", "pod", pod, "-o", "jsonpath={.status.podIP}"]) do
      {ip, 0} ->
        ip = String.trim(ip)
        ip != "" || Bench.fatal!("api pod #{pod} has no IP yet")
        ip

      {out, _} ->
        Bench.fatal!("could not resolve the api pod IP:\n#{out}")
    end
  end

  # ── iam ────────────────────────────────────────────────────────────────────

  defp ensure_instance_profile do
    exists? =
      match?(
        {_, 0},
        System.cmd(
          "aws",
          ["iam", "get-instance-profile", "--instance-profile-name", @role] ++
            ["--profile", profile()],
          stderr_to_stdout: true
        )
      )

    if exists? do
      IO.puts("instance profile #{@role} exists")
    else
      IO.puts("creating instance profile #{@role}")

      trust =
        ~s({"Version":"2012-10-17","Statement":[{"Effect":"Allow",) <>
          ~s("Principal":{"Service":"ec2.amazonaws.com"},"Action":"sts:AssumeRole"}]})

      aws!(["iam", "create-role", "--role-name", @role, "--assume-role-policy-document", trust])

      aws!([
        "iam",
        "attach-role-policy",
        "--role-name",
        @role,
        "--policy-arn",
        "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
      ])

      aws!(["iam", "create-instance-profile", "--instance-profile-name", @role])

      aws!([
        "iam",
        "add-role-to-instance-profile",
        "--instance-profile-name",
        @role,
        "--role-name",
        @role
      ])

      IO.puts("waiting 10s for the instance profile to propagate")
      Process.sleep(10_000)
    end
  end

  # ── up ─────────────────────────────────────────────────────────────────────

  def up do
    case instance_id() do
      nil -> launch(@tag, instance_type(), [root_device(root_gib())])
      id -> IO.puts("#{@tag} already running: #{id}")
    end

    wait_for_ssm(instance_id!(), 60)
    bootstrap(instance_id!())
    status()
  end

  defp root_device(gib) do
    "DeviceName=/dev/xvda,Ebs={VolumeSize=#{gib},VolumeType=gp3," <>
      "Throughput=500,DeleteOnTermination=true}"
  end

  defp launch(tag, type, block_devices) do
    ensure_instance_profile()
    config = vpc_config()
    subnet = Bench.env("LOADGEN_SUBNET", hd(config["subnets"]))
    sg = Bench.env("LOADGEN_SG", node_security_group())

    ami =
      aws!([
        "ssm",
        "get-parameter",
        "--name",
        "/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64",
        "--query",
        "Parameter.Value",
        "--output",
        "text"
      ])

    IO.puts("launching #{tag} as #{type} in #{subnet} with sg #{sg}, ami #{ami}")

    id =
      aws!(
        [
          "ec2",
          "run-instances",
          "--image-id",
          ami,
          "--instance-type",
          type,
          "--subnet-id",
          subnet,
          "--security-group-ids",
          sg,
          "--iam-instance-profile",
          "Name=#{@role}",
          "--block-device-mappings"
        ] ++
          block_devices ++
          [
            "--metadata-options",
            "HttpTokens=required,HttpEndpoint=enabled",
            "--tag-specifications",
            "ResourceType=instance,Tags=[{Key=Name,Value=#{tag}}]",
            "--query",
            "Instances[0].InstanceId",
            "--output",
            "text"
          ]
      )

    IO.puts("launched #{id}, waiting for it to run")
    aws!(["ec2", "wait", "instance-running", "--instance-ids", id])
    id
  end

  defp wait_for_ssm(_id, 0), do: Bench.fatal!("timed out waiting for the SSM agent")

  defp wait_for_ssm(id, attempts) do
    online? =
      aws!([
        "ssm",
        "describe-instance-information",
        "--filters",
        "Key=InstanceIds,Values=#{id}",
        "--query",
        "InstanceInformationList[0].PingStatus",
        "--output",
        "text"
      ]) == "Online"

    if online? do
      IO.puts("SSM agent online")
    else
      Process.sleep(5000)
      wait_for_ssm(id, attempts - 1)
    end
  end

  defp bootstrap(id) do
    IO.puts("installing k6 and go")

    run!(id, """
    set -euo pipefail
    command -v tar >/dev/null || dnf install -y tar gzip >/dev/null
    if [ ! -x /usr/local/go/bin/go ]; then
      curl -fsSL -o /tmp/go.tgz https://go.dev/dl/#{go_version()}.linux-amd64.tar.gz
      rm -rf /usr/local/go
      tar -C /usr/local -xzf /tmp/go.tgz
      rm -f /tmp/go.tgz
    fi
    export PATH=/usr/local/go/bin:$PATH
    if ! command -v k6 >/dev/null; then
      cd /tmp
      curl -fsSL -o k6.tgz \
        https://github.com/grafana/k6/releases/download/#{k6_version()}/k6-#{k6_version()}-linux-amd64.tar.gz
      tar xzf k6.tgz
      install -m 0755 k6-#{k6_version()}-linux-amd64/k6 /usr/local/bin/k6
      rm -rf k6.tgz k6-#{k6_version()}-linux-amd64
    fi
    mkdir -p #{remote_dir()}/results #{remote_dir()}/bodies
    k6 version && go version
    """)

    IO.puts("pushing the harness and building the body")
    push_code(id)
    build_body(id)
  end

  defp days_flag do
    case Bench.env("DAYS", "0") do
      "0" -> ""
      days -> " -days #{days}"
    end
  end

  defp build_body(id) do
    base_date =
      case Bench.env("BASE_DATE", "") do
        "" -> ""
        date -> " -base-date #{date}"
      end

    run!(id, """
    set -euo pipefail
    cd #{remote_dir()}
    export PATH=/usr/local/go/bin:$PATH GOTOOLCHAIN=local GOPATH=/opt/go GOCACHE=/opt/go/cache
    go build -o genbody ./tools/genbody
    ./genbody -shape #{Bench.shape()} -rows #{rows()} -projects 1000 -seed 42#{base_date}#{days_flag()} -out #{body_file()}
    ls -l #{body_file()}
    """)
  end

  defp push_code(id) do
    tarball = Path.join(System.tmp_dir!(), "bench-code.tgz")

    Bench.sh!(
      "tar",
      ["czf", tarball, "k6", "tools", "go.mod", "go.sum", "schemas", "scripts/clickbench"],
      cd: Bench.root(),
      env: [{"COPYFILE_DISABLE", "1"}]
    )

    payload = tarball |> File.read!() |> Base.encode64()
    File.rm(tarball)

    run!(id, """
    set -euo pipefail
    mkdir -p #{remote_dir()}/bodies
    cd #{remote_dir()}
    echo '#{payload}' | base64 -d | tar xzf -
    """)
  end

  # ── ssm command execution ──────────────────────────────────────────────────

  defp run!(id, script), do: run(id, script, true)

  defp run(id, script, raise_on_error) do
    doc = JSON.encode!(%{"commands" => [script]})

    command_id =
      aws!([
        "ssm",
        "send-command",
        "--instance-ids",
        id,
        "--document-name",
        "AWS-RunShellScript",
        "--parameters",
        doc,
        "--timeout-seconds",
        "3600",
        "--query",
        "Command.CommandId",
        "--output",
        "text"
      ])

    await_command(id, command_id, raise_on_error)
  end

  defp await_command(id, command_id, raise_on_error) do
    Process.sleep(2000)

    invocation =
      aws_json!([
        "ssm",
        "get-command-invocation",
        "--instance-id",
        id,
        "--command-id",
        command_id
      ])

    case invocation["Status"] do
      status when status in ["Pending", "InProgress", "Delayed"] ->
        await_command(id, command_id, raise_on_error)

      "Success" ->
        invocation["StandardOutputContent"]

      status ->
        message =
          "remote command #{status}:\n#{invocation["StandardErrorContent"]}\n" <>
            invocation["StandardOutputContent"]

        if raise_on_error, do: Bench.fatal!(message), else: message
    end
  end

  # ── status ─────────────────────────────────────────────────────────────────

  def status do
    case instance_id() do
      nil ->
        IO.puts("no #{@tag} instance. Run: mise run bench-up")

      id ->
        info =
          aws_json!([
            "ec2",
            "describe-instances",
            "--instance-ids",
            id,
            "--query",
            "Reservations[0].Instances[0].{state:State.Name,ip:PrivateIpAddress," <>
              "type:InstanceType,az:Placement.AvailabilityZone}"
          ])

        ping =
          aws!([
            "ssm",
            "describe-instance-information",
            "--filters",
            "Key=InstanceIds,Values=#{id}",
            "--query",
            "InstanceInformationList[0].PingStatus",
            "--output",
            "text"
          ])

        ips = api_pod_ips()

        IO.puts("""
        instance   #{id}
        type       #{info["type"]} in #{info["az"]}
        state      #{info["state"]}
        private ip #{info["ip"]}
        ssm        #{ping}
        targets    #{length(ips)} api pod(s)
        #{Enum.map_join(ips, "\n", &"           http://#{&1}:4000")}
        """)
    end
  end

  def session do
    id = instance_id!()
    IO.puts("aws ssm start-session --target #{id} --region #{region()} --profile #{profile()}")
  end

  # ── sweep ──────────────────────────────────────────────────────────────────

  def sweep do
    benches = Bench.benches()
    ingest? = "ingest" in benches

    box? =
      ingest? or "onebrc" in benches or "tail" in benches or "tsbs" in benches or
        "clickbench" in benches or "vlogs" in benches

    pod_ips = api_pod_ips()
    dataset = Bench.Remote.dataset()
    table = Bench.Remote.table()
    key = Bench.Remote.api_key()

    urls =
      Enum.map_join(pod_ips, ",", fn ip ->
        "http://#{ip}:4000/v1/datasets/#{dataset}/tables/#{table}/insert"
      end)

    File.mkdir_p!(results_dir())

    # Sampling starts before anything touches the cluster, so every run opens
    # with an idle baseline and the setup work — instance lookup, table setup,
    # preflight insert — is on the record too.
    watcher = Bench.WatchMetrics.start(metrics_db())

    id = if box?, do: instance_id!(), else: nil

    if ingest?, do: ingest_preflight(key)

    IO.puts("== benches: #{Enum.join(benches, ", ")}")

    Enum.each(benches, fn bench ->
      Bench.WatchMetrics.set_phase(watcher, bench)

      case bench do
        "ingest" -> run_ingest(id, dataset, table, urls, key, watcher)
        "attrs" -> run_attrs(dataset, table, key, watcher)
        "tail" -> run_tail(id, dataset, table, key, watcher)
        "pruning" -> run_pruning(dataset, table, key)
        "compaction" -> run_compaction()
        "onebrc" -> run_onebrc(id, dataset, table, key, watcher)
        "tsbs" -> run_tsbs(id, key, watcher)
        "clickbench" -> run_clickbench(id, dataset, key, watcher)
        "vlogs" -> run_vlogs(id, dataset, table, key, watcher)
      end
    end)

    db = Bench.WatchMetrics.stop(watcher)

    Bench.ReportHtml.generate(db)

    IO.puts("\n== done → #{results_dir()}")
  end

  defp metrics_db do
    stamp = DateTime.utc_now() |> Calendar.strftime("%Y%m%dT%H%M%SZ")
    Bench.WatchMetrics.db_path(results_dir(), "loadgen-#{stamp}#{label_suffix()}")
  end

  defp ingest_preflight(key) do
    body_path = Path.join(Bench.root(), body_file())

    File.exists?(body_path) ||
      Bench.fatal!("body file missing: #{body_path} (run scripts/gen-bodies.exs)")

    Bench.Remote.setup()

    IO.puts("== preflight via #{Bench.Remote.insert_url()}")

    Bench.RunArm.preflight(
      Bench.Remote.insert_url(),
      "application/x-ndjson",
      "Bearer #{key}",
      body_path
    )
  end

  # ── bench: ingest ──────────────────────────────────────────────────────────

  defp run_ingest(id, dataset, table, urls, key, watcher) do
    IO.puts("\n== ingest: pushing the working tree, rebuilding the body")
    push_code(id)
    build_body(id)

    put_api_key(key)
    run!(id, "rm -f #{remote_dir()}/results/*.json")

    targets = urls |> String.split(",") |> length()

    IO.puts("\n== ingest: loadgen sweep across #{targets} api pod(s)")
    Enum.each(String.split(urls, ","), &IO.puts("     #{&1}"))
    IO.puts("== VUs: #{Enum.join(vus_list(), " ")}, #{duration_s()}s each\n")

    Enum.each(vus_list(), fn vus ->
      label = "loadgen-vus#{vus}#{label_suffix()}"

      Bench.WatchMetrics.set_phase(watcher, "drain-vus#{vus}")
      drain = await_hot_drain(dataset, table, key, drain_wait_s())
      IO.puts("== #{label}: hot tier #{drain_outcome(drain)}")

      Bench.WatchMetrics.set_phase(watcher, "ingest-vus#{vus}")

      IO.puts("== #{label}: warm-up #{warmup_s()}s")
      run!(id, warmup_script(urls, vus))

      IO.puts("== #{label}: pause #{pause_s()}s, then #{duration_s()}s measured")
      Process.sleep(pause_s() * 1000)

      pods_task =
        Task.async(fn -> Bench.WatchPods.sample(String.to_integer(duration_s())) end)

      out = run!(id, measure_script(urls, vus, label))
      IO.puts(String.trim(out))

      pods =
        pods_task
        |> Task.await(:infinity)
        |> Map.put("drain_wait_s", drain.waited_s)
        |> Map.put("drain_hot_files_left", drain.hot_files)

      File.write!(Path.join(results_dir(), "#{label}.pods.json"), JSON.encode!(pods) <> "\n")

      Process.sleep(pause_s() * 1000)
    end)

    delete_api_key()
    fetch()
  end

  defp drain_wait_s, do: Bench.env_int("DRAIN_WAIT_S", 300)

  defp drain_poll_s, do: Bench.env_int("DRAIN_POLL_S", 10)

  defp await_hot_drain(dataset, table, key, wait_s) do
    url = "#{Bench.Remote.base_url()}/v1/queries"
    sql = count_query("#{dataset}.#{table}", "1971-01-01")
    await_hot_drain_with(url, key, sql, wait_s)
  end

  defp await_hot_drain_with(url, key, sql, wait_s) do
    started = System.monotonic_time(:second)
    deadline = started + wait_s
    hot_files = poll_hot_drain(url, key, sql, deadline)
    %{waited_s: System.monotonic_time(:second) - started, hot_files: hot_files}
  end

  defp poll_hot_drain(url, key, sql, deadline) do
    files = hot_files(url, key, sql)

    cond do
      files == 0 ->
        0

      System.monotonic_time(:second) >= deadline ->
        files

      true ->
        Process.sleep(drain_poll_s() * 1000)
        poll_hot_drain(url, key, sql, deadline)
    end
  end

  defp hot_files(url, key, sql) do
    headers = [{"authorization", "Bearer #{key}"}]
    body = JSON.encode!(%{"query" => sql, "timeoutMs" => 60_000, "maxResults" => 1})

    case Bench.http(:post, url, headers, "application/json", body, 90_000) do
      {:ok, status, response} when status in 200..299 ->
        response |> JSON.decode!() |> get_in(["job", "statistics", "hot", "filesTotal"]) ||
          :unknown

      _failure ->
        :unknown
    end
  end

  defp drain_outcome(%{waited_s: waited_s, hot_files: 0}), do: "empty after #{waited_s}s"

  defp drain_outcome(%{waited_s: waited_s, hot_files: hot_files}),
    do: "NOT drained after #{waited_s}s (#{inspect(hot_files)} hot files) — continuing"

  # ── bench: tail ────────────────────────────────────────────────────────────

  defp tail_vus, do: Bench.env_int("TAIL_VUS", 4)

  defp tail_projects do
    "TAIL_PROJECTS"
    |> Bench.env("proj_0617,proj_0589,proj_0878,proj_0809")
    |> String.split(",", trim: true)
    |> Enum.map(&String.trim/1)
  end

  defp tail_duration_s, do: Bench.env_int("TAIL_DURATION_S", 60)

  defp tail_ingest_vus, do: "TAIL_INGEST_VUS" |> Bench.env("32") |> String.split()

  defp tail_limit, do: Bench.env_int("TAIL_LIMIT", 100)

  defp tail_order, do: Bench.env("TAIL_ORDER", "inserted_at")

  defp tail_sleep_s, do: Bench.env("TAIL_SLEEP_S", "0")

  defp tail_columns, do: Bench.env("TAIL_COLUMNS", "timestamp, trace_id, span_id, body")

  defp tail_window_s, do: Bench.env_int("TAIL_WINDOW_S", 300)

  defp tail_query_ips(pod_ips) do
    case Bench.env("TAIL_QUERY_SERVICE", "") do
      "" -> pod_ips
      service -> endpoint_ips(service)
    end
  end

  defp tail_drain_wait_s, do: Bench.env_int("TAIL_DRAIN_WAIT_S", 600)

  defp run_tail(id, dataset, table, key, watcher) do
    IO.puts("\n== tail: pushing the working tree, rebuilding the body")
    push_code(id)
    build_body(id)
    Bench.Remote.setup()
    put_api_key(key)
    run!(id, "rm -f #{remote_dir()}/results/*.json")

    ref = "#{dataset}.#{table}"
    pod_ips = api_pod_ips()
    query_ips = tail_query_ips(pod_ips)
    query_urls = Enum.map_join(query_ips, ",", &"http://#{&1}:4000/v1/queries")

    insert_urls =
      Enum.map_join(pod_ips, ",", fn ip ->
        "http://#{ip}:4000/v1/datasets/#{dataset}/tables/#{table}/insert"
      end)

    IO.puts(
      "== tail: #{ref}, #{tail_vus()} tail VU(s) over #{Enum.join(tail_projects(), ", ")}, " <>
        "queries to #{length(query_ips)} pod(s) of #{Bench.env("TAIL_QUERY_SERVICE", "smolquery-api")}, " <>
        "last #{tail_limit()} by #{tail_order()} within #{tail_window_s()}s, " <>
        "columns #{tail_columns()}, #{tail_duration_s()}s per phase, " <>
        "ingest at #{Enum.join(tail_ingest_vus(), " ")} VU(s)"
    )

    idle = tail_phase(id, watcher, "tail-idle", query_urls, ref, nil)

    ingest_phases =
      Enum.map(tail_ingest_vus(), fn vus ->
        Bench.WatchMetrics.set_phase(watcher, "tail-drain-vus#{vus}")
        drain = await_hot_drain(dataset, table, key, tail_drain_wait_s())
        IO.puts("== tail: hot tier #{drain_outcome(drain)}")

        tail_phase(
          id,
          watcher,
          "tail-ingest-vus#{vus}",
          query_urls,
          ref,
          {insert_urls, vus, drain}
        )
      end)

    Bench.WatchMetrics.set_phase(watcher, "tail-drain")
    drain = await_hot_drain(dataset, table, key, tail_drain_wait_s())
    IO.puts("== tail: hot tier #{drain_outcome(drain)}")
    sealed = tail_phase(id, watcher, "tail-sealed", query_urls, ref, nil)

    delete_api_key()
    fetch()

    label = "loadgen-tail#{label_suffix()}"

    payload = %{
      "inserted_at" => now_iso(),
      "table" => ref,
      "tail_vus" => tail_vus(),
      "projects" => tail_projects(),
      "limit" => tail_limit(),
      "order_column" => tail_order(),
      "columns" => tail_columns(),
      "window_s" => tail_window_s(),
      "phases" => [idle] ++ ingest_phases ++ [sealed]
    }

    File.write!(Path.join(results_dir(), "#{label}.tail.json"), JSON.encode!(payload) <> "\n")
    IO.puts("== tail → #{label}.tail.json")
  end

  defp tail_phase(id, watcher, phase, query_urls, ref, ingest) do
    Bench.WatchMetrics.set_phase(watcher, phase)
    tail_label = "loadgen-#{phase}#{label_suffix()}"
    tail_out = "results/#{tail_label}.tail.json"

    case ingest do
      nil ->
        IO.puts("== #{phase}: #{tail_duration_s()}s of tail queries, no ingest")
        out = run!(id, tail_script(query_urls, ref, tail_duration_s(), tail_out, false))
        IO.puts(String.trim(out))
        %{"phase" => phase, "tail_file" => "#{tail_label}.tail.json", "insert_file" => nil}

      {insert_urls, vus, drain} ->
        insert_label = "loadgen-tail-vus#{vus}#{label_suffix()}"
        IO.puts("== #{phase}: warm-up #{warmup_s()}s at #{vus} VUs")
        run!(id, warmup_script(insert_urls, vus))
        Process.sleep(pause_s() * 1000)

        IO.puts(
          "== #{phase}: tail queries detached, then #{tail_duration_s()}s measured ingest at #{vus} VUs"
        )

        pid =
          run!(id, tail_script(query_urls, ref, tail_duration_s() + pause_s(), tail_out, true))
          |> String.trim()

        pods_task = Task.async(fn -> Bench.WatchPods.sample(tail_duration_s()) end)
        out = run!(id, tail_measure_script(insert_urls, vus, insert_label))
        IO.puts(String.trim(out))
        pods = pods_task |> Task.await(:infinity) |> Map.put("drain_wait_s", drain.waited_s)

        File.write!(
          Path.join(results_dir(), "#{insert_label}.pods.json"),
          JSON.encode!(pods) <> "\n"
        )

        tail_out_text = tail_wait(id, pid, "logs/#{tail_label}.tail.log")
        IO.puts(String.trim(tail_out_text))

        %{
          "phase" => phase,
          "ingest_vus" => vus,
          "tail_file" => "#{tail_label}.tail.json",
          "insert_file" => "#{insert_label}.k6.json"
        }
    end
  end

  defp tail_wait(id, pid, log) do
    out =
      run!(id, """
      cd #{remote_dir()}
      for i in $(seq 1 60); do kill -0 #{pid} 2>/dev/null || break; sleep 2; done
      cat #{log} 2>/dev/null || true
      """)

    out
  end

  defp tail_script(query_urls, ref, duration_s, out_file, detached?) do
    command =
      "k6 run --quiet -e URLS=\"#{query_urls}\" -e AUTH=\"$AUTH\" -e TABLE=#{ref} " <>
        "-e PROJECTS=\"#{Enum.join(tail_projects(), ",")}\" -e VUS=#{tail_vus()} " <>
        "-e DURATION=#{duration_s}s -e LIMIT=#{tail_limit()} -e ORDER_COLUMN=#{tail_order()} " <>
        "-e SLEEP_S=#{tail_sleep_s()} -e COLUMNS=\"#{tail_columns()}\" -e WINDOW_S=#{tail_window_s()} " <>
        "-e JSON_OUT=#{out_file} k6/tail.js"

    if detached? do
      log = String.replace(out_file, "results/", "logs/") |> String.replace(".json", ".log")

      """
      set -euo pipefail
      cd #{remote_dir()}
      mkdir -p logs
      #{fetch_auth()}
      export AUTH
      setsid nohup sh -c '#{command}' > #{log} 2>&1 < /dev/null &
      echo $!
      """
    else
      """
      set -euo pipefail
      cd #{remote_dir()}
      #{fetch_auth()}
      #{command}
      """
    end
  end

  defp tail_measure_script(urls, vus, label) do
    """
    set -euo pipefail
    cd #{remote_dir()}
    #{fetch_auth()}
    k6 run --quiet -e URLS='#{urls}' -e AUTH="$AUTH" -e ROWS=#{rows()} \
      -e BODY=#{remote_dir()}/#{body_file()} \
      -e VUS=#{vus} -e DURATION=#{tail_duration_s()}s \
      -e JSON_OUT=results/#{label}.k6.json k6/insert.js
    """
  end

  # ── bench: attrs ───────────────────────────────────────────────────────────

  defp attrs_repeats, do: Bench.env_int("ATTRS_REPEATS", 3)

  defp attrs_project, do: Bench.env("ATTRS_PROJECT", "proj_0617")

  defp attrs_tiers do
    "ATTRS_TIERS" |> Bench.env("union,sealed") |> String.split(",", trim: true)
  end

  defp attrs_drain_wait_s, do: Bench.env_int("ATTRS_DRAIN_WAIT_S", 600)

  defp attr_type(table) do
    case Bench.env("ATTR_TYPE", "") do
      "" ->
        cond do
          String.contains?(table, "variant") -> "variant"
          String.contains?(table, "map") -> "map"
          true -> "flat"
        end

      type when type in ~w(map variant flat) ->
        type

      other ->
        Bench.fatal!("ATTR_TYPE must be map, variant or flat, got #{inspect(other)}")
    end
  end

  defp attr_string("map", key), do: "log_attributes['#{key}']"
  defp attr_string("variant", key), do: "log_attributes['#{key}']::VARCHAR"
  defp attr_string("flat", key), do: flat_column(key)

  defp attr_int("flat", key), do: flat_column(key)
  defp attr_int(_type, key), do: "TRY_CAST(log_attributes['#{key}'] AS BIGINT)"

  defp attr_present("map", key), do: "map_contains(log_attributes, '#{key}')"
  defp attr_present("variant", key), do: "log_attributes['#{key}'] IS NOT NULL"
  defp attr_present("flat", key), do: "#{flat_column(key)} IS NOT NULL"

  defp flat_column(key), do: String.replace(key, ".", "_")

  defp project_column("flat"), do: "project_id"
  defp project_column(_type), do: "project"

  defp attrs_cases(ref, type) do
    project = "#{project_column(type)} = '#{attrs_project()}'"
    method = attr_string(type, "http.request.method")
    status = attr_int(type, "http.response.status_code")
    route = attr_string(type, "http.route")
    errors = attr_present(type, "exception.type")

    scoped = [
      {"count", "SELECT count(*) AS n FROM #{ref} WHERE %{where}"},
      {"method", "SELECT count(*) AS n FROM #{ref} WHERE %{where} AND #{method} = 'POST'"},
      {"status", "SELECT count(*) AS n FROM #{ref} WHERE %{where} AND #{status} >= 500"},
      {"errors", "SELECT count(*) AS n FROM #{ref} WHERE %{where} AND #{errors}"},
      {"route-group",
       "SELECT #{route} AS route, count(*) AS n FROM #{ref} WHERE %{where} " <>
         "GROUP BY 1 ORDER BY 2 DESC LIMIT 10"},
      {"body-like",
       "SELECT count(*) AS n FROM #{ref} WHERE %{where} AND body LIKE '%slow query%'"}
    ]

    Enum.flat_map(scoped, fn {name, template} ->
      [
        {"#{name}-project", String.replace(template, "%{where}", project)},
        {"#{name}-all", String.replace(template, "%{where}", "1 = 1")}
      ]
    end)
  end

  defp run_attrs(dataset, table, key, watcher) do
    url = "#{Bench.Remote.base_url()}/v1/queries"
    ref = "#{dataset}.#{table}"
    type = attr_type(table)
    cases = attrs_cases(ref, type)

    IO.puts("
== attrs: #{ref} as #{type}, project #{attrs_project()}, tiers #{Enum.join(attrs_tiers(), ", ")}")

    tiers =
      Enum.map(attrs_tiers(), fn tier ->
        if tier == "sealed" do
          Bench.WatchMetrics.set_phase(watcher, "attrs-drain")
          drain = await_hot_drain(dataset, table, key, attrs_drain_wait_s())
          IO.puts("== attrs: hot tier #{drain_outcome(drain)}")
        end

        Bench.WatchMetrics.set_phase(watcher, "attrs-#{tier}")
        hot_files = hot_files(url, key, count_query(ref, "1971-01-01"))
        IO.puts("== attrs: tier #{tier}, #{inspect(hot_files)} hot file(s) at start")

        results = Enum.map(cases, fn {name, sql} -> attrs_case(url, key, name, sql) end)
        %{"tier" => tier, "hot_files_at_start" => hot_files, "cases" => results}
      end)

    label = "loadgen-attrs#{label_suffix()}"

    payload = %{
      "inserted_at" => now_iso(),
      "table" => ref,
      "attr_type" => type,
      "project" => attrs_project(),
      "repeats" => attrs_repeats(),
      "tiers" => tiers
    }

    File.write!(Path.join(results_dir(), "#{label}.attrs.json"), JSON.encode!(payload) <> "
")
    IO.puts("== attrs → #{label}.attrs.json")
  end

  defp attrs_case(url, key, name, sql) do
    measured = Enum.map(1..attrs_repeats(), fn _ -> time_query(url, key, sql) end)
    ok = Enum.filter(measured, &(&1.error == nil))
    explained = explain_query(url, key, sql)

    summary = %{
      "case" => name,
      "sql" => sql,
      "wall_ms_min" => ok |> Enum.map(& &1.wall_ms) |> min_or_nil(),
      "wall_ms_med" => ok |> Enum.map(& &1.wall_ms) |> median_or_nil(),
      "duration_ms_med" => ok |> Enum.map(& &1.duration_ms) |> median_or_nil(),
      "rows" => ok |> Enum.map(& &1.rows) |> List.first(),
      "errors" => Enum.count(measured, &(&1.error != nil)),
      "first_error" =>
        case Enum.find(measured, &(&1.error != nil)) do
          nil -> nil
          failed -> failed.error
        end,
      "engine_total_s" => explained.engine_total_s,
      "explain_analyze" => explained.plan,
      "explain_error" => explained.error
    }

    IO.puts(
      "== #{name}: wall med #{summary["wall_ms_med"]}ms, " <>
        "durationMs med #{summary["duration_ms_med"]}, rows #{summary["rows"]}, " <>
        "errors #{summary["errors"]}, engine #{summary["engine_total_s"] || "?"}s"
    )

    summary
  end

  # ── bench: pruning ─────────────────────────────────────────────────────────

  defp prune_repeats, do: Bench.env_int("PRUNE_REPEATS", 3)

  defp prune_column, do: Bench.env("PRUNE_COLUMN", "duration_ms")

  defp prune_settle_s, do: Bench.env_int("PRUNE_SETTLE_S", 30)

  defp prune_dates do
    case Bench.env("PRUNE_DATES", "") do
      "" -> [Date.utc_today() |> Date.to_iso8601()]
      dates -> dates |> String.split(",", trim: true) |> Enum.map(&String.trim/1)
    end
  end

  defp run_pruning(dataset, table, key) do
    IO.puts("\n== pruning: settling #{prune_settle_s()}s so writes seal")
    Process.sleep(prune_settle_s() * 1000)

    url = "#{Bench.Remote.base_url()}/v1/queries"
    IO.puts("== pruning: querying #{url}")
    ref = "#{dataset}.#{table}"
    empty_date = "1971-01-01"

    dated =
      Enum.flat_map(prune_dates(), fn date ->
        [
          {"count-date-#{date}", count_query(ref, date)},
          {"scan-date-#{date}", scan_query(ref, date)}
        ]
      end)

    cases =
      dated ++
        [
          {"count-date-empty-#{empty_date}", count_query(ref, empty_date)},
          {"scan-date-empty-#{empty_date}", scan_query(ref, empty_date)},
          {"count-no-filter", "SELECT count(*) AS n FROM #{ref}"},
          {"scan-no-filter", "SELECT sum(#{prune_column()}) AS s FROM #{ref}"}
        ]

    results =
      Enum.map(cases, fn {name, sql} ->
        measured = Enum.map(1..prune_repeats(), fn _ -> time_query(url, key, sql) end)
        ok = Enum.filter(measured, &(&1.error == nil))
        explained = explain_query(url, key, sql)

        summary = %{
          "case" => name,
          "sql" => sql,
          "repeats" => prune_repeats(),
          "wall_ms_min" => ok |> Enum.map(& &1.wall_ms) |> min_or_nil(),
          "wall_ms_med" => ok |> Enum.map(& &1.wall_ms) |> median_or_nil(),
          "duration_ms_med" => ok |> Enum.map(& &1.duration_ms) |> median_or_nil(),
          "rows" => ok |> Enum.map(& &1.rows) |> List.first(),
          "errors" => Enum.count(measured, &(&1.error != nil)),
          "first_error" =>
            case Enum.find(measured, &(&1.error != nil)) do
              nil -> nil
              failed -> failed.error
            end,
          "engine_total_s" => explained.engine_total_s,
          "explain_analyze" => explained.plan,
          "explain_error" => explained.error
        }

        IO.puts(
          "== #{name}: wall med #{summary["wall_ms_med"]}ms, " <>
            "durationMs med #{summary["duration_ms_med"]}, rows #{summary["rows"]}, " <>
            "errors #{summary["errors"]}, engine #{summary["engine_total_s"] || "?"}s"
        )

        summary
      end)

    label = "loadgen-prune#{label_suffix()}"
    payload = %{"inserted_at" => now_iso(), "table" => ref, "cases" => results}
    File.write!(Path.join(results_dir(), "#{label}.prune.json"), JSON.encode!(payload) <> "\n")
    IO.puts("== pruning → #{label}.prune.json")
  end

  defp count_query(ref, date), do: "SELECT count(*) AS n FROM #{ref} #{date_where(date)}"

  defp scan_query(ref, date) do
    "SELECT sum(#{prune_column()}) AS s FROM #{ref} #{date_where(date)}"
  end

  defp date_where(date) do
    "WHERE inserted_at >= TIMESTAMP '#{date} 00:00:00' " <>
      "AND inserted_at < TIMESTAMP '#{date} 00:00:00' + INTERVAL 1 DAY"
  end

  defp time_query(url, key, sql, options \\ %{}) do
    headers = [{"authorization", "Bearer #{key}"}]
    timeout_ms = Map.get(options, "timeoutMs", Bench.env_int("PRUNE_TIMEOUT_MS", 180_000))

    body =
      %{"query" => sql, "timeoutMs" => timeout_ms, "maxResults" => 1}
      |> Map.merge(options)
      |> JSON.encode!()

    started = System.monotonic_time(:microsecond)

    case Bench.http(:post, url, headers, "application/json", body, timeout_ms + 30_000) do
      {:ok, status, response} when status in 200..299 ->
        wall_ms = (System.monotonic_time(:microsecond) - started) / 1000
        decoded = JSON.decode!(response)

        %{
          wall_ms: Float.round(wall_ms, 1),
          duration_ms: get_in(decoded, ["job", "durationMs"]),
          rows: first_count(decoded),
          error: nil
        }

      {:ok, status, response} ->
        %{
          wall_ms: nil,
          duration_ms: nil,
          rows: nil,
          error: "HTTP #{status}: #{trunc_text(response)}"
        }

      {:error, reason} ->
        %{wall_ms: nil, duration_ms: nil, rows: nil, error: inspect(reason)}
    end
  end

  defp explain_query(url, key, sql, options \\ %{}) do
    headers = [{"authorization", "Bearer #{key}"}]
    timeout_ms = Map.get(options, "timeoutMs", Bench.env_int("EXPLAIN_TIMEOUT_MS", 120_000))

    body =
      %{"query" => sql, "explain" => "analyze", "timeoutMs" => timeout_ms}
      |> Map.merge(options)
      |> JSON.encode!()

    case Bench.http(:post, url, headers, "application/json", body, timeout_ms + 30_000) do
      {:ok, status, response} when status in 200..299 ->
        plan = response |> JSON.decode!() |> get_in(["job", "explain"])
        %{plan: plan, engine_total_s: engine_total_s(plan), error: nil}

      {:ok, status, response} ->
        %{plan: nil, engine_total_s: nil, error: "HTTP #{status}: #{trunc_text(response)}"}

      {:error, reason} ->
        %{plan: nil, engine_total_s: nil, error: inspect(reason)}
    end
  end

  defp engine_total_s(nil), do: nil

  defp engine_total_s(plan) do
    with [_, seconds] <- Regex.run(~r/Total Time: ([0-9.]+)s/, plan),
         {value, _rest} <- Float.parse(seconds) do
      value
    else
      _no_match -> nil
    end
  end

  defp first_count(%{"rows" => [row | _]}) when is_map(row),
    do: row |> Map.values() |> List.first()

  defp first_count(%{"totalRows" => n}), do: n
  defp first_count(_body), do: nil

  defp trunc_text(text), do: text |> String.trim() |> String.slice(0, 200)

  defp min_or_nil([]), do: nil
  defp min_or_nil(values), do: Enum.min(values)

  defp median_or_nil([]), do: nil

  defp median_or_nil(values) do
    sorted = Enum.sort(values)
    middle = div(length(sorted), 2)

    case rem(length(sorted), 2) do
      1 -> Enum.at(sorted, middle)
      0 -> Float.round((Enum.at(sorted, middle - 1) + Enum.at(sorted, middle)) / 2, 1)
    end
  end

  # ── bench: onebrc ──────────────────────────────────────────────────────────

  @onebrc_query """
  SELECT station, min(temperature) AS min, avg(temperature) AS mean, \
  max(temperature) AS max FROM %{ref} GROUP BY station ORDER BY station\
  """

  defp onebrc_rows, do: Bench.env_int("ONEBRC_ROWS", 1_000_000_000)
  defp onebrc_upload?, do: Bench.env("ONEBRC_UPLOAD", "true") == "true"
  defp onebrc_max_rows, do: Bench.env_int("ONEBRC_MAX_ROWS", 0)
  defp onebrc_queries?, do: Bench.env("ONEBRC_QUERIES", "true") == "true"
  defp onebrc_upload_deadline_s, do: Bench.env_int("ONEBRC_UPLOAD_DEADLINE_S", 0)

  defp onebrc_workers_list do
    "ONEBRC_WORKERS"
    |> Bench.env("8")
    |> String.split([" ", ","], trim: true)
    |> Enum.map(&String.to_integer/1)
  end

  defp onebrc_rows_per_request, do: Bench.env_int("ONEBRC_ROWS_PER_REQUEST", 200_000)
  defp onebrc_poll_s, do: Bench.env_int("ONEBRC_POLL_S", 30)
  defp onebrc_query_repeats, do: Bench.env_int("ONEBRC_QUERY_REPEATS", 10)
  defp onebrc_query_timeout_ms, do: Bench.env_int("ONEBRC_QUERY_TIMEOUT_MS", 600_000)
  defp onebrc_drain_wait_s, do: Bench.env_int("ONEBRC_DRAIN_WAIT_S", 1800)
  defp onebrc_csv, do: "#{remote_dir()}/data/measurements.#{onebrc_rows()}.txt"

  defp run_onebrc(id, dataset, table, key, watcher) do
    IO.puts("\n== onebrc: pushing the working tree, building gen1brc and upload1brc")
    push_code(id)

    run!(id, """
    set -euo pipefail
    cd #{remote_dir()}
    export PATH=/usr/local/go/bin:$PATH GOTOOLCHAIN=local GOPATH=/opt/go GOCACHE=/opt/go/cache
    go build -o gen1brc ./tools/gen1brc
    go build -o upload1brc ./tools/upload1brc
    mkdir -p data logs results
    """)

    if onebrc_upload?() do
      Bench.WatchMetrics.set_phase(watcher, "onebrc-generate")
      IO.puts("== onebrc: #{onebrc_ensure_csv(id)}")
    end

    points = onebrc_points(table)

    Enum.reduce_while(points, :ok, fn {workers, point_table, tag}, :ok ->
      upload = run_onebrc_point(id, dataset, point_table, key, watcher, workers, tag)

      if onebrc_point_failed?(upload) and length(points) > 1 do
        IO.puts(
          "== onebrc: stopping the sweep after #{workers} workers: " <>
            "#{upload["rows_failed"]} rows failed, stopped early #{upload["stopped_early"]}"
        )

        {:halt, :stopped}
      else
        {:cont, :ok}
      end
    end)

    if onebrc_upload?() do
      delete_api_key()
      fetch()
    end
  end

  defp onebrc_points(table) do
    case onebrc_workers_list() do
      [workers] -> [{workers, table, ""}]
      list -> Enum.map(list, &{&1, "#{table}_w#{&1}", "-w#{&1}"})
    end
  end

  defp onebrc_point_failed?(nil), do: false

  defp onebrc_point_failed?(upload) do
    upload["rows_failed"] > 0 or upload["stopped_early"] == true
  end

  defp run_onebrc_point(id, dataset, table, key, watcher, workers, tag) do
    label = "loadgen-onebrc#{label_suffix()}#{tag}"
    ref = "#{dataset}.#{table}"
    url = "#{Bench.Remote.base_url()}/v1/queries"

    IO.puts("\n== onebrc: table #{ref}, #{workers} workers")
    Bench.Remote.setup(table)

    upload =
      if onebrc_upload?() do
        Bench.WatchMetrics.set_phase(watcher, "onebrc-upload#{tag}")
        upload = onebrc_upload(id, dataset, table, key, label, workers)

        IO.puts(
          "== onebrc: #{upload["rows_accepted"]} rows in " <>
            "#{Float.round(upload["duration_s"] / 1, 1)}s = #{round(upload["rows_per_s"])} rows/s, " <>
            "#{Float.round(upload["mib_per_s"] / 1, 1)} MiB/s, #{upload["requests"]} requests, " <>
            "#{upload["retries_429"]} x 429, #{upload["retries_other"]} other retries, " <>
            "#{upload["rows_rejected"]} rejected, #{upload["rows_failed"]} failed, " <>
            "client #{Float.round((upload["client_cores"] || 0) / 1, 2)} cores" <>
            if(upload["stopped_early"], do: ", STOPPED EARLY at the deadline", else: "")
        )

        upload
      else
        IO.puts("== onebrc: ONEBRC_UPLOAD=false, timing queries against the rows already there")
        nil
      end

    Bench.WatchMetrics.set_phase(watcher, "onebrc-drain#{tag}")
    drain_sql = "SELECT count(*) AS n FROM #{ref} WHERE station = '~'"
    drain = await_hot_drain_with(url, key, drain_sql, onebrc_drain_wait_s())
    IO.puts("== onebrc: hot tier #{drain_outcome(drain)}")

    sql = String.replace(@onebrc_query, "%{ref}", ref)
    options = %{"timeoutMs" => onebrc_query_timeout_ms()}

    {queries, sample_rows} =
      if onebrc_queries?() do
        Bench.WatchMetrics.set_phase(watcher, "onebrc-query#{tag}")

        cases = [
          {"aggregate", sql, options},
          {"aggregate-single-engine", sql, Map.put(options, "distributed", false)},
          {"count", "SELECT count(*) AS n FROM #{ref}", options}
        ]

        queries =
          Enum.map(cases, fn {name, case_sql, case_options} ->
            onebrc_query_case(url, key, name, case_sql, case_options)
          end)

        {queries, onebrc_sample_rows(url, key, sql, options)}
      else
        IO.puts("== onebrc: ONEBRC_QUERIES=false, skipping the query cases")
        {[], nil}
      end

    count = onebrc_count(url, key, ref)
    IO.puts("== onebrc: count(*) #{count}#{onebrc_count_verdict(count, upload)}")

    payload = %{
      "inserted_at" => now_iso(),
      "table" => ref,
      "workers" => workers,
      "rows_target" => onebrc_rows(),
      "csv" => if(onebrc_upload?(), do: onebrc_csv(), else: nil),
      "upload" => upload,
      "drain_wait_s" => drain.waited_s,
      "drain_hot_files_left" => drain.hot_files,
      "count" => count,
      "sample_rows" => sample_rows,
      "queries" => queries
    }

    File.write!(Path.join(results_dir(), "#{label}.onebrc.json"), JSON.encode!(payload) <> "\n")
    IO.puts("== onebrc → #{label}.onebrc.json")
    upload
  end

  defp onebrc_count_verdict(_count, nil), do: ""

  defp onebrc_count_verdict(count, upload) do
    if count == upload["rows_accepted"],
      do: " = rows_accepted",
      else: " ≠ rows_accepted #{upload["rows_accepted"]}"
  end

  defp onebrc_ensure_csv(id) do
    csv = onebrc_csv()

    run!(id, """
    set -euo pipefail
    cd #{remote_dir()}
    if [ -f #{csv}.done ] && [ "$(cat #{csv}.done)" = "#{onebrc_rows()}" ]; then
      echo "#{csv}: $(stat -c %s #{csv}) bytes, already generated"
    else
      rm -f #{csv} #{csv}.done
      ./gen1brc -rows #{onebrc_rows()} -seed 42 -out #{csv} 2>/dev/null
      echo #{onebrc_rows()} > #{csv}.done
    fi
    df -h #{remote_dir()} | tail -1
    """)
    |> String.trim()
  end

  defp onebrc_upload(id, dataset, table, key, label, workers) do
    urls =
      Enum.map_join(api_pod_ips(), ",", fn ip ->
        "http://#{ip}:4000/v1/datasets/#{dataset}/tables/#{table}/insert"
      end)

    targets = urls |> String.split(",") |> length()
    stamp = DateTime.utc_now() |> Calendar.strftime("%Y%m%dT%H%M%SZ")
    progress = "logs/#{label}.progress.json"
    summary = "results/#{label}.upload.json"
    log = "logs/#{label}.upload.log"
    max_rows = if onebrc_max_rows() > 0, do: " -max-rows #{onebrc_max_rows()}", else: ""

    deadline =
      if onebrc_upload_deadline_s() > 0,
        do: " -deadline #{onebrc_upload_deadline_s()}s",
        else: ""

    IO.puts(
      "== onebrc: uploading across #{targets} api pod(s), #{workers} workers, " <>
        "~#{onebrc_rows_per_request()} rows/request#{max_rows}#{deadline}"
    )

    put_api_key(key)

    pid =
      run!(id, """
      set -euo pipefail
      cd #{remote_dir()}
      #{fetch_auth()}
      export AUTH
      rm -f #{progress} #{summary}
      setsid nohup ./upload1brc -file #{onebrc_csv()} -urls '#{urls}' \\
        -rows #{onebrc_rows_per_request()} -workers #{workers}#{max_rows}#{deadline} \\
        -progress #{progress} -out #{summary} -insert-prefix #{label}-#{stamp} \\
        > #{log} 2>&1 < /dev/null &
      echo $!
      """)
      |> String.trim()

    IO.puts("== onebrc: upload1brc pid #{pid}, polling every #{onebrc_poll_s()}s")
    upload_poll(id, pid, progress, summary, log)
  end

  defp upload_poll(id, pid, progress, summary, log) do
    Process.sleep(onebrc_poll_s() * 1000)

    out =
      run!(id, """
      cd #{remote_dir()}
      if kill -0 #{pid} 2>/dev/null; then echo running; else echo done; fi
      cat #{progress} 2>/dev/null || echo '{}'
      """)

    [state | rest] = out |> String.trim() |> String.split("\n", parts: 2)
    snapshot = rest |> List.first("{}") |> JSON.decode!()

    if map_size(snapshot) > 0 do
      IO.puts(
        "   #{snapshot["rows_accepted"]} rows, #{round(snapshot["rows_per_s"] || 0)} rows/s overall, " <>
          "#{round(snapshot["rows_per_s_recent"] || 0)} recent, " <>
          "#{snapshot["requests"]} reqs, #{snapshot["retries_429"]} x 429, " <>
          "#{snapshot["retries_other"]} other retries, p50 " <>
          "#{Float.round((snapshot["latency_ms"] || %{})["med"] || 0.0, 1)}ms"
      )
    end

    case state do
      "running" ->
        upload_poll(id, pid, progress, summary, log)

      _done ->
        result = run!(id, "cat #{remote_dir()}/#{summary} 2>/dev/null || true")

        case String.trim(result) do
          "" ->
            tail = run!(id, "tail -20 #{remote_dir()}/#{log} 2>/dev/null || true")
            Bench.fatal!("upload1brc exited without a summary:\n#{tail}")

          json ->
            JSON.decode!(json)
        end
    end
  end

  defp onebrc_query_case(url, key, name, sql, options) do
    measured = Enum.map(1..onebrc_query_repeats(), fn _ -> time_query(url, key, sql, options) end)
    ok = Enum.filter(measured, &(&1.error == nil))
    explained = explain_query(url, key, sql, options)
    walls = Enum.map(ok, & &1.wall_ms)

    summary = %{
      "case" => name,
      "sql" => sql,
      "options" => Map.delete(options, "timeoutMs"),
      "repeats" => onebrc_query_repeats(),
      "wall_ms" => walls,
      "duration_ms" => Enum.map(ok, & &1.duration_ms),
      "wall_ms_min" => min_or_nil(walls),
      "wall_ms_med" => median_or_nil(walls),
      "wall_ms_max" => max_or_nil(walls),
      "duration_ms_med" => ok |> Enum.map(& &1.duration_ms) |> median_or_nil(),
      "errors" => Enum.count(measured, &(&1.error != nil)),
      "first_error" =>
        case Enum.find(measured, &(&1.error != nil)) do
          nil -> nil
          failed -> failed.error
        end,
      "engine_total_s" => explained.engine_total_s,
      "explain_analyze" => explained.plan,
      "explain_error" => explained.error
    }

    IO.puts(
      "== #{name}: wall min #{summary["wall_ms_min"]} med #{summary["wall_ms_med"]} " <>
        "max #{summary["wall_ms_max"]} ms over #{length(walls)} ok, " <>
        "durationMs med #{summary["duration_ms_med"]}, errors #{summary["errors"]}, " <>
        "engine #{summary["engine_total_s"] || "?"}s"
    )

    summary
  end

  defp onebrc_count(url, key, ref) do
    case time_query(url, key, "SELECT count(*) AS n FROM #{ref}", %{
           "timeoutMs" => onebrc_query_timeout_ms()
         }) do
      %{error: nil, rows: n} -> n
      %{error: error} -> error
    end
  end

  defp onebrc_sample_rows(url, key, sql, options) do
    headers = [{"authorization", "Bearer #{key}"}]
    timeout_ms = options["timeoutMs"]
    body = JSON.encode!(Map.merge(%{"query" => sql, "maxResults" => 1000}, options))

    case Bench.http(:post, url, headers, "application/json", body, timeout_ms + 30_000) do
      {:ok, status, response} when status in 200..299 ->
        decoded = JSON.decode!(response)
        rows = decoded["rows"] || []
        %{"total" => decoded["totalRows"] || length(rows), "first" => Enum.take(rows, 5)}

      {:ok, status, response} ->
        %{"error" => "HTTP #{status}: #{trunc_text(response)}"}

      {:error, reason} ->
        %{"error" => inspect(reason)}
    end
  end

  defp max_or_nil([]), do: nil
  defp max_or_nil(values), do: Enum.max(values)

  # ── bench: clickbench ──────────────────────────────────────────────────────

  @clickbench_parquet_url "https://datasets.clickhouse.com/hits_compatible/athena_partitioned"

  defp clickbench_table, do: Bench.env("CLICKBENCH_TABLE", "hits_v2")
  defp clickbench_files, do: Bench.env_int("CLICKBENCH_FILES", 100)
  defp clickbench_upload?, do: Bench.env("CLICKBENCH_UPLOAD", "true") == "true"
  defp clickbench_queries?, do: Bench.env("CLICKBENCH_QUERIES", "true") == "true"
  defp clickbench_only, do: Bench.env("CLICKBENCH_ONLY", "")
  defp clickbench_pipelines, do: Bench.env_int("CLICKBENCH_PIPELINES", 8)
  defp clickbench_workers, do: Bench.env_int("CLICKBENCH_WORKERS", 6)
  defp clickbench_rows_per_request, do: Bench.env_int("CLICKBENCH_ROWS_PER_REQUEST", 4_000)
  defp clickbench_duckdb_threads, do: Bench.env_int("CLICKBENCH_DUCKDB_THREADS", 3)
  defp clickbench_duckdb_memory, do: Bench.env("CLICKBENCH_DUCKDB_MEMORY", "3GB")
  defp clickbench_tries, do: Bench.env_int("CLICKBENCH_TRIES", 3)
  defp clickbench_cold?, do: Bench.env("CLICKBENCH_COLD", "false") == "true"
  defp clickbench_query_pod, do: Bench.env("CLICKBENCH_QUERY_POD", "smolquery-query-0")
  defp clickbench_query_options, do: Bench.env("CLICKBENCH_QUERY_OPTIONS", ~s({"fileCache":true}))
  defp clickbench_probe_tries, do: Bench.env_int("CLICKBENCH_PROBE_TRIES", 10)

  defp clickbench_modes do
    modes = Bench.env("CLICKBENCH_MODES", "single,scatter") |> String.split(",", trim: true)
    modes = Enum.map(modes, &String.trim/1)
    unknown = modes -- ~w(single scatter)

    (modes != [] and unknown == []) ||
      Bench.fatal!("CLICKBENCH_MODES takes single and/or scatter, got #{inspect(modes)}")

    Enum.uniq(modes)
  end

  defp clickbench_mode_options(mode) do
    clickbench_query_options()
    |> JSON.decode!()
    |> Map.put("distributed", mode == "scatter")
    |> JSON.encode!()
  end

  defp clickbench_query_timeout_ms, do: Bench.env_int("CLICKBENCH_QUERY_TIMEOUT_MS", 600_000)
  defp clickbench_drain_wait_s, do: Bench.env_int("CLICKBENCH_DRAIN_WAIT_S", 3600)
  defp clickbench_duckdb_version, do: Bench.env("CLICKBENCH_DUCKDB_VERSION", "v1.5.4")

  defp run_clickbench(id, dataset, key, watcher) do
    table = clickbench_table()
    ref = "#{dataset}.#{table}"
    url = "#{Bench.Remote.base_url()}/v1/queries"
    label = "loadgen-clickbench-#{table}#{label_suffix()}"
    expected_rows = clickbench_files() * 1_000_000

    IO.puts("\n== clickbench: table #{ref}, #{clickbench_files()} parquet file(s)")
    Bench.Remote.setup(table)

    IO.puts("== clickbench: pushing the working tree, building upload1brc and cbquery")
    push_code(id)
    put_api_key(key)
    Bench.WatchMetrics.set_phase(watcher, "clickbench-prepare")
    IO.puts("== clickbench: #{clickbench_prepare(id)}")

    load =
      if clickbench_upload?() do
        Bench.WatchMetrics.set_phase(watcher, "clickbench-load")
        load = clickbench_load(id, dataset, table, label)

        IO.puts(
          "== clickbench: #{load["rows_accepted"]} rows in " <>
            "#{Float.round(load["duration_s"] / 1, 1)}s = #{round(load["rows_per_s"])} rows/s, " <>
            "#{Float.round(load["mib_per_s"] / 1, 1)} MiB/s, #{load["requests"]} requests, " <>
            "#{load["retries_429"]} x 429, #{load["retries_other"]} other retries, " <>
            "#{load["rows_rejected"]} rejected, #{load["rows_failed"]} failed, exit #{load["exit"]}"
        )

        load
      else
        IO.puts("== clickbench: CLICKBENCH_UPLOAD=false, querying the rows already there")
        nil
      end

    Bench.WatchMetrics.set_phase(watcher, "clickbench-drain")
    drain_sql = "SELECT count(*) AS n FROM #{ref} WHERE CounterID = -1"
    drain = await_hot_drain_with(url, key, drain_sql, clickbench_drain_wait_s())
    IO.puts("== clickbench: hot tier #{drain_outcome(drain)}")

    count = clickbench_count(url, key, ref)
    IO.puts("== clickbench: count(*) #{count} (expected #{expected_rows})")

    {passes, probe} =
      if clickbench_queries?() do
        passes =
          Map.new(clickbench_modes(), fn mode ->
            if clickbench_cold?() do
              Bench.WatchMetrics.set_phase(watcher, "clickbench-cold-#{mode}")
              clickbench_restart_query_pods()
            end

            Bench.WatchMetrics.set_phase(watcher, "clickbench-query-#{mode}")

            result =
              clickbench_box_queries(id, ref, "#{label}-#{mode}",
                options: clickbench_mode_options(mode),
                tries: clickbench_tries(),
                only: clickbench_only()
              )

            {mode, result}
          end)

        Bench.WatchMetrics.set_phase(watcher, "clickbench-probe")
        {passes, clickbench_probe(id, ref, label)}
      else
        {%{}, nil}
      end

    payload = %{
      "inserted_at" => now_iso(),
      "table" => ref,
      "files" => clickbench_files(),
      "rows_expected" => expected_rows,
      "count" => count,
      "load" => load,
      "drain_wait_s" => drain.waited_s,
      "drain_hot_files_left" => drain.hot_files,
      "cold" => clickbench_cold?(),
      "modes" => clickbench_modes(),
      "passes" => passes,
      "probe" => probe
    }

    path = Path.join(results_dir(), "#{label}.clickbench.json")
    File.write!(path, JSON.encode!(payload) <> "\n")
    IO.puts("== clickbench → #{label}.clickbench.json")

    try do
      IO.puts("== clickbench: report → #{Bench.ClickbenchReport.generate(path)}")
    rescue
      error -> IO.puts("== clickbench: no report (#{Exception.message(error)})")
    end

    delete_api_key()
  end

  defp clickbench_prepare(id) do
    files = clickbench_files()

    run!(id, """
    set -euo pipefail
    cd #{remote_dir()}
    export PATH=/usr/local/go/bin:$PATH GOTOOLCHAIN=local GOPATH=/opt/go GOCACHE=/opt/go/cache
    go build -o upload1brc ./tools/upload1brc
    go build -o cbquery ./tools/cbquery
    mkdir -p bin data/hits logs results
    if [ ! -x bin/duckdb ]; then
      case "$(uname -m)" in aarch64) arch=arm64 ;; *) arch=amd64 ;; esac
      curl -fsSL -o /tmp/duckdb.zip \\
        https://github.com/duckdb/duckdb/releases/download/#{clickbench_duckdb_version()}/duckdb_cli-linux-$arch.zip
      python3 -c "import zipfile; zipfile.ZipFile('/tmp/duckdb.zip').extractall('bin')"
      chmod +x bin/duckdb
    fi
    seq 0 #{files - 1} | xargs -P 16 -I{} sh -c \\
      '[ -f data/hits/hits_{}.parquet ] || { curl -fsSL -o data/hits/hits_{}.parquet.part #{@clickbench_parquet_url}/hits_{}.parquet && mv data/hits/hits_{}.parquet.part data/hits/hits_{}.parquet; }'
    echo "$(ls data/hits/*.parquet | wc -l) parquet files, $(du -sh data/hits | cut -f1), $(nproc) vCPU on the box"
    """)
    |> String.trim()
  end

  defp clickbench_load(id, dataset, table, label) do
    urls =
      Enum.map_join(api_pod_ips(), ",", fn ip ->
        "http://#{ip}:4000/v1/datasets/#{dataset}/tables/#{table}/insert"
      end)

    stamp = DateTime.utc_now() |> Calendar.strftime("%Y%m%dT%H%M%SZ")
    dir = "logs/#{label}-#{stamp}"
    files = clickbench_files()

    IO.puts(
      "== clickbench: #{clickbench_pipelines()} pipelines x #{clickbench_workers()} workers " <>
        "across #{urls |> String.split(",") |> length()} api pod(s), " <>
        "~#{clickbench_rows_per_request()} rows/request, DuckDB #{clickbench_duckdb_threads()} threads each"
    )

    run!(id, """
    set -euo pipefail
    cd #{remote_dir()}
    #{fetch_auth()}
    export AUTH CB_LABEL=#{label}-#{stamp} CB_URLS='#{urls}' CB_ROWS=#{clickbench_rows_per_request()} \\
      CB_WORKERS=#{clickbench_workers()} CB_THREADS=#{clickbench_duckdb_threads()} \\
      CB_MEMORY=#{clickbench_duckdb_memory()} CB_PREFIX=#{label}-#{stamp}
    mkdir -p #{dir}
    setsid nohup bash -c 'date +%s.%N > #{dir}/started
      seq 0 #{files - 1} | xargs -P #{clickbench_pipelines()} -n 1 bash scripts/clickbench/load-file.sh
      echo $? > #{dir}/exit
      date +%s.%N > #{dir}/finished' > #{dir}/driver.log 2>&1 < /dev/null &
    """)

    IO.puts("== clickbench: load running in #{dir}, polling every #{onebrc_poll_s()}s")
    clickbench_load_poll(id, dir, files)
  end

  defp clickbench_load_poll(id, dir, files) do
    Process.sleep(onebrc_poll_s() * 1000)

    status =
      run!(id, "cd #{remote_dir()} && python3 scripts/clickbench/load-status.py #{dir} #{files}")
      |> String.trim()
      |> JSON.decode!()

    IO.puts(
      "   #{status["files_done"]}/#{files} files, #{status["rows_accepted"]} rows, " <>
        "#{round(status["rows_per_s"] || 0)} rows/s, #{Float.round((status["mib_per_s"] || 0) / 1, 1)} MiB/s, " <>
        "#{status["requests"]} reqs, #{status["retries_429"]} x 429, " <>
        "#{status["retries_other"]} other retries, #{status["rows_failed"]} failed"
    )

    if status["finished"] do
      if status["exit"] != "0" do
        tail =
          run!(id, "cd #{remote_dir()} && tail -5 #{dir}/driver.log #{dir}/f*.log | tail -40")

        IO.puts("== clickbench: a pipeline failed (xargs exit #{status["exit"]}):\n#{tail}")
      end

      status
    else
      clickbench_load_poll(id, dir, files)
    end
  end

  defp clickbench_count(url, key, ref) do
    case time_query(url, key, "SELECT count(*) AS n FROM #{ref}", %{
           "timeoutMs" => clickbench_query_timeout_ms()
         }) do
      %{error: nil, rows: n} -> n
      %{error: error} -> error
    end
  end

  defp clickbench_restart_query_pods do
    IO.puts("== clickbench: CLICKBENCH_COLD=true, deleting the query pods to empty /cache")
    Bench.Kube.cmd(["delete", "pod", "-l", "app=smolquery-query", "--wait=true"])

    case Bench.Kube.cmd(["rollout", "status", "statefulset/smolquery-query", "--timeout=600s"]) do
      {_, 0} -> IO.puts("== clickbench: query pods ready")
      {out, _} -> Bench.fatal!("query pods did not come back:\n#{out}")
    end

    Process.sleep(30_000)
  end

  defp clickbench_probe(id, ref, label) do
    tries = clickbench_probe_tries()

    if tries > 1 do
      runs =
        Map.new(~w(single scatter), fn mode ->
          result =
            clickbench_box_queries(id, ref, "#{label}-probe-#{mode}",
              options: clickbench_mode_options(mode),
              tries: tries,
              queries: "scripts/clickbench/probe.sql"
            )

          {mode, result}
        end)

      single = clickbench_probe_median(runs["single"])
      scatter = clickbench_probe_median(runs["scatter"])
      overhead = if single && scatter, do: Float.round(scatter - single, 1)

      IO.puts(
        "== clickbench: probe median hot single #{single} ms, scatter #{scatter} ms, " <>
          "scatter overhead #{overhead} ms"
      )

      %{"single_ms" => single, "scatter_ms" => scatter, "overhead_ms" => overhead, "runs" => runs}
    end
  end

  defp clickbench_probe_median(%{"queries" => [%{"tries" => [_first | rest]} | _]}) do
    rest |> Enum.reject(& &1["error"]) |> Enum.map(& &1["wall_ms"]) |> median_or_nil()
  end

  defp clickbench_probe_median(_result), do: nil

  defp clickbench_box_queries(id, ref, name, opts) do
    options = Keyword.fetch!(opts, :options)
    tries = Keyword.fetch!(opts, :tries)
    queries = Keyword.get(opts, :queries, "scripts/clickbench/queries.sql")
    only = Keyword.get(opts, :only, "")
    url = "http://#{pod_ip(clickbench_query_pod())}:4000/v1/queries"
    out = "results/#{name}.queries.json"
    log = "logs/#{name}.queries.log"
    only_flag = if only == "", do: "", else: " -only #{only}"

    IO.puts(
      "== clickbench: #{name}: #{tries} tries per query of #{queries} from the box against " <>
        "#{clickbench_query_pod()} (#{url}), options #{options}"
    )

    pid =
      run!(id, """
      set -euo pipefail
      cd #{remote_dir()}
      #{fetch_auth()}
      export AUTH
      rm -f #{out}
      setsid nohup ./cbquery -url #{url} -ref #{ref} -queries #{queries} -tries #{tries} \\
        -timeout-ms #{clickbench_query_timeout_ms()} -options '#{options}'#{only_flag} \\
        -out #{out} > #{log} 2>&1 < /dev/null &
      echo $!
      """)
      |> String.trim()

    clickbench_query_poll(id, pid, out, log, 0)
  end

  defp clickbench_query_poll(id, pid, out, log, printed) do
    Process.sleep(15_000)

    state =
      run!(id, """
      cd #{remote_dir()}
      if kill -0 #{pid} 2>/dev/null; then echo running; else echo done; fi
      """)
      |> String.trim()

    lines =
      run!(id, "cd #{remote_dir()} && tail -n +#{printed + 1} #{log} 2>/dev/null || true")
      |> String.split("\n", trim: true)

    Enum.each(lines, &IO.puts("   #{&1}"))
    printed = printed + length(lines)

    case state do
      "running" ->
        clickbench_query_poll(id, pid, out, log, printed)

      _done ->
        case run!(id, "gzip -c #{remote_dir()}/#{out} 2>/dev/null | base64 -w0 || true")
             |> String.trim() do
          "" ->
            Bench.fatal!("cbquery exited without a result; see #{log} on the box")

          encoded ->
            encoded |> Base.decode64!() |> :zlib.gunzip() |> JSON.decode!()
        end
    end
  end

  # ── bench: compaction ──────────────────────────────────────────────────────

  defp compact_watch_s, do: Bench.env_int("COMPACT_WATCH_S", 900)

  defp run_compaction do
    seconds = compact_watch_s()
    pods = storage_pods()

    IO.puts("\n== compaction: watching #{length(pods)} storage pod(s) for #{seconds}s")
    Enum.each(pods, &IO.puts("     #{&1}"))

    window_start = now_iso()
    deadline = System.monotonic_time(:second) + seconds

    events = watch_compaction(pods, deadline, [])

    label = "loadgen-compact#{label_suffix()}"

    payload = %{
      "inserted_at" => now_iso(),
      "watch_s" => seconds,
      "window_start" => window_start,
      "log_lookback" => "30m",
      "pods" => pods,
      "restarts" => Enum.map(pods, &pod_restart_json/1),
      "events" => events,
      "compacted" => Enum.count(events, &(&1["kind"] == "compacted")),
      "failed" => Enum.count(events, &(&1["kind"] == "failed")),
      "oom" => Enum.count(events, &(&1["kind"] == "failed" and &1["oom"]))
    }

    File.write!(Path.join(results_dir(), "#{label}.compact.json"), JSON.encode!(payload) <> "\n")

    IO.puts(
      "== compaction: #{payload["compacted"]} compacted, #{payload["failed"]} failed " <>
        "(#{payload["oom"]} out-of-memory) → #{label}.compact.json"
    )
  end

  defp storage_pods do
    args = [
      "get",
      "pods",
      "-l",
      "app=smolquery-storage",
      "-o",
      "jsonpath={.items[*].metadata.name}"
    ]

    case Bench.Kube.cmd(args) do
      {output, 0} ->
        case output
             |> String.split(~r/\s+/, trim: true)
             |> Enum.filter(&(&1 =~ ~r/^smolquery-/)) do
          [] -> Bench.fatal!("no storage pods found for label app=smolquery-storage")
          pods -> Enum.sort(pods)
        end

      {out, _} ->
        Bench.fatal!("could not list the storage pods:\n#{out}")
    end
  end

  defp watch_compaction(pods, deadline, seen) do
    events =
      pods
      |> Enum.flat_map(&compaction_events/1)
      |> Enum.reject(&(&1 in seen))

    Enum.each(events, fn event ->
      IO.puts("   #{event["pod"]} #{event["kind"]} #{event["table"]} #{event["at"]}")
    end)

    all = seen ++ events

    if System.monotonic_time(:second) >= deadline do
      all
    else
      Process.sleep(30_000)
      watch_compaction(pods, deadline, all)
    end
  end

  defp compaction_events(pod) do
    case Bench.Kube.cmd(["logs", pod, "--since=30m"]) do
      {output, 0} ->
        output |> String.split("\n") |> Enum.flat_map(&parse_compaction_line(&1, pod))

      _failed ->
        []
    end
  end

  defp parse_compaction_line(line, pod) do
    cond do
      line =~ "compacted" and line =~ "segment(s) of" ->
        [compaction_event(line, pod, "compacted")]

      line =~ "compaction of" and line =~ "failed" ->
        [compaction_event(line, pod, "failed")]

      true ->
        []
    end
  end

  defp compaction_event(line, pod, kind) do
    %{
      "pod" => pod,
      "kind" => kind,
      "at" => line |> String.slice(0, 12) |> String.trim(),
      "table" => extract_table(line),
      "segments" => extract_segments(line),
      "oom" => line =~ "Out of Memory",
      "line" => trunc_text(line)
    }
  end

  defp extract_table(line) do
    case Regex.run(~r/\{"([^"]+)",\s*"([^"]+)"\}/, line) do
      [_, dataset, table] -> "#{dataset}.#{table}"
      _no_match -> nil
    end
  end

  defp extract_segments(line) do
    case Regex.run(~r/compacted (\d+) segment/, line) do
      [_, count] -> String.to_integer(count)
      _no_match -> nil
    end
  end

  defp pod_restart_json(pod) do
    path = "jsonpath={.status.containerStatuses[0].restartCount}"

    restarts =
      case Bench.Kube.cmd(["get", "pod", pod, "-o", path]) do
        {output, 0} ->
          case output |> String.trim() |> Integer.parse() do
            {count, _rest} -> count
            :error -> nil
          end

        _failed ->
          nil
      end

    %{"pod" => pod, "restarts" => restarts}
  end

  defp now_iso, do: DateTime.utc_now() |> DateTime.to_iso8601()

  defp api_key_param, do: "/smolquery-bench/api-key"

  defp put_api_key(key) do
    aws!(
      ["ssm", "put-parameter", "--name", api_key_param(), "--type", "SecureString"] ++
        ["--value", key, "--overwrite"]
    )
  end

  defp delete_api_key do
    System.cmd(
      "aws",
      ["ssm", "delete-parameter", "--name", api_key_param()] ++
        ["--region", region(), "--profile", profile()],
      stderr_to_stdout: true
    )
  end

  defp fetch_auth do
    """
    AUTH="Bearer $(aws ssm get-parameter --name #{api_key_param()} --with-decryption \
      --query Parameter.Value --output text --region #{region()})"
    """
  end

  defp warmup_script(urls, vus) do
    """
    set -euo pipefail
    cd #{remote_dir()}
    #{fetch_auth()}
    k6 run --quiet -e URLS='#{urls}' -e AUTH="$AUTH" -e ROWS=#{rows()} \
      -e BODY=#{remote_dir()}/#{body_file()} \
      -e VUS=#{vus} -e DURATION=#{warmup_s()}s k6/insert.js >/dev/null
    """
  end

  defp measure_script(urls, vus, label) do
    """
    set -euo pipefail
    cd #{remote_dir()}
    #{fetch_auth()}
    k6 run --quiet -e URLS='#{urls}' -e AUTH="$AUTH" -e ROWS=#{rows()} \
      -e BODY=#{remote_dir()}/#{body_file()} \
      -e VUS=#{vus} -e DURATION=#{duration_s()}s \
      -e JSON_OUT=results/#{label}.k6.json k6/insert.js
    """
  end

  # ── bench: tsbs ────────────────────────────────────────────────────────────

  @tsbs_query_types ~w(
    single-groupby-1-1-1 single-groupby-1-1-12 single-groupby-1-8-1
    single-groupby-5-1-1 single-groupby-5-1-12 single-groupby-5-8-1
    cpu-max-all-1 cpu-max-all-8
    double-groupby-1 double-groupby-5 double-groupby-all
  )

  defp tsbs_scales, do: Bench.env("TSBS_SCALES", "100 1000") |> String.split()
  defp tsbs_hours, do: Bench.env_int("TSBS_HOURS", 24)
  defp tsbs_phases, do: Bench.env("TSBS_PHASES", "load,query") |> String.split(",", trim: true)
  defp tsbs_ref, do: Bench.env("TSBS_REF", "8323e59")
  defp tsbs_seed, do: Bench.env_int("TSBS_SEED", 123)
  defp tsbs_queries, do: Bench.env_int("TSBS_QUERIES", 50)
  defp tsbs_verify, do: Bench.env_int("TSBS_VERIFY", 3)
  defp tsbs_query_workers, do: Bench.env("TSBS_QUERY_WORKERS", "1 4") |> String.split()

  defp tsbs_query_types,
    do: Bench.env("TSBS_QUERY_TYPES", Enum.join(@tsbs_query_types, " ")) |> String.split()

  defp tsbs_load_workers, do: Bench.env_int("TSBS_LOAD_WORKERS", 8)
  defp tsbs_load_samples, do: Bench.env_int("TSBS_LOAD_SAMPLES", 10_000)
  defp tsbs_drain_wait_s, do: Bench.env_int("TSBS_DRAIN_WAIT_S", 1800)
  defp tsbs_drain_slack, do: Bench.env_int("TSBS_DRAIN_SLACK", 8)
  defp tsbs_poll_s, do: Bench.env_int("TSBS_POLL_S", 20)

  defp tsbs_results_dir,
    do: Bench.env("TSBS_RESULTS", Path.join(Bench.root(), "results/raw-tsbs"))

  defp tsbs_windows_file, do: Path.join(tsbs_results_dir(), "windows.json")
  defp tsbs_home, do: "#{remote_dir()}/tsbs"

  defp tsbs_gen_dir(scale, w),
    do: "#{tsbs_home()}/gen/s#{scale}-#{String.slice(w["start"], 0, 13)}"

  defp tsbs_out_dir(scale, label), do: "#{tsbs_home()}/out/s#{scale}-#{label}"
  defp tsbs_sql, do: "SELECT count(*) AS n FROM metrics.samples WHERE name = '~'"

  defp tsbs_label do
    case Bench.env("TSBS_LABEL", "") do
      "" -> "sq-" <> String.slice(live_sha(), 0, 7)
      label -> label
    end
  end

  defp live_sha do
    case Bench.Kube.cmd([
           "exec",
           "smolquery-query-0",
           "-c",
           "smolquery",
           "--",
           "printenv",
           "SMOLQUERY_GIT_SHA"
         ]) do
      {sha, 0} -> String.trim(sha)
      _ -> "unknown"
    end
  end

  defp tsbs_windows do
    case File.read(tsbs_windows_file()) do
      {:ok, body} -> JSON.decode!(body)
      _ -> %{}
    end
  end

  defp tsbs_window(scale) do
    windows = tsbs_windows()

    case windows[scale] do
      nil ->
        finish =
          case Map.values(windows) do
            [] ->
              %{DateTime.utc_now() | hour: 0, minute: 0, second: 0, microsecond: {0, 0}}

            taken ->
              taken
              |> Enum.map(&elem(DateTime.from_iso8601(&1["start"]), 1))
              |> Enum.min(DateTime)
          end

        start = DateTime.add(finish, -tsbs_hours() * 3600, :second)
        w = %{"start" => DateTime.to_iso8601(start), "end" => DateTime.to_iso8601(finish)}
        File.mkdir_p!(tsbs_results_dir())
        File.write!(tsbs_windows_file(), JSON.encode!(Map.put(windows, scale, w)))
        w

      w ->
        w
    end
  end

  defp run_tsbs(id, key, watcher) do
    label = tsbs_label()
    File.mkdir_p!(tsbs_results_dir())

    IO.puts(
      "\n== tsbs: #{label}, scales #{Enum.join(tsbs_scales(), " ")}, phases #{Enum.join(tsbs_phases(), ",")}"
    )

    IO.puts(
      "== tsbs: pushing the working tree, building TSBS #{tsbs_ref()}, tsbsrw and tsbsdigest"
    )

    push_code(id)

    run!(id, """
    set -euo pipefail
    cd #{remote_dir()}
    export PATH=/usr/local/go/bin:$PATH GOPATH=/opt/go GOCACHE=/opt/go/cache GOBIN=#{tsbs_home()}/bin
    mkdir -p #{tsbs_home()}/bin
    for c in tsbs_generate_data tsbs_generate_queries tsbs_run_queries_victoriametrics; do
      [ -x #{tsbs_home()}/bin/$c ] || go install github.com/timescale/tsbs/cmd/$c@#{tsbs_ref()}
    done
    go build -o #{tsbs_home()}/bin/tsbsrw ./tools/tsbsrw
    go build -o #{tsbs_home()}/bin/tsbsdigest ./tools/tsbsdigest
    ls #{tsbs_home()}/bin
    """)

    put_api_key(key)

    for scale <- tsbs_scales() do
      w = tsbs_window(scale)
      IO.puts("\n== tsbs s#{scale}: #{w["start"]} to #{w["end"]}")
      Bench.WatchMetrics.set_phase(watcher, "tsbs-s#{scale}-gen")
      IO.puts(tsbs_gen(id, scale, w))

      if "load" in tsbs_phases() do
        Bench.WatchMetrics.set_phase(watcher, "tsbs-s#{scale}-load")
        tsbs_load(id, scale, w, label, key, watcher)
      end

      if "query" in tsbs_phases() do
        Bench.WatchMetrics.set_phase(watcher, "tsbs-s#{scale}-query")
        tsbs_query(id, scale, w, label)
      end

      tsbs_fetch(id, scale, label)
    end

    delete_api_key()
  end

  defp tsbs_gen(id, scale, w) do
    dir = tsbs_gen_dir(scale, w)

    common =
      "--use-case=cpu-only --seed=#{tsbs_seed()} --scale=#{scale} --timestamp-start=#{w["start"]} --timestamp-end=#{w["end"]}"

    queries =
      Enum.map_join(@tsbs_query_types, "\n", fn type ->
        "[ -f #{dir}/#{type}.q ] || bin/tsbs_generate_queries #{common} --format=victoriametrics " <>
          "--query-type=#{type} --queries=#{tsbs_queries()} --file=#{dir}/#{type}.q"
      end)

    run!(id, """
    set -euo pipefail
    cd #{tsbs_home()}
    mkdir -p #{dir}
    if [ ! -f #{dir}/cpu-only.lp ]; then
      bin/tsbs_generate_data #{common} --log-interval=10s --format=victoriametrics --file=#{dir}/cpu-only.lp.tmp
      mv #{dir}/cpu-only.lp.tmp #{dir}/cpu-only.lp
    fi
    #{queries}
    echo "#{dir}: $(du -h #{dir}/cpu-only.lp | cut -f1) data, $(wc -l < #{dir}/cpu-only.lp) lines"
    """)
    |> String.trim()
  end

  defp tsbs_load(id, scale, w, label, key, watcher) do
    url = "#{Bench.Remote.base_url()}/v1/queries"
    baseline = hot_files(url, key, tsbs_sql())
    out = tsbs_out_dir(scale, label)
    urls = Enum.map_join(api_pod_ips(), ",", &"http://#{&1}:8428/api/v1/write")

    IO.puts(
      "== tsbs s#{scale}: hot files before the load #{inspect(baseline)}, #{tsbs_load_workers()} writers across #{length(api_pod_ips())} api pod(s)"
    )

    pid =
      run!(id, """
      set -euo pipefail
      cd #{tsbs_home()}
      #{fetch_auth()}
      export AUTH
      mkdir -p #{out}
      rm -f #{out}/load.json #{out}/load.progress.json
      setsid nohup bin/tsbsrw -file=#{tsbs_gen_dir(scale, w)}/cpu-only.lp -urls='#{urls}' \\
        -workers=#{tsbs_load_workers()} -samples=#{tsbs_load_samples()} \\
        -progress=#{out}/load.progress.json -out=#{out}/load.json \\
        > #{out}/load.log 2>&1 < /dev/null &
      echo $!
      """)
      |> String.trim()

    summary = tsbs_poll_load(id, pid, out)

    IO.puts(
      "== tsbs s#{scale}: #{summary["samples_accepted"]} samples in #{round(summary["duration_s"])} s, " <>
        "#{round(summary["samples_per_s"])}/s, p50 #{round(summary["latency_ms"]["med"])} ms, " <>
        "#{summary["retries_busy"]} busy retries, #{summary["retries_other"]} other, " <>
        "#{summary["samples_rejected"]} rejected, #{summary["samples_failed"]} failed"
    )

    Bench.WatchMetrics.set_phase(watcher, "tsbs-s#{scale}-drain")
    target = if is_integer(baseline), do: baseline + tsbs_drain_slack(), else: tsbs_drain_slack()
    drain = tsbs_drain(url, key, target, System.monotonic_time(:second))

    IO.puts(
      "== tsbs s#{scale}: hot files #{inspect(drain.hot_files)} after #{drain.waited_s} s (target ≤ #{target})"
    )

    payload =
      Map.merge(summary, %{
        "inserted_at" => now_iso(),
        "build" => live_sha(),
        "window" => w,
        "api_pods" => length(api_pod_ips()),
        "hot_files_before" => baseline,
        "drain_s" => drain.waited_s,
        "hot_files_after_drain" => drain.hot_files
      })

    File.write!(
      Path.join(tsbs_results_dir(), "s#{scale}-#{label}.load.json"),
      JSON.encode!(payload) <> "\n"
    )
  end

  defp tsbs_poll_load(id, pid, out) do
    Process.sleep(tsbs_poll_s() * 1000)

    [state | rest] =
      run!(id, """
      if kill -0 #{pid} 2>/dev/null; then echo running; else echo done; fi
      cat #{out}/load.progress.json 2>/dev/null || echo '{}'
      """)
      |> String.trim()
      |> String.split("\n", parts: 2)

    snap = rest |> List.first("{}") |> JSON.decode!()

    if map_size(snap) > 0 do
      IO.puts(
        "   #{snap["samples_accepted"]} samples, #{round(snap["samples_per_s_recent"] || 0)}/s recent, " <>
          "#{snap["retries_busy"]} busy retries, #{snap["retries_other"]} other, responses #{inspect(snap["responses"])}"
      )
    end

    case state do
      "running" ->
        tsbs_poll_load(id, pid, out)

      _ ->
        case run!(id, "cat #{out}/load.json 2>/dev/null || true") |> String.trim() do
          "" ->
            Bench.fatal!(
              "tsbsrw exited without a summary:\n" <> run!(id, "tail -20 #{out}/load.log")
            )

          json ->
            JSON.decode!(json)
        end
    end
  end

  defp tsbs_drain(url, key, target, started) do
    files = hot_files(url, key, tsbs_sql())
    waited = System.monotonic_time(:second) - started

    cond do
      is_integer(files) and files <= target ->
        %{waited_s: waited, hot_files: files}

      waited >= tsbs_drain_wait_s() ->
        %{waited_s: waited, hot_files: files}

      true ->
        IO.puts("   #{waited} s: #{inspect(files)} hot files")
        Process.sleep(drain_poll_s() * 1000)
        tsbs_drain(url, key, target, started)
    end
  end

  defp tsbs_query(id, scale, w, label) do
    dir = tsbs_gen_dir(scale, w)
    out = tsbs_out_dir(scale, label)
    urls = Enum.map_join(endpoint_ips("smolquery-query"), ",", &"http://tsbs:${KEY}@#{&1}:8428")
    runner = "bin/tsbs_run_queries_victoriametrics"

    steps =
      Enum.map_join(tsbs_query_types(), "\n", fn type ->
        passes =
          Enum.map_join(tsbs_query_workers(), "\n", fn workers ->
            """
            rm -f #{out}/#{type}.w#{workers}.json
            #{runner} --file=#{dir}/#{type}.q --urls="#{urls}" --workers=#{workers} --print-interval=0 \\
              --results-file=#{out}/#{type}.w#{workers}.json > #{out}/#{type}.w#{workers}.full.log 2>&1
            echo "exit $?" >> #{out}/#{type}.w#{workers}.full.log
            tail -c 3000 #{out}/#{type}.w#{workers}.full.log > #{out}/#{type}.w#{workers}.log
            rm -f #{out}/#{type}.w#{workers}.full.log
            """
          end)

        """
        echo "$(date -u +%H:%M:%S) #{type}" >> #{out}/query.progress
        #{runner} --file=#{dir}/#{type}.q --urls="#{urls}" --workers=1 --max-queries=#{tsbs_verify()} \\
          --print-interval=0 --print-responses 2>&1 | bin/tsbsdigest > #{out}/#{type}.digest
        #{passes}
        """
      end)

    script = """
    #!/bin/bash
    set -uo pipefail
    cd #{tsbs_home()}
    #{fetch_auth()}
    KEY="${AUTH#Bearer }"
    #{steps}
    touch #{out}/query.done
    """

    payload = Base.encode64(script)

    pid =
      run!(id, """
      set -euo pipefail
      mkdir -p #{out}
      rm -f #{out}/query.done #{out}/query.progress
      echo '#{payload}' | base64 -d > #{out}/query.sh
      setsid nohup bash #{out}/query.sh > #{out}/query.log 2>&1 < /dev/null &
      echo $!
      """)
      |> String.trim()

    IO.puts(
      "== tsbs s#{scale}: queries running as pid #{pid} across #{length(endpoint_ips("smolquery-query"))} query pod(s)"
    )

    tsbs_poll_query(id, pid, out)
  end

  defp tsbs_poll_query(id, pid, out) do
    Process.sleep(tsbs_poll_s() * 1000)

    status =
      run!(id, """
      if [ -f #{out}/query.done ]; then echo done; elif kill -0 #{pid} 2>/dev/null; then echo running; else echo died; fi
      tail -1 #{out}/query.progress 2>/dev/null || true
      """)
      |> String.trim()

    case String.split(status, "\n", parts: 2) do
      ["running" | rest] ->
        IO.puts("   at #{List.first(rest, "?")}")
        tsbs_poll_query(id, pid, out)

      ["done" | _] ->
        :ok

      _ ->
        IO.puts("== tsbs: the query script died:\n" <> run!(id, "tail -20 #{out}/query.log"))
    end
  end

  defp tsbs_fetch(id, scale, label) do
    out = tsbs_out_dir(scale, label)
    local = tsbs_results_dir()

    payload =
      fetch_chunked(
        id,
        "cd #{out} && tar czf - --exclude='*.lp' --exclude=query.sh --exclude=load.progress.json --exclude=load.json . | base64 -w0"
      )

    tmp = Path.join(System.tmp_dir!(), "tsbs-#{scale}-#{label}")
    File.rm_rf!(tmp)
    File.mkdir_p!(tmp)
    tarball = Path.join(tmp, "out.tgz")
    File.write!(tarball, Base.decode64!(payload))
    Bench.sh!("tar", ["xzf", tarball, "-C", tmp])
    File.rm!(tarball)

    for file <- File.ls!(tmp) do
      File.cp!(Path.join(tmp, file), Path.join(local, "s#{scale}-#{label}.#{file}"))
    end

    for type <- tsbs_query_types(), workers <- tsbs_query_workers() do
      json = Path.join(local, "s#{scale}-#{label}.#{type}.w#{workers}.json")
      log = Path.join(local, "s#{scale}-#{label}.#{type}.w#{workers}.log")

      if not File.exists?(json) and File.exists?(log) do
        error =
          log
          |> File.read!()
          |> String.split("\n")
          |> Enum.find("no output", &String.contains?(&1, ["panic:", "statuscode", "error"]))
          |> String.slice(0, 400)

        File.write!(json, JSON.encode!(%{"error" => error}))
      end
    end

    File.rm_rf!(tmp)
    IO.puts("== tsbs s#{scale}: results → #{local}/s#{scale}-#{label}.*")
  end

  defp fetch_chunked(id, producer) do
    staged = "/tmp/tsbs-fetch.b64"

    size =
      run!(id, "#{producer} > #{staged} && stat -c %s #{staged}")
      |> String.trim()
      |> String.to_integer()

    chunk = 20_000

    0..max(div(size - 1, chunk), 0)//1
    |> Enum.map_join(fn i ->
      run!(id, "cut -c #{i * chunk + 1}-#{(i + 1) * chunk} #{staged}") |> String.trim()
    end)
  end

  # ── fetch ──────────────────────────────────────────────────────────────────

  def fetch do
    id = instance_id!()
    File.mkdir_p!(results_dir())

    payload =
      run!(id, """
      set -euo pipefail
      cd #{remote_dir()}
      tar czf - results | base64 -w0
      """)
      |> String.trim()

    byte_size(payload) < @ssm_output_limit ||
      Bench.fatal!(
        "results are #{byte_size(payload)} base64 bytes, over the #{@ssm_output_limit} " <>
          "SSM inline limit — the tarball would be truncated. Fetch fewer runs at a time."
      )

    tarball = Path.join(System.tmp_dir!(), "bench-results.tgz")
    File.write!(tarball, Base.decode64!(payload))

    Bench.sh!("tar", ["xzf", tarball, "--strip-components", "1", "-C", results_dir()])
    File.rm(tarball)

    count = results_dir() |> Path.join("*.k6.json") |> Path.wildcard() |> length()
    IO.puts("fetched #{count} k6 results → #{results_dir()}")
  end

  # ── bench: vlogs ───────────────────────────────────────────────────────────

  @vlogs_tag "smolquery-bench-vlogs"
  @vlogs_systems ["victorialogs", "smolquery"]

  defp vlogs_instance_type, do: Bench.env("VLOGS_INSTANCE_TYPE", "m6a.2xlarge")
  defp vlogs_version, do: Bench.env("VLOGS_VERSION", "v1.53.0")
  defp vlogs_disk_gib, do: Bench.env("VLOGS_DISK_GIB", "500")
  defp vlogs_disk_mibps, do: Bench.env("VLOGS_DISK_MIBPS", "280")
  defp vlogs_rate, do: Bench.env_int("VLOGS_RATE", 10_000)
  defp vlogs_step, do: Bench.env_int("VLOGS_STEP", 10_000)
  defp vlogs_max, do: Bench.env_int("VLOGS_MAX", 150_000)
  defp vlogs_interval_s, do: Bench.env_int("VLOGS_INTERVAL_S", 300)
  defp vlogs_settle_s, do: Bench.env_int("VLOGS_SETTLE_S", 120)
  defp vlogs_batch_lines, do: Bench.env_int("VLOGS_BATCH_LINES", 2000)
  defp vlogs_workers, do: Bench.env_int("VLOGS_WORKERS", 32)

  defp vlogs_writer_flags do
    [
      "-rate=#{vlogs_rate()}",
      "-rampStep=#{vlogs_step()}",
      "-rampInterval=#{vlogs_interval_s()}s",
      "-rampMax=#{vlogs_max()}",
      "-dropOnFull=true",
      "-buffer=400000",
      "-batchLines=#{vlogs_batch_lines()}",
      "-workers=#{vlogs_workers()}",
      "-hosts=125",
      "-apps=40",
      "-seed=1"
    ]
  end

  @doc """
  Launches the VictoriaLogs instance for `BENCHES=vlogs` and installs
  VictoriaLogs on it.

  The default shape copies the reference node of VictoriaMetrics'
  logs-benchmark: 8 vCPU AMD Milan with 32 GiB (m6a.2xlarge against
  n2d-standard-8), and a 500 GiB data disk at 280 MiB/s, the write cap of
  the 500 GiB pd-balanced disk upstream used. The instance wears the node
  security group, so the load generator reaches port 9428 directly.
  """
  def vlogs_up do
    id =
      case instance_id(@vlogs_tag) do
        nil ->
          launch(@vlogs_tag, vlogs_instance_type(), [
            root_device(30),
            "DeviceName=/dev/sdf,Ebs={VolumeSize=#{vlogs_disk_gib()},VolumeType=gp3," <>
              "Iops=3000,Throughput=#{vlogs_disk_mibps()},DeleteOnTermination=true}"
          ])

        id ->
          IO.puts("#{@vlogs_tag} already running: #{id}")
          id
      end

    wait_for_ssm(id, 60)
    IO.puts("installing VictoriaLogs #{vlogs_version()}")
    IO.puts(run_file!(id, "vl-install.sh", [vlogs_version()]))
    IO.puts("victorialogs at http://#{private_ip(id)}:9428")
  end

  @doc "Terminates the VictoriaLogs instance and its data disk."
  def vlogs_down do
    case instance_id(@vlogs_tag) do
      nil ->
        IO.puts("no #{@vlogs_tag} instance to terminate")

      id ->
        aws!(["ec2", "terminate-instances", "--instance-ids", id])
        IO.puts("terminating #{id}")
    end
  end

  defp private_ip(id) do
    aws!([
      "ec2",
      "describe-instances",
      "--instance-ids",
      id,
      "--query",
      "Reservations[0].Instances[0].PrivateIpAddress",
      "--output",
      "text"
    ])
  end

  defp put_file!(id, file) do
    payload = Path.join([Bench.root(), "tools/vlogs", file]) |> File.read!() |> Base.encode64()

    run!(id, """
    set -euo pipefail
    mkdir -p /opt/vlogs
    echo '#{payload}' | base64 -d > /opt/vlogs/#{file}
    """)
  end

  defp run_file!(id, file, args) do
    put_file!(id, file)
    run!(id, "bash /opt/vlogs/#{file} #{Enum.join(args, " ")}")
  end

  @doc """
  Rebuilds the summary of a saved `*.vlogs.json` from its raw samples and
  prints the step table.
  """
  def vlogs_report(path) do
    result = path |> File.read!() |> JSON.decode!()

    summary =
      vlogs_summary(
        result["bench_samples"],
        result["vl_samples"],
        result["steps"],
        result["restarts_before"] || %{}
      )

    File.write!(path, JSON.encode!(Map.put(result, "summary", summary)) <> "\n")
    IO.puts(vlogs_table(summary))
  end

  defp run_vlogs(id, dataset, table, key, watcher) do
    vl_id =
      instance_id(@vlogs_tag) ||
        Bench.fatal!("no #{@vlogs_tag} instance. Run: mise run vlogs-up")

    vl_addr = "http://#{private_ip(vl_id)}:9428"
    sq_addrs = Enum.map_join(api_pod_ips(), "|", &"http://#{&1}:4000")

    sq_query_addrs =
      Bench.env("VLOGS_QUERY_SERVICE", "smolquery-query")
      |> endpoint_ips()
      |> Enum.map_join("|", &"http://#{&1}:4000")

    steps = div(vlogs_max() - vlogs_rate(), vlogs_step()) + 1

    Bench.Remote.setup(table)
    rows_before = vlogs_count(dataset, table, key)

    IO.puts(
      "\n== vlogs: #{steps} steps of #{vlogs_interval_s()}s, " <>
        "#{vlogs_rate()} to #{vlogs_max()} lines/s, #{vlogs_batch_lines()} lines per request"
    )

    IO.puts("== vlogs: victorialogs #{vl_addr}")
    IO.puts("== vlogs: smolquery #{sq_addrs}, #{dataset}.#{table} holds #{rows_before} rows")
    IO.puts("== vlogs: smolquery counts via #{sq_query_addrs}")

    put_file!(vl_id, "vl-sampler.sh")
    IO.puts(String.trim(run_file!(vl_id, "vl-start.sh", [])))

    push_code(id)
    put_api_key(key)

    started =
      run!(id, """
      cd #{remote_dir()}
      SMOLQUERY_DATASET=#{dataset} SMOLQUERY_TABLE=#{table} AWS_REGION=#{region()} \
        bash tools/vlogs/bench-start.sh '#{vl_addr}' '#{sq_addrs}' '#{sq_query_addrs}' #{Enum.join(vlogs_writer_flags(), " ")}
      """)

    delete_api_key()
    IO.puts(String.trim(started))

    restarts_before = pod_restarts()
    bench_file = "#{remote_dir()}/results/vlogs-bench.txt"
    vl_file = "/opt/vlogs/samples.txt"

    acc =
      Enum.reduce(0..(steps - 1), %{bench: [], vl: [], steps: []}, fn i, acc ->
        target = vlogs_rate() + i * vlogs_step()
        Bench.WatchMetrics.set_phase(watcher, "vlogs-#{target}")
        anon_task = Task.async(fn -> pod_anon_peaks(vlogs_interval_s()) end)
        pods = Bench.WatchPods.sample(vlogs_interval_s())
        anon = Task.await(anon_task, :infinity)
        bench = acc.bench ++ tail_lines(id, bench_file, length(acc.bench))
        vl = acc.vl ++ tail_lines(vl_id, vl_file, length(acc.vl))

        step = %{
          "target" => target,
          "ended_at" => now_iso(),
          "pods" => pods,
          "anon_peak_bytes" => anon,
          "restarts" => pod_restarts()
        }

        IO.puts(vlogs_progress(target, bench, vl))
        %{acc | bench: bench, vl: vl, steps: acc.steps ++ [step]}
      end)

    Bench.WatchMetrics.set_phase(watcher, "vlogs-settle")
    run!(id, "systemctl stop vlbench-writer")
    IO.puts("== vlogs: writer stopped, settling #{vlogs_settle_s()}s")
    Process.sleep(vlogs_settle_s() * 1000)
    bench = acc.bench ++ tail_lines(id, bench_file, length(acc.bench))
    vl = acc.vl ++ tail_lines(vl_id, vl_file, length(acc.vl))
    run!(id, "bash #{remote_dir()}/tools/vlogs/bench-stop.sh")

    rows_after = vlogs_count(dataset, table, key)

    result = %{
      "inserted_at" => now_iso(),
      "upstream" => "VictoriaMetrics/logs-benchmark",
      "victorialogs" => %{"version" => vlogs_version(), "instance_type" => vlogs_instance_type()},
      "smolquery" => %{
        "dataset" => dataset,
        "table" => table,
        "rows_before" => rows_before,
        "rows_after" => rows_after
      },
      "config" => %{
        "rate" => vlogs_rate(),
        "step" => vlogs_step(),
        "max" => vlogs_max(),
        "interval_s" => vlogs_interval_s(),
        "batch_lines" => vlogs_batch_lines(),
        "workers" => vlogs_workers(),
        "writer_flags" => vlogs_writer_flags()
      },
      "restarts_before" => restarts_before,
      "steps" => acc.steps,
      "bench_samples" => bench,
      "vl_samples" => vl
    }

    stamp = DateTime.utc_now() |> Calendar.strftime("%Y%m%dT%H%M%SZ")
    out = Path.join(results_dir(), "loadgen-vlogs-#{stamp}#{label_suffix()}.vlogs.json")
    File.write!(out, JSON.encode!(result) <> "\n")
    summary = vlogs_summary(bench, vl, acc.steps, restarts_before)
    File.write!(out, JSON.encode!(Map.put(result, "summary", summary)) <> "\n")
    IO.puts("\n" <> vlogs_table(summary))
    IO.puts("== vlogs → #{out}")
  end

  defp vlogs_count(dataset, table, key) do
    url = "#{Bench.Remote.base_url()}/v1/queries"
    time_query(url, key, "SELECT count(*) AS n FROM #{dataset}.#{table}").rows
  end

  defp tail_lines(id, file, skip) do
    id
    |> run!("tail -n +#{skip + 1} #{file} 2>/dev/null || true")
    |> String.split("\n", trim: true)
  end

  defp pod_restarts do
    args = [
      "get",
      "pods",
      "-l",
      Bench.env("POD_SELECTOR", "cluster=smolquery"),
      "-o",
      "jsonpath={range .items[*]}{.metadata.name}={.status.containerStatuses[0].restartCount} {end}"
    ]

    case Bench.Kube.cmd(args) do
      {out, 0} ->
        out
        |> String.split(~r/\s+/, trim: true)
        |> Map.new(fn pair ->
          [pod, n] = String.split(pair, "=", parts: 2)
          {pod, String.to_integer(n)}
        end)

      _ ->
        %{}
    end
  end

  defp pod_anon_peaks(seconds) do
    deadline = System.monotonic_time(:second) + seconds
    pods = Bench.WatchPods.pods()
    anon_loop(pods, deadline, %{})
  end

  defp anon_loop(pods, deadline, peaks) do
    peaks =
      pods
      |> Task.async_stream(&{&1, pod_anon(&1)}, timeout: 30_000, on_timeout: :kill_task)
      |> Enum.reduce(peaks, fn
        {:ok, {pod, n}}, acc when is_integer(n) -> Map.update(acc, pod, n, &max(&1, n))
        _, acc -> acc
      end)

    if System.monotonic_time(:second) + 15 < deadline do
      Process.sleep(15_000)
      anon_loop(pods, deadline, peaks)
    else
      peaks
    end
  end

  defp pod_anon(pod) do
    script = "awk '/^anon /{print $2}' /sys/fs/cgroup/memory.stat"

    case Bench.Kube.cmd(["exec", pod, "-c", "smolquery", "--", "sh", "-c", script]) do
      {out, 0} ->
        case Integer.parse(String.trim(out)) do
          {n, _} -> n
          :error -> nil
        end

      _ ->
        nil
    end
  end

  defp parse_sample(line) do
    [t | pairs] = String.split(line)

    pairs
    |> Enum.flat_map(fn pair ->
      with [k, v] <- String.split(pair, "=", parts: 2),
           {n, _} <- Float.parse(v) do
        [{k, n}]
      else
        _ -> []
      end
    end)
    |> Map.new()
    |> Map.put("t", String.to_float(t))
  end

  defp vlogs_progress(target, bench, vl) do
    b = bench |> List.last() |> then(&if(&1, do: parse_sample(&1), else: %{}))
    v = vl |> List.last() |> then(&if(&1, do: parse_sample(&1), else: %{}))

    stored =
      Enum.map_join(@vlogs_systems, ", ", fn s ->
        "#{s} stored #{trunc(Map.get(b, "stored_rows:#{s}", 0))} " <>
          "dropped #{trunc(Map.get(b, "lines_dropped_total:#{s}", 0))} " <>
          "errors #{trunc(Map.get(b, "send_line_errors_total:#{s}", 0))}"
      end)

    "== step #{target}/s done: #{stored}; vl anon #{trunc(Map.get(v, "anon_kb", 0) / 1024)} MiB"
  end

  defp vlogs_summary(bench_lines, vl_lines, steps, restarts_before) do
    bench = Enum.map(bench_lines, &parse_sample/1)
    vl = Enum.map(vl_lines, &parse_sample/1)

    groups =
      bench
      |> Enum.filter(&Map.has_key?(&1, "target_rate"))
      |> Enum.chunk_by(&trunc(&1["target_rate"]))

    {rows, _} =
      Enum.map_reduce(groups, nil, fn group, prev ->
        window = if prev, do: [prev | group], else: group
        first = hd(window)
        last = List.last(group)
        target = trunc(last["target_rate"])
        dt = last["t"] - first["t"]
        step = Enum.find(steps, &(&1["target"] == target))

        row =
          if dt > 0 do
            %{
              "target" => target,
              "seconds" => Float.round(dt, 1),
              "victorialogs" =>
                Map.merge(
                  rates(window, "victorialogs"),
                  vl_step(vl, first["t"], last["t"], window)
                ),
              "smolquery" => Map.merge(rates(window, "smolquery"), sq_step(step, restarts_before))
            }
          end

        {row, last}
      end)

    rows = Enum.reject(rows, &is_nil/1)

    %{
      "steps" => rows,
      "ceiling" => Map.new(@vlogs_systems, &{&1, ceiling(rows, &1)})
    }
  end

  defp delta(first, last, k), do: Map.get(last, k, 0) - Map.get(first, k, 0)

  defp rates(window, s) do
    with_key = Enum.filter(window, &Map.has_key?(&1, "stored_rows:#{s}"))
    first = List.first(with_key) || hd(window)
    last = List.last(with_key) || List.last(window)
    dt = max(last["t"] - first["t"], 1.0)

    %{
      "stored_per_s" => round(delta(first, last, "stored_rows:#{s}") / dt),
      "sent_per_s" => round(delta(first, last, "lines_sent_total:#{s}") / dt),
      "dropped_per_s" => round(delta(first, last, "lines_dropped_total:#{s}") / dt),
      "send_errors" => trunc(delta(first, last, "send_line_errors_total:#{s}")),
      "send_retries" => trunc(delta(first, last, "send_retries_total:#{s}")),
      "stored_rows_end" => trunc(Map.get(last, "stored_rows:#{s}", 0))
    }
  end

  defp vl_step(vl, t0, t1, bench_window) do
    window = Enum.filter(vl, &(&1["t"] >= t0 - 8 and &1["t"] <= t1 + 8))

    case window do
      [a, _ | _] ->
        b = List.last(window)
        dt = b["t"] - a["t"]
        tck = a["tck"]
        with_key = Enum.filter(bench_window, &Map.has_key?(&1, "stored_rows:victorialogs"))

        stored =
          if with_key == [],
            do: 0,
            else: delta(hd(with_key), List.last(with_key), "stored_rows:victorialogs")

        written = delta(a, b, "wsec") * 512
        pids = window |> Enum.map(& &1["pid"]) |> Enum.uniq()

        %{
          "process_cores" => Float.round(delta(a, b, "ptick") / tck / dt, 2),
          "node_cores" => Float.round(delta(a, b, "nbusy") / tck / dt, 2),
          "anon_peak_gib" =>
            Float.round(Enum.max(Enum.map(window, & &1["anon_kb"])) / 1_048_576, 2),
          "disk_write_mib_s" => Float.round(written / dt / 1_048_576, 1),
          "disk_bytes_per_line" => if(stored > 0, do: round(written / stored), else: nil),
          "data_bytes" => trunc(b["du"]),
          "restarted" => length(pids) > 1 or Enum.any?(window, &(&1["ptick"] < 0))
        }

      _ ->
        %{}
    end
  end

  defp sq_step(nil, _restarts_before), do: %{}

  defp sq_step(step, restarts_before) do
    pods = step["pods"]["pods"] || []

    cores =
      pods
      |> Enum.group_by(&pod_role(&1["name"]))
      |> Map.new(fn {role, ps} ->
        {role, Float.round(Enum.sum(Enum.map(ps, &(&1["cpu_avg_pct"] || 0))) / 100, 2)}
      end)

    anon =
      step["anon_peak_bytes"]
      |> Enum.group_by(fn {pod, _} -> pod_role(pod) end, fn {_, n} -> n end)
      |> Map.new(fn {role, ns} -> {role, Float.round(Enum.sum(ns) / 1_073_741_824, 2)} end)

    restarts =
      step["restarts"]
      |> Enum.map(fn {pod, n} -> n - Map.get(restarts_before, pod, 0) end)
      |> Enum.sum()

    %{
      "cores" => cores,
      "cores_total" => Float.round(Enum.sum(Map.values(cores)), 2),
      "anon_peak_gib" => anon,
      "anon_peak_gib_total" => Float.round(Enum.sum(Map.values(anon)), 2),
      "restarts_since_start" => restarts,
      "restarted" => restarts > 0
    }
  end

  defp pod_role(name) do
    case Regex.run(~r/^smolquery-([a-z]+)-\d+$/, name) do
      [_, role] -> role
      _ -> name
    end
  end

  defp ceiling(rows, s) do
    rows
    |> Enum.take_while(&(not Map.get(&1[s], "restarted", false)))
    |> Enum.map(& &1[s]["stored_per_s"])
    |> Enum.max(fn -> 0 end)
  end

  defp vlogs_table(summary) do
    header =
      "| target | VL stored/s | VL cores | VL anon GiB | VL disk B/line | " <>
        "SQ stored/s | SQ cores | SQ anon GiB | SQ dropped/s | SQ restarts |\n" <>
        "|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|"

    rows =
      Enum.map(summary["steps"], fn r ->
        v = r["victorialogs"]
        q = r["smolquery"]

        "| #{r["target"]} | #{v["stored_per_s"]} | #{v["process_cores"]} | #{v["anon_peak_gib"]} | " <>
          "#{v["disk_bytes_per_line"]} | #{q["stored_per_s"]} | #{q["cores_total"]} | " <>
          "#{q["anon_peak_gib_total"]} | #{q["dropped_per_s"]} | #{q["restarts_since_start"]} |"
      end)

    ceilings =
      Enum.map_join(summary["ceiling"], ", ", fn {s, n} -> "#{s} #{n} lines/s" end)

    Enum.join([header | rows], "\n") <> "\n\nceiling: " <> ceilings
  end

  # ── down ───────────────────────────────────────────────────────────────────

  def down do
    case instance_id() do
      nil ->
        IO.puts("no #{@tag} instance to terminate")

      id ->
        aws!(["ec2", "terminate-instances", "--instance-ids", id])
        IO.puts("terminating #{id}")
    end
  end
end

Bench.Loadgen.main(System.argv())

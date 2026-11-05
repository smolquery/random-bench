#!/usr/bin/env bash
set -euo pipefail

pin="${LOGS_BENCHMARK_REF:-d6c59e92ae91ea845c55bfde4f0048bad566ed58}"
here="$(cd "$(dirname "$0")" && pwd)"
src="${1:-$here/logs-benchmark}"
out="${2:-$here/bench}"

if [ ! -d "$src/.git" ]; then
  git clone -q https://github.com/VictoriaMetrics/logs-benchmark "$src"
fi
git -C "$src" fetch -q origin "$pin" 2>/dev/null || true
git -C "$src" checkout -q --force "$pin"
git -C "$src" clean -qfd

cp "$here/smolquery.go" "$src/internal/systems/smolquery.go"
perl -0pi -e 's/(\tswitch sysType \{\n)/$1\tcase "smolquery":\n\t\treturn newSmolquery(addr)\n/g' "$src/internal/systems/systems.go"
test "$(grep -c 'case "smolquery"' "$src/internal/systems/systems.go")" = 2

(cd "$src" && GOTOOLCHAIN="${GOTOOLCHAIN:-auto}" go build -tags vlogs -o "$out" ./cmd/bench)
echo "built $out at $pin"

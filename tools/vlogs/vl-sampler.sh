#!/usr/bin/env bash
dir=/opt/vlogs
dev="$(cat "$dir/disk")"
tck="$(getconf CLK_TCK)"
while true; do
  t="$(date +%s.%N | cut -c1-14)"
  pid="$(systemctl show -p MainPID --value vlogs)"
  read -r _ u n s i w x y z _ < /proc/stat
  busy=$((u + n + s + x + y + z))
  total=$((busy + i + w))
  pt=-1
  anon=-1
  if [ "$pid" != 0 ] && [ -r "/proc/$pid/stat" ]; then
    pt="$(awk '{print $14 + $15}' "/proc/$pid/stat")"
    anon="$(awk '/^RssAnon/{print $2}' "/proc/$pid/status")"
  fi
  wsec="$(awk -v d="$dev" '$3 == d {print $10}' /proc/diskstats)"
  du="$(du -sb /data/vl 2>/dev/null | cut -f1)"
  echo "$t pid=$pid ptick=$pt tck=$tck nbusy=$busy ntotal=$total anon_kb=$anon wsec=$wsec du=$du"
  sleep 15
done >> "$dir/samples.txt"
